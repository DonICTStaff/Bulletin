import os
import subprocess
import shutil
import time
import threading
import secrets
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, abort
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
from flask_sqlalchemy import SQLAlchemy
from flask_socketio import SocketIO, emit
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
from datetime import datetime

# ── App Configuration ────────────────────────────────────────────────────────
app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('BULLETIN_SECRET_KEY', secrets.token_hex(32))
app.config['UPLOAD_FOLDER'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uploads')
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('BULLETIN_DATABASE_URI', 'sqlite:///bulletin.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024  # 100 MB max upload

ALLOWED_EXTENSIONS = {'pptx', 'ppt'}

# ── Extensions ────────────────────────────────────────────────────────────────
db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'
socketio = SocketIO(app, async_mode='eventlet', cors_allowed_origins='*')

# ── Database Models ───────────────────────────────────────────────────────────
class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    role = db.Column(db.String(20), nullable=False, default='operator')  # 'admin' or 'operator'
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    def is_admin(self):
        return self.role == 'admin'


class Slideshow(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(256), nullable=False)
    original_filename = db.Column(db.String(256), nullable=False)
    uploaded_by = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
    is_active = db.Column(db.Boolean, default=False)

    uploader = db.relationship('User', backref='slideshows')


class ClientDevice(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    client_id = db.Column(db.String(64), unique=True, nullable=True)  # User-assigned friendly ID (e.g. "library-north")
    name = db.Column(db.String(128), nullable=False, default='Unnamed Device')
    ip_address = db.Column(db.String(45))
    mac_address = db.Column(db.String(17))
    last_seen = db.Column(db.DateTime)
    is_online = db.Column(db.Boolean, default=False)
    cpu_temp = db.Column(db.Float)
    uptime_seconds = db.Column(db.Integer)
    active_presentation = db.Column(db.String(256))
    socket_id = db.Column(db.String(128))  # WebSocket SID for targeted commands


# ── RBAC Decorator ────────────────────────────────────────────────────────────
def admin_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not current_user.is_authenticated or not current_user.is_admin():
            abort(403)
        return f(*args, **kwargs)
    return decorated_function


# ── User Loader ───────────────────────────────────────────────────────────────
@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))


# ── Helpers ───────────────────────────────────────────────────────────────────
def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS


def clear_uploads():
    upload_folder = app.config['UPLOAD_FOLDER']
    for filename in os.listdir(upload_folder):
        file_path = os.path.join(upload_folder, filename)
        try:
            if os.path.isfile(file_path) or os.path.islink(file_path):
                os.unlink(file_path)
            elif os.path.isdir(file_path):
                shutil.rmtree(file_path)
        except Exception as e:
            print(f'Unable to remove {file_path}: {e}')


def run_presentation():
    upload_folder = app.config['UPLOAD_FOLDER']
    for filename in os.listdir(upload_folder):
        if filename.lower().endswith(('.ppt', '.pptx')):
            file_path = os.path.join(upload_folder, filename)
            subprocess.call(['pkill', '-f', 'libreoffice'])
            subprocess.Popen(['libreoffice', '--show', file_path])
            break


def is_libreoffice_running():
    try:
        subprocess.check_output(['pgrep', '-f', 'libreoffice'])
        return True
    except subprocess.CalledProcessError:
        return False


def log_crash():
    now = datetime.now()
    current_time = now.strftime("%H:%M:%S")
    print(f"Presentation crashed or was closed at: {current_time} Relaunching...")


def crash_protection():
    while True:
        if not is_libreoffice_running():
            log_crash()
            run_presentation()
        time.sleep(5)


# ── Routes: Auth ──────────────────────────────────────────────────────────────
@app.route('/', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))

    error = None
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        user = User.query.filter_by(username=username).first()
        if user and user.check_password(password):
            login_user(user)
            return redirect(url_for('dashboard'))
        error = 'Invalid credentials'
    return render_template('login.html', error=error)


@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))


# ── Routes: Dashboard ─────────────────────────────────────────────────────────
@app.route('/dashboard')
@login_required
def dashboard():
    slideshows = Slideshow.query.order_by(Slideshow.uploaded_at.desc()).all()
    active = Slideshow.query.filter_by(is_active=True).first()
    clients = ClientDevice.query.all()
    return render_template('dashboard.html',
                           slideshows=slideshows,
                           active_slideshow=active,
                           clients=clients,
                           User=User)


# ── Routes: File Upload ───────────────────────────────────────────────────────
@app.route('/upload', methods=['POST'])
@login_required
def upload_file():
    if 'file' not in request.files:
        flash('No file selected', 'error')
        return redirect(url_for('dashboard'))

    file = request.files['file']
    if file.filename == '':
        flash('No file selected', 'error')
        return redirect(url_for('dashboard'))

    if not allowed_file(file.filename):
        flash('Only .ppt and .pptx files are allowed', 'error')
        return redirect(url_for('dashboard'))

    filename = secure_filename(file.filename)
    # Add timestamp to avoid collisions
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    stored_name = f"{ts}_{filename}"

    clear_uploads()
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], stored_name)
    file.save(file_path)

    # Deactivate all previous slideshows
    Slideshow.query.update({Slideshow.is_active: False})

    # Create DB record
    slideshow = Slideshow(
        filename=stored_name,
        original_filename=filename,
        uploaded_by=current_user.id,
        is_active=True
    )
    db.session.add(slideshow)
    db.session.commit()

    # Run locally
    run_presentation()

    # Broadcast to all connected clients via WebSocket
    socketio.emit('new_presentation_available', {
        'filename': stored_name,
        'original_filename': filename,
        'url': url_for('download_presentation', _external=True)
    })

    flash(f'Presentation "{filename}" uploaded and activated!', 'success')
    return redirect(url_for('dashboard'))


# ── Routes: Set Active Presentation ───────────────────────────────────────────
@app.route('/slideshow/<int:sid>/activate', methods=['POST'])
@login_required
def activate_slideshow(sid):
    slideshow = Slideshow.query.get_or_404(sid)
    Slideshow.query.update({Slideshow.is_active: False})
    slideshow.is_active = True
    db.session.commit()

    # Copy active file to upload folder for local display
    clear_uploads()
    src = os.path.join(app.config['UPLOAD_FOLDER'], slideshow.filename)
    if os.path.exists(src):
        shutil.copy2(src, os.path.join(app.config['UPLOAD_FOLDER'], slideshow.filename))
    run_presentation()

    socketio.emit('new_presentation_available', {
        'filename': slideshow.filename,
        'original_filename': slideshow.original_filename,
        'url': url_for('download_presentation', _external=True)
    })

    flash(f'Presentation "{slideshow.original_filename}" is now active.', 'success')
    return redirect(url_for('dashboard'))


# ── Routes: Delete Slideshow ──────────────────────────────────────────────────
@app.route('/slideshow/<int:sid>/delete', methods=['POST'])
@login_required
@admin_required
def delete_slideshow(sid):
    slideshow = Slideshow.query.get_or_404(sid)
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], slideshow.filename)
    if os.path.exists(file_path):
        os.unlink(file_path)
    db.session.delete(slideshow)
    db.session.commit()
    flash(f'Presentation "{slideshow.original_filename}" deleted.', 'success')
    return redirect(url_for('dashboard'))


# ── Routes: Download (for Pi clients) ─────────────────────────────────────────
@app.route('/api/download/presentation')
def download_presentation():
    active = Slideshow.query.filter_by(is_active=True).first()
    if not active:
        abort(404)
    return redirect(url_for('static', filename=f'../uploads/{active.filename}'))


@app.route('/api/presentation/active')
def api_active_presentation():
    active = Slideshow.query.filter_by(is_active=True).first()
    if not active:
        return jsonify({'error': 'No active presentation'}), 404
    return jsonify({
        'filename': active.filename,
        'original_filename': active.original_filename,
        'url': url_for('download_presentation', _external=True),
        'uploaded_at': active.uploaded_at.isoformat()
    })


@app.route('/api/clients')
def api_clients():
    """Return all registered client devices."""
    clients = ClientDevice.query.all()
    return jsonify({
        'clients': [{
            'id': c.id,
            'client_id': c.client_id,
            'name': c.name,
            'ip_address': c.ip_address,
            'mac_address': c.mac_address,
            'is_online': c.is_online,
            'cpu_temp': c.cpu_temp,
            'uptime_seconds': c.uptime_seconds,
            'active_presentation': c.active_presentation,
            'last_seen': c.last_seen.isoformat() if c.last_seen else None,
        } for c in clients]
    })


@app.route('/api/clients/<int:cid>/command', methods=['POST'])
def api_client_command(cid):
    """Send a command to a specific client by database ID."""
    if not current_user.is_authenticated:
        abort(401)
    if not current_user.is_admin():
        abort(403)

    client = ClientDevice.query.get_or_404(cid)
    data = request.get_json(silent=True) or {}
    command = data.get('command')

    if command not in ('reboot', 'reload'):
        return jsonify({'error': 'Invalid command'}), 400

    if not client.socket_id:
        return jsonify({'error': 'Client offline, cannot send command'}), 503

    socketio.emit('command', {'command': command}, room=client.socket_id)
    return jsonify({'status': 'sent', 'command': command, 'client': client.client_id or client.name})


# ── Routes: User Management (Admin only) ──────────────────────────────────────
@app.route('/users')
@login_required
@admin_required
def manage_users():
    users = User.query.all()
    return render_template('users.html', users=users)


@app.route('/users/create', methods=['POST'])
@login_required
@admin_required
def create_user():
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '')
    role = request.form.get('role', 'operator')

    if not username or not password:
        flash('Username and password are required', 'error')
        return redirect(url_for('manage_users'))

    if role not in ('admin', 'operator'):
        role = 'operator'

    if User.query.filter_by(username=username).first():
        flash(f'User "{username}" already exists', 'error')
        return redirect(url_for('manage_users'))

    user = User(username=username, password_hash=generate_password_hash(password), role=role)
    db.session.add(user)
    db.session.commit()
    flash(f'User "{username}" created with role "{role}".', 'success')
    return redirect(url_for('manage_users'))


@app.route('/users/<int:uid>/delete', methods=['POST'])
@login_required
@admin_required
def delete_user(uid):
    if uid == current_user.id:
        flash('You cannot delete your own account', 'error')
        return redirect(url_for('manage_users'))
    user = User.query.get_or_404(uid)
    db.session.delete(user)
    db.session.commit()
    flash(f'User "{user.username}" deleted.', 'success')
    return redirect(url_for('manage_users'))


# ── Routes: Fleet Management (Admin only) ─────────────────────────────────────
@app.route('/fleet')
@login_required
@admin_required
def fleet_management():
    clients = ClientDevice.query.all()
    return render_template('fleet.html', clients=clients)


# ── WebSocket Events ──────────────────────────────────────────────────────────
@socketio.on('connect')
def handle_connect():
    print(f'Client connected: {request.sid}')


@socketio.on('disconnect')
def handle_disconnect():
    # Mark client offline
    client = ClientDevice.query.filter_by(socket_id=request.sid).first()
    if client:
        client.is_online = False
        client.socket_id = None
        db.session.commit()
    print(f'Client disconnected: {request.sid}')


@socketio.on('client_register')
def handle_client_register(data):
    """Pi client registers itself on connection."""
    name = data.get('name', 'Unnamed Device')
    ip = request.remote_addr
    mac = data.get('mac_address', '')
    client_id = data.get('client_id', '').strip()

    # Look up by client_id first, then by MAC
    client = None
    if client_id:
        client = ClientDevice.query.filter_by(client_id=client_id).first()
    if not client and mac:
        client = ClientDevice.query.filter_by(mac_address=mac).first()

    if not client:
        client = ClientDevice(name=name, mac_address=mac)

    # Update fields
    client.name = name
    client.ip_address = ip
    client.socket_id = request.sid
    client.is_online = True
    client.last_seen = datetime.utcnow()
    if client_id:
        client.client_id = client_id
    if mac:
        client.mac_address = mac

    db.session.commit()
    emit('registration_ack', {'status': 'ok', 'client_id': client.id})


@socketio.on('telemetry_update')
def handle_telemetry(data):
    """Receive telemetry from Pi clients."""
    client = ClientDevice.query.filter_by(socket_id=request.sid).first()
    if client:
        client.cpu_temp = data.get('cpu_temp')
        client.uptime_seconds = data.get('uptime')
        client.active_presentation = data.get('active_presentation')
        client.ip_address = data.get('ip_address', client.ip_address)
        client.last_seen = datetime.utcnow()
        client.is_online = True
        db.session.commit()

    # Broadcast to all admin dashboards
    emit('fleet_update', {
        'client_id': client.id if client else None,
        'name': client.name if client else 'Unknown',
        'ip_address': client.ip_address if client else '',
        'is_online': True,
        'cpu_temp': data.get('cpu_temp'),
        'uptime': data.get('uptime'),
        'active_presentation': data.get('active_presentation'),
        'last_seen': datetime.utcnow().isoformat()
    }, broadcast=True)


@socketio.on('execute_command')
def handle_execute_command(data):
    """Admin sends a command to a specific client."""
    if not current_user.is_authenticated or not current_user.is_admin():
        emit('error', {'message': 'Unauthorized'})
        return

    target_sid = data.get('socket_id')
    command = data.get('command')

    if command not in ('reboot', 'reload'):
        emit('error', {'message': 'Invalid command'})
        return

    if target_sid:
        emit('command', {'command': command}, room=target_sid)


# ── Changelog (kept from original) ────────────────────────────────────────────
@app.route('/changelog')
def changelog():
    with open(os.path.join(os.path.dirname(__file__), 'changelog.txt'), 'r') as f:
        content = f.read()
    return render_template('changelog.html', content=content)


# ── App Init ──────────────────────────────────────────────────────────────────
def init_db():
    """Create tables and seed default admin user if none exist."""
    db.create_all()
    if not User.query.filter_by(username='admin').first():
        default_pass = os.environ.get('BULLETIN_ADMIN_PASSWORD', 'changeme')
        admin = User(
            username='admin',
            password_hash=generate_password_hash(default_pass),
            role='admin'
        )
        db.session.add(admin)
        db.session.commit()
        print(f'Default admin user created (admin / {default_pass})')
        if default_pass == 'changeme':
            print('WARNING: Using default password "changeme". Change it immediately or set BULLETIN_ADMIN_PASSWORD env var.')


if __name__ == '__main__':
    os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
    with app.app_context():
        init_db()

    run_presentation()
    check_thread = threading.Thread(target=crash_protection, daemon=True)
    check_thread.start()

    socketio.run(app, host='0.0.0.0', port=5000)
