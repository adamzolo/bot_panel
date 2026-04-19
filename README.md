# Bot Manager Panel

Web-based panel for managing Telegram/Discord/WhatsApp/Viber bots on a VPS.

## Installation

Run on a fresh Ubuntu/Debian server as root:

```bash
curl -sL https://raw.githubusercontent.com/adamzolo/bot_panel/main/install.sh | sudo bash
```

The installer will:
1. Install Node.js, Python, Nginx and other dependencies
2. Clone this repo to `/opt/botpanel`
3. Set up a systemd service (`botpanel`)
4. Configure Nginx reverse proxy with self-signed SSL
5. Ask you to set an admin password

## Updating the server

**Manual update:**
```bash
sudo /opt/botpanel/update.sh
```

**What it does:** `git pull origin main` + `systemctl restart botpanel`

## Local development

Clone the repo and edit the source files directly:

```bash
git clone https://github.com/adamzolo/bot_panel.git
cd bot_panel

# Edit backend
nano app/server.js

# Edit frontend
nano static/index.html

# Push changes
git add app/server.js static/index.html
git commit -m "your changes"
git push origin main
```

Then on the server run `sudo /opt/botpanel/update.sh` to deploy.

## Project structure

```
bot_panel/
├── app/
│   └── server.js       # Node.js backend (Express-like, no framework)
├── static/
│   └── index.html      # Single-page frontend (vanilla JS)
├── install.sh          # Installer: clones repo, sets up systemd + nginx
├── update.sh           # Updater: git pull + service restart
└── README.md
```

## Features

- Multi-language bot support: Python, Node.js, PHP, Ruby
- Multi-platform: Telegram, Discord, WhatsApp, Viber
- File manager (upload, download, edit, delete)
- Live log streaming
- Start/stop/restart bots
- Backup & restore (.zip)
- GitHub import for projects
- Dark/light theme, multilingual (RU/UA/EN)
- Onboarding tour for new users
