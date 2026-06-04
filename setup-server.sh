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

REPO_OWNER="DonICTStaff"
REPO_NAME="Bulletin"
BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

INSTALL_DIR="/opt/bulletin"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="bulletin-server"

# ── ANSI Colors ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Spinner ────────────────────────────────────────────────────────────────────
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

# ── Logging ────────────────────────────────────────────────────────────────────
info()    { printf "  ${BLUE}ℹ${NC}  %s\n" "$*"; }
success() { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
error()   { printf "\n  ${RED}✗  ERROR:${NC} %s\n\n" "$*"; exit 1; }
step()    { printf "\n${BOLD}  [%d/%d]${NC} %s\n" "$1" "$2" "$3"; }

# ── Banner ─────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                  ║"
echo "  ║   ██████╗ ██╗   ██╗██╗     ██╗     ███████╗████████╗██╗███╗   ██╗    ║"
echo "  ║   ██╔══██╗██║   ██║██║     ██║     ██╔════╝╚══██╔══╝██║████╗  ██║    ║"
echo "  ║   ██████╔╝██║   ██║██║     ██║     █████╗     ██║   ██║██╔██╗ ██║    ║"
echo "  ║   ██╔══██╗██║   ██║██║     ██║     ██╔══╝     ██║   ██║██║╚██╗██║    ║"
echo "  ║   ██████╔╝╚██████╔╝███████╗███████╗███████╗   ██║   ██║██║ ╚████║    ║"
echo "  ║   ╚═════╝  ╚═════╝ ╚══════╝╚══════╝╚══════╝   ╚═╝   ╚═╝╚═╝  ╚═══╝    ║"
echo "  ║                                                  ║"
echo "  ║          ${NC}${BOLD}Server Installer${CYAN}                          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Don College Bulletin Board Digital Signage System${NC}"
echo -e "  ${DIM}https://github.com/${REPO_OWNER}/${REPO_NAME}${NC}"
echo ""

# ── Interactive Configuration ─────────────────────────────────────────────────
echo -e "  ${BOLD}This installer will set up the Bulletin Board server.${NC}"
echo -e "  ${DIM}You will need to provide a few configuration values.${NC}"
echo ""

# Admin password
while true; do
    printf "  ${BOLD}▸${NC} ${CYAN}Admin password${NC} for the web dashboard: "
    read -r ADMIN_PASS
    ADMIN_PASS="${ADMIN_PASS:-}"
    if [[ -n "$ADMIN_PASS" ]]; then
        break
    fi
    warn "Admin password cannot be empty."
done

# Server hostname
printf "  ${BOLD}▸${NC} ${CYAN}Server hostname${NC} [bulletin-server]: "
read -r SERVER_HOSTNAME
SERVER_HOSTNAME="${SERVER_HOSTNAME:-bulletin-server}"

# Flask port
printf "  ${BOLD}▸${NC} ${CYAN}Flask port${NC} [5000]: "
read -r SERVER_PORT
SERVER_PORT="${SERVER_PORT:-5000}"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
echo -e "  ${DIM}│${NC} ${BOLD}Configuration Summary${NC}"
echo -e "  ${DIM}│${NC}"
echo -e "  ${DIM}│${NC}   Hostname: ${GREEN}${SERVER_HOSTNAME}${NC}"
echo -e "  ${DIM}│${NC}   Port:     ${GREEN}${SERVER_PORT}${NC}"
echo -e "  ${DIM}│${NC}   Install:  ${GREEN}${INSTALL_DIR}${NC}"
echo -e "  ${DIM}└──────────────────────────────────────────────────────┘${NC}"
echo ""

printf "  Proceed with installation? ${DIM}[Y/n]${NC}: "
read -r CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    info "Installation cancelled."
    echo ""
    exit 0
fi

# ── Require root ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root (use sudo)."
fi

TOTAL_STEPS=7

# ── Step 1: System packages ───────────────────────────────────────────────────
step 1 $TOTAL_STEPS "Installing system packages"
spinner_start "Updating package lists..."
apt-get update -qq > /dev/null 2>&1
spinner_stop "Package lists updated"

spinner_start "Installing dependencies (python3, nginx, git, curl)..."
apt-get install -y -qq \
    python3 \
    python3-venv \
    python3-pip \
    nginx \
    git \
    curl \
    > /dev/null 2>&1
spinner_stop "System packages installed"

# ── Step 2: Clone repository ──────────────────────────────────────────────────
step 2 $TOTAL_STEPS "Fetching source code"
if [[ -d "$INSTALL_DIR" ]]; then
    spinner_start "Updating existing installation..."
    cd "$INSTALL_DIR"
    git pull origin "$BRANCH" > /dev/null 2>&1 || true
    spinner_stop "Repository updated"
else
    spinner_start "Cloning repository..."
    git clone --branch "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR" > /dev/null 2>&1
    spinner_stop "Repository cloned to ${INSTALL_DIR}"
fi

# ── Step 3: Python venv ───────────────────────────────────────────────────────
step 3 $TOTAL_STEPS "Setting up Python environment"
spinner_start "Creating virtual environment..."
python3 -m venv "$VENV_DIR" > /dev/null 2>&1
spinner_stop "Virtual environment created"

spinner_start "Installing Python dependencies..."
source "${VENV_DIR}/bin/activate"
pip install -qq -r "${INSTALL_DIR}/requirements.txt" > /dev/null 2>&1
deactivate
spinner_stop "Python dependencies installed"

# ── Step 4: Database ──────────────────────────────────────────────────────────
step 4 $TOTAL_STEPS "Initializing database"
spinner_start "Creating database and admin user..."
SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
export BULLETIN_SECRET_KEY="${SECRET_KEY}"
source "${VENV_DIR}/bin/activate"
python3 -c "
from app import app, init_db, db, User
with app.app_context():
    init_db()
    from werkzeug.security import generate_password_hash
    admin = User.query.filter_by(username='admin').first()
    if admin:
        admin.password_hash = generate_password_hash('${ADMIN_PASS}')
        db.session.commit()
" > /dev/null 2>&1
deactivate
spinner_stop "Database initialized"

# ── Step 5: Config ────────────────────────────────────────────────────────────
step 5 $TOTAL_STEPS "Writing configuration"
cat > "${INSTALL_DIR}/config.env" << EOF
BULLETIN_SECRET_KEY=${SECRET_KEY}
EOF
chmod 600 "${INSTALL_DIR}/config.env"
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
systemctl start "$SERVICE_NAME" > /dev/null 2>&1
sleep 2
spinner_stop "Service started"

# ── Verify ─────────────────────────────────────────────────────────────────────
echo ""
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    success "Service is running"
else
    warn "Service may still be starting. Check: journalctl -u ${SERVICE_NAME} -n 20"
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
