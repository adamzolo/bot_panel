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
write_node_server() {
  info "Writing server.js..."
  cat > "$PD/app/server.js" << 'JSEOF'
#!/usr/bin/env node
'use strict';

// ═══════════════════════════════════════════════════════════
// Bot Manager — Node.js Backend v3.0
// Express + JWT + SSE logs + child_process
// ═══════════════════════════════════════════════════════════

const http   = require('http');
const https  = require('https');
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const {spawn, execSync, spawnSync} = require('child_process');
const {EventEmitter} = require('events');
const os     = require('os');
const url    = require('url');

const PORT   = parseInt(process.env.PORT || '5000');
const PD     = process.env.PANEL_DIR   || '/opt/botpanel';
const BD     = process.env.BOTS_DIR    || '/opt/botpanel/bots';
const SVC    = '/etc/systemd/system/botpanel.service';
const VER    = '3.0.0';
const DRAM   = 256;

let HASH   = process.env.BOTPANEL_HASH   || '';
let TOKEN  = process.env.BOTPANEL_TOKEN  || '';
let SECRET = process.env.BOTPANEL_SECRET || crypto.randomBytes(32).toString('hex');

// ── Helpers ───────────────────────────────────────────────
const b64u = s => Buffer.from(s).toString('base64url');
const je   = o => JSON.stringify(o);

function signJwt(payload) {
  const h = b64u(je({alg:'HS256',typ:'JWT'}));
  const b = b64u(je(payload));
  const s = crypto.createHmac('sha256',SECRET).update(`${h}.${b}`).digest('base64url');
  return `${h}.${b}.${s}`;
}
function verifyJwt(tok) {
  try {
    const [h,b,s] = tok.split('.');
    const exp = crypto.createHmac('sha256',SECRET).update(`${h}.${b}`).digest('base64url');
    if (!crypto.timingSafeEqual(Buffer.from(s,'base64url'),Buffer.from(exp,'base64url'))) return null;
    const p = JSON.parse(Buffer.from(b,'base64url').toString());
    if (p.exp && p.exp < Date.now()/1000) return null;
    return p;
  } catch { return null; }
}

function checkBcrypt(pw, hash) {
  const r = spawnSync('python3',['-c',
    `import bcrypt,sys;sys.exit(0 if bcrypt.checkpw(sys.argv[1].encode(),sys.argv[2].encode()) else 1)`,
    pw, hash], {timeout:8000});
  return r.status === 0;
}
function hashBcrypt(pw) {
  const r = spawnSync('python3',['-c',
    `import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt()).decode())`,
    pw], {timeout:10000, encoding:'utf8'});
  if (r.status !== 0) throw new Error('bcrypt failed');
  return r.stdout.trim();
}

function safeExec(cmd, opts={}) {
  try { return {ok:true, out:execSync(cmd,{stdio:'pipe',timeout:5000,...opts}).toString().trim()}; }
  catch(e) { return {ok:false, out:e.stderr?.toString()||e.message}; }
}

function validPid(p) { return typeof p==='string' && /^[a-z0-9_]{1,64}$/.test(p); }
function botDir(pid) { return path.join(BD, pid); }
function metaFile(pid) { return path.join(BD, pid, '.bm.json'); }
function safeJoin(base, rel) {
  const r = path.resolve(base, rel);
  if (!r.startsWith(path.resolve(base)+path.sep) && r!==path.resolve(base)) throw new Error('Traversal');
  return r;
}
function readMeta(pid) {
  try { return JSON.parse(fs.readFileSync(metaFile(pid),'utf8')); } catch { return {}; }
}
function writeMeta(pid, m) { fs.writeFileSync(metaFile(pid), je(m,null,2)); }

function updateSvc(key, val) {
  if (!fs.existsSync(SVC)) return;
  let c = fs.readFileSync(SVC,'utf8');
  const re = new RegExp(`(Environment="${key.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}=)[^"]*(")`, 'g');
  if (re.test(c)) c = c.replace(re, `$1${val}$2`);
  else c = c.replace('[Service]\n', `[Service]\nEnvironment="${key}=${val}"\n`);
  fs.writeFileSync(SVC, c);
  safeExec('systemctl daemon-reload');
}

// ── State ─────────────────────────────────────────────────
const procs  = {};
const tstart = {};
const logBus = new EventEmitter();
const logBuf = {}; // pid -> string[]
logBus.setMaxListeners(500);

function logPush(pid, line) {
  if (!logBuf[pid]) logBuf[pid] = [];
  logBuf[pid].push(line);
  if (logBuf[pid].length > 3000) logBuf[pid].shift();
  logBus.emit(pid, line);
}

// ── Activity log ──────────────────────────────────────────
const activityLog = []; // global activity feed
function activity(type, pid, msg) {
  activityLog.unshift({type, pid, msg, ts: new Date().toISOString()});
  if (activityLog.length > 200) activityLog.pop();
}

// ── HTTP router ───────────────────────────────────────────
const routes = [];
function route(method, pattern, ...handlers) {
  const keys = [];
  const rx = new RegExp('^' + pattern.replace(/:([^/]+)/g, (_,k) => { keys.push(k); return '([^/]+)'; })
    .replace(/\*/g,'(.*)') + '(?:\\?.*)?$');
  routes.push({method, rx, keys, handlers});
}

function auth(req) {
  const h = req.headers['authorization'] || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : (new URLSearchParams(req._qs||'').get('token')||'');
  if (!t) return false;
  if (TOKEN && t.length===TOKEN.length && crypto.timingSafeEqual(Buffer.from(t),Buffer.from(TOKEN))) return true;
  return !!verifyJwt(t);
}
function needAuth(req, res, next) {
  if (!auth(req)) return send(res, 401, {error:'Unauthorized'});
  next();
}

function send(res, status, data, ct='application/json') {
  const body = typeof data === 'string' ? data : je(data);
  res.writeHead(status, {'Content-Type':ct,'Access-Control-Allow-Origin':'*'});
  res.end(body);
}
function sendFile(res, fp, ct='application/octet-stream') {
  res.writeHead(200,{'Content-Type':ct,'Access-Control-Allow-Origin':'*'});
  fs.createReadStream(fp).pipe(res);
}

// Parse multipart/form-data without deps
function parseMultipart(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      const ct  = req.headers['content-type'] || '';
      const m   = ct.match(/boundary=([^\s;]+)/);
      if (!m) return resolve({fields:{}, files:{}});
      const boundary = '--' + m[1];
      const parts = [];
      let pos = 0;
      const bBuf = Buffer.from(boundary);
      while (pos < buf.length) {
        const idx = buf.indexOf(bBuf, pos);
        if (idx === -1) break;
        const end = buf.indexOf(bBuf, idx + bBuf.length);
        const part = buf.slice(idx + bBuf.length + 2, end === -1 ? buf.length : end - 2);
        const hdEnd = part.indexOf('\r\n\r\n');
        if (hdEnd === -1) { pos = idx + 1; continue; }
        const hd = part.slice(0, hdEnd).toString();
        const body = part.slice(hdEnd + 4);
        const nameMx = hd.match(/name="([^"]+)"/);
        const fileMx = hd.match(/filename="([^"]+)"/);
        if (nameMx) parts.push({name:nameMx[1], filename:fileMx?.[1], body});
        pos = idx + 1;
      }
      const fields = {}, files = {};
      for (const p of parts) {
        if (p.filename) files[p.name] = {filename:p.filename, buffer:p.body};
        else fields[p.name] = p.body.toString().replace(/\r\n$/,'');
      }
      resolve({fields, files});
    });
    req.on('error', reject);
  });
}

// Parse JSON body
function parseBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', c => raw += c);
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); }
      catch { resolve({}); }
    });
    req.on('error', reject);
  });
}

// ── Rate limiting ─────────────────────────────────────────
const rl = {}; // key -> [{ts}]
function rateLimit(key, n, windowMs) {
  const now = Date.now();
  if (!rl[key]) rl[key] = [];
  rl[key] = rl[key].filter(t => now - t < windowMs);
  if (rl[key].length >= n) return false;
  rl[key].push(now);
  return true;
}

// ── Request handler ───────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const parsed = url.parse(req.url, true);
  req._path = parsed.pathname;
  req._qs   = parsed.search ? parsed.search.slice(1) : '';
  req._query= parsed.query;

  // CORS preflight
  res.setHeader('Access-Control-Allow-Origin','*');
  res.setHeader('Access-Control-Allow-Headers','Content-Type,Authorization');
  res.setHeader('Access-Control-Allow-Methods','GET,POST,PUT,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }

  // Static files
  const staticDir = path.join(PD, 'static');
  if (req.method==='GET' && !req._path.startsWith('/api') && !req._path.startsWith('/webhook')) {
    const fp = req._path === '/' ? path.join(staticDir,'index.html') : path.join(staticDir, req._path.slice(1));
    const safe = path.resolve(fp);
    if (safe.startsWith(staticDir) && fs.existsSync(safe) && fs.statSync(safe).isFile()) {
      const ext = path.extname(safe);
      const ct  = {'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.svg':'image/svg+xml'}[ext]||'application/octet-stream';
      if (ext==='.html') {
        res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store,no-cache,must-revalidate,max-age=0','Pragma':'no-cache'});
      } else {
        res.writeHead(200,{'Content-Type':ct});
      }
      fs.createReadStream(safe).pipe(res);
      return;
    }
    // SPA fallback
    const idx = path.join(staticDir,'index.html');
    if (fs.existsSync(idx)) {
      res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store,no-cache,must-revalidate'});
      fs.createReadStream(idx).pipe(res);
    } else { send(res,404,'Not found','text/plain'); }
    return;
  }

  // Match route
  for (const {method, rx, keys, handlers} of routes) {
    if (method !== req.method && method !== '*') continue;
    const m = req._path.match(rx);
    if (!m) continue;
    req.params = {};
    keys.forEach((k,i) => req.params[k] = decodeURIComponent(m[i+1]||''));
    req.query  = req._query;

    // Parse body for non-GET/SSE
    if (!['GET','DELETE'].includes(req.method) && req.headers['content-type']?.includes('application/json')) {
      req.body = await parseBody(req);
    } else { req.body = {}; }

    let i = 0;
    const next = () => { if (i < handlers.length) handlers[i++](req, res, next); };
    next();
    return;
  }

  send(res, 404, {error:'Not found'});
});

// ═══════════════════════════════════════════════════════════
// API ROUTES
// ═══════════════════════════════════════════════════════════

// ── Auth ──────────────────────────────────────────────────
const loginLock = {};

route('POST','/api/login', async (req,res) => {
  const ip = req.socket.remoteAddress;
  const now = Date.now();
  const lk = loginLock[ip]||{n:0,until:0};
  if (lk.until > now) return send(res,429,{error:`Locked ${Math.ceil((lk.until-now)/1000)}s`});
  if (!rateLimit('login'+ip, 10, 60000)) return send(res,429,{error:'Rate limit'});

  const {password=''} = req.body;
  if (!password || !HASH) return send(res,401,{error:'Invalid'});
  const ok = checkBcrypt(password, HASH);
  if (!ok) {
    lk.n++; if (lk.n>=5){lk.until=now+900000;lk.n=0;} loginLock[ip]=lk;
    return send(res,401,{error:'Invalid password'});
  }
  loginLock[ip]={n:0,until:0};
  const token = signJwt({sub:'admin', exp:Math.floor(now/1000)+86400});
  send(res,200,{token, expires_in:86400});
});

route('GET','/api/ping', needAuth, (req,res) => {
  send(res,200,{ok:true, version:VER, ts:Math.floor(Date.now()/1000)});
});

// ── Panel settings ────────────────────────────────────────
route('POST','/api/panel/password', needAuth, async (req,res) => {
  const {password=''} = req.body;
  if (password.length < 4) return send(res,400,{error:'Too short'});
  try {
    const h = hashBcrypt(password);
    updateSvc('BOTPANEL_HASH', h); HASH = h;
    send(res,200,{ok:true});
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/panel/token', needAuth, (req,res) => send(res,200,{token:TOKEN}));

route('POST','/api/panel/token', needAuth, (req,res) => {
  try {
    const t = crypto.randomBytes(32).toString('base64url');
    updateSvc('BOTPANEL_TOKEN', t); TOKEN = t;
    send(res,200,{ok:true, token:t});
  } catch(e) { send(res,500,{error:e.message}); }
});

// ── Projects ──────────────────────────────────────────────
route('GET','/api/projects', needAuth, (req,res) => {
  if (!fs.existsSync(BD)) return send(res,200,[]);
  const out = [];
  for (const pid of fs.readdirSync(BD).sort()) {
    try {
      const d = path.join(BD,pid);
      if (!fs.statSync(d).isDirectory()) continue;
      const m = readMeta(pid);
      const proc = procs[pid];
      const running = !!proc && proc.exitCode===null;
      const up = running && tstart[pid] ? Math.floor((Date.now()-tstart[pid])/1000) : 0;
      out.push({id:pid, name:m.name||pid, token:m.token||'', created:m.created||'',
        running, main:m.main||'bot.py', autostart:!!m.autostart, uptime:up,
        ram_limit:m.ram_limit||DRAM, cpu_limit:m.cpu_limit||80,
        platform:m.platform||'telegram', lang:m.lang||'python'});
    } catch {}
  }
  send(res,200,out);
});

route('POST','/api/projects', needAuth, async (req,res) => {
  const {name='', token='', template='basic', lang='python', platform='telegram', restore_only=false} = req.body;
  if (!name.trim()) return send(res,400,{error:'Name required'});
  const pid = name.trim().toLowerCase().replace(/\s+/g,'_').replace(/[^a-z0-9_]/g,'').replace(/_+/g,'_').slice(0,64);
  if (!validPid(pid)) return send(res,400,{error:'Invalid name'});
  const bd = botDir(pid);
  if (fs.existsSync(bd)) return send(res,409,{error:'Already exists'});
  fs.mkdirSync(bd,{recursive:true});

  const mf = {python:'bot.py',php:'bot.php',ruby:'bot.rb',node:'bot.js'}[lang]||'bot.py';
  const rf = {python:'requirements.txt',php:'composer.json',ruby:'Gemfile',node:'package.json'}[lang];

  if (!restore_only) {
    fs.writeFileSync(path.join(bd,mf), makeBotTemplate(template,token,lang,platform));
    if (rf) fs.writeFileSync(path.join(bd,rf), makeDepsFile(lang,platform));
  }
  writeMeta(pid,{name:name.trim(), token, created:new Date().toISOString(), main:mf,
    autostart:false, template, platform, lang, ram_limit:DRAM, cpu_limit:80});
  logBuf[pid] = [];
  activity('create',pid,`Project "${name}" created`);
  setTimeout(()=>installDeps(pid).catch(()=>{}), 200);
  send(res,201,{id:pid, name:name.trim()});
});

route('DELETE','/api/projects/:pid', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const bd = botDir(pid);
  if (!fs.existsSync(bd)) return send(res,404,{error:'Not found'});
  botStop(pid);
  delete logBuf[pid];
  fs.rmSync(bd,{recursive:true,force:true});
  const vd = path.join(PD,'bots_venv',pid);
  if (fs.existsSync(vd)) fs.rmSync(vd,{recursive:true,force:true});
  activity('delete',pid,`Project "${pid}" deleted`);
  send(res,200,{ok:true});
});

route('POST','/api/projects/:pid/rename', needAuth, async (req,res) => {
  const {pid} = req.params;
  const {name=''} = req.body;
  if (!name.trim()) return send(res,400,{error:'Name required'});
  if (!validPid(pid)||!fs.existsSync(botDir(pid))) return send(res,404,{error:'Not found'});
  const m = readMeta(pid); m.name = name.trim(); writeMeta(pid,m);
  activity('rename',pid,`Renamed to "${name}"`);
  send(res,200,{ok:true, name:name.trim()});
});

route('POST','/api/projects/:pid/autostart', needAuth, async (req,res) => {
  const {pid} = req.params;
  const {enabled=false} = req.body;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const m = readMeta(pid); m.autostart = !!enabled; writeMeta(pid,m);
  send(res,200,{ok:true, autostart:!!enabled});
});

route('POST','/api/projects/:pid/limits', needAuth, async (req,res) => {
  const {pid} = req.params;
  const m = readMeta(pid);
  if (req.body.ram_limit!==undefined) m.ram_limit = parseInt(req.body.ram_limit)||DRAM;
  if (req.body.cpu_limit!==undefined) m.cpu_limit = parseInt(req.body.cpu_limit)||80;
  writeMeta(pid,m); send(res,200,{ok:true});
});

route('PUT','/api/projects/:pid/token', needAuth, async (req,res) => {
  const {pid} = req.params;
  const m = readMeta(pid); m.token = req.body.token||''; writeMeta(pid,m);
  send(res,200,{ok:true});
});

// ── ENV ───────────────────────────────────────────────────
route('GET','/api/projects/:pid/env', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const ef = path.join(botDir(pid),'.env');
  send(res,200,{content: fs.existsSync(ef) ? fs.readFileSync(ef,'utf8') : ''});
});

route('PUT','/api/projects/:pid/env', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const ef = path.join(botDir(pid),'.env');
  fs.writeFileSync(ef, req.body.content||'', 'utf8');
  try { fs.chmodSync(ef,0o640); } catch {}
  activity('env',pid,'Config vars updated');
  send(res,200,{ok:true});
});

// ── Bot control ───────────────────────────────────────────
route('POST','/api/projects/:pid/start', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const [ok,r] = await botStart(pid);
  if (!ok) return send(res, r==='Already running'?409:500, {error:r});
  activity('start',pid,'Bot started');
  send(res,200,{ok:true, pid:r});
});

route('POST','/api/projects/:pid/stop', needAuth, (req,res) => {
  const {pid} = req.params;
  botStop(pid);
  activity('stop',pid,'Bot stopped');
  send(res,200,{ok:true});
});

route('POST','/api/projects/:pid/restart', needAuth, async (req,res) => {
  const {pid} = req.params;
  botStop(pid);
  await new Promise(r=>setTimeout(r,600));
  const [ok,r] = await botStart(pid);
  if (!ok) return send(res,500,{error:r});
  activity('restart',pid,'Bot restarted');
  send(res,200,{ok:true, pid:r});
});

// ── Files ─────────────────────────────────────────────────
route('GET','/api/projects/:pid/files', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)||!fs.existsSync(botDir(pid))) return send(res,404,{error:'Not found'});
  const bd = botDir(pid);
  const files = fs.readdirSync(bd)
    .filter(f=>!f.startsWith('.'))
    .map(f=>{
      const fp=path.join(bd,f); const st=fs.statSync(fp);
      return st.isFile() ? {name:f,size:st.size,modified:st.mtime.toISOString()} : null;
    }).filter(Boolean).sort((a,b)=>a.name.localeCompare(b.name));
  send(res,200,files);
});

route('GET','/api/projects/:pid/files/*', needAuth, (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    if (!fs.existsSync(fp)) return send(res,404,{error:'Not found'});
    send(res,200,{name:fn, content:fs.readFileSync(fp,'utf8')});
  } catch(e) { send(res,403,{error:'Forbidden'}); }
});

route('PUT','/api/projects/:pid/files/*', needAuth, async (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    fs.mkdirSync(path.dirname(fp),{recursive:true});
    fs.writeFileSync(fp, req.body.content||'','utf8');
    send(res,200,{ok:true, size:fs.statSync(fp).size});
  } catch(e) { send(res,403,{error:e.message}); }
});

route('DELETE','/api/projects/:pid/files/*', needAuth, (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    if (!fs.existsSync(fp)) return send(res,404,{error:'Not found'});
    fs.unlinkSync(fp); send(res,200,{ok:true});
  } catch(e) { send(res,403,{error:e.message}); }
});

route('POST','/api/projects/:pid/files', needAuth, async (req,res) => {
  const {pid} = req.params; const {name=''} = req.body;
  if (!name||name.includes('..')||name.includes('/')) return send(res,400,{error:'Invalid name'});
  const fp = path.join(botDir(pid),name);
  if (fs.existsSync(fp)) return send(res,409,{error:'Exists'});
  fs.writeFileSync(fp,''); send(res,201,{ok:true});
});

// Upload via multipart
route('POST','/api/projects/:pid/upload', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  try {
    const {files} = await parseMultipart(req);
    const f = files.file;
    if (!f) return send(res,400,{error:'No file'});
    const fn  = path.basename(f.filename||'upload');
    const dest = path.join(botDir(pid),fn);
    fs.writeFileSync(dest,f.buffer);
    send(res,201,{ok:true,name:fn,size:fs.statSync(dest).size});
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/projects/:pid/download/*', needAuth, (req,res) => {
  const {pid} = req.params; const fn = req.params[0]||'';
  try {
    const fp = safeJoin(botDir(pid),fn);
    if (!fs.existsSync(fp)) return send(res,404,'Not found','text/plain');
    res.writeHead(200,{'Content-Type':'application/octet-stream',
      'Content-Disposition':`attachment; filename="${path.basename(fn)}"`,
      'Access-Control-Allow-Origin':'*'});
    fs.createReadStream(fp).pipe(res);
  } catch(e) { send(res,403,{error:'Forbidden'}); }
});

// Backup as zip
route('GET','/api/projects/:pid/backup', needAuth, (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)||!fs.existsSync(botDir(pid))) return send(res,404,{error:'Not found'});
  const ts = new Date().toISOString().slice(0,19).replace('T','_').replace(/:/g,'-');
  const fname = `bot_${pid}_${ts}.zip`;
  try {
    const buf = execSync(`cd "${botDir(pid)}" && zip -r - . --exclude ".*"`,
      {maxBuffer:100*1024*1024, timeout:30000});
    res.writeHead(200,{'Content-Type':'application/zip',
      'Content-Disposition':`attachment; filename="${fname}"`,
      'Access-Control-Allow-Origin':'*'});
    res.end(buf);
  } catch(e) { send(res,500,{error:e.message}); }
});

// Restore from zip
route('POST','/api/projects/:pid/restore', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const bd = botDir(pid);
  if (!fs.existsSync(bd)) fs.mkdirSync(bd,{recursive:true});
  try {
    const {files} = await parseMultipart(req);
    const f = files.file;
    if (!f) return send(res,400,{error:'No file'});
    const tmp = path.join(os.tmpdir(),`restore_${pid}_${Date.now()}.zip`);
    fs.writeFileSync(tmp, f.buffer);
    execSync(`unzip -o "${tmp}" -d "${bd}"`,{timeout:30000,stdio:'pipe'});
    fs.unlinkSync(tmp);
    // auto-detect lang
    const m = readMeta(pid);
    if (!m.lang||m.lang==='python') {
      if (fs.existsSync(path.join(bd,'bot.js'))) { m.lang='node'; m.main='bot.js'; }
      else if (fs.existsSync(path.join(bd,'bot.rb'))) { m.lang='ruby'; m.main='bot.rb'; }
      else if (fs.existsSync(path.join(bd,'bot.php'))) { m.lang='php'; m.main='bot.php'; }
    }
    writeMeta(pid,m);
    const list = execSync(`unzip -Z1 "${tmp}" 2>/dev/null||true`).toString().trim().split('\n').filter(Boolean);
    activity('restore',pid,`Restored ${list.length} files`);
    send(res,200,{ok:true, files:list.length, lang:m.lang, main:m.main});
  } catch(e) { send(res,500,{error:e.message}); }
});

// ── Logs (SSE) ────────────────────────────────────────────
route('GET','/api/projects/:pid/logs', needAuth, (req,res) => {
  const {pid} = req.params;
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache',
    'X-Accel-Buffering':'no','Connection':'keep-alive','Access-Control-Allow-Origin':'*'});
  res.write('data: [00:00:00]|o|Connected\n\n');
  // replay buffer
  if (logBuf[pid]) for (const l of logBuf[pid]) res.write(`data: ${l.replace(/\n/g,' ')}\n\n`);
  const h = l => res.write(`data: ${l.replace(/\n/g,' ')}\n\n`);
  logBus.on(pid, h);
  const ka = setInterval(()=>res.write(':ka\n\n'),15000);
  req.on('close',()=>{ logBus.off(pid,h); clearInterval(ka); });
});

// ── Activity ──────────────────────────────────────────────
route('GET','/api/activity', needAuth, (req,res) => {
  const pid = req.query.pid;
  const list = pid ? activityLog.filter(a=>a.pid===pid) : activityLog;
  send(res,200,list.slice(0,50));
});

// ── Metrics ───────────────────────────────────────────────
route('GET','/api/projects/:pid/metrics', needAuth, (req,res) => {
  const {pid} = req.params;
  const proc = procs[pid];
  const running = !!proc && proc.exitCode===null;
  const up = running&&tstart[pid] ? Math.floor((Date.now()-tstart[pid])/1000) : 0;
  if (!running) return send(res,200,{running:false,cpu:0,ram:0,uptime:0,threads:0});
  try {
    const stat = fs.readFileSync(`/proc/${proc.pid}/status`,'utf8');
    const vmRss = parseInt((stat.match(/VmRSS:\s+(\d+)/)||[0,0])[1]);
    const threads = parseInt((stat.match(/Threads:\s+(\d+)/)||[0,1])[1]);
    const m = readMeta(pid);
    send(res,200,{running:true, pid:proc.pid, ram:Math.round(vmRss/1024),
      uptime:up, threads, ram_limit:m.ram_limit||DRAM, cpu_limit:m.cpu_limit||80});
  } catch { send(res,200,{running:true,pid:proc.pid,ram:0,uptime:up,threads:0}); }
});

route('GET','/api/system/metrics', needAuth, (req,res) => {
  try {
    const mem = fs.readFileSync('/proc/meminfo','utf8');
    const totKB = parseInt((mem.match(/MemTotal:\s+(\d+)/)||[0,0])[1]);
    const avlKB = parseInt((mem.match(/MemAvailable:\s+(\d+)/)||[0,0])[1]);
    const disk = execSync('df / --output=size,used -B1 | tail -1',{stdio:'pipe'}).toString().trim().split(/\s+/);
    const load = os.loadavg();
    const running = Object.values(procs).filter(p=>p.exitCode===null).length;
    const total = fs.existsSync(BD)?fs.readdirSync(BD).filter(p=>fs.statSync(path.join(BD,p)).isDirectory()).length:0;
    send(res,200,{
      cpu:Math.round(load[0]*100)/100, load_1:load[0],load_5:load[1],load_15:load[2],
      ram_total:Math.round(totKB/1024/1024*100)/100,
      ram_used:Math.round((totKB-avlKB)/1024/1024*100)/100,
      ram_percent:Math.round((totKB-avlKB)/totKB*100),
      disk_total:Math.round(parseInt(disk[0])/1e9*10)/10,
      disk_used:Math.round(parseInt(disk[1])/1e9*10)/10,
      disk_percent:Math.round(parseInt(disk[1])/parseInt(disk[0])*100),
      bots_running:running, bots_total:total,
    });
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/server/status', needAuth, (req,res) => {
  try {
    const uptime = parseFloat(fs.readFileSync('/proc/uptime','utf8').split(' ')[0]);
    const mem = fs.readFileSync('/proc/meminfo','utf8');
    const totKB = parseInt((mem.match(/MemTotal:\s+(\d+)/)||[0,0])[1]);
    const avlKB = parseInt((mem.match(/MemAvailable:\s+(\d+)/)||[0,0])[1]);
    const disk = execSync('df / --output=size,used -B1 | tail -1',{stdio:'pipe'}).toString().trim().split(/\s+/);
    const load = os.loadavg();
    const running = Object.values(procs).filter(p=>p.exitCode===null).length;
    const total = fs.existsSync(BD)?fs.readdirSync(BD).filter(p=>fs.statSync(path.join(BD,p)).isDirectory()).length:0;
    const panelOk = spawnSync('systemctl',['is-active','--quiet','botpanel'],{stdio:'pipe'}).status===0;
    const nginxOk = spawnSync('systemctl',['is-active','--quiet','nginx'],{stdio:'pipe'}).status===0;
    send(res,200,{
      uptime_sec:Math.round(uptime), load_1:load[0],load_5:load[1],load_15:load[2],
      ram_total:Math.round(totKB/1024/1024*100)/100,
      ram_used:Math.round((totKB-avlKB)/1024/1024*100)/100,
      ram_pct:Math.round((totKB-avlKB)/totKB*100),
      disk_total:Math.round(parseInt(disk[0])/1e9*10)/10,
      disk_used:Math.round(parseInt(disk[1])/1e9*10)/10,
      disk_pct:Math.round(parseInt(disk[1])/parseInt(disk[0])*100),
      panel_active:panelOk, nginx_active:nginxOk,
      bots_running:running, bots_total:total,
      hostname:os.hostname(), node:process.version,
    });
  } catch(e) { send(res,500,{error:e.message}); }
});

route('GET','/api/system/info', needAuth, (req,res) => {
  const se = cmd => { try{return execSync(cmd,{stdio:'pipe',timeout:3000}).toString().trim();}catch{return 'n/a';} };
  send(res,200,{
    version:VER, node:process.version,
    python:se('python3 --version').replace('Python ',''),
    ruby:se('ruby --version').split(' ')[1]||'n/a',
    php:se('php --version').split('\n')[0].split(' ')[1]||'n/a',
    os:`${os.type()} ${os.release()}`, hostname:os.hostname(),
    bots_total:fs.existsSync(BD)?fs.readdirSync(BD).filter(p=>fs.statSync(path.join(BD,p)).isDirectory()).length:0,
  });
});

// ── Server power ──────────────────────────────────────────
route('POST','/api/server/restart_panel', needAuth, async (req,res) => {
  const {mode='soft'} = req.body;
  if (mode==='hard') Object.keys(procs).forEach(pid=>botStop(pid));
  send(res,200,{ok:true,mode});
  activity('power','panel',`Panel ${mode} restart`);
  setTimeout(()=>spawn('sudo',['systemctl','restart','botpanel'],{detached:true,stdio:'ignore'}).unref(),300);
});

route('POST','/api/server/reboot', needAuth, async (req,res) => {
  const {mode='soft'} = req.body;
  send(res,200,{ok:true,mode});
  activity('power','server',`Server ${mode} reboot`);
  setTimeout(()=>{
    if (mode==='hard') {
      try {
        execSync('sudo sh -c "echo 1 > /proc/sys/kernel/sysrq"',{stdio:'pipe'});
        execSync('sudo sh -c "echo b > /proc/sysrq-trigger"',{stdio:'pipe'});
      } catch { spawn('sudo',['reboot','-f'],{detached:true,stdio:'ignore'}).unref(); }
    } else {
      spawn('sudo',['systemctl','reboot'],{detached:true,stdio:'ignore'}).unref();
    }
  },300);
});

route('POST','/api/server/update', needAuth, (req,res) => {
  send(res,200,{ok:true});
  setTimeout(()=>{
    for (const loc of ['/root/install.sh','/home/install.sh','/tmp/install.sh']) {
      if (fs.existsSync(loc)) { spawn('bash',[loc,'--update'],{detached:true,stdio:'ignore'}).unref(); return; }
    }
    spawn('sudo',['systemctl','restart','botpanel'],{detached:true,stdio:'ignore'}).unref();
  },300);
});

// ── Diagnose ──────────────────────────────────────────────
route('POST','/api/projects/:pid/diagnose', needAuth, async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const m = readMeta(pid); const bd = botDir(pid); const results = [];
  results.push({check:'Token set',ok:!!m.token,msg:m.token?m.token.slice(0,14)+'…':'Not set'});
  if (m.token && m.platform==='telegram') {
    try {
      const r = await new Promise((resolve,reject)=>{
        const u = new URL(`https://api.telegram.org/bot${m.token}/getMe`);
        https.get(u.toString(), res2=>{
          let d=''; res2.on('data',c=>d+=c); res2.on('end',()=>resolve(JSON.parse(d)));
        }).on('error',reject);
      });
      if (r.ok) results.push({check:'Token valid',ok:true,msg:'@'+r.result.username});
      else results.push({check:'Token valid',ok:false,msg:r.description||'Bad token'});
    } catch(e) { results.push({check:'Token valid',ok:false,msg:e.message}); }
  }
  const rf = {python:'requirements.txt',php:'composer.json',ruby:'Gemfile',node:'package.json'}[m.lang||'python'];
  results.push({check:'Deps file',ok:fs.existsSync(path.join(bd,rf||'')),msg:rf||'n/a'});
  const envFile = path.join(bd,'.env');
  results.push({check:'.env file',ok:fs.existsSync(envFile),msg:fs.existsSync(envFile)?'Present':'Not found'});
  results.push({check:'Bot running',ok:!!procs[pid]&&procs[pid].exitCode===null,msg:procs[pid]?.exitCode===null?'Running':'Stopped'});
  send(res,200,{results});
});

// ── Webhook proxy ─────────────────────────────────────────
const webhookHandler = async (req,res) => {
  const {pid} = req.params;
  if (!validPid(pid)) return send(res,400,{error:'Invalid'});
  const m = readMeta(pid);
  if (!m.webhook_port) return send(res,503,'Bot webhook not configured','text/plain');
  const sub = req.params[0]||'/';
  const qs  = req._qs ? '?'+req._qs : '';
  const target = `http://127.0.0.1:${m.webhook_port}${sub}${qs}`;
  const chunks=[]; req.on('data',c=>chunks.push(c));
  req.on('end',()=>{
    const body = Buffer.concat(chunks);
    const u = new URL(target);
    const opts={hostname:u.hostname,port:u.port,path:u.pathname+u.search,method:req.method,
      headers:{...req.headers,host:u.host,'content-length':body.length}};
    const pr = http.request(opts, upstream=>{
      res.writeHead(upstream.statusCode, upstream.headers);
      upstream.pipe(res);
    });
    pr.on('error',()=>res.end('Bot not running'));
    pr.end(body);
  });
};
route('*','/webhook/:pid', webhookHandler);
route('*','/webhook/:pid/*', webhookHandler);

// ═══════════════════════════════════════════════════════════
// BOT PROCESS MANAGEMENT
// ═══════════════════════════════════════════════════════════
async function botStart(pid) {
  if (!fs.existsSync(botDir(pid))) return [false,'Not found'];
  if (procs[pid]?.exitCode===null) return [false,'Already running'];
  try { await installDeps(pid); } catch(e) { logPush(pid,`[${ts()}]|w|[deps] ${e.message}`); }
  const m   = readMeta(pid);
  const cmd = getCmd(pid,m);
  const env = getEnv(pid,m);
  if (!logBuf[pid]) logBuf[pid]=[];
  logPush(pid,`[${ts()}]|o|Starting "${pid}" (${path.basename(cmd[0])})...`);
  const proc = spawn(cmd[0],cmd.slice(1),{cwd:botDir(pid),env:{...process.env,...env},stdio:['ignore','pipe','pipe']});
  procs[pid]=proc; tstart[pid]=Date.now();
  const streamLine = stream => {
    let buf='';
    stream.on('data',chunk=>{
      buf+=chunk.toString();
      const lines=buf.split('\n'); buf=lines.pop();
      for (const l of lines) logPush(pid,`[${ts()}]|${classify(l)}|${l}`);
    });
  };
  streamLine(proc.stdout); streamLine(proc.stderr);
  proc.once('exit',code=>{
    delete procs[pid]; delete tstart[pid];
    logPush(pid,`[${ts()}]|wd|[WD] Crashed rc=${code}, restart in 3s...`);
    setTimeout(async()=>{
      const m2=readMeta(pid);
      if (m2.autostart!==false&&!procs[pid]) {
        const [ok,r]=await botStart(pid);
        logPush(pid,`[${ts()}]|wd|[WD] Restart: ${ok?'OK pid='+r:'FAIL '+r}`);
      }
    },3000);
  });
  // RAM watchdog
  const wd=setInterval(()=>{
    if (!procs[pid]||procs[pid].exitCode!==null){clearInterval(wd);return;}
    try {
      const st=fs.readFileSync(`/proc/${proc.pid}/status`,'utf8');
      const ram=parseInt((st.match(/VmRSS:\s+(\d+)/)||[0,0])[1])/1024;
      const lim=(readMeta(pid).ram_limit||DRAM);
      if(ram>lim){logPush(pid,`[${ts()}]|wd|[WD] RAM ${ram.toFixed(0)}>${lim}MB, killing`);proc.kill('SIGKILL');}
    } catch {}
  },10000);
  return [true,proc.pid];
}

function botStop(pid) {
  const p=procs[pid];
  if (p?.exitCode===null) {
    p.removeAllListeners('exit');
    p.kill('SIGTERM');
    setTimeout(()=>{try{p.kill('SIGKILL');}catch{}},5000);
  }
  delete procs[pid]; delete tstart[pid];
}

const ts = ()=>new Date().toTimeString().slice(0,8);
const classify = l=>/\b(error|exception|traceback|critical|fatal)\b/i.test(l)?'e':/\b(warn|warning)\b/i.test(l)?'w':l.startsWith('[WD]')?'wd':'o';

function getCmd(pid,m){
  const lang=m.lang||'python', main=m.main||'bot.py';
  if (m.run_cmd) return m.run_cmd.split(' ');
  if (lang==='python'){const py=path.join(PD,'bots_venv',pid,'bin','python3');return[fs.existsSync(py)?py:'python3',main];}
  if (lang==='node') return ['node',main];
  if (lang==='php')  return ['php',main];
  if (lang==='ruby'){
    const bd2=path.join(PD,'bots_venv',pid,'ruby_gems');
    const gf=path.join(botDir(pid),'Gemfile');
    const hasGems=fs.existsSync(bd2)&&fs.readdirSync(bd2).length>0;
    return hasGems&&fs.existsSync(gf)?['bundle','exec','ruby',main]:['ruby',main];
  }
  return ['python3',main];
}

function getEnv(pid,m){
  const lang=m.lang||'python';
  const e={HOME:botDir(pid),BOT_DIR:botDir(pid),PYTHONUNBUFFERED:'1'};
  if(m.token) e.BOT_TOKEN=m.token;
  if(m.webhook_port) e.WEBHOOK_PORT=String(m.webhook_port);
  if(m.platform) e.BOT_PLATFORM=m.platform;
  // .env file
  const ef=path.join(botDir(pid),'.env');
  if(fs.existsSync(ef)){
    for(const line of fs.readFileSync(ef,'utf8').split('\n')){
      const l=line.trim();
      if(!l||l.startsWith('#')||!l.includes('=')) continue;
      const [k,...vs]=l.split('='); const v=vs.join('=').trim().replace(/^["']|["']$/g,'');
      if(k.trim()) e[k.trim()]=v;
    }
  }
  if(lang==='ruby'){
    const bd2=path.join(PD,'bots_venv',pid,'ruby_gems');
    e.BUNDLE_PATH=bd2; e.BUNDLE_GEMFILE=path.join(botDir(pid),'Gemfile');
    const cfgP=path.join(PD,'.ruby_gem_dir');
    const sys=fs.existsSync(cfgP)?fs.readFileSync(cfgP,'utf8').trim():'/usr/local/bundle';
    try{const gp=execSync('gem environment gempath',{stdio:'pipe',timeout:5000}).toString().trim();
      e.GEM_PATH=[bd2,sys,...gp.split(':')].filter(Boolean).join(':');}
    catch{e.GEM_PATH=[bd2,sys].join(':');}
    e.GEM_HOME=bd2;
  }
  if(lang==='node'){
    try{const gm=execSync('npm root -g',{stdio:'pipe',timeout:5000}).toString().trim();
      e.NODE_PATH=[path.join(botDir(pid),'node_modules'),gm].filter(Boolean).join(':');}catch{}
  }
  return e;
}

async function installDeps(pid){
  const m=readMeta(pid); const lang=m.lang||'python'; const bd=botDir(pid);
  const log=msg=>logPush(pid,`[${ts()}]|o|[deps] ${msg}`);
  if(lang==='python'){
    const vd=path.join(PD,'bots_venv',pid);
    if(!fs.existsSync(vd)){log('Creating venv...');execSync(`python3 -m venv "${vd}"`,{timeout:60000,stdio:'pipe'});}
    const rf=path.join(bd,'requirements.txt');
    if(fs.existsSync(rf)){
      log('Installing Python packages...');
      try{execSync(`"${path.join(vd,'bin','pip')}" install --quiet --no-cache-dir -r "${rf}"`,{timeout:300000,stdio:'pipe'});log('OK');}
      catch(e){log('pip FAILED: '+e.stderr?.toString().slice(0,200));}
    }
  } else if(lang==='node'){
    const pf=path.join(bd,'package.json');
    if(fs.existsSync(pf)){
      log('Installing Node.js packages...');
      try{execSync(`npm install --prefix "${bd}" --no-audit --no-fund`,{cwd:bd,timeout:300000,stdio:'pipe'});log('OK');}
      catch{log('npm failed, using global fallback');
        try{const gm=execSync('npm root -g',{timeout:5000,stdio:'pipe'}).toString().trim();
          const nm=path.join(bd,'node_modules');
          if(!fs.existsSync(nm)&&gm&&fs.existsSync(gm)){fs.symlinkSync(gm,nm);log('Linked global node_modules');}
        }catch{}
      }
    }
  } else if(lang==='ruby'){
    const gf=path.join(bd,'Gemfile');
    if(fs.existsSync(gf)){
      log('Installing Ruby gems...');
      const bd2=path.join(PD,'bots_venv',pid,'ruby_gems');
      try{execSync(`bundle install`,{cwd:bd,timeout:300000,stdio:'pipe',
        env:{...process.env,BUNDLE_PATH:bd2,BUNDLE_GEMFILE:gf,HOME:bd}});log('OK');}
      catch(e){log('bundle failed: '+e.stderr?.toString().slice(0,150));
        const gems=(fs.readFileSync(gf,'utf8').split('\n')
          .filter(l=>l.trim().startsWith('gem '))
          .map(l=>l.trim().split(/\s+/)[1]?.replace(/['"]/g,'')).filter(Boolean));
        for(const g of gems){
          try{execSync(`gem install ${g} --no-document`,{timeout:120000,stdio:'pipe'});log(`${g}: OK`);}
          catch{log(`${g}: FAILED`);}
        }
      }
    }
  } else if(lang==='php'){log('PHP: using built-in extensions');}
}

// ── Bot templates ─────────────────────────────────────────
function makeDepsFile(lang,plat){
  if(lang==='python') return {telegram:'python-telegram-bot>=20.0\n',discord:'discord.py>=2.0\n',whatsapp:'flask\nrequests\n',viber:'viberbot\nflask\n'}[plat]||'requests\n';
  if(lang==='node'){const d={telegram:'{"node-telegram-bot-api":"*"}',discord:'{"discord.js":"^14.0.0"}',whatsapp:'{"express":"*","axios":"*"}',viber:'{"viber-bot":"*","express":"*"}'}[plat]||'{}';return `{"name":"bot","version":"1.0.0","dependencies":${d}}\n`;}
  if(lang==='ruby') return "source 'https://rubygems.org'\n";
  return '{"require":{}}\n';
}

function makeBotTemplate(tpl,tok,lang,plat){
  // Node.js Telegram
  if(lang==='node'&&plat==='telegram'){
    if(tpl==='echo') return `const TBot=require('node-telegram-bot-api');\nconst bot=new TBot('${tok}',{polling:true});\nbot.on('message',msg=>{if(msg.text)bot.sendMessage(msg.chat.id,msg.text);});\nconsole.log('Echo bot started');\n`;
    if(tpl==='menu') return `const TBot=require('node-telegram-bot-api');\nconst bot=new TBot('${tok}',{polling:true});\nconst kb={reply_markup:{keyboard:[['Help','About']],resize_keyboard:true}};\nbot.onText(/\\/start/,msg=>bot.sendMessage(msg.chat.id,'Hello!',kb));\nbot.on('message',msg=>{\n  if(msg.text==='Help')bot.sendMessage(msg.chat.id,'Press buttons!');\n  if(msg.text==='About')bot.sendMessage(msg.chat.id,'Bot Manager v3');\n});\nconsole.log('Menu bot started');\n`;
    return `const TBot=require('node-telegram-bot-api');\nconst bot=new TBot('${tok}',{polling:true});\nbot.onText(/\\/start/,msg=>bot.sendMessage(msg.chat.id,'Hello! Type /help'));\nbot.onText(/\\/help/,msg=>bot.sendMessage(msg.chat.id,'/start\\n/help'));\nconsole.log('Bot started');\n`;
  }
  // Node.js Discord
  if(lang==='node'&&plat==='discord') return `const {Client,GatewayIntentBits}=require('discord.js');\nconst client=new Client({intents:[GatewayIntentBits.Guilds,GatewayIntentBits.GuildMessages,GatewayIntentBits.MessageContent]});\nclient.once('ready',()=>console.log('Logged in as '+client.user.tag));\nclient.on('messageCreate',msg=>{\n  if(msg.author.bot)return;\n  if(msg.content==='!ping')msg.reply('Pong!');\n});\nclient.login('${tok}');\n`;
  // Ruby stdlib Telegram
  if(lang==='ruby'&&plat==='telegram'){
    const hdr='require "net/http"\nrequire "json"\nrequire "uri"\nrequire "openssl"\n';
    const fn='def tg(m,p={})\n  u=URI("https://api.telegram.org/bot"+TOKEN+"/"+m.to_s)\n  h=Net::HTTP.new(u.host,u.port);h.use_ssl=true;h.verify_mode=OpenSSL::SSL::VERIFY_NONE\n  JSON.parse(h.post(u.path,p.to_json,"Content-Type"=>"application/json").body)\nrescue=>e;STDERR.puts e.to_s;{}\nend\n';
    return hdr+`TOKEN=ENV["BOT_TOKEN"]||"${tok}"\n`+fn+
      'offset=0;puts "Bot started (no gems)"\nloop do\n  (tg("getUpdates",{timeout:25,offset:offset})["result"]||[]).each do |u|\n    offset=u["update_id"]+1\n    msg=u["message"];next unless msg\n    chat=msg["chat"]["id"];text=msg["text"]||""\n    case text\n    when "/start" then tg("sendMessage",{chat_id:chat,text:"Hello! Type /help"})\n    when "/help" then tg("sendMessage",{chat_id:chat,text:"/start\n/help"})\n    end\n  end\nrescue Interrupt;exit\nrescue=>e;STDERR.puts e;sleep 3\nend\n';
  }
  // PHP Telegram
  if(lang==='php'&&plat==='telegram') return `<?php\n$token=getenv('BOT_TOKEN')?:\"${tok}\";\n$offset=0;\nwhile(true){\n  $r=@json_decode(file_get_contents("https://api.telegram.org/bot$token/getUpdates?timeout=30&offset=$offset"),true);\n  foreach($r["result"]??[] as $u){\n    $offset=$u["update_id"]+1;\n    $chat=$u["message"]["chat"]["id"]??"";\n    $text=$u["message"]["text"]??"";\n    if($text==="/start")@file_get_contents("https://api.telegram.org/bot$token/sendMessage?chat_id=$chat&text=Hello!");\n  }\n  sleep(1);\n}\n`;
  // Python Telegram (default)
  if(tpl==='echo') return `#!/usr/bin/env python3\nimport os,logging\nfrom telegram import Update\nfrom telegram.ext import ApplicationBuilder,MessageHandler,filters,ContextTypes\nlogging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')\nBOT_TOKEN=os.environ.get('BOT_TOKEN','${tok}')\nasync def echo(u:Update,c:ContextTypes.DEFAULT_TYPE):\n  if u.message and u.message.text:await u.message.reply_text(u.message.text)\nif __name__=='__main__':\n  ApplicationBuilder().token(BOT_TOKEN).build().run_polling(drop_pending_updates=True)\n`;
  if(tpl==='menu') return `#!/usr/bin/env python3\nimport os,logging\nfrom telegram import Update,ReplyKeyboardMarkup\nfrom telegram.ext import ApplicationBuilder,CommandHandler,MessageHandler,filters,ContextTypes\nlogging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')\nBOT_TOKEN=os.environ.get('BOT_TOKEN','${tok}')\nMENU=ReplyKeyboardMarkup([['Help','About']],resize_keyboard=True)\nasync def start(u:Update,c:ContextTypes.DEFAULT_TYPE):await u.message.reply_text('Hello!',reply_markup=MENU)\nasync def handle(u:Update,c:ContextTypes.DEFAULT_TYPE):\n  t=u.message.text\n  if t=='Help':await u.message.reply_text('Press buttons!')\n  elif t=='About':await u.message.reply_text('Bot Manager v3')\nif __name__=='__main__':\n  a=ApplicationBuilder().token(BOT_TOKEN).build()\n  a.add_handler(CommandHandler('start',start))\n  a.add_handler(MessageHandler(filters.TEXT&~filters.COMMAND,handle))\n  a.run_polling(drop_pending_updates=True)\n`;
  // basic python
  return `#!/usr/bin/env python3\nimport os,logging\nfrom telegram import Update\nfrom telegram.ext import ApplicationBuilder,CommandHandler,ContextTypes\nlogging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')\nBOT_TOKEN=os.environ.get('BOT_TOKEN','${tok}')\nasync def start(u:Update,c:ContextTypes.DEFAULT_TYPE):await u.message.reply_text('Hello! Type /help')\nasync def help_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):await u.message.reply_text('/start\\n/help')\nif __name__=='__main__':\n  a=ApplicationBuilder().token(BOT_TOKEN).build()\n  a.add_handler(CommandHandler('start',start))\n  a.add_handler(CommandHandler('help',help_cmd))\n  a.run_polling(drop_pending_updates=True)\n`;
}

// ── Autostart ─────────────────────────────────────────────
function autostart(){
  if(!fs.existsSync(BD)) return;
  setTimeout(async()=>{
    for(const pid of fs.readdirSync(BD)){
      if(!fs.statSync(path.join(BD,pid)).isDirectory()) continue;
      try{const m=readMeta(pid);if(m.autostart){const[ok,r]=await botStart(pid);console.log(`[autostart] ${ok?'OK':'FAIL'} ${pid}: ${r}`);}}
      catch(e){console.error(`[autostart] ${pid}:`,e.message);}
    }
  },3000);
}

// ── Shutdown ──────────────────────────────────────────────
process.on('SIGTERM',()=>{Object.keys(procs).forEach(botStop);process.exit(0);});
process.on('SIGINT', ()=>{Object.keys(procs).forEach(botStop);process.exit(0);});

// ── Start ─────────────────────────────────────────────────
server.listen(PORT,'127.0.0.1',()=>{
  console.log(`[botpanel] Node.js v${process.version} started on :${PORT}`);
  autostart();
});

JSEOF
  chmod 640 "$PD/app/server.js"
  ok "server.js written"
}

# ════════════════════════════
# Write index.html
# ════════════════════════════
write_frontend() {
  info "Writing index.html..."
  python3 << 'PYEOF'
html = r"""
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Bot Manager</title>
<style>
:root{
  --bg:#f8fafc;--sf:#ffffff;--sf2:#f1f5f9;--sf3:#e2e8f0;
  --br:#cbd5e1;--pr:#6762a6;--pr2:#5a559c;--prl:rgba(103,98,166,.1);
  --ok:#059669;--er:#dc2626;--wa:#d97706;
  --tx:#1e293b;--mu:#64748b;--muli:#94a3b8;
  --m:'JetBrains Mono','Fira Code',monospace;--s:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;
  --tr:.15s cubic-bezier(.4,0,.2,1);--r:8px;
}
[data-dark]{
  --bg:#0d0e12;--sf:#16181f;--sf2:#1e2029;--sf3:#252836;
  --br:#2d3048;--tx:#e2e8f0;--mu:#94a3b8;--muli:#64748b;--prl:rgba(103,98,166,.15);
}
*{box-sizing:border-box;margin:0;padding:0;}
html,body{height:100%;background:var(--bg);color:var(--tx);font-family:var(--s);font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased;}
a{color:var(--pr);text-decoration:none;}
button{font-family:var(--s);}

/* ── Layout ─────────────────────────────────────────────── */
#app{display:flex;flex-direction:column;height:100vh;}
#hdr{height:56px;background:var(--sf);border-bottom:1px solid var(--br);display:flex;align-items:center;padding:0 24px;gap:16px;flex-shrink:0;z-index:100;}
#body{display:flex;flex:1;overflow:hidden;}
#sidebar{width:256px;background:var(--sf);border-right:1px solid var(--br);display:flex;flex-direction:column;flex-shrink:0;overflow:hidden;transition:width var(--tr);}
#main{flex:1;overflow:auto;}

/* ── Header ─────────────────────────────────────────────── */
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:.88rem;color:var(--tx);}
.logo-box{width:32px;height:32px;background:var(--pr);border-radius:8px;display:flex;align-items:center;justify-content:center;flex-shrink:0;}
.hdr-divider{width:1px;height:22px;background:var(--br);}
.hdr-crumb{font-size:.8rem;color:var(--mu);}
.hdr-right{margin-left:auto;display:flex;align-items:center;gap:2px;}
.ico-btn{width:34px;height:34px;border-radius:6px;border:none;background:transparent;color:var(--mu);cursor:pointer;display:flex;align-items:center;justify-content:center;transition:background var(--tr),color var(--tr);}
.ico-btn:hover{background:var(--sf2);color:var(--tx);}
.ico-btn.danger:hover{background:#fee2e2;color:var(--er);}
[data-dark] .ico-btn.danger:hover{background:rgba(220,38,38,.15);}
.conn{width:8px;height:8px;border-radius:50%;background:var(--ok);flex-shrink:0;transition:background var(--tr);}
.conn.off{background:var(--er);}
.lang-dd{background:var(--sf2);border:1px solid var(--br);color:var(--tx);border-radius:6px;padding:4px 8px;font-size:.75rem;cursor:pointer;outline:none;}

/* ── Sidebar ─────────────────────────────────────────────── */
.sb-top{padding:12px 12px 8px;}
.sb-search{width:100%;background:var(--sf2);border:1px solid var(--br);border-radius:6px;padding:7px 10px 7px 32px;color:var(--tx);font-size:.8rem;outline:none;transition:border-color var(--tr);background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='13' height='13' fill='none' stroke='%2394a3b8' stroke-width='2' viewBox='0 0 24 24'%3E%3Ccircle cx='11' cy='11' r='8'/%3E%3Cline x1='21' y1='21' x2='16.65' y2='16.65'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:10px center;}
.sb-search:focus{border-color:var(--pr);}
.sb-section-lbl{font-size:.65rem;font-weight:700;color:var(--muli);text-transform:uppercase;letter-spacing:.08em;padding:10px 14px 4px;}
.sb-apps{flex:1;overflow-y:auto;padding:0 8px 8px;}
.sb-app{display:flex;align-items:center;gap:9px;padding:8px 10px;border-radius:6px;cursor:pointer;transition:background var(--tr);position:relative;}
.sb-app:hover{background:var(--sf2);}
.sb-app.act{background:var(--prl);}
.sb-app-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;transition:background var(--tr);}
.sb-app-dot.on{background:var(--ok);}
.sb-app-dot.off{background:var(--muli);}
.sb-app-name{font-size:.82rem;font-weight:500;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--tx);}
.sb-app-meta{display:flex;gap:5px;align-items:center;flex-shrink:0;}
.sb-app-lang{font-size:.65rem;color:var(--mu);background:var(--sf2);padding:1px 5px;border-radius:3px;font-family:var(--m);}
.sb-app-up{font-size:.65rem;color:var(--mu);}
.sb-footer{padding:8px;border-top:1px solid var(--br);}
.sb-new-btn{width:100%;display:flex;align-items:center;gap:8px;padding:8px 12px;border-radius:6px;border:none;background:none;color:var(--mu);cursor:pointer;font-size:.8rem;transition:all var(--tr);}
.sb-new-btn:hover{background:var(--prl);color:var(--pr);}

/* ── Welcome ─────────────────────────────────────────────── */
#welcome{display:flex;align-items:center;justify-content:center;min-height:100%;padding:40px 20px;}
.welcome-inner{width:100%;max-width:480px;display:flex;flex-direction:column;align-items:center;gap:0;}
.wel-hero{text-align:center;margin-bottom:36px;}
.wel-icon{width:72px;height:72px;background:linear-gradient(135deg,var(--pr) 0%,#8b5cf6 100%);border-radius:18px;display:flex;align-items:center;justify-content:center;margin:0 auto 18px;box-shadow:0 8px 32px rgba(103,98,166,.3);}
.wel-title{font-size:1.6rem;font-weight:700;margin-bottom:8px;letter-spacing:-.02em;}
.wel-sub{color:var(--mu);font-size:.88rem;}
/* Big primary button */
.wel-cta{width:100%;padding:16px 24px;background:var(--pr);border:none;border-radius:10px;color:#fff;font-size:.95rem;font-weight:600;cursor:pointer;display:flex;align-items:center;gap:14px;text-align:left;margin-bottom:10px;transition:background var(--tr),transform var(--tr),box-shadow var(--tr);box-shadow:0 4px 14px rgba(103,98,166,.35);}
.wel-cta:hover{background:var(--pr2);transform:translateY(-1px);box-shadow:0 6px 20px rgba(103,98,166,.45);}
.wel-cta-icon{width:42px;height:42px;background:rgba(255,255,255,.18);border-radius:8px;display:flex;align-items:center;justify-content:center;flex-shrink:0;}
.wel-cta-t{font-size:.95rem;font-weight:700;margin-bottom:2px;}
.wel-cta-s{font-size:.72rem;opacity:.8;}
/* Secondary button */
.wel-sec{width:100%;padding:12px 16px;background:var(--sf);border:1px solid var(--br);border-radius:8px;color:var(--tx);font-size:.83rem;font-weight:500;cursor:pointer;display:flex;align-items:center;gap:12px;text-align:left;margin-bottom:28px;transition:all var(--tr);}
.wel-sec:hover{background:var(--sf2);border-color:var(--pr);}
.wel-sec-icon{width:34px;height:34px;background:var(--sf2);border-radius:7px;display:flex;align-items:center;justify-content:center;flex-shrink:0;}
/* Stats grid */
.wel-stats{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;width:100%;margin-bottom:28px;}
.wel-stat{background:var(--sf);border:1px solid var(--br);border-radius:8px;padding:14px 10px;text-align:center;}
.wel-stat-l{font-size:.6rem;color:var(--mu);text-transform:uppercase;letter-spacing:.07em;margin-bottom:5px;}
.wel-stat-v{font-size:1.15rem;font-weight:700;}
/* Quick help */
.wel-help-t{font-size:.65rem;font-weight:700;color:var(--mu);text-transform:uppercase;letter-spacing:.08em;margin-bottom:8px;width:100%;}
.wel-help-links{width:100%;display:flex;flex-direction:column;gap:2px;}
.wel-help-a{display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:7px;border:none;background:none;cursor:pointer;color:var(--tx);width:100%;text-align:left;transition:background var(--tr);font-size:.82rem;font-weight:500;}
.wel-help-a:hover{background:var(--sf2);}

/* ── App page ─────────────────────────────────────────────── */
#apppage{display:none;flex-direction:column;height:100%;overflow:hidden;}
/* App header */
.app-hdr{background:var(--sf);border-bottom:1px solid var(--br);padding:20px 24px 0;flex-shrink:0;}
.app-bc{font-size:.73rem;color:var(--mu);margin-bottom:10px;}
.app-bc span{color:var(--tx);font-weight:500;}
.app-title-row{display:flex;align-items:center;gap:12px;margin-bottom:18px;flex-wrap:wrap;}
.app-name{font-size:1.3rem;font-weight:700;letter-spacing:-.01em;}
.app-badge{font-size:.68rem;font-weight:700;padding:3px 8px;border-radius:20px;text-transform:uppercase;letter-spacing:.04em;}
.badge-tg{background:#dbeafe;color:#1d4ed8;}
.badge-dc{background:#ede9fe;color:#6d28d9;}
.badge-wa{background:#d1fae5;color:#065f46;}
.badge-vb{background:#fce7f3;color:#9d174d;}
[data-dark] .badge-tg{background:rgba(29,78,216,.2);color:#60a5fa;}
[data-dark] .badge-dc{background:rgba(109,40,217,.2);color:#a78bfa;}
[data-dark] .badge-wa{background:rgba(6,95,70,.2);color:#34d399;}
[data-dark] .badge-vb{background:rgba(157,23,77,.2);color:#f9a8d4;}
.app-btns{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding-bottom:14px;}
/* Buttons */
.btn{display:inline-flex;align-items:center;gap:5px;padding:7px 14px;border-radius:6px;border:none;font-size:.78rem;font-weight:600;cursor:pointer;transition:all var(--tr);white-space:nowrap;}
.btn:disabled{opacity:.4;cursor:not-allowed !important;}
.btn-pr{background:var(--pr);color:#fff;}
.btn-pr:hover:not(:disabled){background:var(--pr2);}
.btn-ok{background:#059669;color:#fff;}
.btn-ok:hover:not(:disabled){background:#047857;}
.btn-stop{background:#374151;color:#fff;}
.btn-stop:hover:not(:disabled){background:#4b5563;}
[data-dark] .btn-stop{background:#1f2937;}
.btn-wa{background:#d97706;color:#fff;}
.btn-wa:hover:not(:disabled){background:#b45309;}
.btn-ghost{background:var(--sf2);border:1px solid var(--br);color:var(--tx);}
.btn-ghost:hover:not(:disabled){background:var(--sf3);}
.btn-danger{background:transparent;border:1px solid var(--er);color:var(--er);}
.btn-danger:hover:not(:disabled){background:#fee2e2;}
[data-dark] .btn-danger:hover:not(:disabled){background:rgba(220,38,38,.12);}
/* Tabs */
.tabs{display:flex;gap:0;border-bottom:none;}
.tab{padding:10px 18px;border:none;background:none;color:var(--mu);font-size:.8rem;font-weight:600;cursor:pointer;border-bottom:2px solid transparent;transition:all var(--tr);letter-spacing:.01em;}
.tab:hover:not(.act){color:var(--tx);}
.tab.act{color:var(--pr);border-bottom-color:var(--pr);}
/* App body */
.app-body{flex:1;overflow:auto;}
.pane{display:none;padding:24px;}
.pane.act{display:block;}
.pane.full{display:none;padding:0;height:100%;}
.pane.full.act{display:flex;flex-direction:column;}

/* ── Cards/sections ──────────────────────────────────────── */
.card{background:var(--sf);border:1px solid var(--br);border-radius:var(--r);padding:16px 20px;margin-bottom:14px;}
.card-t{font-size:.68rem;font-weight:700;text-transform:uppercase;letter-spacing:.07em;color:var(--mu);margin-bottom:14px;}
.info-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;}
.info-cell{background:var(--sf2);border-radius:6px;padding:12px 14px;}
.info-cell-l{font-size:.65rem;text-transform:uppercase;letter-spacing:.06em;color:var(--mu);margin-bottom:5px;}
.info-cell-v{font-size:.88rem;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
/* autostart row */
.auto-row{display:flex;align-items:center;justify-content:space-between;}
.auto-row-left h3{font-size:.88rem;font-weight:600;}
.auto-row-left p{font-size:.75rem;color:var(--mu);margin-top:2px;}
.toggle{width:42px;height:24px;background:var(--muli);border-radius:12px;border:none;cursor:pointer;position:relative;transition:background var(--tr);flex-shrink:0;}
.toggle::after{content:'';position:absolute;width:18px;height:18px;border-radius:50%;background:#fff;top:3px;left:3px;transition:transform var(--tr);box-shadow:0 1px 3px rgba(0,0,0,.2);}
.toggle.on{background:var(--ok);}
.toggle.on::after{transform:translateX(18px);}
/* resource bars */
.res-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;}
.res-label{font-size:.72rem;color:var(--mu);margin-bottom:5px;}
.res-val{font-size:1rem;font-weight:700;margin-bottom:6px;}
.res-bar{height:5px;background:var(--sf3);border-radius:3px;overflow:hidden;}
.res-fill{height:100%;border-radius:3px;transition:width .5s ease;}
.res-fill.ok{background:var(--ok);}
.res-fill.wa{background:var(--wa);}
.res-fill.er{background:var(--er);}
.res-hint{font-size:.68rem;color:var(--mu);margin-top:4px;}
/* limits */
.limits-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px;}
.fg label{display:block;font-size:.72rem;color:var(--mu);margin-bottom:4px;}
.inp{width:100%;background:var(--sf2);border:1px solid var(--br);border-radius:6px;padding:8px 12px;color:var(--tx);font-size:.82rem;outline:none;transition:border-color var(--tr);}
.inp:focus{border-color:var(--pr);}
select.inp{cursor:pointer;}

/* ── Config Vars (Heroku-style) ──────────────────────────── */
.cfgvar-header{display:flex;align-items:center;gap:8px;padding:0 0 16px;}
.cfgvar-header h2{font-size:1rem;font-weight:700;flex:1;}
.cfgvar-note{background:var(--sf2);border:1px solid var(--br);border-radius:8px;padding:12px 16px;font-size:.78rem;color:var(--mu);margin-bottom:16px;line-height:1.7;}
.cfgvar-note code{font-family:var(--m);background:var(--sf3);padding:1px 5px;border-radius:3px;font-size:.75rem;}
.env-editor{width:100%;min-height:220px;max-height:60vh;background:var(--sf);border:1px solid var(--br);border-radius:8px;padding:14px;font-family:var(--m);font-size:.8rem;color:var(--tx);resize:vertical;outline:none;line-height:1.9;transition:border-color var(--tr);}
.env-editor:focus{border-color:var(--pr);}

/* ── Editor ──────────────────────────────────────────────── */
.editor-layout{display:flex;height:100%;overflow:hidden;}
.editor-sidebar{width:210px;border-right:1px solid var(--br);background:var(--sf);display:flex;flex-direction:column;overflow:hidden;flex-shrink:0;}
.editor-sidebar-hdr{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border-bottom:1px solid var(--br);font-size:.72rem;font-weight:700;color:var(--mu);text-transform:uppercase;letter-spacing:.06em;}
.file-list{flex:1;overflow-y:auto;padding:6px;}
.file-item{display:flex;align-items:center;gap:7px;padding:7px 8px;border-radius:5px;cursor:pointer;transition:background var(--tr);font-family:var(--m);font-size:.76rem;color:var(--tx);}
.file-item:hover{background:var(--sf2);}
.file-item.act{background:var(--prl);color:var(--pr);}
.file-size{font-size:.65rem;color:var(--mu);margin-left:auto;}
.editor-main{flex:1;display:flex;flex-direction:column;overflow:hidden;}
.editor-toolbar{display:flex;align-items:center;gap:8px;padding:8px 14px;border-bottom:1px solid var(--br);background:var(--sf);flex-shrink:0;}
.editor-fname{font-family:var(--m);font-size:.8rem;color:var(--mu);}
.editor-ta{flex:1;border:none;background:var(--sf2);color:var(--tx);font-family:var(--m);font-size:.78rem;padding:16px;resize:none;outline:none;line-height:1.8;}

/* ── Files manager ───────────────────────────────────────── */
.file-row{display:flex;align-items:center;gap:10px;padding:11px 16px;border-bottom:1px solid var(--br);transition:background var(--tr);}
.file-row:last-child{border-bottom:none;}
.file-row:hover{background:var(--sf2);}
.file-row-name{font-family:var(--m);font-size:.8rem;flex:1;}
.file-row-size{font-size:.72rem;color:var(--mu);flex-shrink:0;}
.icon-btn{width:28px;height:28px;border-radius:5px;border:none;background:none;color:var(--mu);cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all var(--tr);flex-shrink:0;}
.icon-btn:hover{background:var(--sf3);color:var(--tx);}
.icon-btn.red:hover{background:#fee2e2;color:var(--er);}
[data-dark] .icon-btn.red:hover{background:rgba(220,38,38,.15);}

/* ── Logs ────────────────────────────────────────────────── */
.log-wrap{height:100%;display:flex;flex-direction:column;}
.log-toolbar{display:flex;align-items:center;gap:8px;padding:10px 16px;border-bottom:1px solid var(--br);background:var(--sf);flex-shrink:0;}
.log-body{flex:1;overflow-y:auto;padding:12px 16px;font-family:var(--m);font-size:.75rem;line-height:1.9;background:var(--sf);}
.ll{white-space:pre-wrap;word-break:break-all;}
.ll.e{color:#ef4444;}.ll.w{color:#f59e0b;}.ll.wd{color:var(--mu);font-style:italic;}.ll.o{color:var(--ok);}
[data-dark] .ll.o{color:#86efac;}

/* ── Activity ────────────────────────────────────────────── */
.act-item{display:flex;gap:12px;align-items:flex-start;padding:12px 0;border-bottom:1px solid var(--br);}
.act-item:last-child{border-bottom:none;}
.act-icon{width:34px;height:34px;border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:.9rem;flex-shrink:0;}
.act-msg{font-size:.83rem;font-weight:500;}
.act-ts{font-size:.72rem;color:var(--mu);margin-top:2px;}

/* ── Diagnose ────────────────────────────────────────────── */
.diag-row{display:flex;align-items:center;gap:12px;padding:12px 16px;background:var(--sf);border:1px solid var(--br);border-radius:8px;margin-bottom:8px;}
.diag-icon{font-size:1.1rem;flex-shrink:0;}
.diag-check{font-size:.83rem;font-weight:600;}
.diag-msg{font-size:.75rem;color:var(--mu);margin-top:1px;}

/* ── Tooltips ────────────────────────────────────────────── */
[data-tip]{position:relative;}
[data-tip]:hover::after{content:attr(data-tip);position:absolute;bottom:calc(100% + 7px);left:50%;transform:translateX(-50%);background:#1e293b;color:#e2e8f0;border:1px solid #334155;padding:5px 10px;border-radius:7px;font-size:11px;white-space:nowrap;z-index:9999;pointer-events:none;box-shadow:0 4px 16px rgba(0,0,0,.3);}
[data-tip]:hover::before{content:'';position:absolute;bottom:calc(100% + 2px);left:50%;transform:translateX(-50%);border:5px solid transparent;border-top-color:#334155;z-index:9999;pointer-events:none;}

/* ── Power menu ──────────────────────────────────────────── */
.pwr-wrap{position:relative;}
.pwr-menu{position:absolute;right:0;top:calc(100% + 8px);background:var(--sf);border:1px solid var(--br);border-radius:10px;min-width:260px;z-index:400;box-shadow:0 8px 30px rgba(0,0,0,.15);padding:6px;display:none;}
[data-dark] .pwr-menu{box-shadow:0 8px 30px rgba(0,0,0,.5);}
.pwr-menu.op{display:block;}
.pwr-lbl{font-size:.65rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--mu);padding:6px 10px 4px;}
.pwr-div{height:1px;background:var(--br);margin:4px 0;}
.pwr-item{width:100%;display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:7px;border:none;background:none;cursor:pointer;color:var(--tx);font-size:.8rem;transition:background var(--tr);text-align:left;}
.pwr-item:hover{background:var(--sf2);}
.pwr-item.red:hover{background:#fee2e2;color:var(--er);}
[data-dark] .pwr-item.red:hover{background:rgba(220,38,38,.12);}
.pwr-item-ic{width:22px;text-align:center;flex-shrink:0;font-size:.9rem;}
.pwr-item-t{font-weight:600;font-size:.8rem;}
.pwr-item-s{font-size:.7rem;color:var(--mu);}

/* ── More menu ───────────────────────────────────────────── */
.more-menu{position:absolute;right:0;top:calc(100% + 6px);background:var(--sf);border:1px solid var(--br);border-radius:8px;min-width:200px;z-index:300;box-shadow:0 6px 20px rgba(0,0,0,.12);padding:5px;display:none;}
[data-dark] .more-menu{box-shadow:0 6px 20px rgba(0,0,0,.4);}
.more-menu.op{display:block;}
.more-item{width:100%;display:flex;align-items:center;gap:9px;padding:8px 11px;border:none;background:none;cursor:pointer;color:var(--tx);border-radius:5px;font-size:.8rem;text-align:left;transition:background var(--tr);}
.more-item:hover{background:var(--sf2);}
.more-item.red{color:var(--er);}
.more-item.red:hover{background:#fee2e2;}
[data-dark] .more-item.red:hover{background:rgba(220,38,38,.12);}

/* ── Op status modal ─────────────────────────────────────── */
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.5);backdrop-filter:blur(4px);z-index:500;display:none;align-items:center;justify-content:center;padding:16px;}
.overlay.op{display:flex;}
.modal{background:var(--sf);border:1px solid var(--br);border-radius:12px;width:100%;max-width:480px;max-height:88vh;overflow:auto;box-shadow:0 20px 60px rgba(0,0,0,.2);}
[data-dark] .modal{box-shadow:0 20px 60px rgba(0,0,0,.6);}
.modal-hdr{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;border-bottom:1px solid var(--br);}
.modal-t{font-size:.95rem;font-weight:700;}
.modal-body{padding:20px;}
.modal-foot{padding:14px 20px;border-top:1px solid var(--br);display:flex;justify-content:flex-end;gap:8px;}
.mclose{width:28px;height:28px;border-radius:5px;border:none;background:none;color:var(--mu);cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:.9rem;}
.mclose:hover{background:var(--sf2);}
.spinner{width:48px;height:48px;border:3px solid var(--br);border-top-color:var(--pr);border-radius:50%;animation:spin 1s linear infinite;margin:0 auto 16px;}
@keyframes spin{to{transform:rotate(360deg)}}
.countdown{font-size:2.5rem;font-weight:700;color:var(--pr);margin:8px 0;}
/* mode tabs */
.mode-tabs{display:flex;background:var(--sf2);border-radius:7px;padding:3px;gap:3px;margin-bottom:18px;}
.mode-tab{flex:1;padding:7px;border-radius:5px;border:none;font-size:.78rem;font-weight:600;cursor:pointer;transition:all var(--tr);background:none;color:var(--mu);}
.mode-tab.act{background:var(--sf);color:var(--tx);box-shadow:0 1px 3px rgba(0,0,0,.1);}
/* drop zone */
.dropzone{border:2px dashed var(--br);border-radius:8px;padding:24px;text-align:center;cursor:pointer;transition:all var(--tr);font-size:.82rem;color:var(--mu);}
.dropzone:hover,.dropzone.drag{border-color:var(--pr);background:var(--prl);}
.dropzone-icon{font-size:1.5rem;margin-bottom:8px;}
/* Toast */
.toasts{position:fixed;bottom:20px;right:20px;z-index:2000;display:flex;flex-direction:column;gap:8px;pointer-events:none;}
.toast{background:var(--sf);border:1px solid var(--br);border-radius:9px;padding:11px 16px;font-size:.8rem;display:flex;align-items:center;gap:10px;box-shadow:0 4px 20px rgba(0,0,0,.15);pointer-events:auto;animation:tin .2s ease;min-width:200px;max-width:320px;}
[data-dark] .toast{box-shadow:0 4px 20px rgba(0,0,0,.5);}
.toast.ok{border-left:3px solid var(--ok);}
.toast.err{border-left:3px solid var(--er);}
.toast.info{border-left:3px solid var(--pr);}
@keyframes tin{from{transform:translateX(16px);opacity:0}to{transform:translateX(0);opacity:1}}

/* Help */
.help-art-body{font-size:.84rem;line-height:1.9;color:var(--tx);}
.help-art-body h3{font-size:.95rem;font-weight:700;margin-bottom:12px;}
.help-art-body p{margin-bottom:10px;}
.help-art-body ul{margin:6px 0 10px 20px;line-height:2;}
.help-art-body code{font-family:var(--m);background:var(--sf2);padding:1px 5px;border-radius:3px;font-size:.78rem;}
.help-art-body pre{background:var(--sf2);padding:10px 14px;border-radius:7px;overflow-x:auto;margin:8px 0;font-family:var(--m);font-size:.78rem;}
.help-link{width:100%;display:flex;align-items:center;gap:12px;padding:12px 14px;border-radius:8px;border:none;background:none;cursor:pointer;color:var(--tx);text-align:left;transition:background var(--tr);font-size:.85rem;font-weight:500;}
.help-link:hover{background:var(--sf2);}

/* Responsive */
@media(max-width:768px){
  #sidebar{position:fixed;inset:0;z-index:200;width:280px;transform:translateX(-100%);transition:transform var(--tr);}
  #sidebar.mob{transform:translateX(0);}
  .info-grid{grid-template-columns:1fr;}
  .wel-stats{grid-template-columns:repeat(2,1fr);}
  .pane{padding:14px;}
  #mob-btn{display:flex!important;}
}
</style>
</head>
<body>
<div id="app">

<!-- ═══ HEADER ═══ -->
<header id="hdr">
  <div class="logo">
    <div class="logo-box">
      <svg width="18" height="18" fill="none" stroke="#fff" stroke-width="1.5" viewBox="0 0 24 24">
        <rect x="2" y="9" width="20" height="12" rx="3"/>
        <circle cx="8" cy="15" r="2.5" fill="#fff" stroke="none"/>
        <circle cx="16" cy="15" r="2.5" fill="#fff" stroke="none"/>
        <line x1="8" y1="3" x2="8" y2="9" stroke-linecap="round"/>
        <line x1="16" y1="3" x2="16" y2="9" stroke-linecap="round"/>
      </svg>
    </div>
    Bot Manager
  </div>
  <div class="hdr-divider"></div>
  <div class="hdr-crumb" id="hdr-crumb"></div>
  <div class="hdr-right">
    <div class="conn" id="conn"></div>
    <div class="pwr-wrap">
      <button class="ico-btn danger" id="pwr-btn" onclick="togglePwr()" data-tip="Питание">
        <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>
      </button>
      <div class="pwr-menu" id="pwr-menu">
        <div class="pwr-lbl" id="pm-lbl">Питание</div>
        <div class="pwr-div"></div>
        <button class="pwr-item" onclick="pwrAction('panel','soft')">
          <span class="pwr-item-ic" style="color:var(--pr)">↻</span>
          <div><div class="pwr-item-t" id="pm-ps">Мягкий рестарт панели</div><div class="pwr-item-s" id="pm-ps-s">Боты продолжают работать</div></div>
        </button>
        <button class="pwr-item" onclick="pwrAction('panel','hard')">
          <span class="pwr-item-ic" style="color:#8b5cf6">⏹</span>
          <div><div class="pwr-item-t" id="pm-ph">Стоп ботов + рестарт</div><div class="pwr-item-s" id="pm-ph-s">Остановить всех, затем рестарт</div></div>
        </button>
        <div class="pwr-div"></div>
        <button class="pwr-item" onclick="pwrAction('vds','soft')">
          <span class="pwr-item-ic" style="color:var(--wa)">↻</span>
          <div><div class="pwr-item-t" id="pm-vs">Мягкая перезагрузка VDS</div><div class="pwr-item-s" id="pm-vs-s">Корректное завершение ОС</div></div>
        </button>
        <button class="pwr-item red" onclick="pwrAction('vds','hard')">
          <span class="pwr-item-ic">⚡</span>
          <div><div class="pwr-item-t" id="pm-vh">Жёсткая перезагрузка VDS</div><div class="pwr-item-s" id="pm-vh-s">Только если сервер завис</div></div>
        </button>
        <div class="pwr-div"></div>
        <button class="pwr-item" onclick="openSrvStatus()">
          <span class="pwr-item-ic" style="color:var(--mu)">⟳</span>
          <div class="pwr-item-t" id="pm-stat">Статус сервера</div>
        </button>
      </div>
    </div>
    <button class="ico-btn" onclick="openHelp()" data-tip="Справка">
      <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
    </button>
    <button class="ico-btn" onclick="openSettings()" data-tip="Настройки">
      <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
    </button>
    <button class="ico-btn" onclick="toggleDark()" data-tip="Тема">
      <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
    </button>
    <select class="lang-dd" id="lang-dd" onchange="setLang(this.value)">
      <option value="ru">RU</option>
      <option value="ua">UA</option>
      <option value="en">EN</option>
    </select>
    <button class="ico-btn" id="mob-btn" onclick="toggleMob()" style="display:none">
      <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
    </button>
  </div>
</header>

<!-- ═══ BODY ═══ -->
<div id="body">

  <!-- Sidebar -->
  <nav id="sidebar">
    <div class="sb-top">
      <input class="sb-search" id="sb-q" placeholder="/" oninput="filterBots(this.value)">
    </div>
    <div class="sb-section-lbl" id="sb-apps-lbl">Приложения</div>
    <div class="sb-apps" id="sb-apps"></div>
    <div class="sb-footer">
      <button class="sb-new-btn" onclick="openCreate('new')" id="sb-new-btn">
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
        <span id="sb-new-lbl">Новый бот</span>
      </button>
    </div>
  </nav>

  <!-- Main -->
  <main id="main">

    <!-- Welcome -->
    <div id="welcome">
      <div class="welcome-inner">
        <div class="wel-hero">
          <div class="wel-icon">
            <svg width="36" height="36" fill="none" stroke="#fff" stroke-width="1.5" viewBox="0 0 24 24">
              <rect x="2" y="9" width="20" height="12" rx="3"/>
              <circle cx="8" cy="15" r="2.5" fill="#fff" stroke="none"/>
              <circle cx="16" cy="15" r="2.5" fill="#fff" stroke="none"/>
              <line x1="8" y1="3" x2="8" y2="9" stroke-linecap="round"/>
              <line x1="16" y1="3" x2="16" y2="9" stroke-linecap="round"/>
            </svg>
          </div>
          <h1 class="wel-title" id="wel-t">Выберите проект</h1>
          <p class="wel-sub" id="wel-s">Создайте бота или выберите из списка</p>
        </div>

        <button class="wel-cta" onclick="openCreate('new')">
          <div class="wel-cta-icon">
            <svg width="22" height="22" fill="none" stroke="#fff" stroke-width="2.5" viewBox="0 0 24 24"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
          </div>
          <div>
            <div class="wel-cta-t" id="wel-cta-t">Создать приложение</div>
            <div class="wel-cta-s">Telegram · Discord · WhatsApp · Viber</div>
          </div>
        </button>

        <button class="wel-sec" onclick="openCreate('restore')">
          <div class="wel-sec-icon">
            <svg width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
          </div>
          <div>
            <div style="font-weight:600;margin-bottom:1px" id="wel-rst-t">Восстановить из backup</div>
            <div style="font-size:.72rem;color:var(--mu)" id="wel-rst-s">Загрузить .zip архив</div>
          </div>
          <svg width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24" style="margin-left:auto;opacity:.4"><polyline points="9 18 15 12 9 6"/></svg>
        </button>

        <div class="wel-stats">
          <div class="wel-stat"><div class="wel-stat-l">CPU</div><div class="wel-stat-v" id="w-cpu">—</div></div>
          <div class="wel-stat"><div class="wel-stat-l">RAM</div><div class="wel-stat-v" id="w-ram">—</div></div>
          <div class="wel-stat"><div class="wel-stat-l">DISK</div><div class="wel-stat-v" id="w-disk">—</div></div>
          <div class="wel-stat"><div class="wel-stat-l" id="w-bots-l">BOTS</div><div class="wel-stat-v" id="w-bots">—</div></div>
        </div>

        <div class="wel-help-t" id="wel-help-t">Быстрая помощь</div>
        <div class="wel-help-links" id="wel-help-links"></div>
      </div>
    </div>

    <!-- App page -->
    <div id="apppage">
      <div class="app-hdr">
        <div class="app-bc"><a href="#" onclick="goHome();return false">Bot Manager</a> / <span id="ap-pid"></span></div>
        <div class="app-title-row">
          <div class="app-name" id="ap-name"></div>
          <span class="app-badge" id="ap-badge"></span>
          <div style="margin-left:auto;display:flex;gap:8px;position:relative">
            <button class="btn btn-ghost" id="more-btn" onclick="toggleMore()">
              <svg width="14" height="14" fill="currentColor" viewBox="0 0 24 24"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>
              <span id="more-lbl">Ещё</span>
            </button>
            <div class="more-menu" id="more-menu">
              <button class="more-item" onclick="showTab('lg');closeMore()"><svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="9" y1="21" x2="9" y2="9"/></svg><span id="mm-logs">Логи</span></button>
              <button class="more-item" onclick="dlBackup();closeMore()"><svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg><span id="mm-bkp">Backup .zip</span></button>
              <button class="more-item" onclick="openRename();closeMore()"><svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg><span id="mm-ren">Переименовать</span></button>
              <div style="height:1px;background:var(--br);margin:4px 0"></div>
              <button class="more-item red" onclick="confirmDel();closeMore()"><svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg><span id="mm-del">Удалить</span></button>
            </div>
          </div>
        </div>
        <div class="app-btns">
          <button class="btn btn-ok" onclick="botStart()" id="bt-start" data-tip="Запустить бота">
            <svg width="12" height="12" fill="currentColor" viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg>
            <span id="bt-start-l">Старт</span>
          </button>
          <button class="btn btn-stop" onclick="botStop()" id="bt-stop" data-tip="Остановить бота">
            <svg width="11" height="11" fill="currentColor" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16"/></svg>
            <span id="bt-stop-l">Стоп</span>
          </button>
          <button class="btn btn-wa" onclick="botRestart()" id="bt-restart" data-tip="Перезапустить (Ctrl+S → Рестарт)">
            <svg width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>
            <span id="bt-restart-l">Рестарт</span>
          </button>
        </div>
        <nav class="tabs" role="tablist">
          <button class="tab act" id="tb-ov" onclick="showTab('ov')"><span id="tl-ov">Обзор</span></button>
          <button class="tab" id="tb-ed" onclick="showTab('ed')"><span id="tl-ed">Редактор</span></button>
          <button class="tab" id="tb-ev" onclick="showTab('ev')"><span id="tl-ev">Config Vars</span></button>
          <button class="tab" id="tb-fm" onclick="showTab('fm')"><span id="tl-fm">Файлы</span></button>
          <button class="tab" id="tb-lg" onclick="showTab('lg')"><span id="tl-lg">Логи</span></button>
          <button class="tab" id="tb-ac" onclick="showTab('ac')"><span id="tl-ac">Activity</span></button>
          <button class="tab" id="tb-dg" onclick="showTab('dg')"><span id="tl-dg">Диагностика</span></button>
        </nav>
      </div>

      <div class="app-body">

        <!-- Overview -->
        <div class="pane act" id="pane-ov">
          <div class="info-grid" style="margin-bottom:14px">
            <div class="info-cell"><div class="info-cell-l" id="ic-status-l">Статус</div><div class="info-cell-v" id="ic-status">—</div></div>
            <div class="info-cell"><div class="info-cell-l" id="ic-up-l">Аптайм</div><div class="info-cell-v" id="ic-up">—</div></div>
            <div class="info-cell"><div class="info-cell-l">TOKEN</div><div class="info-cell-v" id="ic-tok" style="font-family:var(--m);font-size:.75rem;cursor:pointer" onclick="copyTok()" data-tip="Копировать">—</div></div>
            <div class="info-cell"><div class="info-cell-l" id="ic-main-l">Файл</div><div class="info-cell-v" id="ic-main" style="font-family:var(--m)">—</div></div>
            <div class="info-cell"><div class="info-cell-l" id="ic-cre-l">Создан</div><div class="info-cell-v" id="ic-cre">—</div></div>
            <div class="info-cell"><div class="info-cell-l" id="ic-lang-l">Язык</div><div class="info-cell-v" id="ic-lang" style="font-family:var(--m)">—</div></div>
          </div>

          <div class="card">
            <div class="card-t" id="ov-auto-t">Автозапуск</div>
            <div class="auto-row">
              <div class="auto-row-left">
                <h3 id="ov-auto-h">Автозапуск включён</h3>
                <p id="ov-auto-s">Бот запускается после перезагрузки сервера</p>
              </div>
              <button class="toggle" id="auto-sw" onclick="toggleAuto()"></button>
            </div>
          </div>

          <div class="card">
            <div class="card-t" id="ov-res-t">Ресурсы</div>
            <div class="res-grid">
              <div>
                <div class="res-label">RAM</div>
                <div class="res-val" id="ov-ram">— MB</div>
                <div class="res-bar"><div class="res-fill ok" id="ov-ram-fill" style="width:0%"></div></div>
                <div class="res-hint" id="ov-ram-hint"></div>
              </div>
              <div>
                <div class="res-label" id="ov-up-l">Аптайм</div>
                <div class="res-val" id="ov-up2">—</div>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="card-t" id="ov-lim-t">Watchdog / Лимиты</div>
            <div class="limits-grid">
              <div class="fg"><label id="lim-ram-l">RAM лимит (MB)</label><input class="inp" type="number" id="lim-ram" min="32" max="4096" value="256"></div>
              <div class="fg"><label id="lim-cpu-l">CPU лимит (%)</label><input class="inp" type="number" id="lim-cpu" min="10" max="100" value="80"></div>
            </div>
            <button class="btn btn-ghost" onclick="saveLimits()"><span id="lim-save-l">Сохранить</span></button>
          </div>
        </div>

        <!-- Editor -->
        <div class="pane full" id="pane-ed">
          <div class="editor-layout">
            <div class="editor-sidebar">
              <div class="editor-sidebar-hdr">
                <span id="ed-files-l">Файлы</span>
                <button class="icon-btn" onclick="newFile()" data-tip="Создать файл">+</button>
              </div>
              <div class="file-list" id="ed-filelist"></div>
            </div>
            <div class="editor-main">
              <div class="editor-toolbar">
                <span class="editor-fname" id="ed-fname">—</span>
                <div style="margin-left:auto">
                  <button class="btn btn-ok" style="font-size:.73rem;padding:5px 12px" onclick="saveFile()" id="bt-save" data-tip="Ctrl+S">
                    <span id="bt-save-l">Сохранить</span>
                  </button>
                </div>
              </div>
              <textarea class="editor-ta" id="editor" spellcheck="false" placeholder="Выберите файл..."></textarea>
            </div>
          </div>
        </div>

        <!-- Config Vars -->
        <div class="pane" id="pane-ev">
          <div class="cfgvar-header">
            <h2 id="ev-t">Config Variables</h2>
            <button class="btn btn-ok" onclick="saveEnv()" id="bt-env"><span id="bt-env-l">Сохранить</span></button>
          </div>
          <div class="cfgvar-note" id="ev-note">
            Переменные доступны боту как переменные окружения.
            Python: <code>os.environ.get('KEY')</code> · Node.js: <code>process.env.KEY</code>
            Формат: <code>KEY=value</code> (по одной на строку). Не коммитить .env в git.
          </div>
          <textarea class="env-editor" id="env-ed" placeholder="BOT_TOKEN=123456:ABC...&#10;DATABASE_URL=postgresql://...&#10;DEBUG=false"></textarea>
        </div>

        <!-- Files -->
        <div class="pane" id="pane-fm">
          <div style="display:flex;align-items:center;gap:10px;margin-bottom:16px;flex-wrap:wrap">
            <h2 style="font-size:.95rem;font-weight:700;flex:1" id="fm-t">Файлы</h2>
            <label class="btn btn-ghost" style="cursor:pointer" data-tip="Загрузить файл">
              <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
              <span id="fm-up-l">Загрузить</span>
              <input type="file" id="fm-inp" style="display:none" onchange="uploadFile(this)">
            </label>
          </div>
          <div class="card" style="padding:0;overflow:hidden" id="fm-list"></div>
        </div>

        <!-- Logs -->
        <div class="pane full" id="pane-lg">
          <div class="log-wrap">
            <div class="log-toolbar">
              <select id="log-filter" class="inp" style="width:auto;padding:4px 8px;font-size:.75rem" onchange="logFilter=this.value">
                <option value="all" id="lf-all">Все</option>
                <option value="e" id="lf-err">Ошибки</option>
                <option value="w" id="lf-warn">Предупреждения</option>
                <option value="wd" id="lf-wd">Watchdog</option>
              </select>
              <div style="margin-left:auto;display:flex;gap:6px">
                <button class="btn btn-ghost toggle" id="as-btn" style="width:auto;height:auto;padding:5px 12px;font-size:.73rem;border-radius:6px;font-family:var(--s);border:1px solid var(--br)" onclick="toggleAs()">
                  <span id="as-l">Автопрокрутка</span>
                </button>
                <button class="btn btn-ghost" style="font-size:.73rem" onclick="clearLogs()"><span id="cl-l">Очистить</span></button>
              </div>
            </div>
            <div class="log-body" id="log-body"></div>
          </div>
        </div>

        <!-- Activity -->
        <div class="pane" id="pane-ac">
          <h2 style="font-size:.95rem;font-weight:700;margin-bottom:16px" id="ac-t">Activity</h2>
          <div id="ac-list"></div>
        </div>

        <!-- Diagnose -->
        <div class="pane" id="pane-dg">
          <div style="display:flex;align-items:center;gap:10px;margin-bottom:16px">
            <h2 style="font-size:.95rem;font-weight:700;flex:1" id="dg-t">Диагностика</h2>
            <button class="btn btn-pr" onclick="runDiag()" id="bt-dg"><span id="bt-dg-l">Проверить</span></button>
          </div>
          <div id="dg-res"></div>
        </div>

      </div><!-- app-body -->
    </div><!-- apppage -->
  </main>
</div>

<!-- ═══ TOASTS ═══ -->
<div class="toasts" id="toasts"></div>

<!-- ═══ OP MODAL ═══ -->
<div class="overlay" id="op-modal">
  <div class="modal" style="max-width:340px">
    <div class="modal-body" style="text-align:center;padding:28px 20px">
      <div class="spinner" id="op-spin"></div>
      <div style="font-size:.95rem;font-weight:700;margin-bottom:8px" id="op-t">Выполняется...</div>
      <div style="font-size:.8rem;color:var(--mu)" id="op-s"></div>
      <div class="countdown" id="op-cd" style="display:none"></div>
    </div>
  </div>
</div>

<!-- ═══ CREATE MODAL ═══ -->
<div class="overlay" id="modal-create">
  <div class="modal">
    <div class="modal-hdr">
      <div class="modal-t" id="mc-t">Новый бот</div>
      <button class="mclose" onclick="closeM('modal-create')">✕</button>
    </div>
    <div class="modal-body">
      <div class="mode-tabs">
        <button class="mode-tab act" id="mt-new" onclick="setMode('new')"><span id="mt-new-l">✦ Новый бот</span></button>
        <button class="mode-tab" id="mt-rst" onclick="setMode('restore')"><span id="mt-rst-l">⟳ Восстановить</span></button>
      </div>
      <!-- New bot -->
      <div id="mc-new">
        <div class="fg" style="margin-bottom:12px">
          <label class="inp" style="display:none"></label>
          <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="mc-name-l">Название</label>
          <input class="inp" id="mc-name" placeholder="my_telegram_bot">
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:12px">
          <div class="fg">
            <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="mc-plat-l">Платформа</label>
            <select class="inp" id="mc-plat" onchange="onPlatChange()">
              <option value="telegram">Telegram</option>
              <option value="discord">Discord</option>
              <option value="whatsapp">WhatsApp</option>
              <option value="viber">Viber</option>
            </select>
          </div>
          <div class="fg">
            <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="mc-lang-l">Язык</label>
            <select class="inp" id="mc-lang">
              <option value="python">Python</option>
              <option value="node">Node.js</option>
              <option value="php">PHP</option>
              <option value="ruby">Ruby</option>
            </select>
          </div>
        </div>
        <div class="fg" style="margin-bottom:12px">
          <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="mc-tok-l">Токен бота</label>
          <input class="inp" id="mc-tok" placeholder="123456:ABC...">
          <div style="font-size:.7rem;color:var(--mu);margin-top:4px" id="mc-tok-h">Получить у @BotFather в Telegram</div>
        </div>
        <div class="fg">
          <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="mc-tpl-l">Шаблон кода</label>
          <select class="inp" id="mc-tpl">
            <option value="basic">Basic — /start /help</option>
            <option value="echo">Echo — повтор сообщений</option>
            <option value="menu">Menu — кнопки клавиатуры</option>
            <option value="broadcast">Broadcast — рассылка</option>
            <option value="inline">Inline — кнопки под сообщением</option>
          </select>
        </div>
      </div>
      <!-- Restore -->
      <div id="mc-rst" style="display:none">
        <div class="fg" style="margin-bottom:12px">
          <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="mc-rname-l">Название (или оставь пустым)</label>
          <input class="inp" id="mc-rname" placeholder="my_bot">
        </div>
        <div class="dropzone" id="mc-drop" onclick="document.getElementById('mc-zip').click()"
          ondragover="event.preventDefault();this.classList.add('drag')"
          ondragleave="this.classList.remove('drag')"
          ondrop="onDrop(event)">
          <div class="dropzone-icon">📦</div>
          <div id="mc-drop-lbl" style="font-weight:600;margin-bottom:3px">Перетащи .zip или нажми</div>
          <div style="font-size:.72rem;opacity:.7">bot_name_20260418.zip</div>
        </div>
        <input type="file" id="mc-zip" accept=".zip" style="display:none" onchange="onZip(this.files[0])">
        <div id="mc-zip-ok" style="display:none;background:var(--sf2);border-radius:7px;padding:8px 12px;font-size:.78rem;margin-top:8px;color:var(--ok)"></div>
      </div>
    </div>
    <div class="modal-foot">
      <button class="btn btn-ghost" onclick="closeM('modal-create')" id="mc-cancel">Отмена</button>
      <button class="btn btn-pr" onclick="submitCreate()" id="mc-ok">Создать</button>
    </div>
  </div>
</div>

<!-- ═══ RENAME MODAL ═══ -->
<div class="overlay" id="modal-rename">
  <div class="modal" style="max-width:380px">
    <div class="modal-hdr">
      <div class="modal-t" id="ren-t">Переименовать</div>
      <button class="mclose" onclick="closeM('modal-rename')">✕</button>
    </div>
    <div class="modal-body">
      <div class="fg" style="margin-bottom:8px">
        <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="ren-l">Новое название</label>
        <input class="inp" id="ren-inp">
      </div>
      <div style="font-size:.73rem;color:var(--mu)" id="ren-note">Название отображается в панели. Папка бота не переименовывается.</div>
    </div>
    <div class="modal-foot">
      <button class="btn btn-ghost" onclick="closeM('modal-rename')">Отмена</button>
      <button class="btn btn-pr" onclick="submitRename()"><span id="ren-ok-l">Сохранить</span></button>
    </div>
  </div>
</div>

<!-- ═══ SETTINGS MODAL ═══ -->
<div class="overlay" id="modal-settings">
  <div class="modal">
    <div class="modal-hdr">
      <div class="modal-t" id="set-t">Настройки</div>
      <button class="mclose" onclick="closeM('modal-settings')">✕</button>
    </div>
    <div class="modal-body">
      <div class="card">
        <div class="card-t" id="set-pw-t">Пароль</div>
        <div class="fg" style="margin-bottom:10px"><label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="set-pw-l">Новый пароль</label><input class="inp" type="password" id="set-pw" placeholder="Минимум 4 символа"></div>
        <button class="btn btn-pr" onclick="changePw()" style="font-size:.75rem"><span id="set-chpw-l">Изменить пароль</span></button>
      </div>
      <div class="card">
        <div class="card-t" id="set-tok-t">Токен доступа</div>
        <div style="font-size:.75rem;color:var(--mu);margin-bottom:10px" id="set-tok-s">Ссылка для входа без пароля</div>
        <div style="display:flex;gap:8px;margin-bottom:6px">
          <input class="inp" id="set-tok-v" readonly style="font-family:var(--m);font-size:.72rem;flex:1">
          <button class="btn btn-ghost" onclick="copyLink()" data-tip="Копировать ссылку">
            <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
          </button>
          <button class="btn btn-wa" onclick="regenTok()"><span id="set-regen-l">Обновить</span></button>
        </div>
      </div>
      <div class="card" id="srv-card" style="display:none">
        <div class="card-t" id="set-srv-t">Статус сервера</div>
        <div id="srv-body" style="font-family:var(--m);font-size:.75rem;color:var(--mu);line-height:2.1"></div>
      </div>
    </div>
  </div>
</div>

<!-- ═══ HELP MODAL ═══ -->
<div class="overlay" id="modal-help">
  <div class="modal" style="max-width:620px">
    <div class="modal-hdr">
      <div class="modal-t" id="help-t">Справка</div>
      <button class="mclose" onclick="closeM('modal-help')">✕</button>
    </div>
    <div class="modal-body" style="max-height:72vh;overflow-y:auto">
      <div id="help-list"></div>
      <div id="help-art" style="display:none">
        <button onclick="backToHelp()" style="display:flex;align-items:center;gap:6px;background:none;border:none;color:var(--pr);cursor:pointer;font-size:.8rem;margin-bottom:16px;padding:0;font-weight:600">
          <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="15 18 9 12 15 6"/></svg>
          <span id="help-back-l">Назад</span>
        </button>
        <div id="help-art-body" class="help-art-body"></div>
      </div>
    </div>
  </div>
</div>

<!-- ═══ LOGIN ═══ -->
<div id="login" style="position:fixed;inset:0;background:var(--bg);z-index:900;display:flex;align-items:center;justify-content:center;padding:20px">
  <div style="width:100%;max-width:360px">
    <div style="text-align:center;margin-bottom:28px">
      <div style="width:56px;height:56px;background:var(--pr);border-radius:14px;display:flex;align-items:center;justify-content:center;margin:0 auto 16px">
        <svg width="28" height="28" fill="none" stroke="#fff" stroke-width="1.5" viewBox="0 0 24 24"><rect x="2" y="9" width="20" height="12" rx="3"/><circle cx="8" cy="15" r="2.5" fill="#fff" stroke="none"/><circle cx="16" cy="15" r="2.5" fill="#fff" stroke="none"/><line x1="8" y1="3" x2="8" y2="9" stroke-linecap="round"/><line x1="16" y1="3" x2="16" y2="9" stroke-linecap="round"/></svg>
      </div>
      <h1 style="font-size:1.3rem;font-weight:700;margin-bottom:6px">Bot Manager</h1>
      <p style="color:var(--mu);font-size:.83rem" id="lg-sub">Войдите чтобы управлять ботами</p>
    </div>
    <div id="lg-form" style="display:none">
      <div class="fg" style="margin-bottom:12px">
        <label style="font-size:.72rem;color:var(--mu);margin-bottom:4px;display:block" id="lg-pw-l">Пароль</label>
        <input class="inp" type="password" id="lg-pw" placeholder="Введите пароль...">
      </div>
      <button class="btn btn-pr" style="width:100%;justify-content:center;padding:10px;font-size:.88rem" onclick="doLogin()" id="lg-btn">
        <span id="lg-btn-l">Войти</span>
      </button>
      <div id="lg-err" style="color:var(--er);font-size:.78rem;margin-top:8px;display:none;text-align:center"></div>
    </div>
    <button style="width:100%;padding:10px;margin-top:10px;background:var(--sf2);border:1px solid var(--br);border-radius:7px;color:var(--mu);cursor:pointer;font-size:.82rem;transition:all var(--tr)" onclick="showLoginForm()" id="lg-show-btn" onmouseover="this.style.background='var(--sf3)'" onmouseout="this.style.background='var(--sf2)'">
      <span id="lg-show-l">Войти с паролем</span>
    </button>
  </div>
</div>

<script>
// ═══════════════════════════════════════════════════════════
// I18N — полный RU/UA/EN
// ═══════════════════════════════════════════════════════════
const T={
ru:{
  w_t:'Выберите проект',w_s:'Создайте бота или выберите из списка',
  w_cta:'Создать приложение',w_rst:'Восстановить из backup',w_rst_s:'Загрузить .zip архив',
  w_help:'Быстрая помощь',sb_apps:'Приложения',sb_new:'Новый бот',
  tl_ov:'Обзор',tl_ed:'Редактор',tl_ev:'Config Vars',tl_fm:'Файлы',tl_lg:'Логи',tl_ac:'Activity',tl_dg:'Диагностика',
  bt_start:'Старт',bt_stop:'Стоп',bt_restart:'Рестарт',bt_save:'Сохранить',
  ic_status:'Статус',ic_up:'Аптайм',ic_main:'Файл',ic_cre:'Создан',ic_lang:'Язык',
  ov_auto:'Автозапуск',ov_auto_h:'Автозапуск включён',ov_auto_s:'Бот запускается после перезагрузки сервера',
  ov_res:'Ресурсы',ov_lim:'Watchdog / Лимиты',lim_ram:'RAM лимит (MB)',lim_cpu:'CPU лимит (%)',lim_save:'Сохранить',
  ev_t:'Config Variables',ev_save:'Сохранить',
  ev_note:'Переменные доступны боту как env vars. Python: os.environ.get("KEY") · Node.js: process.env.KEY. Формат: KEY=value (по одной на строку).',
  fm_t:'Файлы',fm_up:'Загрузить',
  ac_t:'Activity',dg_t:'Диагностика',dg_check:'Проверить',
  ed_files:'Файлы',
  lf_all:'Все',lf_err:'Ошибки',lf_warn:'Предупреждения',lf_wd:'Watchdog',as_l:'Автопрокрутка',cl_l:'Очистить',
  mm_logs:'Просмотр логов',mm_bkp:'Backup .zip',mm_ren:'Переименовать',mm_del:'Удалить',more:'Ещё',
  pm_lbl:'Питание',pm_ps:'Мягкий рестарт панели',pm_ps_s:'Боты продолжают работать',
  pm_ph:'Стоп ботов + рестарт',pm_ph_s:'Остановить всех, затем рестарт',
  pm_vs:'Мягкая перезагрузка VDS',pm_vs_s:'Корректное завершение ОС',
  pm_vh:'Жёсткая перезагрузка VDS',pm_vh_s:'Только если сервер завис',
  pm_stat:'Статус сервера',
  set_t:'Настройки',set_pw_t:'Пароль',set_pw_l:'Новый пароль',set_chpw:'Изменить пароль',
  set_tok_t:'Токен доступа',set_tok_s:'Ссылка для входа без пароля',set_regen:'Обновить',set_srv_t:'Статус сервера',
  mc_t_new:'Новый бот',mc_t_rst:'Восстановить',mt_new:'✦ Новый бот',mt_rst:'⟳ Восстановить',
  mc_name:'Название',mc_plat:'Платформа',mc_lang:'Язык',mc_tok:'Токен бота',
  mc_tok_h:'Получить у @BotFather в Telegram',mc_tpl:'Шаблон кода',
  mc_rname:'Название (или оставь пустым)',mc_drop:'Перетащи .zip или нажми',
  mc_cancel:'Отмена',mc_ok_new:'Создать',mc_ok_rst:'Восстановить',
  ren_t:'Переименовать',ren_l:'Новое название',ren_note:'Название отображается в панели. Папка не переименовывается.',ren_ok:'Сохранить',
  help_t:'Справка',help_back:'Назад к статьям',
  lg_sub:'Войдите чтобы управлять ботами',lg_pw:'Пароль',lg_btn:'Войти',lg_show:'Войти с паролем',
  running:'Запущен',stopped:'Остановлен',
  op_panel:'Перезапуск панели...',op_panel_s:'Страница обновится через несколько секунд',
  op_vds:'Перезагрузка сервера...',op_vds_s:'Сервер перезагружается',
  confirm_del:'Удалить проект и все файлы?',
  confirm_vds:'Перезагрузить сервер?',
  confirm_hard:'⚡ Жёсткая перезагрузка — мгновенный ресет. Продолжить?',
  w_bots_l:'БОТЫ',
},
ua:{
  w_t:'Виберіть проект',w_s:'Створіть бота або виберіть зі списку',
  w_cta:'Створити застосунок',w_rst:'Відновити з backup',w_rst_s:'Завантажити .zip архів',
  w_help:'Швидка допомога',sb_apps:'Застосунки',sb_new:'Новий бот',
  tl_ov:'Огляд',tl_ed:'Редактор',tl_ev:'Config Vars',tl_fm:'Файли',tl_lg:'Логи',tl_ac:'Activity',tl_dg:'Діагностика',
  bt_start:'Старт',bt_stop:'Стоп',bt_restart:'Рестарт',bt_save:'Зберегти',
  ic_status:'Статус',ic_up:'Аптайм',ic_main:'Файл',ic_cre:'Створено',ic_lang:'Мова',
  ov_auto:'Автозапуск',ov_auto_h:'Автозапуск увімкнено',ov_auto_s:'Бот запускається після перезавантаження',
  ov_res:'Ресурси',ov_lim:'Watchdog / Ліміти',lim_ram:'RAM ліміт (MB)',lim_cpu:'CPU ліміт (%)',lim_save:'Зберегти',
  ev_t:'Config Variables',ev_save:'Зберегти',
  ev_note:'Змінні доступні боту як env vars. Python: os.environ.get("KEY") · Node.js: process.env.KEY. Формат: KEY=value.',
  fm_t:'Файли',fm_up:'Завантажити',
  ac_t:'Activity',dg_t:'Діагностика',dg_check:'Перевірити',ed_files:'Файли',
  lf_all:'Всі',lf_err:'Помилки',lf_warn:'Попередження',lf_wd:'Watchdog',as_l:'Автопрокрутка',cl_l:'Очистити',
  mm_logs:'Переглянути логи',mm_bkp:'Backup .zip',mm_ren:'Перейменувати',mm_del:'Видалити',more:'Ще',
  pm_lbl:'Живлення',pm_ps:"М'який рестарт панелі",pm_ps_s:'Боти продовжують працювати',
  pm_ph:'Стоп ботів + рестарт',pm_ph_s:'Зупинити всіх, потім рестарт',
  pm_vs:"М'яке перезавантаження VDS",pm_vs_s:'Коректне завершення ОС',
  pm_vh:'Жорстке перезавантаження VDS',pm_vh_s:'Тільки якщо сервер завис',
  pm_stat:'Статус сервера',
  set_t:'Налаштування',set_pw_t:'Пароль',set_pw_l:'Новий пароль',set_chpw:'Змінити пароль',
  set_tok_t:'Токен доступу',set_tok_s:'Посилання для входу без пароля',set_regen:'Оновити',set_srv_t:'Статус сервера',
  mc_t_new:'Новий бот',mc_t_rst:'Відновити',mt_new:'✦ Новий бот',mt_rst:'⟳ Відновити',
  mc_name:'Назва',mc_plat:'Платформа',mc_lang:'Мова',mc_tok:'Токен бота',
  mc_tok_h:'Отримати у @BotFather в Telegram',mc_tpl:'Шаблон коду',
  mc_rname:"Назва (або залиш порожнім)",mc_drop:'Перетягни .zip або натисни',
  mc_cancel:'Скасувати',mc_ok_new:'Створити',mc_ok_rst:'Відновити',
  ren_t:'Перейменувати',ren_l:'Нова назва',ren_note:"Назва відображається в панелі. Папка не перейменовується.",ren_ok:'Зберегти',
  help_t:'Довідка',help_back:'Назад до статей',
  lg_sub:'Увійдіть щоб керувати ботами',lg_pw:'Пароль',lg_btn:'Увійти',lg_show:'Увійти з паролем',
  running:'Запущено',stopped:'Зупинено',
  op_panel:'Перезапуск панелі...',op_panel_s:'Сторінка оновиться за кілька секунд',
  op_vds:'Перезавантаження сервера...',op_vds_s:'Сервер перезавантажується',
  confirm_del:'Видалити проект і всі файли?',
  confirm_vds:'Перезавантажити сервер?',
  confirm_hard:'⚡ Жорстке перезавантаження — миттєвий ресет. Продовжити?',
  w_bots_l:'БОТИ',
},
en:{
  w_t:'Select a project',w_s:'Create a bot or choose from the list',
  w_cta:'Create new app',w_rst:'Restore from backup',w_rst_s:'Upload .zip archive',
  w_help:'Quick help',sb_apps:'Apps',sb_new:'New bot',
  tl_ov:'Overview',tl_ed:'Editor',tl_ev:'Config Vars',tl_fm:'Files',tl_lg:'Logs',tl_ac:'Activity',tl_dg:'Diagnose',
  bt_start:'Start',bt_stop:'Stop',bt_restart:'Restart',bt_save:'Save',
  ic_status:'Status',ic_up:'Uptime',ic_main:'File',ic_cre:'Created',ic_lang:'Language',
  ov_auto:'Autostart',ov_auto_h:'Autostart enabled',ov_auto_s:'Bot starts after server reboot',
  ov_res:'Resources',ov_lim:'Watchdog / Limits',lim_ram:'RAM limit (MB)',lim_cpu:'CPU limit (%)',lim_save:'Save',
  ev_t:'Config Variables',ev_save:'Save',
  ev_note:'Variables available to bot as env vars. Python: os.environ.get("KEY") · Node.js: process.env.KEY. Format: KEY=value per line.',
  fm_t:'Files',fm_up:'Upload',
  ac_t:'Activity',dg_t:'Diagnose',dg_check:'Check',ed_files:'Files',
  lf_all:'All',lf_err:'Errors',lf_warn:'Warnings',lf_wd:'Watchdog',as_l:'Autoscroll',cl_l:'Clear',
  mm_logs:'View logs',mm_bkp:'Backup .zip',mm_ren:'Rename',mm_del:'Delete',more:'More',
  pm_lbl:'Power',pm_ps:'Soft panel restart',pm_ps_s:'Bots keep running',
  pm_ph:'Stop bots + restart',pm_ph_s:'Stop all bots, then restart',
  pm_vs:'Soft VDS reboot',pm_vs_s:'Graceful OS shutdown',
  pm_vh:'Hard VDS reboot',pm_vh_s:'Only if server is frozen',
  pm_stat:'Server status',
  set_t:'Settings',set_pw_t:'Password',set_pw_l:'New password',set_chpw:'Change password',
  set_tok_t:'Access token',set_tok_s:'Login link without password',set_regen:'Regenerate',set_srv_t:'Server status',
  mc_t_new:'New bot',mc_t_rst:'Restore',mt_new:'✦ New bot',mt_rst:'⟳ Restore',
  mc_name:'Name',mc_plat:'Platform',mc_lang:'Language',mc_tok:'Bot token',
  mc_tok_h:'Get from @BotFather in Telegram',mc_tpl:'Code template',
  mc_rname:'Name (or leave empty)',mc_drop:'Drop .zip or click',
  mc_cancel:'Cancel',mc_ok_new:'Create',mc_ok_rst:'Restore',
  ren_t:'Rename',ren_l:'New name',ren_note:'Display name only. Bot folder is not renamed.',ren_ok:'Save',
  help_t:'Help',help_back:'Back to articles',
  lg_sub:'Log in to manage your bots',lg_pw:'Password',lg_btn:'Log in',lg_show:'Log in with password',
  running:'Running',stopped:'Stopped',
  op_panel:'Restarting panel...',op_panel_s:'Page will reload in a few seconds',
  op_vds:'Rebooting server...',op_vds_s:'Server is rebooting',
  confirm_del:'Delete project and all its files?',
  confirm_vds:'Reboot the server?',
  confirm_hard:'⚡ Hard reboot — instant reset. Continue?',
  w_bots_l:'BOTS',
},
};

// ── Help articles (RU/UA/EN) ──────────────────────────────
const HELP={
ru:[
  {id:'create',icon:'🤖',t:'Как создать бота',b:`<h3>Как создать бота</h3>
<p>Нажми кнопку <b>Создать приложение</b> на главном экране или <b>+ Новый бот</b> в боковой панели.</p>
<p><b>Шаг 1 — Название.</b> Любое имя латиницей, например <code>my_telegram_bot</code>. Используется как идентификатор.</p>
<p><b>Шаг 2 — Платформа.</b></p>
<ul><li><b>Telegram</b> — самый простой старт, токен от @BotFather</li><li><b>Discord</b> — OAuth2 → Bot → Token</li><li><b>WhatsApp</b> — Meta Developers, Business API</li><li><b>Viber</b> — Viber Admin Panel</li></ul>
<p><b>Шаг 3 — Язык.</b> Python (проще всего), Node.js, PHP, Ruby.</p>
<p><b>Шаг 4 — Токен.</b> Вставь токен бота. Он автоматически передаётся в <code>BOT_TOKEN</code> переменную окружения.</p>
<p><b>Шаг 5 — Шаблон.</b> Basic, Echo, Menu, Broadcast или Inline — готовый код сразу запускается.</p>
<p>Нажми <b>Создать</b> — папка с кодом и зависимостями будет готова автоматически.</p>`},
  {id:'token',icon:'🔑',t:'Токен Telegram (@BotFather)',b:`<h3>Получить токен Telegram</h3>
<p>1. Открой Telegram, найди <b>@BotFather</b>.</p>
<p>2. Отправь команду <code>/newbot</code></p>
<p>3. Придумай имя (видят пользователи) и username (должен заканчиваться на <b>bot</b>).</p>
<p>4. BotFather пришлёт токен:</p>
<pre>1234567890:ABCdefGHIjklMNOpqrsTUV</pre>
<p>Скопируй токен и вставь в поле <b>Токен бота</b> при создании.</p>
<p><b>Важно:</b> токен хранится в env бота (<code>BOT_TOKEN</code>) и в коде шаблона. Никому не передавай — это полный доступ к боту.</p>`},
  {id:'start',icon:'▶️',t:'Запуск, остановка, рестарт',b:`<h3>Управление ботом</h3>
<p><b>Старт</b> — запустить бота. Бот запускается через несколько секунд, статус меняется на «Запущен».</p>
<p><b>Стоп</b> — корректно остановить бота.</p>
<p><b>Рестарт</b> — перезапустить. Удобно после изменения кода: сохрани файл → нажми Рестарт.</p>
<p><b>Автозапуск</b> — включи тумблер на вкладке Обзор. Бот будет стартовать автоматически после перезагрузки сервера.</p>
<p><b>Watchdog</b> — если бот упадёт с ошибкой, автоматически перезапустится через 3 секунды. В логах будет: <code>[WD] Crashed rc=1, restart in 3s...</code></p>`},
  {id:'edit',icon:'✏️',t:'Редактирование кода',b:`<h3>Редактор кода</h3>
<p>Перейди на вкладку <b>Редактор</b>. Слева — список файлов, нажми на нужный.</p>
<p><b>Сохранить:</b> кнопка «Сохранить» или <code>Ctrl+S</code>.</p>
<p><b>Применить изменения:</b> после сохранения нажми <b>Рестарт</b> на панели вверху.</p>
<p><b>Токен</b> доступен в коде через переменную окружения:</p>
<pre># Python
BOT_TOKEN = os.environ.get('BOT_TOKEN', '')
# Node.js
const BOT_TOKEN = process.env.BOT_TOKEN</pre>
<p><b>Создать файл:</b> кнопка «+» над списком файлов.</p>`},
  {id:'env',icon:'⚙️',t:'Config Variables (.env)',b:`<h3>Config Variables</h3>
<p>Вкладка <b>Config Vars</b> — переменные окружения для бота (аналог Heroku Config Vars).</p>
<p>Формат: одна переменная на строку</p>
<pre>BOT_TOKEN=123456:ABC...
DATABASE_URL=postgresql://user:pass@host/db
DEBUG=false
API_KEY=your_secret_key</pre>
<p>Доступ в коде:</p>
<pre># Python
import os
db = os.environ.get('DATABASE_URL')
# Node.js
const db = process.env.DATABASE_URL</pre>
<p>Применяются при следующем запуске бота. Нажми <b>Рестарт</b> после сохранения.</p>`},
  {id:'logs',icon:'📋',t:'Логи в реальном времени',b:`<h3>Логи</h3>
<p>Вкладка <b>Логи</b> — вывод бота в реальном времени через SSE.</p>
<p><b>Цвета строк:</b></p>
<ul><li style="color:#ef4444">Красный — ошибки (Error, Exception, Traceback, Critical)</li><li style="color:#f59e0b">Жёлтый — предупреждения (Warning)</li><li style="color:#10b981">Зелёный — обычный вывод</li><li style="color:#94a3b8">Серый [WD] — сообщения Watchdog</li></ul>
<p><b>Частые причины ошибок:</b></p>
<ul><li><code>ModuleNotFoundError</code> — нет библиотеки, проверь requirements.txt</li><li><code>Unauthorized (401)</code> — неверный токен бота</li><li><code>Conflict (409)</code> — бот запущен в другом месте</li><li><code>ConnectionError</code> — нет интернета или Telegram недоступен</li></ul>`},
  {id:'backup',icon:'💾',t:'Backup и восстановление',b:`<h3>Backup</h3>
<p><b>Скачать backup:</b> кнопка «Ещё» → «Backup .zip». Скачается архив со всеми файлами бота.</p>
<p><b>Восстановить бота из backup:</b> главный экран → «Восстановить из backup» → загрузи .zip → укажи название.</p>
<p>Язык программирования определяется автоматически по файлам в архиве:</p>
<ul><li><code>bot.py</code> → Python</li><li><code>bot.js</code> → Node.js</li><li><code>bot.rb</code> → Ruby</li><li><code>bot.php</code> → PHP</li></ul>
<p>💡 Делай backup перед важными изменениями. Храни резервные копии локально.</p>`},
  {id:'power',icon:'🖥️',t:'Управление сервером',b:`<h3>Управление сервером (кнопка ⏻)</h3>
<p><b>Мягкий рестарт панели</b> — перезапускает только сервис Bot Manager. Боты продолжают работать. Страница автоматически обновится через ~6 секунд.</p>
<p><b>Стоп ботов + рестарт</b> — сначала корректно останавливает всех ботов, затем перезапускает панель. Боты с автозапуском поднимутся сами.</p>
<p><b>Мягкая перезагрузка VDS</b> — <code>systemctl reboot</code>. ОС корректно завершает все процессы. После загрузки боты с автозапуском стартуют автоматически.</p>
<p><b>Жёсткая перезагрузка VDS</b> — мгновенный ресет через sysrq. Использовать только если сервер завис и не реагирует на команды.</p>
<p><b>Статус сервера</b> — показывает uptime, нагрузку, RAM, диск, статус nginx и панели.</p>`},
],
ua:[
  {id:'create',icon:'🤖',t:'Як створити бота',b:`<h3>Як створити бота</h3>
<p>Натисни <b>Створити застосунок</b> на головному екрані або <b>+ Новий бот</b> у боковій панелі.</p>
<p><b>Крок 1 — Назва.</b> Будь-яке ім'я латиницею: <code>my_telegram_bot</code>.</p>
<p><b>Крок 2 — Платформа.</b> Telegram (найпростіше), Discord, WhatsApp, Viber.</p>
<p><b>Крок 3 — Мова.</b> Python, Node.js, PHP, Ruby.</p>
<p><b>Крок 4 — Токен.</b> Вставте токен. Він автоматично передається як <code>BOT_TOKEN</code>.</p>
<p><b>Крок 5 — Шаблон.</b> Basic, Echo, Menu, Broadcast або Inline.</p>
<p>Натисни <b>Створити</b> — код і залежності готові автоматично.</p>`},
  {id:'token',icon:'🔑',t:'Токен Telegram (@BotFather)',b:`<h3>Отримати токен Telegram</h3>
<p>1. Знайди <b>@BotFather</b> у Telegram.</p>
<p>2. Відправ <code>/newbot</code></p>
<p>3. Вигадай ім'я та username (має закінчуватись на <b>bot</b>).</p>
<p>4. BotFather надішле токен — скопіюй і встав у поле Токен.</p>
<p><b>Важливо:</b> нікому не передавай токен — це повний доступ до бота.</p>`},
  {id:'start',icon:'▶️',t:'Запуск, зупинка, рестарт',b:`<h3>Керування ботом</h3>
<p><b>Старт</b> — запустити бота. <b>Стоп</b> — зупинити. <b>Рестарт</b> — перезапустити після змін коду.</p>
<p><b>Автозапуск</b> — увімкни тумблер на вкладці Огляд. Бот стартує після перезавантаження сервера.</p>
<p><b>Watchdog</b> — при падінні перезапускається через 3 секунди. В логах: <code>[WD] Crashed rc=1...</code></p>`},
  {id:'edit',icon:'✏️',t:'Редагування коду',b:`<h3>Редактор коду</h3>
<p>Вкладка <b>Редактор</b> → вибери файл зліва → редагуй.</p>
<p><b>Зберегти:</b> кнопка «Зберегти» або <code>Ctrl+S</code>.</p>
<p><b>Застосувати:</b> після збереження натисни <b>Рестарт</b>.</p>
<p>Токен доступний через <code>os.environ.get('BOT_TOKEN')</code> (Python) або <code>process.env.BOT_TOKEN</code> (Node.js).</p>`},
  {id:'env',icon:'⚙️',t:'Config Variables (.env)',b:`<h3>Config Variables</h3>
<p>Вкладка <b>Config Vars</b> — змінні середовища для бота.</p>
<p>Формат: одна змінна на рядок</p>
<pre>DATABASE_URL=postgresql://...
DEBUG=false</pre>
<p>Python: <code>os.environ.get('KEY')</code> · Node.js: <code>process.env.KEY</code></p>
<p>Застосовуються при наступному запуску. Після збереження — натисни Рестарт.</p>`},
  {id:'logs',icon:'📋',t:'Логи в реальному часі',b:`<h3>Логи</h3>
<p>Вкладка <b>Логи</b> — вивід бота в реальному часі.</p>
<ul><li style="color:#ef4444">Червоний — помилки</li><li style="color:#f59e0b">Жовтий — попередження</li><li style="color:#10b981">Зелений — звичайний вивід</li><li style="color:#94a3b8">[WD] — Watchdog</li></ul>
<p>Часті помилки: <code>ModuleNotFoundError</code> — немає бібліотеки; <code>Unauthorized</code> — невірний токен.</p>`},
  {id:'backup',icon:'💾',t:'Backup і відновлення',b:`<h3>Backup</h3>
<p><b>Завантажити:</b> «Ще» → «Backup .zip».</p>
<p><b>Відновити:</b> головний екран → «Відновити з backup» → завантаж .zip.</p>
<p>Мова визначається автоматично: <code>bot.py</code>→Python, <code>bot.js</code>→Node.js тощо.</p>`},
  {id:'power',icon:'🖥️',t:'Керування сервером',b:`<h3>Керування сервером (кнопка ⏻)</h3>
<p><b>М'який рестарт панелі</b> — перезапускає Bot Manager, боти працюють далі.</p>
<p><b>Стоп ботів + рестарт</b> — зупиняє всіх ботів, потім рестарт.</p>
<p><b>М'яке перезавантаження VDS</b> — коректне завершення ОС.</p>
<p><b>Жорстке перезавантаження</b> — миттєвий ресет через sysrq. Тільки якщо сервер завис.</p>`},
],
en:[
  {id:'create',icon:'🤖',t:'How to create a bot',b:`<h3>Create a bot</h3>
<p>Click <b>Create new app</b> on the main screen or <b>+ New bot</b> in the sidebar.</p>
<p><b>Step 1 — Name.</b> Any Latin name: <code>my_telegram_bot</code>.</p>
<p><b>Step 2 — Platform.</b> Telegram (easiest), Discord, WhatsApp, Viber.</p>
<p><b>Step 3 — Language.</b> Python, Node.js, PHP, Ruby.</p>
<p><b>Step 4 — Token.</b> Paste the bot token. Automatically available as <code>BOT_TOKEN</code> env var.</p>
<p><b>Step 5 — Template.</b> Basic, Echo, Menu, Broadcast, or Inline — ready to run.</p>
<p>Click <b>Create</b> — code and dependencies are set up automatically.</p>`},
  {id:'token',icon:'🔑',t:'Telegram token (@BotFather)',b:`<h3>Get Telegram token</h3>
<p>1. Find <b>@BotFather</b> in Telegram.</p>
<p>2. Send <code>/newbot</code></p>
<p>3. Choose a name (visible to users) and username (must end in <b>bot</b>).</p>
<p>4. BotFather sends a token — copy and paste it into the Token field.</p>
<p><b>Important:</b> never share your token — it grants full bot access.</p>`},
  {id:'start',icon:'▶️',t:'Start, stop, restart',b:`<h3>Bot control</h3>
<p><b>Start</b> — launch the bot. <b>Stop</b> — stop it. <b>Restart</b> — restart after code changes.</p>
<p><b>Autostart</b> — enable in Overview. Bot starts automatically after server reboot.</p>
<p><b>Watchdog</b> — auto-restarts on crash after 3 seconds. Logs: <code>[WD] Crashed rc=1, restart in 3s...</code></p>`},
  {id:'edit',icon:'✏️',t:'Edit code',b:`<h3>Code editor</h3>
<p><b>Editor</b> tab → pick a file on the left → edit.</p>
<p><b>Save:</b> Save button or <code>Ctrl+S</code>.</p>
<p><b>Apply:</b> after saving click <b>Restart</b>.</p>
<p>Token is available via <code>os.environ.get('BOT_TOKEN')</code> (Python) or <code>process.env.BOT_TOKEN</code> (Node.js).</p>`},
  {id:'env',icon:'⚙️',t:'Config Variables (.env)',b:`<h3>Config Variables</h3>
<p><b>Config Vars</b> tab — environment variables for the bot (like Heroku Config Vars).</p>
<p>Format: one variable per line</p>
<pre>DATABASE_URL=postgresql://...
DEBUG=false</pre>
<p>Python: <code>os.environ.get('KEY')</code> · Node.js: <code>process.env.KEY</code></p>
<p>Applied on next bot start. Click Restart after saving.</p>`},
  {id:'logs',icon:'📋',t:'Real-time logs',b:`<h3>Logs</h3>
<p><b>Logs</b> tab — real-time bot output via SSE.</p>
<ul><li style="color:#ef4444">Red — errors (Error, Traceback)</li><li style="color:#f59e0b">Yellow — warnings</li><li style="color:#10b981">Green — normal output</li><li style="color:#94a3b8">[WD] — Watchdog</li></ul>
<p>Common errors: <code>ModuleNotFoundError</code> — missing library; <code>Unauthorized</code> — bad token; <code>Conflict</code> — bot running elsewhere.</p>`},
  {id:'backup',icon:'💾',t:'Backup & restore',b:`<h3>Backup</h3>
<p><b>Download:</b> More → Backup .zip.</p>
<p><b>Restore:</b> main screen → Restore from backup → upload .zip.</p>
<p>Language auto-detected: <code>bot.py</code>→Python, <code>bot.js</code>→Node.js, etc.</p>`},
  {id:'power',icon:'🖥️',t:'Server management',b:`<h3>Server management (⏻ button)</h3>
<p><b>Soft panel restart</b> — restarts Bot Manager only. Bots keep running.</p>
<p><b>Stop bots + restart</b> — stops all bots, then restarts panel.</p>
<p><b>Soft VDS reboot</b> — graceful OS shutdown via <code>systemctl reboot</code>.</p>
<p><b>Hard reboot</b> — instant reset via sysrq. Only if server is completely frozen.</p>`},
],
};

// ═══════════════════════════════════════════════════════════
// CORE
// ═══════════════════════════════════════════════════════════
const g = id => document.getElementById(id);
const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
const fmtUp = s => { if(!s)return'—'; const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60),sec=s%60; return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m ${sec}s`; };
const fmtMem = mb => mb>=1024?`${(mb/1024).toFixed(1)}GB`:`${mb}MB`;

let lang='ru', token='', cur=null, projects=[], curFile='';
let logEs=null, pollT=null, logFilter='all', autoScroll=true;
let restoreFile=null;

// ── Lang ──────────────────────────────────────────────────
function i(k){ return (T[lang]||T.en)[k]||k; }
function setText(id,key){ const e=g(id); if(e)e.textContent=i(key); }
function setLang(l){ lang=l; localStorage.setItem('bm-lang',l); applyLang(); }
function applyLang(){
  g('lang-dd').value=lang;
  setText('wel-t','w_t');setText('wel-s','w_s');setText('wel-cta-t','w_cta');
  setText('wel-rst-t','w_rst');setText('wel-rst-s','w_rst_s');setText('wel-help-t','w_help');
  setText('sb-apps-lbl','sb_apps');setText('sb-new-lbl','sb_new');
  setText('tl-ov','tl_ov');setText('tl-ed','tl_ed');setText('tl-ev','tl_ev');
  setText('tl-fm','tl_fm');setText('tl-lg','tl_lg');setText('tl-ac','tl_ac');setText('tl-dg','tl_dg');
  setText('bt-start-l','bt_start');setText('bt-stop-l','bt_stop');setText('bt-restart-l','bt_restart');
  setText('bt-save-l','bt_save');
  setText('ic-status-l','ic_status');setText('ic-up-l','ic_up');setText('ic-main-l','ic_main');
  setText('ic-cre-l','ic_cre');setText('ic-lang-l','ic_lang');
  setText('ov-auto-t','ov_auto');setText('ov-auto-h','ov_auto_h');setText('ov-auto-s','ov_auto_s');
  setText('ov-res-t','ov_res');setText('ov-lim-t','ov_lim');
  setText('lim-ram-l','lim_ram');setText('lim-cpu-l','lim_cpu');setText('lim-save-l','lim_save');
  setText('ev-t','ev_t');setText('bt-env-l','ev_save');setText('ev-note','ev_note');
  setText('fm-t','fm_t');setText('fm-up-l','fm_up');setText('ed-files-l','ed_files');
  setText('ac-t','ac_t');setText('dg-t','dg_t');setText('bt-dg-l','dg_check');
  setText('lf-all','lf_all');setText('lf-err','lf_err');setText('lf-warn','lf_warn');setText('lf-wd','lf_wd');
  setText('as-l','as_l');setText('cl-l','cl_l');
  setText('mm-logs','mm_logs');setText('mm-bkp','mm_bkp');setText('mm-ren','mm_ren');setText('mm-del','mm_del');
  setText('more-lbl','more');
  setText('pm-lbl','pm_lbl');setText('pm-ps','pm_ps');setText('pm-ps-s','pm_ps_s');
  setText('pm-ph','pm_ph');setText('pm-ph-s','pm_ph_s');
  setText('pm-vs','pm_vs');setText('pm-vs-s','pm_vs_s');
  setText('pm-vh','pm_vh');setText('pm-vh-s','pm_vh_s');setText('pm-stat','pm_stat');
  setText('set-t','set_t');setText('set-pw-t','set_pw_t');setText('set-pw-l','set_pw_l');
  setText('set-chpw-l','set_chpw');setText('set-tok-t','set_tok_t');setText('set-tok-s','set_tok_s');
  setText('set-regen-l','set_regen');setText('set-srv-t','set_srv_t');
  setText('mc-name-l','mc_name');setText('mc-plat-l','mc_plat');setText('mc-lang-l','mc_lang');
  setText('mc-tok-l','mc_tok');setText('mc-tok-h','mc_tok_h');setText('mc-tpl-l','mc_tpl');
  setText('mc-rname-l','mc_rname');setText('mc-drop-lbl','mc_drop');
  setText('mc-cancel','mc_cancel');setText('mt-new-l','mt_new');setText('mt-rst-l','mt_rst');
  setText('ren-t','ren_t');setText('ren-l','ren_l');setText('ren-note','ren_note');setText('ren-ok-l','ren_ok');
  setText('help-t','help_t');setText('help-back-l','help_back');
  setText('lg-sub','lg_sub');setText('lg-pw-l','lg_pw');setText('lg-btn-l','lg_btn');setText('lg-show-l','lg_show');
  setText('ov-up-l','ic_up');setText('w-bots-l','w_bots_l');
  renderHelp();renderWelHelp();
}

// ── Theme ─────────────────────────────────────────────────
function toggleDark(){
  const dark=!document.documentElement.hasAttribute('data-dark');
  dark?document.documentElement.setAttribute('data-dark',''):document.documentElement.removeAttribute('data-dark');
  localStorage.setItem('bm-dark',dark?'1':'');
}
(()=>{ if(localStorage.getItem('bm-dark')==='1')document.documentElement.setAttribute('data-dark',''); })();

// ── API ───────────────────────────────────────────────────
async function api(method,path,body){
  const opts={method,headers:{'Content-Type':'application/json','Authorization':'Bearer '+token}};
  if(body!==undefined)opts.body=JSON.stringify(body);
  const r=await fetch('/api'+path,opts);
  if(r.status===401){logout();throw new Error('Unauthorized');}
  const d=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(d.error||r.statusText);
  return d;
}

// ── Auth ──────────────────────────────────────────────────
function getUrlToken(){ try{return new URL(location.href).searchParams.get('token')||'';}catch{return '';} }

async function initApp(){
  g('login').style.display='none';
  if(history.replaceState)history.replaceState(null,'',location.pathname);
  localStorage.setItem('bm_token',token);
  await loadProjects();
  startPolling(); startConn();
  applyLang(); updateWelStats(); loadTok();
}
function logout(){ token=''; localStorage.removeItem('bm_token'); g('login').style.display='flex'; }
function showLoginForm(){ g('lg-form').style.display='block'; g('lg-show-btn').style.display='none'; setTimeout(()=>g('lg-pw').focus(),50); }

async function doLogin(){
  const pw=g('lg-pw').value.trim(); if(!pw)return;
  g('lg-btn').disabled=true; g('lg-err').style.display='none';
  try{
    const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw})});
    const d=await r.json();
    if(!r.ok){g('lg-err').textContent=d.error||'Error';g('lg-err').style.display='block';g('lg-btn').disabled=false;return;}
    token=d.token; await initApp();
  }catch(e){g('lg-err').textContent=e.message;g('lg-err').style.display='block';g('lg-btn').disabled=false;}
}

(async()=>{
  // Init lang
  const saved=localStorage.getItem('bm-lang');
  if(saved)lang=saved;
  else{ const bl=(navigator.language||'en').toLowerCase().slice(0,2); lang=bl==='ru'?'ru':bl==='uk'?'ua':'en'; }
  applyLang();

  const ut=getUrlToken();
  if(ut){token=ut;try{await api('GET','/ping');await initApp();return;}catch{token='';}}
  const sv=localStorage.getItem('bm_token');
  if(sv){token=sv;try{await api('GET','/ping');await initApp();return;}catch{token='';localStorage.removeItem('bm_token');}}
  g('login').style.display='flex';
  g('lg-pw').addEventListener('keydown',e=>{if(e.key==='Enter')doLogin();});
})();

// ── Projects ──────────────────────────────────────────────
async function loadProjects(){
  try{projects=await api('GET','/projects');}catch{return;}
  renderSidebar();
  if(cur){const p=projects.find(x=>x.id===cur.id);if(p){cur=p;renderOv();}else goHome();}
}
function filterBots(q){renderSidebar(q);}
function renderSidebar(q=''){
  const fl=projects.filter(p=>!q||p.name.toLowerCase().includes(q.toLowerCase())||p.id.includes(q));
  g('sb-apps').innerHTML=fl.map(p=>`
    <div class="sb-app${cur&&cur.id===p.id?' act':''}" onclick="selBot('${p.id}')">
      <div class="sb-app-dot ${p.running?'on':'off'}"></div>
      <div class="sb-app-name">${esc(p.name)}</div>
      <div class="sb-app-meta">
        <span class="sb-app-lang">${p.lang}</span>
        ${p.running?`<span class="sb-app-up">${fmtUp(p.uptime)}</span>`:''}
      </div>
    </div>`).join('');
}

async function selBot(pid){
  const p=projects.find(x=>x.id===pid);if(!p)return;
  cur=p; renderSidebar(g('sb-q').value||'');
  g('welcome').style.display='none';
  g('apppage').style.display='flex';g('apppage').style.flexDirection='column';
  g('hdr-crumb').textContent=p.name;
  renderOv(); showTab('ov');
  startLogs(pid); loadAc();
}
function goHome(){
  cur=null; g('welcome').style.display='flex'; g('apppage').style.display='none';
  g('hdr-crumb').textContent='';
  if(logEs){logEs.close();logEs=null;}
  renderSidebar(); updateWelStats();
}

// ── Overview ──────────────────────────────────────────────
function renderOv(){
  if(!cur)return; const p=cur;
  g('ap-name').textContent=p.name; g('ap-pid').textContent=p.id;
  const bc={telegram:'badge-tg',discord:'badge-dc',whatsapp:'badge-wa',viber:'badge-vb'};
  g('ap-badge').className='app-badge '+(bc[p.platform]||'badge-tg');
  g('ap-badge').textContent=p.platform;
  g('ic-status').textContent=p.running?i('running'):i('stopped');
  g('ic-status').style.color=p.running?'var(--ok)':'var(--mu)';
  g('ic-up').textContent=fmtUp(p.uptime);
  g('ic-tok').textContent=p.token?(p.token.slice(0,18)+'…'):'—';
  g('ic-main').textContent=p.main||'—';
  g('ic-cre').textContent=(p.created||'').slice(0,10)||'—';
  g('ic-lang').textContent=p.lang||'python';
  g('lim-ram').value=p.ram_limit||256; g('lim-cpu').value=p.cpu_limit||80;
  const sw=g('auto-sw'); sw.classList.toggle('on',!!p.autostart);
  g('bt-start').disabled=p.running; g('bt-stop').disabled=!p.running; g('bt-restart').disabled=!p.running;
  loadMetrics();
}
async function loadMetrics(){
  if(!cur)return;
  try{
    const m=await api('GET',`/projects/${cur.id}/metrics`);
    if(m.running){
      const pct=Math.round(m.ram/(m.ram_limit||256)*100);
      g('ov-ram').textContent=fmtMem(m.ram);
      const f=g('ov-ram-fill');f.style.width=Math.min(pct,100)+'%';
      f.className='res-fill '+(pct>85?'er':pct>70?'wa':'ok');
      g('ov-ram-hint').textContent=`Лимит: ${m.ram_limit||256} MB`;
      g('ov-up2').textContent=fmtUp(m.uptime);
    }
  }catch{}
}

// ── Tabs ──────────────────────────────────────────────────
const TABS=['ov','ed','ev','fm','lg','ac','dg'];
function showTab(id){
  TABS.forEach(t=>{
    const p=g('pane-'+t),b=g('tb-'+t);
    if(p){p.classList.remove('act');}
    if(b)b.classList.toggle('act',t===id);
  });
  const pane=g('pane-'+id);
  if(pane)pane.classList.add('act');
  if(id==='ed')loadEdFiles();
  if(id==='fm')loadFm();
  if(id==='ev')loadEnv();
  if(id==='dg')runDiag();
  if(id==='ac')loadAc();
}

// ── Bot controls ──────────────────────────────────────────
async function botStart(){if(!cur)return;g('bt-start').disabled=true;try{await api('POST',`/projects/${cur.id}/start`);toast(i('running'),'ok');await loadProjects();}catch(e){toast(e.message,'err');g('bt-start').disabled=false;}}
async function botStop(){if(!cur)return;try{await api('POST',`/projects/${cur.id}/stop`);toast(i('stopped'),'ok');await loadProjects();}catch(e){toast(e.message,'err');}}
async function botRestart(){if(!cur)return;g('bt-restart').disabled=true;try{await api('POST',`/projects/${cur.id}/restart`);toast('Restarted','ok');await loadProjects();}catch(e){toast(e.message,'err');}}
async function toggleAuto(){if(!cur)return;const sw=g('auto-sw');const v=!sw.classList.contains('on');try{await api('POST',`/projects/${cur.id}/autostart`,{enabled:v});sw.classList.toggle('on',v);cur.autostart=v;}catch(e){toast(e.message,'err');}}
async function saveLimits(){if(!cur)return;try{await api('POST',`/projects/${cur.id}/limits`,{ram_limit:parseInt(g('lim-ram').value),cpu_limit:parseInt(g('lim-cpu').value)});toast('Saved','ok');}catch(e){toast(e.message,'err');}}
async function confirmDel(){if(!cur||!confirm(i('confirm_del')+' "'+cur.name+'"?'))return;try{await api('DELETE',`/projects/${cur.id}`);toast('Deleted','ok');goHome();await loadProjects();}catch(e){toast(e.message,'err');}}
async function copyTok(){if(!cur)return;navigator.clipboard.writeText(cur.token||'').then(()=>toast('Copied','ok'));}

// ── Editor ────────────────────────────────────────────────
async function loadEdFiles(){
  if(!cur)return;
  try{
    const fl=await api('GET',`/projects/${cur.id}/files`);
    g('ed-filelist').innerHTML=fl.map(f=>`
      <div class="file-item${f.name===curFile?' act':''}" onclick="openFile('${esc(f.name)}')">
        <svg width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
        ${esc(f.name)}
        <span class="file-size">${(f.size/1024).toFixed(1)}K</span>
      </div>`).join('');
  }catch(e){toast(e.message,'err');}
}
async function openFile(fn){
  if(!cur)return; curFile=fn;
  try{const d=await api('GET',`/projects/${cur.id}/files/${encodeURIComponent(fn)}`);g('editor').value=d.content||'';g('ed-fname').textContent=fn;}
  catch(e){toast(e.message,'err');}
  loadEdFiles();
}
async function saveFile(){
  if(!cur||!curFile)return;
  try{await api('PUT',`/projects/${cur.id}/files/${encodeURIComponent(curFile)}`,{content:g('editor').value});toast(i('bt_save'),'ok');}
  catch(e){toast(e.message,'err');}
}
async function newFile(){
  const name=prompt('Имя файла:');if(!name||!cur)return;
  try{await api('POST',`/projects/${cur.id}/files`,{name});loadEdFiles();}catch(e){toast(e.message,'err');}
}
g('editor').addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='s'){e.preventDefault();saveFile();}});

// ── Config Vars ───────────────────────────────────────────
async function loadEnv(){if(!cur)return;try{const d=await api('GET',`/projects/${cur.id}/env`);g('env-ed').value=d.content||'';}catch(e){toast(e.message,'err');}}
async function saveEnv(){if(!cur)return;try{await api('PUT',`/projects/${cur.id}/env`,{content:g('env-ed').value});toast(i('ev_save'),'ok');}catch(e){toast(e.message,'err');}}

// ── Files ─────────────────────────────────────────────────
async function loadFm(){
  if(!cur)return;
  try{
    const fl=await api('GET',`/projects/${cur.id}/files`);
    g('fm-list').innerHTML=fl.length?fl.map(f=>`
      <div class="file-row">
        <svg width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
        <div class="file-row-name">${esc(f.name)}</div>
        <div class="file-row-size">${(f.size/1024).toFixed(1)} KB</div>
        <a href="/api/projects/${cur.id}/download/${encodeURIComponent(f.name)}?token=${token}" class="icon-btn" download data-tip="Скачать" style="text-decoration:none">
          <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
        </a>
        <button class="icon-btn red" onclick="delFile('${esc(f.name)}')" data-tip="Удалить">
          <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg>
        </button>
      </div>`).join(''):`<div style="padding:20px;text-align:center;color:var(--mu);font-size:.82rem">Нет файлов</div>`;
  }catch(e){toast(e.message,'err');}
}
async function delFile(fn){if(!cur||!confirm('Удалить '+fn+'?'))return;try{await api('DELETE',`/projects/${cur.id}/files/${encodeURIComponent(fn)}`);loadFm();}catch(e){toast(e.message,'err');}}
async function uploadFile(inp){
  if(!cur||!inp.files[0])return;
  const fd=new FormData();fd.append('file',inp.files[0]);
  try{await fetch(`/api/projects/${cur.id}/upload`,{method:'POST',headers:{Authorization:'Bearer '+token},body:fd});toast('Загружено','ok');loadFm();}
  catch(e){toast(e.message,'err');}
  inp.value='';
}
function dlBackup(){if(!cur)return;window.open(`/api/projects/${cur.id}/backup?token=${token}`,'_blank');}

// ── Logs ──────────────────────────────────────────────────
function startLogs(pid){
  if(logEs){logEs.close();logEs=null;}
  g('log-body').innerHTML='';
  logEs=new EventSource(`/api/projects/${pid}/logs?token=${token}`);
  logEs.onmessage=e=>{
    if(!e.data||e.data===':ka')return;
    const m=e.data.match(/^\\[[\\d:]+\\]\\|([a-z]*)\\|(.*)$/);
    if(!m)return;
    const[,cls,line]=m;
    if(logFilter!=='all'&&cls!==logFilter)return;
    const lb=g('log-body');
    const d=document.createElement('div');d.className='ll '+(cls||'o');d.textContent=line;
    lb.appendChild(d);
    if(lb.children.length>3000)lb.removeChild(lb.firstChild);
    if(autoScroll)lb.scrollTop=lb.scrollHeight;
  };
}
function toggleAs(){autoScroll=!autoScroll;g('as-btn').classList.toggle('on',autoScroll);}
function clearLogs(){g('log-body').innerHTML='';}

// ── Activity ──────────────────────────────────────────────
async function loadAc(){
  const url=cur?`/activity?pid=${cur.id}`:'/activity';
  try{
    const acts=await api('GET',url);
    const ic={create:'🤖',delete:'🗑️',start:'▶️',stop:'⏹',restart:'🔄',env:'⚙️',restore:'💾',rename:'✏️',power:'⚡'};
    g('ac-list').innerHTML=acts.length?acts.map(a=>`
      <div class="act-item">
        <div class="act-icon" style="background:var(--sf2)">${ic[a.type]||'📝'}</div>
        <div><div class="act-msg">${esc(a.msg)}</div><div class="act-ts">${new Date(a.ts).toLocaleString()}</div></div>
      </div>`).join(''):`<div style="color:var(--mu);font-size:.82rem">Нет событий</div>`;
  }catch{}
}

// ── Diagnose ──────────────────────────────────────────────
async function runDiag(){
  if(!cur)return;
  g('dg-res').innerHTML='<div style="color:var(--mu);font-size:.82rem">Проверяем...</div>';
  try{
    const{results}=await api('POST',`/projects/${cur.id}/diagnose`);
    g('dg-res').innerHTML=results.map(r=>`
      <div class="diag-row">
        <div class="diag-icon">${r.ok?'✅':'❌'}</div>
        <div><div class="diag-check">${esc(r.check)}</div><div class="diag-msg">${esc(r.msg||'')}</div></div>
      </div>`).join('');
  }catch(e){g('dg-res').innerHTML=`<div style="color:var(--er)">${e.message}</div>`;}
}

// ── Create/Restore ────────────────────────────────────────
function openCreate(mode){
  g('mc-name').value='';g('mc-tok').value='';g('mc-rname').value='';
  restoreFile=null;g('mc-zip-ok').style.display='none';
  g('mc-drop-lbl').textContent=i('mc_drop');
  setMode(mode||'new');openM('modal-create');
}
function setMode(m){
  const isNew=m==='new';
  g('mc-new').style.display=isNew?'block':'none';
  g('mc-rst').style.display=isNew?'none':'block';
  g('mt-new').classList.toggle('act',isNew);g('mt-rst').classList.toggle('act',!isNew);
  g('mc-t').textContent=isNew?i('mc_t_new'):i('mc_t_rst');
  g('mc-ok').textContent=isNew?i('mc_ok_new'):i('mc_ok_rst');
  setTimeout(()=>{(isNew?g('mc-name'):g('mc-rname')).focus();},50);
}
function onPlatChange(){
  const h={telegram:'Получить у @BotFather',discord:'OAuth2 → Bot → Token',whatsapp:'Meta Developers API',viber:'Viber Admin Panel'};
  g('mc-tok-h').textContent=h[g('mc-plat').value]||h.telegram;
}
function onDrop(e){e.preventDefault();const f=e.dataTransfer.files[0];if(f)onZip(f);g('mc-drop').classList.remove('drag');}
function onZip(f){restoreFile=f;g('mc-drop-lbl').textContent='📦 '+f.name;g('mc-zip-ok').style.display='block';g('mc-zip-ok').textContent='Файл: '+f.name;}

async function submitCreate(){
  const isNew=g('mt-new').classList.contains('act');
  let name,body;
  if(isNew){
    name=g('mc-name').value.trim();if(!name)return toast('Введи название','err');
    body={name,token:g('mc-tok').value.trim(),template:g('mc-tpl').value,lang:g('mc-lang').value,platform:g('mc-plat').value};
  }else{
    if(!restoreFile)return toast('Выбери .zip файл','err');
    name=g('mc-rname').value.trim()||restoreFile.name.replace(/\\.zip$/i,'').replace(/^bot_/,'').replace(/_[\\d_]+$/,'');
    if(!name)return toast('Введи название','err');
    body={name,restore_only:true,template:'basic',lang:'python',platform:'telegram'};
  }
  g('mc-ok').disabled=true;
  try{
    const cr=await api('POST','/projects',body);
    if(!isNew&&restoreFile){
      const fd=new FormData();fd.append('file',restoreFile);
      const r=await fetch(`/api/projects/${cr.id}/restore`,{method:'POST',headers:{Authorization:'Bearer '+token},body:fd});
      const d=await r.json();
      if(!r.ok)throw new Error(d.error||'Restore failed');
      toast('Восстановлено: '+d.files+' файлов','ok');
    }
    closeM('modal-create');await loadProjects();
    const p=projects.find(x=>x.id===cr.id);if(p)selBot(p.id);
  }catch(e){toast(e.message,'err');}
  g('mc-ok').disabled=false;
}

// ── Rename ────────────────────────────────────────────────
function openRename(){if(!cur)return;g('ren-inp').value=cur.name;openM('modal-rename');setTimeout(()=>g('ren-inp').focus(),50);}
async function submitRename(){
  const name=g('ren-inp').value.trim();if(!name||!cur)return;
  try{await api('POST',`/projects/${cur.id}/rename`,{name});cur.name=name;g('ap-name').textContent=name;renderSidebar();closeM('modal-rename');toast('OK','ok');}
  catch(e){toast(e.message,'err');}
}

// ── Settings ──────────────────────────────────────────────
function openSettings(){openM('modal-settings');loadTok();}
async function loadTok(){try{const d=await api('GET','/panel/token');if(d.token){token=d.token;const inp=g('set-tok-v');if(inp)inp.value=d.token;}}catch{}}
async function changePw(){const pw=g('set-pw').value.trim();if(!pw)return toast('Введи пароль','err');try{await api('POST','/panel/password',{password:pw});toast('OK','ok');g('set-pw').value='';}catch(e){toast(e.message,'err');}}
async function regenTok(){try{const d=await api('POST','/panel/token');token=d.token;g('set-tok-v').value=d.token;localStorage.setItem('bm_token',d.token);toast('OK','ok');}catch(e){toast(e.message,'err');}}
function copyLink(){const tok=g('set-tok-v').value;navigator.clipboard.writeText(location.origin+'/?token='+tok).then(()=>toast('Ссылка скопирована','ok'));}

// ── Server status ─────────────────────────────────────────
async function openSrvStatus(){
  togglePwr();
  openSettings();
  try{
    const d=await api('GET','/server/status');
    g('srv-card').style.display='block';
    g('srv-body').innerHTML=`🖥 <b>${d.hostname}</b> — Node ${d.node}<br>⏱ Uptime: ${fmtUp(d.uptime_sec)}<br>📊 Load: ${d.load_1.toFixed(2)} / ${d.load_5.toFixed(2)}<br>🧠 RAM: ${d.ram_used}GB / ${d.ram_total}GB (${d.ram_pct}%)<br>💾 Disk: ${d.disk_used}GB / ${d.disk_total}GB (${d.disk_pct}%)<br>🤖 Боты: ${d.bots_running}/${d.bots_total}<br>🟢 Панель: ${d.panel_active?'active':'—'} · Nginx: ${d.nginx_active?'active':'—'}`;
  }catch(e){toast(e.message,'err');}
}

// ── Welcome stats ─────────────────────────────────────────
async function updateWelStats(){
  try{
    const d=await api('GET','/server/status');
    const cv=g('w-cpu');if(cv){cv.textContent=d.load_1.toFixed(1);cv.style.color=d.load_1>2?'var(--er)':d.load_1>1?'var(--wa)':'var(--ok)';}
    const rv=g('w-ram');if(rv){rv.textContent=Math.round(d.ram_pct)+'%';rv.style.color=d.ram_pct>85?'var(--er)':d.ram_pct>70?'var(--wa)':'var(--tx)';}
    const dv=g('w-disk');if(dv)dv.textContent=Math.round(d.disk_pct)+'%';
    const bv=g('w-bots');if(bv)bv.textContent=d.bots_running+'/'+d.bots_total;
  }catch{}
}

// ── Power ─────────────────────────────────────────────────
function togglePwr(){
  const m=g('pwr-menu');m.classList.toggle('op');
  if(m.classList.contains('op'))setTimeout(()=>document.addEventListener('click',function h(e){
    if(!g('pwr-menu').contains(e.target)&&e.target!==g('pwr-btn')){m.classList.remove('op');document.removeEventListener('click',h);}
  }),10);
}

async function pwrAction(target,mode){
  g('pwr-menu').classList.remove('op');
  if(mode==='hard'&&target==='vds'){if(!confirm(i('confirm_hard')))return;}
  else if(target==='vds'){if(!confirm(i('confirm_vds')))return;}
  const isPanel=target==='panel';
  showOp(isPanel?i('op_panel'):i('op_vds'),isPanel?i('op_panel_s'):i('op_vds_s'),isPanel?7:0);
  try{
    await api('POST',isPanel?'/server/restart_panel':'/server/reboot',{mode});
    if(isPanel)startCd(7,()=>location.reload());
  }catch(e){toast(e.message,'err');g('op-modal').classList.remove('op');}
}

let cdT=null;
function showOp(title,sub,sec){
  g('op-t').textContent=title;g('op-s').textContent=sub;
  const cd=g('op-cd');if(sec>0){cd.style.display='block';cd.textContent=sec+'s';}else cd.style.display='none';
  g('op-modal').classList.add('op');
}
function startCd(sec,cb){
  const cd=g('op-cd');cd.textContent=sec+'s';
  const tick=()=>{sec--;cd.textContent=sec+'s';if(sec<=0){clearTimeout(cdT);cb();}else cdT=setTimeout(tick,1000);};
  cdT=setTimeout(tick,1000);
}

// ── More menu ─────────────────────────────────────────────
function toggleMore(){const m=g('more-menu');const op=m.classList.contains('op');m.classList.toggle('op');if(!op)setTimeout(()=>document.addEventListener('click',function h(e){if(!g('more-menu').contains(e.target)&&e.target!==g('more-btn')){g('more-menu').classList.remove('op');document.removeEventListener('click',h);}},10));}
function closeMore(){g('more-menu').classList.remove('op');}

// ── Polling ───────────────────────────────────────────────
function startPolling(){clearInterval(pollT);pollT=setInterval(async()=>{await loadProjects();if(cur)loadMetrics();if(g('welcome').style.display!=='none')updateWelStats();},5000);}
function startConn(){setInterval(async()=>{try{await api('GET','/ping');g('conn').className='conn';}catch{g('conn').className='conn off';}},15000);}

// ── Modals ────────────────────────────────────────────────
function openM(id){g(id).classList.add('op');}
function closeM(id){g(id).classList.remove('op');}
document.querySelectorAll('.overlay').forEach(o=>o.addEventListener('click',e=>{if(e.target===o)o.classList.remove('op');}));

// ── Toast ─────────────────────────────────────────────────
function toast(msg,type='info'){
  const w=g('toasts'),d=document.createElement('div');d.className='toast '+(type||'info');d.textContent=msg;
  w.appendChild(d);setTimeout(()=>d.remove(),4000);
}

// ── Help ──────────────────────────────────────────────────
function renderHelp(){
  const arts=(HELP[lang]||HELP.en);
  g('help-list').innerHTML=arts.map(a=>`
    <button class="help-link" onclick="showArt('${a.id}')">
      <span style="font-size:1.2rem;width:26px;text-align:center">${a.icon}</span>
      <span>${a.t}</span>
      <svg style="margin-left:auto;opacity:.4" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="9 18 15 12 9 6"/></svg>
    </button>`).join('');
}
function renderWelHelp(){
  const arts=(HELP[lang]||HELP.en).slice(0,4);
  g('wel-help-links').innerHTML=arts.map(a=>`
    <button class="wel-help-a" onclick="openHelp('${a.id}')">
      <span class="wel-help-item-icon">${a.icon}</span>${a.t}
      <svg style="margin-left:auto;opacity:.3" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="9 18 15 12 9 6"/></svg>
    </button>`).join('');
}
function openHelp(artId){openM('modal-help');if(artId)showArt(artId);else backToHelp();}
function backToHelp(){g('help-list').style.display='block';g('help-art').style.display='none';}
function showArt(id){
  const a=(HELP[lang]||HELP.en).find(x=>x.id===id);if(!a)return;
  g('help-art-body').innerHTML=a.b;
  g('help-art').style.display='block';g('help-list').style.display='none';
}

// ── Keyboard shortcuts ────────────────────────────────────
document.addEventListener('keydown',e=>{
  if(e.key==='/'&&e.target.tagName!=='INPUT'&&e.target.tagName!=='TEXTAREA'){e.preventDefault();g('sb-q').focus();}
  if(e.key==='Escape'){document.querySelectorAll('.overlay.op').forEach(o=>o.classList.remove('op'));}
});

// ── Mobile ────────────────────────────────────────────────
if(window.innerWidth<=768)g('mob-btn').style.display='flex';
function toggleMob(){g('sidebar').classList.toggle('mob');}
g('main').addEventListener('click',()=>{if(window.innerWidth<=768)g('sidebar').classList.remove('mob');});
</script>
</body>
</html>"""
with open('/opt/botpanel/static/index.html','w') as f:
  f.write(html)
print('index.html: '+str(len(html))+' bytes')
PYEOF
  ok "index.html written"
}
  ok "index.html written ($(wc -c < $PD/static/index.html) bytes)"
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
  mkdir -p "$PD"/{app,static,bots,bots_venv}
  install_pkgs
  install_ruby_gems
  write_node_server; write_frontend; write_svc; write_admin; write_nginx; write_ipwatch
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
write_node_server; write_frontend; create_user

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
