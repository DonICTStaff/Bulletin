#!/usr/bin/env python3
"""
client_daemon.py — Raspberry Pi Bulletin Board Kiosk Daemon

Connects to the Flask Bulletin server via HTTP + WebSockets.
Downloads the active .pptx, launches LibreOffice in kiosk mode,
reports telemetry, and accepts remote commands (reboot, reload).
"""

import os
import sys
import time
import json
import signal
import subprocess
import threading
import platform
import socket
import uuid
import argparse

try:
    import psutil
except ImportError:
    psutil = None
    print("WARNING: psutil not installed. Telemetry will be limited.")

try:
    import socketio
except ImportError:
    print("ERROR: python-socketio not installed. Run: pip install python-socketio")
    sys.exit(1)

import urllib.request
import urllib.error

# ── Configuration ─────────────────────────────────────────────────────────────
SERVER_URL = os.environ.get('BULLETIN_SERVER', 'http://don-bulletin-library:5000')
DEVICE_NAME = os.environ.get('BULLETIN_DEVICE_NAME', socket.gethostname())
CACHE_DIR = os.environ.get('BULLETIN_CACHE_DIR', '/tmp/bulletin_cache')
TELEMETRY_INTERVAL = 60  # seconds
RECONNECT_BASE_DELAY = 5  # seconds
RECONNECT_MAX_DELAY = 300  # seconds

# ── Globals ───────────────────────────────────────────────────────────────────
sio = socketio.Client(reconnection=True, reconnection_delay=RECONNECT_BASE_DELAY,
                       reconnection_delay_max=RECONNECT_MAX_DELAY)
current_presentation = None
libreoffice_proc = None
running = True


# ── Helpers ───────────────────────────────────────────────────────────────────
def get_mac_address():
    """Get the primary MAC address."""
    mac = uuid.getnode()
    return ':'.join(f'{(mac >> i) & 0xff:02x}' for i in range(0, 48, 8))


def get_ip_address():
    """Get the primary IP address."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_cpu_temp():
    """Get CPU temperature (Raspberry Pi specific)."""
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
    """Get system uptime in seconds."""
    try:
        with open('/proc/uptime', 'r') as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return None


def ensure_cache_dir():
    os.makedirs(CACHE_DIR, exist_ok=True)


# ── Presentation Management ──────────────────────────────────────────────────
def kill_libreoffice():
    """Kill any running LibreOffice processes."""
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
    """Launch LibreOffice Impress in kiosk/show mode."""
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
    """Download the active presentation from the server."""
    global current_presentation
    ensure_cache_dir()

    try:
        # Query the active presentation API
        req = urllib.request.urlopen(f"{SERVER_URL}/api/presentation/active", timeout=10)
        data = json.loads(req.read().decode())

        filename = data['filename']
        url = data['url']

        # Download the file
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


def check_and_update():
    """Check server for active presentation and update if changed."""
    global current_presentation
    try:
        req = urllib.request.urlopen(f"{SERVER_URL}/api/presentation/active", timeout=10)
        data = json.loads(req.read().decode())
        filename = data['filename']

        if filename != current_presentation:
            print(f"New presentation detected: {filename}")
            filepath = download_presentation()
            if filepath:
                launch_presentation(filepath)
        else:
            # Check if LibreOffice is still running
            if libreoffice_proc and libreoffice_proc.poll() is not None:
                print("LibreOffice exited, relaunching...")
                filepath = os.path.join(CACHE_DIR, current_presentation)
                if os.path.exists(filepath):
                    launch_presentation(filepath)
    except Exception as e:
        print(f"Error checking for updates: {e}")


# ── Telemetry ─────────────────────────────────────────────────────────────────
def send_telemetry():
    """Send device telemetry to the server via WebSocket."""
    if not sio.connected:
        return
    data = {
        'name': DEVICE_NAME,
        'ip_address': get_ip_address(),
        'mac_address': get_mac_address(),
        'cpu_temp': get_cpu_temp(),
        'uptime': get_uptime(),
        'active_presentation': current_presentation,
    }
    sio.emit('telemetry_update', data)


def telemetry_loop():
    """Background thread: send telemetry every TELEMETRY_INTERVAL seconds."""
    while running:
        send_telemetry()
        time.sleep(TELEMETRY_INTERVAL)


# ── WebSocket Event Handlers ─────────────────────────────────────────────────
@sio.event
def connect():
    print(f"Connected to server: {SERVER_URL}")
    sio.emit('client_register', {
        'name': DEVICE_NAME,
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
    """Server pushed a new presentation."""
    print(f"New presentation notification: {data.get('original_filename', 'unknown')}")
    filepath = download_presentation()
    if filepath:
        launch_presentation(filepath)


@sio.event
def command(data):
    """Execute a remote command from the admin."""
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
    global SERVER_URL, DEVICE_NAME

    parser = argparse.ArgumentParser(description='Bulletin Board Pi Client Daemon')
    parser.add_argument('--server', default=SERVER_URL, help='Server URL')
    parser.add_argument('--name', default=DEVICE_NAME, help='Device name')
    parser.add_argument('--cache-dir', default=CACHE_DIR, help='Local cache directory')
    args = parser.parse_args()

    SERVER_URL = args.server
    DEVICE_NAME = args.name
    cache_dir = args.cache_dir

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    ensure_cache_dir()

    # Download and display the current active presentation on startup
    print(f"Bulletin Board Kiosk Daemon starting...")
    print(f"  Server: {SERVER_URL}")
    print(f"  Device: {DEVICE_NAME}")
    print(f"  MAC: {get_mac_address()}")
    print(f"  Cache: {cache_dir}")

    filepath = download_presentation()
    if filepath:
        launch_presentation(filepath)
    else:
        print("WARNING: No active presentation on server. Waiting for push...")

    # Start telemetry thread
    telem_thread = threading.Thread(target=telemetry_loop, daemon=True)
    telem_thread.start()

    # Connect WebSocket (blocking)
    while running:
        try:
            sio.connect(SERVER_URL)
            sio.wait()
        except Exception as e:
            print(f"Connection error: {e}. Reconnecting in {RECONNECT_BASE_DELAY}s...")
            time.sleep(RECONNECT_BASE_DELAY)


if __name__ == '__main__':
    main()
