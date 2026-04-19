#!/bin/bash
# Update bot panel from GitHub and reload service
set -euo pipefail

REPO_DIR=/opt/botpanel
TOKEN_FILE=/opt/botpanel/.gh_token

# Use stored token if available
if [[ -f "$TOKEN_FILE" ]]; then
  GH_TOKEN=$(cat "$TOKEN_FILE")
  git -C "$REPO_DIR" remote set-url origin "https://${GH_TOKEN}@github.com/adamzolo/bot_panel.git"
fi

echo "[update] Pulling latest changes from GitHub..."
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
git -C "$REPO_DIR" pull origin main

# Restore clean URL (no token in stored remote)
git -C "$REPO_DIR" remote set-url origin "https://github.com/adamzolo/bot_panel.git"

echo "[update] Restarting botpanel service..."
systemctl restart botpanel

echo "[update] Done."
