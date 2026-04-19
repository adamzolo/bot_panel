#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║  Bot Manager — Final Clean Installer                     ║
# ║  Telegram / Discord / WhatsApp / Viber                   ║
# ║  Python / Node.js / PHP / Ruby                           ║
# ╚══════════════════════════════════════════════════════════╝
set -euo pipefail; IFS=$'\n\t'
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'
ok()   { echo -e "${G}[OK]${N}  $1"; }
info() { echo -e "${C}[..]${N}  $1"; }
warn() { echo -e "${Y}[!!]${N}  $1"; }
die()  { echo -e "${R}[XX]${N}  $1"; exit 1; }

PD=/opt/botpanel; BD=/opt/botpanel/bots; VE=/opt/botpanel/venv
SS=/opt/botpanel/ssl; BK=/opt/botpanel_backups; IC=/opt/botpanel/.last_ip
RU=botpanel; PO=8080; UPD=0; NOSSL=0
TOK=""; SK=""; HP=""; PP=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in --update) UPD=1;shift;; --no-ssl) NOSSL=1;shift;;
      --help) echo "sudo bash install.sh [--update] [--no-ssl]";exit 0;;
      *) die "Unknown: $1";; esac; done; }

detect_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS"
  . /etc/os-release; OS=$ID; OL="${ID_LIKE:-}"; info "OS: $OS ${VERSION_ID:-}"; }

install_pkgs() {
  info "Installing system packages..."

  # ── STEP 1: Kill Apache BEFORE installing anything ──────
  # php packages trigger apache restart via triggers — stop it first
  info "Checking for conflicting web servers..."
  for svc in apache2 httpd lighttpd; do
    systemctl stop $svc 2>/dev/null||true
    systemctl disable $svc 2>/dev/null||true
    systemctl mask $svc 2>/dev/null||true
  done
  # Kill anything on port 80/443 right now
  command -v fuser &>/dev/null && {
    fuser -k 80/tcp 2>/dev/null||true
    fuser -k 443/tcp 2>/dev/null||true
  }||true

  # ── STEP 2: Install packages ─────────────────────────────
  if [[ "$OS" == ubuntu || "$OS" == debian || "$OL" == *debian* ]]; then
    apt-get update -qq
    # Install base packages WITHOUT apache-related php modules
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      python3 python3-pip python3-venv python3-dev build-essential \
      nginx curl openssl rsync psmisc net-tools \
      ruby ruby-dev libyaml-dev libssl-dev libffi-dev zlib1g-dev gcc make 2>/dev/null
    # Install PHP CLI only (no apache module!)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      php-cli php-curl php-json php-mbstring 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      php-cli 2>/dev/null || true
    # Node.js 20.x
    if ! command -v node &>/dev/null; then
      info "Installing Node.js 20.x..."
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
      apt-get install -y -qq nodejs 2>/dev/null
    fi
  else
    dnf install -y --setopt=install_weak_deps=False \
      python3 python3-pip python3-devel nginx curl openssl rsync psmisc \
      net-tools ruby ruby-devel gcc make 2>/dev/null || \
    yum install -y python3 python3-pip python3-devel nginx curl openssl rsync psmisc \
      net-tools ruby ruby-devel gcc make 2>/dev/null||true
    dnf install -y php-cli php-json 2>/dev/null || \
    yum install -y php-cli php-json 2>/dev/null||true
    if ! command -v node &>/dev/null; then
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
      dnf install -y nodejs 2>/dev/null || yum install -y nodejs 2>/dev/null||true
    fi
  fi

  # ── STEP 3: Make sure apache stays dead after php installed ─
  for svc in apache2 httpd; do
    systemctl stop $svc 2>/dev/null||true
    systemctl mask $svc 2>/dev/null||true
  done

  # ── STEP 4: Ruby gems — install globally ─────────────────
  # Ruby gems installed separately after dirs are created (see install_ruby_gems)
  ok "Ruby system packages ready"


  # ── STEP 5: Node.js packages — install globally ──────────
  if command -v npm &>/dev/null; then
    info "Installing Node.js packages globally..."
    npm install -g --silent node-telegram-bot-api 2>/dev/null && ok "  node-telegram-bot-api: OK" || warn "  node-telegram-bot-api: failed"
    npm install -g --silent discord.js 2>/dev/null && ok "  discord.js: OK" || warn "  discord.js: failed"
    npm install -g --silent express axios 2>/dev/null && ok "  express/axios: OK" || warn "  express/axios: failed"
  fi

  # ── STEP 6: Show installed versions ──────────────────────
  echo ""
  ok "Installed versions:"
  python3 --version 2>/dev/null||echo "  python3: not found"
  node --version 2>/dev/null && echo -n "  node: " || echo "  node: not found"
  ruby --version 2>/dev/null||echo "  ruby: not found"
  php --version 2>/dev/null|head -1||echo "  php: not found"
  echo ""
}


get_ip() {
  local ip
  ip=$(curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)  && [[ -n "$ip" ]] && echo "$ip" && return
  hostname -I | awk '{print $1}'; }

create_user() {
  id "$RU" &>/dev/null || useradd --system --no-create-home \
    --shell /usr/sbin/nologin --home-dir "$PD" "$RU"
  local SF="/etc/sudoers.d/botpanel"
  cat > "$SF" << 'SUDEOF'
botpanel ALL=(ALL) NOPASSWD: /usr/sbin/reboot
botpanel ALL=(ALL) NOPASSWD: /bin/systemctl reboot
botpanel ALL=(ALL) NOPASSWD: /bin/systemctl restart botpanel
botpanel ALL=(ALL) NOPASSWD: /bin/systemctl start botpanel
botpanel ALL=(ALL) NOPASSWD: /bin/systemctl stop botpanel
SUDEOF
  chmod 440 "$SF"
  ok "User '$RU' + sudoers for power management"; }

ask_password() {
  [[ -n "$PP" ]] && return
  echo -e "\n${Y}Set admin password (for emergency console access):${N}"
  while true; do
    read -s -rp "Password: " P1; echo; read -s -rp "Confirm:  " P2; echo
    [[ "$P1" == "$P2" && ${#P1} -ge 4 ]] && PP="$P1" && break; warn "Mismatch or too short"; done; }

mk_dirs() {
  mkdir -p "$PD"/{app,static,bots,bots_venv} "$BK" "$SS"
  chmod 750 "$PD"; ok "Dirs ready"; }

mk_venv() {
  info "Python venv..."
  python3 -m venv "$VE"
  "$VE/bin/pip" install --upgrade pip -q
  "$VE/bin/pip" install flask flask-cors pyjwt bcrypt psutil requests -q
  ok "Venv ready"; }

install_ruby_gems() {
  # Install Ruby gems to /usr/local/bundle (world-readable, survives user changes)
  RUBY_GEM_DIR=/usr/local/bundle
  mkdir -p "$RUBY_GEM_DIR"
  chmod 755 "$RUBY_GEM_DIR"
  GEM_INSTALL="gem install --no-document --quiet --install-dir $RUBY_GEM_DIR"
  export GEM_PATH="$RUBY_GEM_DIR:$(gem environment gempath 2>/dev/null||true)"
  info "Installing Ruby gems (may take 1-2 min)..."
  # Test connectivity first
  if curl -s --connect-timeout 5 https://rubygems.org > /dev/null 2>&1; then
    $GEM_INSTALL bundler         2>/dev/null && ok "  bundler: OK"           || warn "  bundler: failed"
    $GEM_INSTALL telegram-bot-ruby 2>/dev/null && ok "  telegram-bot-ruby: OK" || warn "  telegram-bot-ruby: failed"
    $GEM_INSTALL discordrb       2>/dev/null && ok "  discordrb: OK"         || warn "  discordrb: failed"
    $GEM_INSTALL sinatra rack    2>/dev/null && ok "  sinatra+rack: OK"      || warn "  sinatra: failed"
    $GEM_INSTALL httparty        2>/dev/null && ok "  httparty: OK"          || warn "  httparty: failed"
  else
    warn "rubygems.org unreachable — gems will install on first bot start"
    warn "Or run manually: gem install --install-dir /usr/local/bundle telegram-bot-ruby"
  fi
  # Save gem dir path so server.py can find it
  echo "$RUBY_GEM_DIR" > "$PD/.ruby_gem_dir" 2>/dev/null||true
  ok "Ruby gem dir: $RUBY_GEM_DIR"
}

hash_pw() {
  HP=$(python3 -c "import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt()).decode())" "$PP"); }

gen_cert() {
  local IP="${1:-127.0.0.1}"
  info "Self-signed cert for $IP (10yr)..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$SS/key.pem" -out "$SS/cert.pem" -days 3650 \
    -subj "/CN=${IP}/O=BotManager/C=UA" \
    -addext "subjectAltName=IP:${IP},IP:127.0.0.1" 2>/dev/null
  chmod 640 "$SS/key.pem" "$SS/cert.pem"
  chown "root:$RU" "$SS/key.pem" "$SS/cert.pem" 2>/dev/null || true
  echo "$IP" > "$IC"; ok "Cert ready"; }

open_fw() {
  if command -v ufw &>/dev/null; then
    ufw allow 80/tcp 2>/dev/null||true; ufw allow 443/tcp 2>/dev/null||true; ok "ufw: 80+443"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service={http,https} 2>/dev/null||true
    firewall-cmd --reload 2>/dev/null||true; ok "firewalld"; fi; }

# ══════════════════════════════════════════
# Nginx
# ══════════════════════════════════════════
write_nginx() {
  info "Nginx..."
  # Stop Apache if running — conflicts with nginx on port 80/443
  if systemctl is-active --quiet apache2 2>/dev/null; then
    warn "Apache2 detected — stopping and disabling..."
    systemctl stop apache2 2>/dev/null||true
    systemctl disable apache2 2>/dev/null||true
    ok "Apache2 stopped"
  fi
  if systemctl is-active --quiet httpd 2>/dev/null; then
    warn "HTTPD detected — stopping and disabling..."
    systemctl stop httpd 2>/dev/null||true
    systemctl disable httpd 2>/dev/null||true
    ok "HTTPD stopped"
  fi
  # Free port 80/443 if anything else is using it
  command -v fuser &>/dev/null && {
    fuser -k 80/tcp 2>/dev/null||true
    fuser -k 443/tcp 2>/dev/null||true
  } || true
  for f in /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; do
    [[ -f "$f" ]] && mv "$f" "${f}.bak" 2>/dev/null||true; done
  if [[ -d /etc/nginx/sites-enabled ]]; then CF=/etc/nginx/sites-available/botpanel; LK=/etc/nginx/sites-enabled/botpanel
  else CF=/etc/nginx/conf.d/botpanel.conf; LK=""; fi
  if [[ $NOSSL -eq 0 ]]; then
    cat > "$CF" << 'NGEOF'
limit_req_zone  $binary_remote_addr zone=api:10m   rate=60r/s;
limit_req_zone  $binary_remote_addr zone=tok:10m   rate=30r/m;
limit_conn_zone $binary_remote_addr zone=con:10m;
server { listen 80; listen [::]:80; server_name _; return 301 https://$host$request_uri; }
server {
    listen 443 ssl http2; listen [::]:443 ssl http2; server_name _;
    ssl_certificate     /opt/botpanel/ssl/cert.pem;
    ssl_certificate_key /opt/botpanel/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d; server_tokens off;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    client_max_body_size 50M;
    gzip on; gzip_vary on; gzip_types application/json text/plain text/css application/javascript;
    location ~ ^/api/.*/logs$ {
        limit_req zone=api burst=10 nodelay; limit_conn con 20;
        proxy_pass http://127.0.0.1:5000; proxy_http_version 1.1;
        proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https; proxy_set_header Connection "";
        proxy_buffering off; proxy_cache off; chunked_transfer_encoding on; proxy_read_timeout 3600s; }
    # Webhook proxy — for WhatsApp/Viber bots
    location ~ ^/webhook/(.+) {
        limit_req zone=api burst=20 nodelay; limit_conn con 30;
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 60s; }
    location / {
        limit_req zone=api burst=40 nodelay; limit_conn con 50;
        proxy_pass http://127.0.0.1:5000; proxy_http_version 1.1;
        proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https; proxy_read_timeout 120s; } }
NGEOF
  else
    cat > "$CF" << 'NGEOF'
limit_req_zone  $binary_remote_addr zone=api:10m rate=60r/s;
limit_conn_zone $binary_remote_addr zone=con:10m;
server { listen 8080; server_name _; server_tokens off; client_max_body_size 50M;
    add_header X-Frame-Options DENY always; add_header X-Content-Type-Options nosniff always;
    location ~ ^/api/.*/logs$ { limit_req zone=api burst=10 nodelay;
        proxy_pass http://127.0.0.1:5000; proxy_http_version 1.1;
        proxy_set_header Host $host; proxy_set_header Connection "";
        proxy_buffering off; proxy_cache off; proxy_read_timeout 3600s; }
    location / { limit_req zone=api burst=40 nodelay; limit_conn con 50;
        proxy_pass http://127.0.0.1:5000; proxy_http_version 1.1;
        proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_read_timeout 120s; } }
NGEOF
  fi
  [[ -n "${LK:-}" ]] && ln -sf "$CF" "$LK"
  # Check port availability
  for port in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
      warn "Port $port is in use — attempting to free it..."
      fuser -k ${port}/tcp 2>/dev/null||true
      sleep 1
    fi
  done
  # Test nginx config
  if ! nginx -t 2>/tmp/nginx_test.log; then
    warn "Nginx config test failed:"
    cat /tmp/nginx_test.log
    die "Fix nginx config issue above"
  fi
  systemctl restart nginx && systemctl enable nginx
  ok "Nginx ready (port 80→443)"; }

# ══════════════════════════════════════════
# IP Watcher
# ══════════════════════════════════════════
write_ipwatch() {
  info "IP watcher..."
  cat > /opt/botpanel/ipwatch.sh << 'WEOF'
#!/bin/bash
set -euo pipefail
LOG=/var/log/botpanel-ipwatch.log; CACHE=/opt/botpanel/.last_ip; SSL=/opt/botpanel/ssl
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"|tee -a "$LOG"; }
get_ip() {
  local ip
  ip=$(curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null)&&[[ -n "$ip" ]]&&echo "$ip"&&return
  ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)&&[[ -n "$ip" ]]&&echo "$ip"&&return
  hostname -I|awk '{print $1}'; }
CUR=$(get_ip); OLD=$(cat "$CACHE" 2>/dev/null||echo "")
[[ "$CUR" == "$OLD" ]]&&exit 0
log "IP: $OLD -> $CUR"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$SSL/key.pem" -out "$SSL/cert.pem" -days 3650 \
  -subj "/CN=${CUR}/O=BotManager/C=UA" -addext "subjectAltName=IP:${CUR},IP:127.0.0.1" 2>/dev/null
chmod 640 "$SSL/key.pem" "$SSL/cert.pem"
chown "root:botpanel" "$SSL/key.pem" "$SSL/cert.pem" 2>/dev/null||true
echo "$CUR" > "$CACHE"
systemctl reload nginx 2>/dev/null||systemctl restart nginx 2>/dev/null||true
log "New cert for $CUR, nginx reloaded"
WEOF
  chmod +x /opt/botpanel/ipwatch.sh
  cat > /etc/systemd/system/botpanel-ipwatch.service << 'EOF'
[Unit]
Description=BotManager IP Watcher
After=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/botpanel/ipwatch.sh
EOF
  cat > /etc/systemd/system/botpanel-ipwatch.timer << 'EOF'
[Unit]
Description=BotManager IP Watcher timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now botpanel-ipwatch.timer; ok "IP watcher: every 5 min"; }

# ══════════════════════════════════════════
# Admin CLI
# ══════════════════════════════════════════
write_admin() {
  info "Admin CLI..."
  cat > /usr/local/bin/botmanager-admin << 'AEOF'
#!/bin/bash
set -euo pipefail
G='\033[0;32m'; C='\033[0;36m'; N='\033[0m'
SVC=/etc/systemd/system/botpanel.service
[[ $EUID -ne 0 ]]&&echo "Need root"&&exit 1
hp() { python3 -c "import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt()).decode())" "$1"; }
get_url() {
  IP=$(curl -4 -s --connect-timeout 5 https://ifconfig.me 2>/dev/null||hostname -I|awk '{print $1}')
  T=$(grep 'BOTPANEL_TOKEN=' "$SVC"|head -1|sed 's/.*BOTPANEL_TOKEN=//'|tr -d '"')
  echo "https://$IP/?token=$T"; }
case "${1:-help}" in
  --new-client)
    echo -e "${C}=== New client ===${N}"
    while true; do read -s -rp "Password: " P1;echo;read -s -rp "Confirm: " P2;echo
      [[ "$P1"=="$P2"&&${#P1} -ge 4 ]]&&break;echo "Retry";done
    H=$(hp "$P1"); T=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")
    S=$(python3 -c "import secrets;print(secrets.token_hex(32))")
    sed -i "s|BOTPANEL_HASH=.*|BOTPANEL_HASH=\"$H\"|" "$SVC"
    sed -i "s|BOTPANEL_TOKEN=.*|BOTPANEL_TOKEN=\"$T\"|" "$SVC"
    sed -i "s|BOTPANEL_SECRET=.*|BOTPANEL_SECRET=\"$S\"|" "$SVC"
    systemctl daemon-reload&&systemctl restart botpanel
    echo -e "\n${G}[OK]${N} Client ready\n  ${C}$(get_url)${N}\n";;
  --change-pass)
    while true; do read -s -rp "New password: " P1;echo;read -s -rp "Confirm: " P2;echo
      [[ "$P1"=="$P2"&&${#P1} -ge 4 ]]&&break;echo "Retry";done
    H=$(hp "$P1"); sed -i "s|BOTPANEL_HASH=.*|BOTPANEL_HASH=\"$H\"|" "$SVC"
    systemctl daemon-reload&&systemctl restart botpanel; echo -e "${G}[OK]${N} Password changed";;
  --regen-token)
    T=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")
    sed -i "s|BOTPANEL_TOKEN=.*|BOTPANEL_TOKEN=\"$T\"|" "$SVC"
    systemctl daemon-reload&&systemctl restart botpanel
    echo -e "${G}[OK]${N} New link:\n  ${C}$(get_url)${N}";;
  --show-token) echo -e "  ${C}$(get_url)${N}";;
  --status) systemctl status botpanel --no-pager;;
  *) echo "botmanager-admin: --new-client --change-pass --regen-token --show-token --status";;
esac
AEOF
  chmod +x /usr/local/bin/botmanager-admin; ok "botmanager-admin ready"; }

# ══════════════════════════════════════════
# Systemd service
# ══════════════════════════════════════════
write_svc() {
  info "Systemd service..."
  cat > /etc/systemd/system/botpanel.service << EOF
[Unit]
Description=Bot Manager
After=network.target
[Service]
Type=simple
User=${RU}
Group=${RU}
WorkingDirectory=${PD}/app
Environment="BOTPANEL_SECRET=${SK}"
Environment="BOTPANEL_HASH=${HP}"
Environment="BOTPANEL_TOKEN=${TOK}"
Environment="BOTS_DIR=${BD}"
Environment="PANEL_DIR=${PD}"
Environment="PORT=5000"
ExecStart=/usr/bin/node ${PD}/app/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${PD} ${BK}
ProtectHome=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload&&systemctl enable botpanel; ok "Service: user=$RU, sandboxed"; }


write_app() {
  info "Writing server.py..."
  cat > "$PD/app/server.py" 
# ════════════════════════════
# Write Node.js server
# ════════════════════════════
# ========================
# Deploy Node.js server (from cloned repo)
# ========================
write_node_server() {
  info "Deploying server.js from repo..."
  [[ -f "$PD/app/server.js" ]] || die "server.js not found in repo — run clone_or_update_repo first"
  chmod 640 "$PD/app/server.js"
  ok "server.js ready"
}

# ========================
# Clone or update repo from GitHub
# ========================
clone_or_update_repo() {
  local REPO_URL="https://github.com/adamzolo/bot_panel.git"
  if [[ -d "$PD/.git" ]]; then
    info "Updating from GitHub..."
    git -C "$PD" pull origin main || warn "Git pull failed, using existing files"
  else
    info "Cloning from GitHub..."
    git clone --depth=1 "$REPO_URL" "$PD" || die "Failed to clone repo"
  fi
}

# ========================
# Deploy app files (verify repo files exist)
# ========================
deploy_app() {
  info "Deploying app files from repo..."
  [[ -f "$PD/app/server.js" ]]    || die "server.js not found in repo"
  [[ -f "$PD/static/index.html" ]] || die "index.html not found in repo"
  chmod 640 "$PD/app/server.js"
  ok "App files ready from repo"
}


# ════════════════════════════
# Write index.html
# ════════════════════════════
# ========================
# Deploy frontend (from cloned repo)
# ========================
write_frontend() {
  info "Deploying index.html from repo..."
  [[ -f "$PD/static/index.html" ]] || die "index.html not found in repo — run clone_or_update_repo first"
  ok "index.html ready"
}


run_update() {
  info "=== UPDATE ==="
  local TS; TS=$(date +%Y%m%d_%H%M%S)
  mkdir -p "$BK"
  [[ -d "$PD" ]] && rsync -a --exclude='bots/' --exclude='bots_venv/' "$PD/" "$BK/backup_$TS/" 2>/dev/null||true
  ok "Backup → $BK/backup_$TS"
  if [[ -f /etc/systemd/system/botpanel.service ]]; then
    _S=$(grep 'BOTPANEL_SECRET=' /etc/systemd/system/botpanel.service|head -1|sed 's/.*BOTPANEL_SECRET=//'|tr -d '"')
    _H=$(grep 'BOTPANEL_HASH='  /etc/systemd/system/botpanel.service|head -1|sed 's/.*BOTPANEL_HASH=//'  |tr -d '"')
    _T=$(grep 'BOTPANEL_TOKEN=' /etc/systemd/system/botpanel.service|head -1|sed 's/.*BOTPANEL_TOKEN=/' |tr -d '"')
    [[ -n "${_S:-}" ]]&&SK="$_S"; [[ -n "${_H:-}" ]]&&HP="$_H"&&PP="***"; [[ -n "${_T:-}" ]]&&TOK="$_T"
    info "Credentials preserved"
  fi
  systemctl stop botpanel 2>/dev/null||true
  mkdir -p "$PD"/{bots,bots_venv}
  install_pkgs
  install_ruby_gems
  clone_or_update_repo
  deploy_app
  write_svc; write_admin; write_nginx; write_ipwatch
  chown -R "$RU:$RU" "$PD"; chmod -R 750 "$PD"
  systemctl daemon-reload&&systemctl restart botpanel
  sleep 2
  systemctl is-active --quiet botpanel&&ok "Updated!"||warn "Check: journalctl -u botpanel -n 30"
}

print_summary() {
  local IP; IP=$(get_ip 2>/dev/null||echo "?")
  local URL; [[ $NOSSL -eq 0 ]]&&URL="https://$IP"||URL="http://$IP:$PO"
  echo ""
  echo -e "${G}╔═══════════════════════════════════════════════╗${N}"
  echo -e "${G}║      Bot Manager — Ready!                     ║${N}"
  echo -e "${G}╚═══════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  Panel:   ${C}${URL}${N}"
  echo ""
  echo -e "  ${Y}Access link (no password needed):${N}"
  echo -e "  ${C}${URL}/?token=${TOK}${N}"
  echo ""
  [[ $NOSSL -eq 0 ]]&&echo -e "  SSL: Self-signed (browser: Accept risk)"
  echo -e "  IP watch: auto-recert on IP change (every 5 min)"
  echo ""
  echo -e "  User: $RU (no shell, no sudo, sandboxed)"
  echo ""
  echo -e "  ${Y}Console commands:${N}"
  echo -e "  sudo botmanager-admin --new-client"
  echo -e "  sudo botmanager-admin --regen-token"
  echo -e "  sudo botmanager-admin --show-token"
  echo -e "  journalctl -u botpanel -f"
  echo ""
  # Quick connectivity test
  sleep 1
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "${URL}/" 2>/dev/null || echo "000")
  if [[ "$HTTP" == "200" || "$HTTP" == "302" || "$HTTP" == "301" ]]; then
    ok "Panel responding: HTTP $HTTP"
  else
    warn "Panel check: HTTP $HTTP (may need a moment to start)"
    warn "Run: journalctl -u botpanel -f"
  fi
  echo ""
}

[[ $EUID -ne 0 ]]&&die "Run as root: sudo bash install.sh"
parse_args "$@"

echo -e "${C}"
cat << 'LOGO'
  ██████╗  ██████╗ ████████╗
  ██╔══██╗██╔═══██╗╚══██╔══╝
  ██████╔╝██║   ██║   ██║
  ██╔══██╗██║   ██║   ██║
  ██████╔╝╚██████╔╝   ██║
  ╚═════╝  ╚═════╝    ╚═╝
  Bot Manager v2.0
LOGO
echo -e "${N}"

[[ $UPD -eq 1 ]]&&{ run_update;print_summary;exit 0; }

TOK=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")
SK=$(python3 -c "import secrets;print(secrets.token_hex(32))")

detect_os; install_pkgs; ask_password; mk_dirs; install_ruby_gems; hash_pw
clone_or_update_repo; deploy_app; create_user

[[ $NOSSL -eq 0 ]]&&{ SERVER_IP=$(get_ip 2>/dev/null||echo "127.0.0.1"); gen_cert "$SERVER_IP"; }

write_svc; write_admin; write_nginx; write_ipwatch; open_fw

chown -R "$RU:$RU" "$PD"; chmod -R 750 "$PD"
# SSL: cert readable by nginx, key protected
if [[ -f "$SS/key.pem" ]]; then
  chmod 644 "$SS/cert.pem"; chmod 640 "$SS/key.pem"
  chown root:root "$SS/key.pem" "$SS/cert.pem" 2>/dev/null||true
  # Let nginx worker read the key
  for NGXU in www-data nginx http; do
    id "$NGXU" &>/dev/null && {
      setfacl -m "u:${NGXU}:r" "$SS/key.pem" 2>/dev/null ||         { chown "root:${NGXU}" "$SS/key.pem"; chmod 640 "$SS/key.pem"; } 2>/dev/null || true
      break
    }
  done
fi

info "Starting Bot Manager..."
systemctl start botpanel; sleep 3
systemctl is-active --quiet botpanel&&ok "Running!"||warn "Check: journalctl -u botpanel -n 20"

print_summary
