#!/usr/bin/env bash
# setup-server.sh — Bulletin Board Server Installer
set -euo pipefail

TTY="/dev/tty"
if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
    echo "ERROR: No terminal available."; exit 1
fi

REPO_OWNER="DonICTStaff"
REPO_NAME="Bulletin"
BRANCH="main"
INSTALL_DIR="/opt/bulletin"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="bulletin-server"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
SPINNER_PID=""; SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'); SPINNER_INDEX=0

spinner_start() { local m="${1:-...}"; printf "  ${CYAN}%s${NC} %s" "${SPINNER_FRAMES[0]}" "$m"; (while true; do SPINNER_INDEX=$(( (SPINNER_INDEX+1)%10 )); printf "\r  ${CYAN}%s${NC} %s" "${SPINNER_FRAMES[$SPINNER_INDEX]}" "$m"; sleep 0.1; done) & SPINNER_PID=$!; disown "$SPINNER_PID" 2>/dev/null || true; }
spinner_stop() { [[ -n "$SPINNER_PID" ]] && { kill "$SPINNER_PID" 2>/dev/null||true; wait "$SPINNER_PID" 2>/dev/null||true; SPINNER_PID=""; }; printf "\r  ${GREEN}✓${NC}  %s\n" "$1"; }
warn() { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
error() { printf "\n  ${RED}✗  ERROR:${NC} %s\n\n" "$*"; exit 1; }
step() { printf "\n${BOLD}  [%d/%d]${NC} %s\n" "$1" "$2" "$3"; }

clear 2>/dev/null||true; echo ""; echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════╗\n  ║          Bulletin Board Server Installer         ║\n  ╚══════════════════════════════════════════════════╝${NC}"; echo -e "  ${DIM}Don College Bulletin Board Digital Signage System${NC}\n"

echo -e "  ${BOLD}This installer will set up the Bulletin Board server.${NC}\n"
while true; do printf "  ${BOLD}▸${NC} ${CYAN}Admin password${NC}: "; read -r ADMIN_PASS < "$TTY"; ADMIN_PASS="${ADMIN_PASS:-}"; [[ -n "$ADMIN_PASS" ]] && break; warn "Cannot be empty."; done
printf "  ${BOLD}▸${NC} ${CYAN}Hostname${NC} [bulletin-server]: "; read -r SERVER_HOSTNAME < "$TTY"; SERVER_HOSTNAME="${SERVER_HOSTNAME:-bulletin-server}"
printf "  ${BOLD}▸${NC} ${CYAN}Port${NC} [5000]: "; read -r SERVER_PORT < "$TTY"; SERVER_PORT="${SERVER_PORT:-5000}"
echo -e "\n  ${DIM}┌──────────────────────────────────────────┐\n  │  Hostname: ${GREEN}${SERVER_HOSTNAME}${NC}\n  │  Port:     ${GREEN}${SERVER_PORT}${NC}\n  │  Install:  ${GREEN}${INSTALL_DIR}${NC}\n  └──────────────────────────────────────────┘${NC}\n"
printf "  Proceed? ${DIM}[Y/n]${NC}: "; read -r CONFIRM < "$TTY"; CONFIRM="${CONFIRM:-Y}"; [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo ""; exit 0; }
[[ $EUID -ne 0 ]] && error "Run as root (use sudo)."
TOTAL_STEPS=7

# ── Step 1 ────────────────────────────────────────────────────────────────────
step 1 $TOTAL_STEPS "Installing system packages"
spinner_start "Updating packages..."; apt-get update -qq > /dev/null 2>&1; spinner_stop "Done"
spinner_start "Installing python3, nginx, git..."; apt-get install -y -qq python3 python3-venv python3-pip nginx git curl > /dev/null 2>&1; spinner_stop "Done"

# ── Step 2 ────────────────────────────────────────────────────────────────────
step 2 $TOTAL_STEPS "Fetching source code"
DB_TMP=""; CONFIG_TMP=""
[[ -f "${INSTALL_DIR}/instance/bulletin.db" ]] && { DB_TMP=$(mktemp); cp "${INSTALL_DIR}/instance/bulletin.db" "$DB_TMP"; info "Preserved database"; }
[[ -f "${INSTALL_DIR}/config.env" ]] && { CONFIG_TMP=$(mktemp); cp "${INSTALL_DIR}/config.env" "$CONFIG_TMP"; info "Preserved config"; }

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    spinner_start "Updating..."; cd "$INSTALL_DIR"
    git reset --hard HEAD 2>/dev/null||true; git clean -fdx 2>/dev/null||true
    if git pull origin "$BRANCH" 2>/dev/null; then
        spinner_stop "Updated"
    else
        warn "Pull failed, re-cloning..."
        [[ -n "$DB_TMP" ]] && cp "${INSTALL_DIR}/instance/bulletin.db" "$DB_TMP" 2>/dev/null||true
        rm -rf "$INSTALL_DIR"
        git clone --branch "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR" 2>/dev/null||true
        spinner_stop "Cloned fresh"
    fi
else
    spinner_start "Cloning..."; [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    git clone --branch "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR" 2>/dev/null||true
    spinner_stop "Cloned"
fi

[[ -n "$DB_TMP" && -f "$DB_TMP" ]] && { mkdir -p "${INSTALL_DIR}/instance"; cp "$DB_TMP" "${INSTALL_DIR}/instance/bulletin.db"; rm -f "$DB_TMP"; info "Restored database"; }
[[ -n "$CONFIG_TMP" && -f "$CONFIG_TMP" ]] && { cp "$CONFIG_TMP" "${INSTALL_DIR}/config.env"; rm -f "$CONFIG_TMP"; info "Restored config"; }
chown -R www-data:www-data "${INSTALL_DIR}"

if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    spinner_start "Restarting server..."; timeout 15 systemctl restart "${SERVICE_NAME}" 2>/dev/null||true; sleep 2; spinner_stop "Restarted"
fi

# ── Step 3 ────────────────────────────────────────────────────────────────────
step 3 $TOTAL_STEPS "Setting up Python environment"
spinner_start "Creating venv..."; python3 -m venv "$VENV_DIR" 2>/dev/null; spinner_stop "Done"
spinner_start "Installing dependencies (this may take a minute)..."
if "${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt" 2>&1; then
    spinner_stop "Dependencies installed"
else
    spinner_stop "FAILED"; error "pip install failed. Run manually: ${VENV_DIR}/bin/pip install -r ${INSTALL_DIR}/requirements.txt"
fi

# ── Step 4 ────────────────────────────────────────────────────────────────────
step 4 $TOTAL_STEPS "Initializing database"
spinner_start "Creating admin user..."
KEYTMP=$(mktemp); python3 -c "import secrets; print(secrets.token_hex(32))" > $KEYTMP 2>/dev/null; SECRET_KEY=$(cat $KEYTMP); rm -f $KEYTMP
export BULLETIN_SECRET_KEY=$(python3 BULLETIN_ADMIN_PASSWORD=*** "${VENV_DIR}/bin/python" -c "
import os
from app import app, init_db, db, User
with app.app_context():
    init_db()
    from werkzeug.security import generate_password_hash
    pw = os.environ.get('BULLETIN_ADMIN_PASSWORD', 'changeme')
    admin = User.query.filter_by(username='admin').first()
    if admin:
        admin.password_hash = generate_password_hash(pw)
        db.session.commit()
        print('OK: admin user ready')
    else:
        print('ERROR: admin user not found after init')
" 2>&1
unset BULLETIN_ADMIN_PASSWORD
spinner_stop "Database ready"

# ── Step 5 ────────────────────────────────────────────────────────────────────
step 5 $TOTAL_STEPS "Writing configuration"
if [[ ! -f "${INSTALL_DIR}/config.env" ]]; then
    echo "BULLETIN_SECRET_KEY=${SECR...>" "${INSTALL_DIR}/config.env"
    chmod 600 "${INSTALL_DIR}/config.env"
fi
mkdir -p "${INSTALL_DIR}/uploads"
chown www-data:www-data "${INSTALL_DIR}/uploads"
success "Config saved"

# ── Step 6 ────────────────────────────────────────────────────────────────────
step 6 $TOTAL_STEPS "Creating systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << 'SVCEOF'
[Unit]
Description=Bulletin Board Flask Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/bulletin
EnvironmentFile=/opt/bulletin/config.env
ExecStart=/opt/bulletin/venv/bin/python /opt/bulletin/app.py
Restart=always
RestartSec=5
TimeoutStopSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
chown -R www-data:www-data "${INSTALL_DIR}/uploads" "${INSTALL_DIR}/instance" 2>/dev/null||true
success "Service created"

# ── Step 7 ────────────────────────────────────────────────────────────────────
step 7 $TOTAL_STEPS "Configuring Nginx"
spinner_start "Writing Nginx config..."
cat > "/etc/nginx/sites-available/bulletin" << NGEOF
server {
    listen 80;
    server_name _;
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /socket.io {
        proxy_pass http://127.0.0.1:5000/socket.io;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
NGEOF
ln -sf "/etc/nginx/sites-available/bulletin" "/etc/nginx/sites-enabled/bulletin"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null||true
nginx -t > /dev/null 2>&1 && systemctl reload nginx > /dev/null 2>&1
spinner_stop "Nginx configured"

# ── Start ─────────────────────────────────────────────────────────────────────
echo ""; spinner_start "Starting ${SERVICE_NAME}..."
systemctl daemon-reload > /dev/null 2>&1
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
systemctl start "$SERVICE_NAME" > /dev/null 2>&1||true
sleep 3
systemctl is-active --quiet "${SERVICE_NAME}" && spinner_stop "Service running" || spinner_stop "Service may need manual start"

# ── Done ──────────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${BOLD}${GREEN}  ╔══════════════════════════════════════════════════╗\n  ║            Installation Complete!                ║\n  ╚══════════════════════════════════════════════════╝${NC}"
echo -e "  ${BOLD}Dashboard:${NC}   ${CYAN}http://${SERVER_IP}:${SERVER_PORT}${NC}"
echo -e "  ${BOLD}Admin user:${NC}  admin"
echo -e "  ${BOLD}Admin pass:${NC}  ${ADMIN_PASS}"
echo -e "\n  ${DIM}To add a kiosk client, run this on the Pi:${NC}"
echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/deploy-client.sh | sudo bash${NC}"
echo -e "\n  ${BOLD}Commands:${NC}"
echo -e "  ${CYAN}systemctl status ${SERVICE_NAME}${NC}  Check status"
echo -e "  ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}  View logs"
echo -e "  ${CYAN}sudo systemctl restart ${SERVICE_NAME}${NC}  Restart"
echo ""
