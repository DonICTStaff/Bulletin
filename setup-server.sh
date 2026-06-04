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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo "=============================================="
echo "  Bulletin Board Server Installer"
echo "=============================================="
echo ""

# ── Interactive Configuration ─────────────────────────────────────────────────
# ── Interactive Configuration ─────────────────────────────────────────────────
while true; do
    read -rp "Enter the admin password for the web dashboard: " ADMIN_PASS
    ADMIN_PASS="${ADMIN_PASS:-}"
    if [[ -n "$ADMIN_PASS" ]]; then
        break
    fi
    warn "Admin password cannot be empty."
done

read -rp "Enter the server hostname/domain [bulletin-server]: " SERVER_HOSTNAME
SERVER_HOSTNAME="${SERVER_HOSTNAME:-bulletin-server}"

read -rp "Enter the Flask listen port [5000]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-5000}"

echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root (use sudo)."
fi

# ── Step 1: System packages ───────────────────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
    python3 \
    python3-venv \
    python3-pip \
    nginx \
    git \
    curl \
    > /dev/null 2>&1
success "System packages installed."

# ── Step 2: Clone the repository ───────────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
    info "Install directory exists, pulling latest..."
    cd "$INSTALL_DIR"
    git pull origin "$BRANCH" 2>/dev/null || warn "Git pull failed, using existing files."
else
    info "Cloning repository..."
    git clone --branch "$BRANCH" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi
success "Repository ready at ${INSTALL_DIR}"

# ── Step 3: Python venv and dependencies ───────────────────────────────────────
info "Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
source "${VENV_DIR}/bin/activate"
pip install -qq -r requirements.txt
deactivate
success "Python dependencies installed."

# ── Step 4: Create uploads directory ──────────────────────────────────────────
mkdir -p "${INSTALL_DIR}/uploads"

# ── Step 5: Initialize the database ───────────────────────────────────────────
info "Initializing database..."
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
source "${VENV_DIR}/bin/activate"
BULLETIN_SECRET_KEY="$SECRET_KEY" python3 -c "
import os
os.environ['BULLETIN_SECRET_KEY'] = '${SECRET_KEY}'
from app import app, init_db, db, User
with app.app_context():
    init_db()
    from werkzeug.security import generate_password_hash
    admin = User.query.filter_by(username='admin').first()
    if admin:
        admin.password_hash = generate_password_hash('${ADMIN_PASS}')
        db.session.commit()
        print('Admin password updated.')
"
deactivate
success "Database initialized."

# ── Step 6: Write server config ───────────────────────────────────────────────
cat > "${INSTALL_DIR}/config.env" << EOF
BULLETIN_SECRET_KEY=${SECRET_KEY}
EOF
chmod 600 "${INSTALL_DIR}/config.env"
success "Config saved."

# ── Step 7: Create systemd service ─────────────────────────────────────────────
info "Creating systemd service..."
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

# Ensure www-data can write uploads and DB
chown -R www-data:www-data "${INSTALL_DIR}/uploads"
chown -R www-data:www-data "${INSTALL_DIR}/instance" 2>/dev/null || true

# ── Step 8: Configure Nginx ────────────────────────────────────────────────────
info "Configuring Nginx..."
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
nginx -t && systemctl reload nginx
success "Nginx configured."

# ── Step 9: Enable and start ───────────────────────────────────────────────────
info "Enabling and starting ${SERVICE_NAME}..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
success "Service ${SERVICE_NAME} is running."

# ── Summary ────────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "=============================================="
echo "  Installation Complete!"
echo "=============================================="
echo ""
echo "  Dashboard:    http://${SERVER_IP}:${SERVER_PORT}"
echo "  Admin user:   admin"
echo "  Admin pass:   ${ADMIN_PASS}"
echo ""
echo "  To add a kiosk client, run this on the Pi:"
echo "    curl -fsSL ${GITHUB_RAW}/deploy-client.sh | sudo bash"
echo ""
echo "  Useful commands:"
echo "    Status:  systemctl status ${SERVICE_NAME}"
echo "    Logs:    journalctl -u ${SERVICE_NAME} -f"
echo "    Restart: sudo systemctl restart ${SERVICE_NAME}"
echo ""
