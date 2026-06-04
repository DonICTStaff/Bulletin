# Bulletin Board Server Deployment (Ubuntu Server)
# Assumes Ubuntu 24.04 with Python 3.12+

# ── 1. Install system packages ────────────────────────────────────────────────
sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx

# ── 2. Set up the application ────────────────────────────────────────────────
sudo mkdir -p /opt/bulletin
sudo cp -r . /opt/bulletin/
cd /opt/bulletin

python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# ── 3. Initialize the database ───────────────────────────────────────────────
source venv/bin/activate
python3 -c "from app import init_db; init_db()"

# ── 4. Create systemd service for the Flask server ───────────────────────────
sudo cp deployment/bulletin-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable bulletin-server
sudo systemctl start bulletin-server

# ── 5. Configure Nginx reverse proxy ─────────────────────────────────────────
sudo cp deployment/nginx-bulletin /etc/nginx/sites-available/bulletin
sudo ln -sf /etc/nginx/sites-available/bulletin /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ── 6. Verify ────────────────────────────────────────────────────────────────
curl http://localhost/api/presentation/active
