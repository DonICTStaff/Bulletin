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

# When run via "curl | bash", stdin is the script pipe, not the terminal.
# All interactive prompts must read from /dev/tty explicitly.
TTY="/dev/tty"

# Verify we can read from the terminal for interactive prompts
if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
    echo "ERROR: No terminal available for interactive input."
    echo "Run this script directly (not piped), or use: bash deploy-client.sh"
    exit 1
fi

REPO_OWNER="DonICTStaff"
REPO_NAME="Bulletin"
BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

INSTALL_DIR="/opt/bulletin-client"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="bulletin-client"

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
            printf "\\r  ${CYAN}%s${NC} %s" "${SPINNER_FRAMES[$SPINNER_INDEX]}" "$msg"
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
    printf "\\r  ${GREEN}✓${NC} %s\\n" "$1"
}

# ── Logging ────────────────────────────────────────────────────────────────────
info()    { printf "  ${BLUE}ℹ${NC}  %s\\n" "$*"; }
success() { printf "  ${GREEN}✓${NC}  %s\\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\\n" "$*"; }
error()   { printf "\\n  ${RED}✗  ERROR:${NC} %s\\n\\n" "$*"; exit 1; }
step()    { printf "\\n${BOLD}  [%d/%d]${NC} %s\\n" "$1" "$2" "$3"; }

# ── Banner ─────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                  ║"
echo "  ║   $(uv run python -m pyfiglet -f slant Bulletin | sed 's/^/      /')   ║"
echo "  ║                                                  ║"
echo "  ║          ${NC}${BOLD}Kiosk Client Installer${CYAN}                    ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Don College Bulletin Board Digital Signage System${NC}"
echo -e "  ${DIM}https://github.com/${REPO_OWNER}/${REPO_NAME}${NC}"
echo ""

# ── Interactive Configuration ─────────────────────────────────────────────────
echo -e "  ${BOLD}This installer will set up the kiosk client on this device.${NC}"
echo -e "  ${DIM}You will need to provide a few configuration values.${NC}"
echo ""

# Server URL
while true; do
    printf "  ${BOLD}▸${NC} ${CYAN}Server URL${NC} (e.g. http://192.168.1.50:5000): "
    read -r SERVER_URL < "$TTY"
    SERVER_URL="${SERVER_URL%/}"
    if [[ -n "$SERVER_URL" ]]; then
        break
    fi
    warn "Server URL cannot be empty."
done

# Client ID
while true; do
    printf "  ${BOLD}▸${NC} ${CYAN}Client ID${NC} (e.g. library-north, gym-display): "
    read -r CLIENT_ID < "$TTY"
    CLIENT_ID="$(echo "$CLIENT_ID" | xargs)"
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
printf "  ${BOLD}▸${NC} ${CYAN}Device name${NC} [${CLIENT_ID}]: "
read -r DEVICE_NAME < "$TTY"
DEVICE_NAME="${DEVICE_NAME:-$CLIENT_ID}"
DEVICE_NAME="$(echo "$DEVICE_NAME" | xargs)"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${DIM}┌──────────────────────────────────────────────────────┐${NC}"
echo -e "  ${DIM}│${NC} ${BOLD}Configuration Summary${NC}"
echo -e "  ${DIM}│${NC}"
echo -e "  ${DIM}│${NC}   Server URL:  ${GREEN}${SERVER_URL}${NC}"
echo -e "  ${DIM}│${NC}   Client ID:   ${GREEN}${CLIENT_ID}${NC}"
echo -e "  ${DIM}│${NC}   Device Name: ${GREEN}${DEVICE_NAME}${NC}"
echo -e "  ${DIM}└──────────────────────────────────────────────────────┘${NC}"
echo ""

printf "  Proceed with installation? ${DIM}[Y/n]${NC}: "
read -r CONFIRM < "$TTY"
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

TOTAL_STEPS=8

# ── Step 1: System dependencies ───────────────────────────────────────────────
step 1 $TOTAL_STEPS "Installing system packages"
spinner_start "Updating package lists..."
apt-get update -qq > /dev/null 2>&1
spinner_stop "Package lists updated"

spinner_start "Installing dependencies (python3, libreoffice, curl, jq)..."
apt-get install -y -qq \
    python3 \
    python3-venv \
    python3-pip \
    libreoffice-impress \
    libreoffice-gtk3 \
    curl \
    jq \
    > /dev/null 2>&1
spinner_stop "System packages installed"

# ── Step 2: Create install directory ───────────────────────────────────────────
step 2 $TOTAL_STEPS "Setting up install directory"
spinner_start "Creating ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
spinner_stop "Directory ready"

spinner_start "Downloading client_daemon.py from GitHub..."
curl -fsSL "${GITHUB_RAW}/client_daemon.py" -o "${INSTALL_DIR}/client_daemon.py"
chmod +x "${INSTALL_DIR}/client_daemon.py"
spinner_stop "client_daemon.py downloaded"

# ── Step 3: Python venv ───────────────────────────────────────────────────────
step 3 $TOTAL_STEPS "Setting up Python environment"
spinner_start "Creating virtual environment..."
python3 -m venv "${VENV_DIR}" > /dev/null 2>&1
spinner_stop "Virtual environment created"

spinner_start "Installing Python dependencies..."
cat > "${INSTALL_DIR}/client-requirements.txt" << 'REQEOF'
python-socketio[client]>=5.11
eventlet>=0.35
psutil>=5.9
REQEOF
source "${VENV_DIR}/bin/activate"
pip install -qq -r "${INSTALL_DIR}/client-requirements.txt" > /dev/null 2>&1
deactivate
spinner_stop "Python dependencies installed"

# ── Step 4: Write config ──────────────────────────────────────────────────────
step 4 $TOTAL_STEPS "Writing configuration"
cat > "${INSTALL_DIR}/config.env" << EOF
BULLETIN_SERVER=${SERVER_URL}
BULLETIN_CLIENT_ID=${CLIENT_ID}
BULLETIN_DEVICE_NAME=${DEVICE_NAME}
EOF
chmod 600 "${INSTALL_DIR}/config.env"
success "Configuration saved to ${INSTALL_DIR}/config.env"

# ── Step 5: Register with server ──────────────────────────────────────────────
step 5 $TOTAL_STEPS "Registering with server"
spinner_start "Requesting API key from server..."
API_KEY=$(curl -fsSL -X POST "${SERVER_URL}/api/register" \
    -H "Content-Type: application/json" \
    -d "{\\"client_id\\":\\"${CLIENT_ID}\\",\\"name\\":\\"${DEVICE_NAME}\\\"}" \
    2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('api_key', ''))
except:
    print('')
" 2>/dev/null)

if [[ -n "$API_KEY" ]]; then
    # Save API key to a separate file the daemon can load
    echo "$API_KEY" > "${INSTALL_DIR}/.api_key"
    chmod 600 "${INSTALL_DIR}/.api_key"
    spinner_stop "Registered (key: ${API_KEY[:8]}...)"
else
    spinner_stop "Could not register (will retry on first connection)"
    warn "Server may be unreachable. Client will register via WebSocket on first connect."
fi

# ── Step 6: Systemd service ───────────────────────────────────────────────────
step 6 $TOTAL_STEPS "Creating systemd service"
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
success "Service file created"

# ── Step 6: Sudoers ───────────────────────────────────────────────────────────
step 6 $TOTAL_STEPS "Configuring sudoers for remote reboot"
SUDOERS_FILE="/etc/sudoers.d/bulletin-kiosk"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "${KIOSK_USER} ALL=(ALL) NOPASSWD: /sbin/reboot, /usr/sbin/reboot" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    success "Sudoers configured for user '${KIOSK_USER}'"
else
    warn "Sudoers file already exists, skipping"
fi

# ── Step 7: Enable and start ──────────────────────────────────────────────────
step 7 $TOTAL_STEPS "Starting service"
spinner_start "Enabling and starting ${SERVICE_NAME}..."
systemctl daemon-reload > /dev/null 2>&1
systemctl enable "${SERVICE_NAME}" > /dev/null 2>&1
systemctl start "${SERVICE_NAME}" > /dev/null 2>&1
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
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║            Installation Complete!                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}${CLIENT_ID}${NC} is now connecting to:"
echo -e "  ${DIM}${SERVER_URL}${NC}"
echo ""
echo -e "  The client will appear in the server's Fleet Management"
echo -e "  page once connected."
echo ""
echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    ${CYAN}systemctl status ${SERVICE_NAME}${NC}    Check status"
echo -e "    ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}    View live logs"
echo -e "    ${CYAN}sudo systemctl restart ${SERVICE_NAME}${NC}  Restart"
echo -e "    ${CYAN}sudo nano ${INSTALL_DIR}/config.env${NC}       Edit config"
echo ""