#!/usr/bin/env bash
# Irys Storage - Install + Upload helper
# Compatibilité : Ubuntu 20.04 / 22.04 / 24.04
# Auteur : EasyNode helper
# Sécurité : ne JAMAIS afficher la clé privée. Ce script n'imprime jamais la clé
#           et évite de la logger (stdout/stderr). Attention : passer une clé en argument
#           à un processus peut apparaître dans la table des processus pour l'utilisateur courant.
#           Utilisez un wallet généré si possible.

set -Eeuo pipefail
IFS=$'\n\t'

############################################
# Utilitaires & gestion d'erreurs
############################################
abort() {
  echo "❌ Erreur : $*" >&2
  exit 1
}

trap 'abort "Une erreur non gérée est survenue. Consultez les messages ci-dessus."' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || abort "Commande requise manquante : $1"
}

confirm() {
  # confirm "Message"  (Y/n)
  local msg="${1:-Continuer ?}"
  read -r -p "$msg [Y/n] " resp || true
  case "${resp:-Y}" in
    Y|y|O|o|Yes|yes|"" ) return 0 ;;
    * ) return 1 ;;
  esac
}

ask() {
  # ask "Question" "default"
  local q="${1:-}"; local def="${2:-}"
  local prompt="$q"
  [[ -n "$def" ]] && prompt+=" ($def)"
  prompt+=" : "
  read -r -p "$prompt" ans || true
  echo "${ans:-$def}"
}

ask_secret() {
  # ask_secret "Question"
  local q="${1:-Entrer une valeur secrète}"
  read -r -s -p "$q : " ans || true
  echo
  echo "$ans"
}

############################################
# Vérifs préalables (sudo, OS)
############################################
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    abort "Ce script nécessite les privilèges administrateur. Installez sudo ou exécutez en root."
  fi
else
  SUDO=""
fi

for f in /etc/os-release /etc/lsb-release; do
  [[ -f "$f" ]] && . "$f"
done
UBU_VER="${VERSION_ID:-unknown}"
case "$UBU_VER" in
  20.04|22.04|24.04) : ;;
  *) echo "⚠️ Ubuntu détecté : $PRETTY_NAME. Le script est testé sur 20.04/22.04/24.04." ;;
esac

############################################
# Logs (optionnels)
############################################
LOG_CHOICE=$(ask "Voulez-vous créer un dossier de logs ?" "oui")
if [[ "$LOG_CHOICE" =~ ^(o|O|y|Y|oui|Yes)$ ]]; then
  LOG_DIR="${HOME}/irys-logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
  # Rediriger les sorties générales vers le log (mais pas les saisies secrètes)
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "🗒️  Les logs seront enregistrés ici : $LOG_FILE"
fi

############################################
# Mise à jour système & dépendances
############################################
echo "🔧 Mise à jour du système (apt-get update/upgrade)..."
$SUDO apt-get update -y
$SUDO DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "📦 Installation des paquets requis (curl, git, build-essential, jq, imagemagick, openssl, ca-certificates, gnupg)..."
$SUDO apt-get install -y curl git build-essential jq imagemagick openssl ca-certificates gnupg

############################################
# Installation Node.js 20.x + npm
############################################
install_node() {
  echo "⬇️ Installation de Node.js 20.x (NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
}

if command -v node >/dev/null 2>&1; then
  NODE_V=$(node -v | sed 's/^v//')
  NODE_MAJOR="${NODE_V%%.*}"
  if [[ "${NODE_MAJOR:-0}" -lt 20 ]]; then
    echo "ℹ️ Node.js ${NODE_V} détecté (<20). Mise à niveau vers Node 20..."
    install_node
  else
    echo "✅ Node.js $NODE_V OK (>=20)"
  fi
else
  install_node
fi

require_cmd node
require_cmd npm

echo "🔎 Versions : node=$(node -v) | npm=$(npm -v)"

############################################
# Installation Irys CLI
############################################
echo "⬇️ Installation Irys CLI global : @irys/cli ..."
# On tente sans sudo d'abord. Si ça échoue (permissions), on réessaie avec sudo.
if ! npm i -g @irys/cli >/dev/null 2>&1; then
  echo "⚠️ Requête d'élévation (sudo) pour installer la CLI globalement..."
  $SUDO npm i -g @irys/cli
fi

# Vérification binaire
if ! command -v irys >/dev/null 2>&1; then
  abort "Irys CLI introuvable après installation."
fi
echo "✅ Irys CLI installée : $(irys --version 2>/dev/null || echo 'version inconnue')"

############################################
# Préparation utilitaires Node (ethers) pour clés/addresses
############################################
WORKDIR="$(mktemp -d -t irys-node-XXXXXX)"
cleanup() { rm -rf "$WORKDIR" || true; }
trap cleanup EXIT

pushd "$WORKDIR" >/dev/null
npm init -y >/dev/null 2>&1
npm install ethers@6 >/dev/null 2>&1
popd >/dev/null

node_derive() {
  # $1 = PRIVATE_KEY (optionnel). Si absent => génération aléatoire
  node -e 'const {Wallet}=require("'"$WORKDIR"'/node_modules/ethers"); 
    const pk=process.env.PK;
    if(pk){ 
      try{ const w=new Wallet(pk); 
        console.log(JSON.stringify({address:w.address})); 
      }catch(e){ console.error("invalid"); process.exit(1); }
    } else { 
      const w=Wallet.createRandom(); 
      console.log(JSON.stringify({address:w.address, privateKey:w.privateKey, mnemonic:(w.mnemonic?.phrase||"")}));
    }' 2>/dev/null
}

############################################
# Paramétrage : réseau, RPC, token
############################################
echo "🌐 Choix du réseau Irys pour la facturation (token EVM)."
IRYS_NET=$(ask "Réseau : mainnet ou devnet ?" "devnet")
case "$IRYS_NET" in
  mainnet|MAINNET) IRYS_NET="mainnet" ;;
  devnet|DEVNET|"") IRYS_NET="devnet" ;;
  *) echo "Valeur inconnue, bascule sur devnet."; IRYS_NET="devnet" ;;
esac

# Token (EVM). Par défaut 'ethereum'
TOKEN=$(ask "Token de paiement (EVM) (ex: ethereum, base-eth, linea-eth, polygon, arbitrum, scroll, ...)" "ethereum")

# RPC URL (utile surtout en devnet). Valeur par défaut pour Sepolia.
DEFAULT_RPC="https://rpc.sepolia.dev"
if [[ "$IRYS_NET" == "devnet" ]]; then
  RPC_URL=$(ask "RPC URL (devnet) à utiliser (laisser vide pour défaut)" "$DEFAULT_RPC")
else
  RPC_URL=$(ask "RPC URL (mainnet) à utiliser (optionnel, Enter pour ignorer)" "")
fi

############################################
# Wallet : fourniture clé privée OU génération
############################################
echo "🔐 Choisissez une option de wallet :"
echo "  1) J'ai déjà une clé privée (EVM, hex 0x...)"
echo "  2) Générer un nouveau wallet (recommandé pour débuter)"
CHOICE=$(ask "Votre choix" "2")

PRIVATE_KEY=""
ADDRESS=""
MNEMONIC=""

if [[ "$CHOICE" == "1" ]]; then
  PRIVATE_KEY=$(ask_secret "➡️  Entrez votre clé privée EVM (elle ne sera pas affichée)")
  [[ -z "$PRIVATE_KEY" ]] && abort "Clé privée vide."
  # Deriver l'adresse depuis la clé (Node + ethers)
  ADDR_JSON="$(PK="$PRIVATE_KEY" node_derive || true)"
  [[ "$ADDR_JSON" == "invalid" || -z "$ADDR_JSON" ]] && abort "Clé privée invalide."
  ADDRESS="$(echo "$ADDR_JSON" | jq -r '.address')"
  echo "✅ Adresse dérivée : $ADDRESS"
else
  echo "🪪 Génération d'un wallet..."
  GEN_JSON="$(node_derive)"
  ADDRESS="$(echo "$GEN_JSON" | jq -r '.address')"
  PRIVATE_KEY="$(echo "$GEN_JSON" | jq -r '.privateKey')"
  MNEMONIC="$(echo "$GEN_JSON" | jq -r '.mnemonic')"
  echo "✅ Nouveau wallet : $ADDRESS"
  # Sauvegarde sûre dans le HOME (chmod 600)
  SEC_DIR="${HOME}/.irys-wallet"
  mkdir -p "$SEC_DIR"
  WALLET_FILE="${SEC_DIR}/wallet_$(date +%Y%m%d_%H%M%S).json"
  umask 077
  cat > "$WALLET_FILE" <<JSON
{"address":"$ADDRESS","privateKey":"$PRIVATE_KEY","mnemonic":"$MNEMONIC"}
JSON
  chmod 600 "$WALLET_FILE"
  echo "🔒 Clés sauvegardées en local (chmod 600) : $WALLET_FILE"
  echo "ℹ️  Gardez-les en sécurité. Ne partagez jamais votre clé privée."
fi

############################################
# Vérification du solde Irys (via CLI)
############################################
echo "💰 Vérification du solde (Irys balance) pour $ADDRESS ..."
BAL_ARGS=(-t "$TOKEN")
[[ "$IRYS_NET" == "devnet" ]] && BAL_ARGS+=(-n devnet)
[[ -n "${RPC_URL:-}" ]] && BAL_ARGS+=(--provider-url "$RPC_URL")

# balance ne nécessite pas la clé privée
if ! irys balance "$ADDRESS" "${BAL_ARGS[@]}"; then
  echo "⚠️ Impossible de lire le solde. Vérifiez la connexion réseau / RPC."
fi

echo
echo "👉 Si votre solde est insuffisant :"
echo "   - Réalisez un faucet/approvisionnement sur l'adresse : $ADDRESS"
if [[ "$IRYS_NET" == "devnet" ]]; then
  echo "   - Réseau devnet (ex: Sepolia). Un RPC par défaut est configuré."
fi
confirm "Avez-vous des fonds suffisants pour l’upload (sinon, pressez 'n' et refaites un faucet) ?" || {
  echo "ℹ️  Annulation à votre demande. Relancez le script après avoir crédité le wallet."
  exit 0
}

############################################
# Sélection du contenu à uploader
############################################
echo "🖼️ Que souhaitez-vous uploader ?"
echo "  1) Un fichier"
echo "  2) Un dossier"
echo "  3) Générer une image aléatoire (PNG 512x512) et l'uploader"
SEL=$(ask "Votre choix" "3")

TARGET_PATH=""
CONTENT_TYPE=""

case "$SEL" in
  1)
    TARGET_PATH="$(ask "Chemin du fichier à uploader (ex: /home/USER/image.png)" "")"
    [[ -z "$TARGET_PATH" || ! -f "$TARGET_PATH" ]] && abort "Fichier introuvable : $TARGET_PATH"
    # Tentative de détection Content-Type simple
    case "${TARGET_PATH##*.}" in
      png) CONTENT_TYPE="image/png" ;;
      jpg|jpeg) CONTENT_TYPE="image/jpeg" ;;
      gif) CONTENT_TYPE="image/gif" ;;
      json) CONTENT_TYPE="application/json" ;;
      *) CONTENT_TYPE="" ;;
    esac
    ;;
  2)
    TARGET_PATH="$(ask "Chemin du dossier à uploader (ex: /home/USER/mon_dossier)" "")"
    [[ -z "$TARGET_PATH" || ! -d "$TARGET_PATH" ]] && abort "Dossier introuvable : $TARGET_PATH"
    ;;
  3|*)
    # Génération image aléatoire
    RAND_DIR="${HOME}/irys-uploads"
    mkdir -p "$RAND_DIR"
    TARGET_PATH="${RAND_DIR}/random_$(date +%Y%m%d_%H%M%S).png"
    # ImageMagick : créer une image bruitée aléatoire 512x512
    echo "🧪 Génération d'une image aléatoire : $TARGET_PATH"
    convert -size 512x512 xc:white +noise Random "$TARGET_PATH"
    [[ ! -f "$TARGET_PATH" ]] && abort "Echec génération de l'image."
    CONTENT_TYPE="image/png"
    ;;
esac

############################################
# Upload avec Irys CLI
############################################
echo "🚀 Upload en cours via Irys CLI..."
UP_ARGS=(-t "$TOKEN")
[[ "$IRYS_NET" == "devnet" ]] && UP_ARGS+=(-n devnet)
[[ -n "${RPC_URL:-}" ]] && UP_ARGS+=(--provider-url "$RPC_URL")

# IMPORTANT : on n'affiche pas la clé privée, ni la commande complète.
# La CLI exige -w <clé>. On imprime uniquement des messages neutres.
if [[ -f "$TARGET_PATH" ]]; then
  echo "   • Fichier : $TARGET_PATH"
  # Optionnel : ajouter un tag Content-Type si connu
  if [[ -n "$CONTENT_TYPE" ]]; then
    echo "   • Tag Content-Type : $CONTENT_TYPE"
    # On exécute la commande en silence (sans écho de la clé), seules les sorties de la CLI seront visibles
    irys upload "$TARGET_PATH" "${UP_ARGS[@]}" -w "$PRIVATE_KEY" --tags "Content-Type $CONTENT_TYPE"
  else
    irys upload "$TARGET_PATH" "${UP_ARGS[@]}" -w "$PRIVATE_KEY"
  fi
else
  echo "   • Dossier : $TARGET_PATH"
  irys upload-dir "$TARGET_PATH" "${UP_ARGS[@]}" -w "$PRIVATE_KEY"
fi

echo
echo "✅ Terminé."
echo "🔗 Si la CLI a affiché une URL gateway.irys.xyz, c'est votre lien de téléchargement."
echo "💡 Astuce : Conservez votre fichier wallet ($SEC_DIR) si vous avez généré une clé."
echo "🛡️  Sécurité : Ne partagez JAMAIS votre clé privée."
