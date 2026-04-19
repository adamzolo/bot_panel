#!/bin/bash
# Update bot panel from GitHub and reload service
set -euo pipefail

REPO_DIR=/opt/botpanel

echo "[update] Pulling latest changes from GitHub..."
cd "$REPO_DIR"
git pull origin main

echo "[update] Restarting botpanel service..."
systemctl restart botpanel

echo "[update] Done. Updated and restarted."
