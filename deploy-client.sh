#!/usr/bin/env bash
# deploy-client.sh — Bulletin Board Kiosk Client Installer
# 
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/deploy-client.sh | bash
#
# Or download first, then run:
#   wget https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/deploy-client.sh
#   bash deploy-client.sh

set -euo pipefail

REPO_OWNER="DonICTStaff"
REPO_NAME="Bulletin"
BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

INSTALL_DIR="/opt/bulletin-client"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="bulletin-client"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  Bulletin Board Kiosk Client Installer"
echo "=============================================="
echo ""

# ── Interactive Configuration ─────────────────────────────────────────────────
echo "This script will set up the Bulletin Board kiosk client on this device."
echo "You will need to provide a few configuration values."
echo ""

# Server URL
while true; do
    read -rp "Enter the Bulletin server URL (e.g. http://192.168.1.50:5000): " SERVER_URL
    SERVER_URL="${SERVER_URL%/}"  # strip trailing slash
    if [[ -n "$SERVER_URL" ]]; then
        break
    fi
    warn "Server URL cannot be empty."
done

# Client ID
while true; do
    read -rp "Enter a unique client ID for this device (e.g. 'library-north', 'gym-display'): " CLIENT_ID
    CLIENT_ID="$(echo "$CLIENT_ID" | xargs)"  # trim whitespace
    if [[ -n "$CLIENT_ID" ]]; then
        if [[ "$CLIENT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            warn "Client ID must contain only letters, numbers, hyphens, and underscores."
        fi
    else
        warn "Client ID cannot be empty."
    fi
done

# Device name (optional)
read -rp "Enter a display name for this device [${CLIENT_ID}]: " DEVICE_NAME
DEVICE_NAME="${DEVICE_NAME:-$CLIENT_ID}"
DEVICE_NAME="$(echo "$DEVICE_NAME" | xargs)"

echo ""
echo "── Configuration Summary ────────────────────────────────"
echo "  Server URL:  ${SERVER_URL}"
echo "  Client ID:   ${CLIENT_ID}"
echo "  Device Name: ${DEVICE_NAME}"
echo "──────────────────────────────────────────────────────"
echo ""

read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# ── Require root for system-level setup ────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root (use sudo)."
fi

# ── Step 1: Install system dependencies ────────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
    python3 \
    python3-venv \
    python3-pip \
    libreoffice-impress \
    libreoffice-gtk3 \
    curl \
    jq \
    > /dev/null 2>&1
success "System packages installed."

# ── Step 2: Create install directory and fetch files ──────────────────────────
info "Creating install directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

info "Downloading client daemon from GitHub..."
curl -fsSL "${GITHUB_RAW}/client_daemon.py" -o "${INSTALL_DIR}/client_daemon.py"
chmod +x "${INSTALL_DIR}/client_daemon.py"

info "Downloading requirements file..."
curl -fsSL "${GITHUB_RAW}/requirements.txt" -o "${INSTALL_DIR}/requirements.txt"
success "Source files downloaded."

# We only need a subset of requirements for the client
# Create a minimal requirements file for the client
cat > "${INSTALL_DIR}/client-requirements.txt" << 'REQEOF'
python-socketio[client]>=5.11
eventlet>=0.35
psutil>=5.9
REQEOF

# ── Step 3: Create Python venv ────────────────────────────────────────────────
info "Creating Python virtual environment..."
python3 -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"
pip install -qq -r "${INSTALL_DIR}/client-requirements.txt"
deactivate
success "Python dependencies installed."

# ── Step 4: Write config file ─────────────────────────────────────────────────
info "Writing configuration..."
cat > "${INSTALL_DIR}/config.env" << EOF
BULLETIN_SERVER=${SERVER_URL}
BULLETIN_CLIENT_ID=${CLIENT_ID}
BULLETIN_DEVICE_NAME=${DEVICE_NAME}
EOF
chmod 600 "${INSTALL_DIR}/config.env"
success "Configuration saved to ${INSTALL_DIR}/config.env"

# ── Step 5: Create systemd service ─────────────────────────────────────────────
info "Creating systemd service..."

# Detect the user running the kiosk (the sudo user, or 'pi' as fallback)
KIOSK_USER="${SUDO_USER:-pi}"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SVCEOF
[Unit]
Description=Bulletin Board Kiosk Client
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
User=${KIOSK_USER}
Group=${KIOSK_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/config.env
ExecStart=${VENV_DIR}/bin/python ${INSTALL_DIR}/client_daemon.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
SVCEOF

# ── Step 6: Configure sudoers for passwordless reboot ──────────────────────────
info "Configuring sudoers for passwordless reboot..."
SUDOERS_FILE="/etc/sudoers.d/bulletin-kiosk"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "${KIOSK_USER} ALL=(ALL) NOPASSWD: /sbin/reboot, /usr/sbin/reboot" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    success "Sudoers configured for user '${KIOSK_USER}'."
else
    warn "Sudoers file already exists, skipping."
fi

# ── Step 7: Enable and start ───────────────────────────────────────────────────
info "Enabling and starting ${SERVICE_NAME}..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"
success "Service ${SERVICE_NAME} is running."

# ── Verify ─────────────────────────────────────────────────────────────────────
echo ""
sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    success "Bulletin Board Kiosk Client is installed and running!"
else
    warn "Service may not have started yet. Check: journalctl -u ${SERVICE_NAME} -n 20"
fi

echo ""
echo "── Useful Commands ──────────────────────────────────"
echo "  Check status:  systemctl status ${SERVICE_NAME}"
echo "  View logs:     journalctl -u ${SERVICE_NAME} -f"
echo "  Restart:       sudo systemctl restart ${SERVICE_NAME}"
echo "  Edit config:   sudo nano ${INSTALL_DIR}/config.env"
echo ""
echo "Your client '${CLIENT_ID}' should appear in the server's"
echo "fleet management page once connected."
echo "──────────────────────────────────────────────────────"
