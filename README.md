# Bulletin Board

A client-server digital signage system for Don College. Upload a PowerPoint slideshow to the central server and it instantly appears on all connected Raspberry Pi displays.

## How It Works

```
┌──────────────────────┐                            ┌──────────────────────┐
│                      │ ──── new presentation ──► │                      │
│   Ubuntu Server      │         WebSocket push    │   Raspberry Pi       │
│                      │ ◄──── telemetry (60s) ── │   (Kiosk Client)     │
│   Flask + Nginx      │                            │                      │
│                      │ ──── remote commands ───► │   LibreOffice        │
│   Admin Dashboard    │                            │   Impress (kiosk)    │
└──────────────────────┘                            └──────────────────────┘
```

1. **Upload** a `.pptx` file via the web dashboard
2. **Server** saves it and broadcasts a WebSocket event to all connected clients
3. **Clients** download the file, kill the current LibreOffice process, and launch the new presentation in full-screen kiosk mode
4. **Telemetry** (CPU temp, uptime, IP, active presentation) is reported back to the server every 60 seconds
5. **Admins** can remotely reboot clients or reload presentations from the Fleet Management page

## Features

- **Role-based access**: Administrators (full control) and Operators (upload only)
- **Real-time sync**: WebSocket push notifications -- no polling
- **Fleet management**: Live dashboard showing all connected devices, health, and status
- **Remote commands**: Reboot or reload any client from the web UI
- **Crash protection**: Client daemon relaunches LibreOffice if it exits unexpectedly
- **Auto-reconnect**: Exponential backoff if the network drops
- **One-command install**: Both server and client have interactive `curl | bash` installers

## Architecture

| Component | Technology |
|---|---|
| Server backend | Python, Flask, Flask-SocketIO, SQLAlchemy |
| Server frontend | Flask templates, vanilla JS, Socket.IO client |
| Client daemon | Python, python-socketio, psutil, subprocess |
| Display engine | LibreOffice Impress in `--show` kiosk mode |
| Communication | HTTP/REST (file transfer) + WebSockets (push/telemetry) |
| Database | SQLite (development) or PostgreSQL (production) |
| Reverse proxy | Nginx with WebSocket upgrade support |
| Process management | systemd services on both server and clients |

## Quick Start

### Server (Ubuntu 24.04)

```bash
curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/setup-server.sh | sudo bash
```

The installer will ask for:
- **Admin password** for the web dashboard
- **Server hostname** (e.g. `bulletin-server` or an IP)
- **Flask port** (default: `5000`)

It then automatically: clones the repo, sets up the Python venv, initializes the database, configures Nginx (with WebSocket proxy), and starts the systemd service.

When it finishes, the dashboard URL and admin credentials are displayed.

### Client (Raspberry Pi OS)

On each Raspberry Pi that will act as a display:

```bash
curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/deploy-client.sh | sudo bash
```

The installer will ask for:
- **Server URL** -- the address of your Bulletin server (e.g. `http://192.168.1.50:5000`)
- **Client ID** -- a unique identifier for this display (e.g. `library-north`, `gym-display`)
- **Device Name** -- a human-readable name (defaults to the Client ID)

It then: installs system dependencies (LibreOffice, Python venv), downloads the client daemon from GitHub, creates a systemd service, and starts it.

The client will appear in the server's **Fleet Management** page once it connects.

## Manual Installation

### Server

#### 1. System packages

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx git
```

#### 2. Clone and configure

```bash
sudo git clone https://github.com/DonICTStaff/Bulletin.git /opt/bulletin
cd /opt/bulletin
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
deactivate
```

#### 3. Set environment variables

```bash
cat > /opt/bulletin/config.env << EOF
BULLETIN_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
BULLETIN_DATABASE_URI=sqlite:///bulletin.db
EOF
chmod 600 /opt/bulletin/config.env
```

#### 4. Initialize the database

```bash
source venv/bin/activate
BULLETIN_SECRET_KEY=your-secret-key python3 -c "from app import init_db; init_db()"
deactivate
```

#### 5. Create the systemd service

```bash
sudo cp deployment/bulletin-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now bulletin-server
```

#### 6. Configure Nginx

```bash
sudo cp deployment/nginx-bulletin /etc/nginx/sites-available/bulletin
sudo sed -i 's/__SERVER_NAME__/your-hostname/' /etc/nginx/sites-available/bulletin
sudo sed -i 's/__FLASK_PORT__/5000/' /etc/nginx/sites-available/bulletin
sudo ln -sf /etc/nginx/sites-available/bulletin /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

#### 7. Verify

```bash
systemctl status bulletin-server
curl http://localhost:5000/api/presentation/active
```

### Client

#### 1. System packages

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip libreoffice-impress
```

#### 2. Download client files

```bash
sudo mkdir -p /opt/bulletin-client
cd /opt/bulletin-client
sudo curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/client_daemon.py -o client_daemon.py
sudo chmod +x client_daemon.py
```

#### 3. Python dependencies

```bash
python3 -m venv venv
source venv/bin/activate
pip install python-socketio[client] eventlet psutil
deactivate
```

#### 4. Write configuration

```bash
cat > /opt/bulletin-client/config.env << EOF
BULLETIN_SERVER=http://your-server:5000
BULLETIN_CLIENT_ID=library-north
BULLETIN_DEVICE_NAME=Library North Display
EOF
chmod 600 /opt/bulletin-client/config.env
```

#### 5. Allow passwordless reboot (for remote admin)

```bash
echo "pi ALL=(ALL) NOPASSWD: /sbin/reboot, /usr/sbin/reboot" | sudo tee /etc/sudoers.d/bulletin-kiosk
sudo chmod 440 /etc/sudoers.d/bulletin-kiosk
```

#### 6. Create the systemd service

```bash
sudo cp deployment/kiosk-daemon.service /etc/systemd/system/bulletin-client.service
sudo systemctl daemon-reload
sudo systemctl enable --now bulletin-client
```

#### 7. Verify

```bash
systemctl status bulletin-client
journalctl -u bulletin-client -f
```

## Configuration Reference

### Server (`/opt/bulletin/config.env`)

| Variable | Default | Description |
|---|---|---|
| `BULLETIN_SECRET_KEY` | random per startup | Flask secret key. Set this for stable sessions across restarts. |
| `BULLETIN_DATABASE_URI` | `sqlite:///bulletin.db` | SQLAlchemy connection string. Use `postgresql://user:pass@host/db` for production. |

### Client (`/opt/bulletin-client/config.env`)

| Variable | Default | Description |
|---|---|---|
| `BULLETIN_SERVER` | *(required)* | Full URL of the Flask server (e.g. `http://192.168.1.50:5000`) |
| `BULLETIN_CLIENT_ID` | *(empty)* | Unique identifier for this display (e.g. `library-north`). Letters, numbers, hyphens, underscores only. |
| `BULLETIN_DEVICE_NAME` | hostname | Human-readable name shown in the fleet dashboard |
| `BULLETIN_CACHE_DIR` | `/tmp/bulletin_cache` | Local directory for downloaded `.pptx` files |
| `BULLETIN_TELEMETRY_INTERVAL` | `60` | Seconds between telemetry reports to the server |

## Web Dashboard

After installing the server, access the dashboard at `http://your-server:5000`.

### Login

Use the admin credentials you set during installation. Default admin username is `admin`.

### Dashboard (all users)

- View the currently active presentation
- Upload a new `.pptx` file (replaces the active one)
- See presentation history and switch between them
- View connected client devices with online/offline status

### User Management (Admin only)

- Create new users with Admin or Operator roles
- Delete users (cannot delete your own account)

Operators can upload and activate presentations. Administrators can also manage users and access fleet controls.

### Fleet Management (Admin only)

- Live table of all registered client devices
- Status indicators: online/offline, CPU temperature, uptime, active presentation
- **Reload Presentation** -- tells the client to re-download and restart the current slideshow
- **Reboot Device** -- remotely reboots the Raspberry Pi

## API Reference

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/api/presentation/active` | GET | Public | Get metadata about the active presentation |
| `/api/download/presentation` | GET | Public | Download the active `.pptx` file |
| `/api/clients` | GET | Public | List all registered client devices |
| `/api/clients/<id>/command` | POST | Admin | Send a command (`reboot` or `reload`) to a client |

## Troubleshooting

### Client won't connect

```bash
# Check the service status
sudo systemctl status bulletin-client

# View recent logs
sudo journalctl -u bulletin-client -n 50

# Verify the config
cat /opt/bulletin-client/config.env

# Test connectivity to the server
curl http://your-server:5000/api/presentation/active
```

### Presentation not displaying

```bash
# Check if LibreOffice is running
pgrep -a libreoffice

# Check the cache directory
ls -la /tmp/bulletin_cache/

# Restart the client daemon
sudo systemctl restart bulletin-client
```

### Server not responding

```bash
# Check Flask
sudo systemctl status bulletin-server
sudo journalctl -u bulletin-server -n 50

# Check Nginx
sudo nginx -t
sudo systemctl status nginx

# Verify the port is listening
ss -tlnp | grep 5000
```

### Change the admin password

```bash
cd /opt/bulletin
source venv/bin/activate
python3 -c "
from app import db, User
from werkzeug.security import generate_password_hash
admin = User.query.filter_by(username='admin').first()
admin.password_hash = generate_password_hash('new-password-here')
db.session.commit()
print('Password updated.')
"
deactivate
```

## Updating

### Server

```bash
cd /opt/bulletin
sudo git pull origin main
sudo systemctl restart bulletin-server
```

### Client

```bash
cd /opt/bulletin-client
sudo curl -fsSL https://raw.githubusercontent.com/DonICTStaff/Bulletin/main/client_daemon.py -o client_daemon.py
sudo systemctl restart bulletin-client
```

## Project Structure

```
Bulletin/
├── app.py                  # Flask server (all routes, models, WebSocket handlers)
├── client_daemon.py        # Raspberry Pi client daemon
├── requirements.txt        # Python dependencies (server)
├── setup-server.sh         # Interactive server installer
├── deploy-client.sh        # Interactive client installer
├── templates/
│   ├── login.html          # Login page
│   ├── dashboard.html      # Main dashboard (upload, history, client list)
│   ├── fleet.html          # Fleet management (telemetry, remote commands)
│   ├── users.html          # User management (admin only)
│   ├── changelog.html      # Changelog display
│   └── upload.html         # Legacy redirect
├── static/
│   ├── donlogo.jpg         # Don College logo
│   ├── stylelogin.css      # Login page styles
│   ├── styleuploads.css    # Dashboard/fleet styles
│   └── stylechangelog.css  # Changelog styles
├── deployment/
│   ├── DEPLOY.md           # Detailed deployment guide
│   ├── bulletin-server.service  # Server systemd unit
│   ├── kiosk-daemon.service     # Client systemd unit
│   ├── nginx-bulletin           # Nginx site config (template)
│   └── sudoers-bulletin         # Sudoers config for passwordless reboot
└── Project.md              # Project goals and milestones
```

## License

Internal project for Don College.
