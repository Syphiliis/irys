Irys One-Click Uploader (Devnet / Sepolia)

Beginner-friendly one-click script to install the Irys CLI, set up (or reuse) an EVM wallet, auto-fund your Irys balance from Sepolia ETH, and upload a file, folder, or a random image — on Ubuntu 20.04 / 22.04 / 24.04.

🧪 Network: Irys devnet
🔗 RPC: https://ethereum-sepolia-rpc.publicnode.com
🧰 No prior blockchain or Node.js knowledge required

Features
✅ System prep: installs curl, git, build-essential, jq, imagemagick, openssl, ca-certificates, gnupg
✅ Installs Node.js 20.x and the Irys CLI (@irys/cli)
✅ Wallet handling:
Auto-detect existing wallets in ~/.irys-wallet/
Import private key (hidden input) or generate a new wallet (saved locally, chmod 600)
✅ Balance checks:
Sepolia ETH via JSON-RPC (curl + jq)
Irys on-node balance via irys balance

✅ Auto-fund Irys if needed:
Uses 70% of the wallet balance
Keeps a dynamic gas reserve = min(10% of wallet, 0.0005 ETH)
Enforces a small minimum fund (0.00005 ETH) when possible
Rechecks Irys balance before uploading

✅ Upload options:

Single file (irys upload) with proper --content-type
Directory (irys upload-dir)
Random image (via ImageMagick; falls back to a tiny PNG if not available)

Quick Start

Run:

chmod +x irys.sh
./irys.sh


Follow the prompts to:

reuse a detected wallet or import / generate one,
auto-fund Irys from your Sepolia ETH if your Irys balance is 0,
choose what to upload (file, folder, or random image).




Security Notes

Generated keys are stored locally with restrictive permissions.
Never commit your wallet files or private key to GitHub.
This script is intended for dev/test (Sepolia + Irys devnet).
Do not reuse test keys for mainnet.


Acknowledgements

Irys Storage — Docs & CLI

Sepolia public RPC: https://ethereum-sepolia-rpc.publicnode.com

Faucet (Sepolia test ETH): https://sepolia-faucet.pk910.de/

⭐ If this helps, please star the repo and open issues/PRs for improvements!
