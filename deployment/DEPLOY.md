# Bulletin Board — Deployment Guide

## Quick Start

### Server (Ubuntu Server)

```bash
curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/setup-server.sh | sudo bash
```

The script will interactively ask for:
- Admin password
- Server hostname/domain
- Flask port (default: 5000)

It then automatically: clones the repo, sets up the Python venv, initializes the SQLite database, configures Nginx (with WebSocket proxy), and starts the systemd service.

### Client (Raspberry Pi)

```bash
curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/deploy-client.sh | sudo bash
```

The script will interactively ask for:
- **Server URL** — e.g. `http://192.168.1.50:5000`
- **Client ID** — a unique identifier like `library-north`, `gym-display`, `canteen-01`
- **Device Name** — display name (defaults to Client ID)

It then: installs system deps (LibreOffice, Python venv, etc.), downloads `client_daemon.py` from GitHub, creates a systemd service, and starts it.

The client will appear in the server's **Fleet Management** page once it connects.

---

## Manual Server Setup

### 1. System packages
```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx libreoffice-impress
```

### 2. Clone and configure
```bash
sudo git clone https://github.com/DonICTStaff/Bulletin.git /opt/bulletin
cd /opt/bulletin
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 3. Set environment variables
```bash
cat > /opt/bulletin/config.env << EOF
BULLETIN_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
BULLETIN_DATABASE_URI=sqlite:///bulletin.db
EOF
chmod 600 /opt/bulletin/config.env
```

### 4. Initialize database
```bash
BULLETIN_SECRET_KEY=<your-secret> venv/bin/python -c "from app import init_db; init_db()"
```

### 5. Systemd service
```bash
sudo cp deployment/bulletin-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now bulletin-server
```

### 6. Nginx
```bash
sudo cp deployment/nginx-bulletin /etc/nginx/sites-available/bulletin
sudo sed -i 's/bulletin-server/YOUR_HOSTNAME/' /etc/nginx/sites-available/bulletin
sudo ln -sf /etc/nginx/sites-available/bulletin /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## Manual Client Setup

### 1. Install dependencies
```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip libreoffice-impress
```

### 2. Download client files from GitHub
```bash
sudo mkdir -p /opt/bulletin-client
cd /opt/bulletin-client
sudo curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/client_daemon.py -o client_daemon.py
sudo curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/requirements.txt -o requirements.txt
```

### 3. Install Python dependencies
```bash
python3 -m venv venv
source venv/bin/activate
pip install python-socketio[client] eventlet psutil
deactivate
```

### 4. Write config
```bash
cat > /opt/bulletin-client/config.env << EOF
BULLETIN_SERVER=http://YOUR_SERVER:5000
BULLETIN_CLIENT_ID=my-client-id
BULLETIN_DEVICE_NAME=My Display
EOF
chmod 600 /opt/bulletin-client/config.env
```

### 5. Configure sudoers (for remote reboot)
```bash
echo "pi ALL=(ALL) NOPASSWD: /sbin/reboot, /usr/sbin/reboot" | sudo tee /etc/sudoers.d/bulletin-kiosk
sudo chmod 440 /etc/sudoers.d/bulletin-kiosk
```

### 6. Systemd service
```bash
sudo cp deployment/kiosk-daemon.service /etc/systemd/system/bulletin-client.service
sudo systemctl daemon-reload && sudo systemctl enable --now bulletin-client
```

---

## Environment Variables Reference

### Server (`/opt/bulletin/config.env`)
| Variable | Default | Description |
|---|---|---|
| `BULLETIN_SECRET_KEY` | random per startup | Flask secret key (set for stable sessions) |
| `BULLETIN_DATABASE_URI` | `sqlite:///bulletin.db` | SQLAlchemy database URI |

### Client (`/opt/bulletin-client/config.env`)
| Variable | Default | Description |
|---|---|---|
| `BULLETIN_SERVER` | *(required)* | Full URL of the Flask server |
| `BULLETIN_CLIENT_ID` | *(empty)* | Unique client identifier (e.g. `library-north`) |
| `BULLETIN_DEVICE_NAME` | hostname | Human-readable device name |
| `BULLETIN_CACHE_DIR` | `/tmp/bulletin_cache` | Local `.pptx` cache directory |
| `BULLETIN_TELEMETRY_INTERVAL` | `60` | Seconds between telemetry reports |
