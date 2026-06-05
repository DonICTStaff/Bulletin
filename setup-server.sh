#!/usr/bin/env bash
# setup-server.sh — Bulletin Board Server Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/setup-server.sh | sudo bash
#
# Or download first, then run:
#   wget https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/setup-server.sh
#   sudo bash setup-server.sh

set -euo pipefail

TTY="/dev/tty"

if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
    echo "ERROR: No terminal available for interactive input."
    echo "Run this script directly (not piped), or use: bash setup-server.sh"
    exit 1
fi

REPO_OWNER="DonICTStaff"
REPO_NAME="Bulletin"
BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

INSTALL_DIR="/opt/bulletin"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="bulletin-server"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SPINNER_PID=""
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_INDEX=0

spinner_start() {
    local msg="${1:-Working...}"
    printf "  ${CYAN}%s${NC} %s" "${SPINNER_FRAMES[0]}" "$msg"
    (
        while true; do
            SPINNER_INDEX=$(( (SPINNER_INDEX + 1) % 10 ))
            printf "\r  ${CYAN}%s${NC} %s" "${SPINNER_FRAMES[$SPINNER_INDEX]}" "$msg"
            sleep 0.1
        done
    ) & SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r  ${GREEN}✓${NC}  %s\n" "$1"
}

info()    { printf "  ${BLUE}ℹ${NC}  %s\n" "$*"; }
success() { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
error()   { printf "\n  ${RED}✗  ERROR:${NC} %s\n\n" "$*"; exit 1; }
step()    { printf "\n${BOLD}  [%d/%d]${NC} %s\n" "$1" "$2" "$3"; }

clear 2>/dev/null || true
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║          Bulletin Board Server Installer         ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Don College Bulletin Board Digital Signage System${NC}"
echo ""

echo -e "  ${BOLD}This installer will set up the Bulletin Board server.${NC}"
echo -e "  ${DIM}You will need to provide a few configuration values.${NC}"
echo ""

while true; do
    printf "  ${BOLD}▸${NC} ${CYAN}Admin password${NC} for the web dashboard: "
    read -r ADMIN_PASS < "$TTY"
    ADMIN_PASS="${ADMIN_PASS:-}"
    if [[ -n "$ADMIN_PASS" ]]; then break; fi
    warn "Admin password cannot be empty."
done

printf "  ${BOLD}▸${NC} ${CYAN}Server hostname${NC} [bulletin-server]: "
read -r SERVER_HOSTNAME < "$TTY"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-bulletin-server}"

printf "  ${BOLD}▸${NC} ${CYAN}Flask port${NC} [5000]: "
read -r SERVER_PORT < "$TTY"
SERVER_PORT="${SERVER_PORT:-5000}"

echo ""
echo -e "  ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
echo -e "  ${DIM}│${NC} ${BOLD}Configuration Summary${NC}"
echo -e "  ${DIM}│${NC}   Hostname: ${GREEN}${SERVER_HOSTNAME}${NC}"
echo -e "  ${DIM}│${NC}   Port:     ${GREEN}${SERVER_PORT}${NC}"
echo -e "  ${DIM}│${NC}   Install:  ${GREEN}${INSTALL_DIR}${NC}"
echo -e "  ${DIM}└──────────────────────────────────────────────────────┘${NC}"
echo ""

printf "  Proceed with installation? ${DIM}[Y/n]${NC}: "
read -r CONFIRM < "$TTY"
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then echo ""; info "Installation cancelled."; echo ""; exit 0; fi

if [[ $EUID -ne 0 ]]; then error "This installer must be run as root (use sudo)."; fi

TOTAL_STEPS=7

# ── Step 1: System packages ───────────────────────────────────────────────────
step 1 $TOTAL_STEPS "Installing system packages"
spinner_start "Updating package lists..."
apt-get update -qq > /dev/null 2>&1
spinner_stop "Package lists updated"
spinner_start "Installing dependencies..."
apt-get install -y -qq python3 python3-venv python3-pip nginx git curl > /dev/null 2>&1
spinner_stop "System packages installed"

# ── Step 2: Fetch source code ─────────────────────────────────────────────────
step 2 $TOTAL_STEPS "Fetching source code"

# Preserve database and config if they exist
DB_TMP=""
CONFIG_TMP=""
if [[ -f "${INSTALL_DIR}/instance/bulletin.db" ]]; then
    DB_TMP=$(mktemp)
    cp "${INSTALL_DIR}/instance/bulletin.db" "$DB_TMP"
    info "Preserved existing database"
fi
if [[ -f "${INSTALL_DIR}/config.env" ]]; then
    CONFIG_TMP=$(mktemp)
    cp "${INSTALL_DIR}/config.env" "$CONFIG_TMP"
    info "Preserved existing config"
fi

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    spinner_start "Updating existing installation..."
    cd "$INSTALL_DIR"
    git reset --hard HEAD 2>/dev/null || true
    git clean -fdx 2>/dev/null || true
    if git pull origin "$BRANCH" 2>/dev/null; then
        spinner_stop "Repository updated"
    else
        warn "Git pull failed, re-cloning..."
        rm -rf "$INSTALL_DIR"
        git clone --branch "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR" 2>/dev/null || true
        spinner_stop "Repository cloned"
    fi
else
    spinner_start "Cloning repository..."
    if [[ -d "$INSTALL_DIR" ]]; then rm -rf "$INSTALL_DIR"; fi
    git clone --branch "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR" 2>/dev/null || true
    spinner_stop "Repository cloned"
fi

# Restore preserved files
if [[ -n "$DB_TMP" && -f "$DB_TMP" ]]; then
    mkdir -p "${INSTALL_DIR}/instance"
    cp "$DB_TMP" "${INSTALL_DIR}/instance/bulletin.db"
    rm -f "$DB_TMP"
    info "Restored database"
fi
if [[ -n "$CONFIG_TMP" && -f "$CONFIG_TMP" ]]; then
    cp "$CONFIG_TMP" "${INSTALL_DIR}/config.env"
    rm -f "$CONFIG_TMP"
    info "Restored config"
fi

chown -R www-data:www-data "${INSTALL_DIR}"

# Restart service if running
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    spinner_start "Restarting server..."
    timeout 15 systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    sleep 2
    spinner_stop "Server restarted"
fi

# ── Step 3: Python venv ───────────────────────────────────────────────────────
step 3 $TOTAL_STEPS "Setting up Python environment"
spinner_start "Creating virtual environment..."
python3 -m venv "$VENV_DIR" > /dev/null 2>&1
spinner_stop "Virtual environment created"
spinner_start "Installing Python dependencies..."
source "${VENV_DIR}/bin/activate"
if pip install -r "${INSTALL_DIR}/requirements.txt" 2>&1; then
    spinner_stop "Python dependencies installed"
else
    spinner_stop "Some dependencies failed (non-critical)"
    warn "If the server fails to start, check: pip install -r ${INSTALL_DIR}/requirements.txt"
fi
deactivate

# ── Step 4: Database ──────────────────────────────────────────────────────────
step 4 $TOTAL_STEPS "Initializing database"
spinner_start "Creating database and admin user..."
SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
export BULLETIN_SECRET_KEY="${SECRET_KEY}"
export BULLETIN_ADMIN_PASSWORD="${ADMIN_PASS}"
source "${VENV_DIR}/bin/activate"
python3 -c "
import os
from app import app, init_db, db, User
with app.app_context():
    init_db()
    from werkzeug.security import generate_password_hash
    admin = User.query.filter_by(username='admin').first()
    if admin:
        admin.password_hash = generate_password_hash(os.environ['BULLETIN_ADMIN_PASSWORD'])
        db.session.commit()
" 2>&1 || true
ACTIVATION_STATUS=$?
deactivate
unset BULLETIN_ADMIN_PASSWORD
if [[ $ACTIVATION_STATUS -ne 0 ]]; then
    spinner_stop "Failed (see error above)"
    error "Database initialization failed. Check the error output above."
fi
spinner_stop "Database initialized"

# ── Step 5: Config ────────────────────────────────────────────────────────────
step 5 $TOTAL_STEPS "Writing configuration"
if [[ ! -f "${INSTALL_DIR}/config.env" ]]; then
    cat > "${INSTALL_DIR}/config.env" << EOF
BULLETIN_SECRET_KEY=${SECRET_KEY}
EOF
    chmod 600 "${INSTALL_DIR}/config.env"
fi
mkdir -p "${INSTALL_DIR}/uploads"
success "Config saved to ${INSTALL_DIR}/config.env"

# ── Step 6: Systemd service ───────────────────────────────────────────────────
step 6 $TOTAL_STEPS "Creating systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SVCEOF
[Unit]
Description=Bulletin Board Flask Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/config.env
ExecStart=${VENV_DIR}/bin/python ${INSTALL_DIR}/app.py
Restart=always
RestartSec=5
TimeoutStopSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

chown -R www-data:www-data "${INSTALL_DIR}/uploads"
chown -R www-data:www-data "${INSTALL_DIR}/instance" 2>/dev/null || true
success "Service file created"

# ── Step 7: Nginx ─────────────────────────────────────────────────────────────
step 7 $TOTAL_STEPS "Configuring Nginx"
spinner_start "Writing Nginx configuration..."
cat > "/etc/nginx/sites-available/bulletin" << NGINXEOF
server {
    listen 80;
    server_name ${SERVER_HOSTNAME};

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:${SERVER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /socket.io {
        proxy_pass http://127.0.0.1:${SERVER_PORT}/socket.io;
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
NGINXEOF

ln -sf "/etc/nginx/sites-available/bulletin" "/etc/nginx/sites-enabled/bulletin"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t > /dev/null 2>&1 && systemctl reload nginx > /dev/null 2>&1
spinner_stop "Nginx configured"

# ── Start ──────────────────────────────────────────────────────────────────────
echo ""
spinner_start "Enabling and starting ${SERVICE_NAME}..."
systemctl daemon-reload > /dev/null 2>&1
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
systemctl start "$SERVICE_NAME" > /dev/null 2>&1 || true
sleep 3
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    spinner_stop "Service started"
else
    spinner_stop "Service start failed"
    warn "Check: journalctl -u ${SERVICE_NAME} -n 30"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║            Installation Complete!                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Dashboard:${NC}   ${CYAN}http://${SERVER_IP}:${SERVER_PORT}${NC}"
echo -e "  ${BOLD}Admin user:${NC}  admin"
echo -e "  ${BOLD}Admin pass:${NC}  ${ADMIN_PASS}"
echo ""
echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}To add a kiosk client, run this on the Pi:${NC}"
echo ""
echo -e "    ${CYAN}curl -fsSL ${GITHUB_RAW}/deploy-client.sh | sudo bash${NC}"
echo ""
echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    ${CYAN}systemctl status ${SERVICE_NAME}${NC}    Check status"
echo -e "    ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}    View live logs"
echo -e "    ${CYAN}sudo systemctl restart ${SERVICE_NAME}${NC}  Restart"
echo ""
