#!/usr/bin/env python3
"""
client_daemon.py — Raspberry Pi Bulletin Board Kiosk Daemon

Connects to the Flask Bulletin server via HTTP + WebSockets.
Downloads the active .pptx, launches LibreOffice in kiosk mode,
reports telemetry, and accepts remote commands (reboot, reload).

Typical usage:
    python3 client_daemon.py --server http://192.168.1.100:5000 --client-id library-north

Or set environment variables:
    BULLETIN_SERVER=http://192.168.1.100:5000
    BULLETIN_CLIENT_ID=library-north
    BULLETIN_DEVICE_NAME=pi-north
"""

import os
import sys
import time
import json
import signal
import subprocess
import threading
import socket
import uuid
import argparse

try:
    import psutil
except ImportError:
    psutil = None

try:
    import socketio
except ImportError:
    print("ERROR: python-socketio not installed. Run: pip install python-socketio")
    sys.exit(1)

import urllib.request
import urllib.error

# ── Configuration (all from env vars or CLI args, no hardcoded defaults) ──────
SERVER_URL = os.environ.get('BULLETIN_SERVER', '')
CLIENT_ID = os.environ.get('BULLETIN_CLIENT_ID', '')
DEVICE_NAME = os.environ.get('BULLETIN_DEVICE_NAME', socket.gethostname())
CACHE_DIR = os.environ.get('BULLETIN_CACHE_DIR', '/tmp/bulletin_cache')
TELEMETRY_INTERVAL = int(os.environ.get('BULLETIN_TELEMETRY_INTERVAL', '60'))
RECONNECT_BASE_DELAY = 5
RECONNECT_MAX_DELAY = 300

# ── Globals ───────────────────────────────────────────────────────────────────
sio = socketio.Client(reconnection=True, reconnection_delay=RECONNECT_BASE_DELAY,
                       reconnection_delay_max=RECONNECT_MAX_DELAY)
current_presentation = None
libreoffice_proc = None
running = True


# ── Helpers ───────────────────────────────────────────────────────────────────
def get_mac_address():
    mac = uuid.getnode()
    return ':'.join(f'{(mac >> i) & 0xff:02x}' for i in range(0, 48, 8))


def get_ip_address():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            return float(f.read().strip()) / 1000.0
    except Exception:
        if psutil:
            temps = psutil.sensors_temperatures()
            if temps:
                for entries in temps.values():
                    if entries:
                        return entries[0].current
        return None


def get_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return None


def ensure_cache_dir():
    os.makedirs(CACHE_DIR, exist_ok=True)


# ── Presentation Management ──────────────────────────────────────────────────
def kill_libreoffice():
    global libreoffice_proc
    try:
        subprocess.call(['pkill', '-f', 'libreoffice'])
    except Exception:
        pass
    if libreoffice_proc:
        try:
            libreoffice_proc.terminate()
            libreoffice_proc.wait(timeout=5)
        except Exception:
            try:
                libreoffice_proc.kill()
            except Exception:
                pass
        libreoffice_proc = None


def launch_presentation(filepath):
    global libreoffice_proc, current_presentation
    kill_libreoffice()

    if not os.path.exists(filepath):
        print(f"ERROR: File not found: {filepath}")
        return False

    try:
        libreoffice_proc = subprocess.Popen([
            'libreoffice', '--show', filepath,
            '--norestore', '--nologo'
        ])
        current_presentation = os.path.basename(filepath)
        print(f"Launched presentation: {current_presentation} (PID: {libreoffice_proc.pid})")
        return True
    except Exception as e:
        print(f"ERROR launching LibreOffice: {e}")
        return False


def download_presentation():
    global current_presentation
    ensure_cache_dir()

    try:
        req = urllib.request.urlopen(f"{SERVER_URL}/api/presentation/active", timeout=10)
        data = json.loads(req.read().decode())

        filename = data['filename']
        url = data['url']

        dest = os.path.join(CACHE_DIR, filename)
        urllib.request.urlretrieve(url, dest)
        print(f"Downloaded: {filename} -> {dest}")
        return dest

    except urllib.error.URLError as e:
        print(f"ERROR downloading presentation: {e}")
        return None
    except Exception as e:
        print(f"ERROR: {e}")
        return None


# ── Telemetry ─────────────────────────────────────────────────────────────────
def send_telemetry():
    if not sio.connected:
        return
    data = {
        'name': DEVICE_NAME,
        'client_id': CLIENT_ID,
        'ip_address': get_ip_address(),
        'mac_address': get_mac_address(),
        'cpu_temp': get_cpu_temp(),
        'uptime': get_uptime(),
        'active_presentation': current_presentation,
    }
    sio.emit('telemetry_update', data)


def telemetry_loop():
    while running:
        send_telemetry()
        time.sleep(TELEMETRY_INTERVAL)


# ── WebSocket Event Handlers ─────────────────────────────────────────────────
@sio.event
def connect():
    print(f"Connected to server: {SERVER_URL}")
    sio.emit('client_register', {
        'name': DEVICE_NAME,
        'client_id': CLIENT_ID,
        'mac_address': get_mac_address(),
    })


@sio.event
def disconnect():
    print("Disconnected from server")


@sio.event
def registration_ack(data):
    print(f"Registered with server: {data}")


@sio.event
def new_presentation_available(data):
    print(f"New presentation notification: {data.get('original_filename', 'unknown')}")
    filepath = download_presentation()
    if filepath:
        launch_presentation(filepath)


@sio.event
def command(data):
    cmd = data.get('command')
    print(f"Received command: {cmd}")

    if cmd == 'reboot':
        print("Executing reboot...")
        kill_libreoffice()
        subprocess.call(['sudo', 'reboot'])

    elif cmd == 'reload':
        print("Reloading presentation...")
        filepath = download_presentation()
        if filepath:
            launch_presentation(filepath)
        elif current_presentation:
            filepath = os.path.join(CACHE_DIR, current_presentation)
            if os.path.exists(filepath):
                launch_presentation(filepath)


# ── Main ──────────────────────────────────────────────────────────────────────
def signal_handler(signum, frame):
    global running
    print(f"\nReceived signal {signum}, shutting down...")
    running = False
    kill_libreoffice()
    if sio.connected:
        sio.disconnect()
    sys.exit(0)


def main():
    global SERVER_URL, CLIENT_ID, DEVICE_NAME, CACHE_DIR

    parser = argparse.ArgumentParser(description='Bulletin Board Pi Client Daemon')
    parser.add_argument('--server', default=SERVER_URL, help='Server URL (e.g. http://192.168.1.100:5000)')
    parser.add_argument('--client-id', default=CLIENT_ID, help='Unique client identifier (e.g. library-north)')
    parser.add_argument('--name', default=DEVICE_NAME, help='Device hostname')
    parser.add_argument('--cache-dir', default=CACHE_DIR, help='Local cache directory')
    args = parser.parse_args()

    SERVER_URL = args.server
    CLIENT_ID = args.client_id
    DEVICE_NAME = args.name
    CACHE_DIR = args.cache_dir

    # Validate required config
    if not SERVER_URL:
        print("ERROR: Server URL is required. Set BULLETIN_SERVER env var or use --server.")
        sys.exit(1)

    # Normalize URL (strip trailing slash)
    SERVER_URL = SERVER_URL.rstrip('/')

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    ensure_cache_dir()

    print(f"Bulletin Board Kiosk Daemon v2.0")
    print(f"  Server:    {SERVER_URL}")
    print(f"  Client ID: {CLIENT_ID or '(not set)'}")
    print(f"  Hostname:  {DEVICE_NAME}")
    print(f"  MAC:       {get_mac_address()}")
    print(f"  Cache:     {CACHE_DIR}")

    filepath = download_presentation()
    if filepath:
        launch_presentation(filepath)
    else:
        print("WARNING: No active presentation on server. Waiting for push...")

    telem_thread = threading.Thread(target=telemetry_loop, daemon=True)
    telem_thread.start()

    while running:
        try:
            sio.connect(SERVER_URL)
            sio.wait()
        except Exception as e:
            print(f"Connection error: {e}. Reconnecting in {RECONNECT_BASE_DELAY}s...")
            time.sleep(RECONNECT_BASE_DELAY)


if __name__ == '__main__':
    main()
