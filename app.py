import os
import subprocess
import shutil
import time
import threading
import secrets
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, abort, send_from_directory
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
from flask_sqlalchemy import SQLAlchemy
from flask_socketio import SocketIO, emit
from flask_wtf.csrf import CSRFProtect
from wtforms import StringField, PasswordField, SelectField, FileField
from wtforms.validators import DataRequired, Length
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
from datetime import datetime, timedelta

# ── App Configuration ────────────────────────────────────────────────────────
app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('BULLETIN_SECRET_KEY', secrets.token_hex(32))
app.config['UPLOAD_FOLDER'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uploads')
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('BULLETIN_DATABASE_URI', 'sqlite:///bulletin.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024  # 100 MB max upload

# Session security
app.config['PERMANENT_SESSION_LIFETIME'] = 28800  # 8 hours
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
# Set SESSION_COOKIE_SECURE=True in production behind HTTPS

ALLOWED_EXTENSIONS = {'pptx', 'ppt'}


def broadcast_to_clients(event_name, data):
    """Emit a WebSocket event only to registered Pi client SIDs,
    not to dashboard browsers or unauthenticated connections."""
    for sid in PI_CLIENT_SIDS:
        socketio.emit(event_name, data, room=sid)

# ── Extensions ────────────────────────────────────────────────────────────────
db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'
login_manager.remember_cookie_duration = timedelta(days=30)
socketio = SocketIO(app, async_mode='eventlet', cors_allowed_origins='*')

# CSRF protection for all HTML form POSTs
# API routes (/api/*) are exempt -- they use API key auth instead
csrf = CSRFProtect(app)


# ── Database Models ───────────────────────────────────────────────────────────
# Many-to-many: which clients a slideshow is assigned to
slideshow_clients = db.Table('slideshow_clients',
    db.Column('slideshow_id', db.Integer, db.ForeignKey('slideshow.id'), primary_key=True),
    db.Column('clientdevice_id', db.Integer, db.ForeignKey('client_device.id'), primary_key=True)
)


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
    target_clients = db.relationship('ClientDevice', secondary=slideshow_clients,
                                     backref=db.backref('assigned_slideshows', lazy='dynamic'),
                                     lazy='dynamic')


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
    api_key = db.Column(db.String(64), unique=True, nullable=True)  # Auth key for WebSocket registration
    registered_at = db.Column(db.DateTime)  # When the client first registered


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
    os.makedirs(upload_folder, exist_ok=True)
    for filename in os.listdir(upload_folder):
        if filename.lower().endswith(('.ppt', '.pptx')):
            file_path = os.path.join(upload_folder, filename)
            try:
                subprocess.call(['pkill', '-f', 'libreoffice'])
                subprocess.Popen(['libreoffice', '--show', file_path])
            except FileNotFoundError:
                # LibreOffice not installed — server-only, Pi clients handle display
                pass
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
@csrf.exempt
@app.route('/', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))

    error = None
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        remember = request.form.get('remember') is not None
        user = User.query.filter_by(username=username).first()
        if user and user.check_password(password):
            login_user(user, remember=remember)
            next_page = request.args.get('next')
            return redirect(next_page or url_for('dashboard'))
        error = 'Invalid credentials'
    return render_template('login.html', error=error)


@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))


# ── Error Handlers ──────────────────────────────────────────────────────────
@app.errorhandler(403)
def forbidden(e):
    return render_template('error.html', code=403,
                           message='You do not have permission to access this page. '
                                   'Operators can only upload presentations — contact an '
                                   'administrator for additional access.'), 403


@app.errorhandler(404)
def not_found(e):
    return render_template('error.html', code=404,
                           message='The requested page was not found.'), 404


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

    # Do NOT clear_uploads() here -- old files are still referenced by
    # Slideshow DB records. Individual files are deleted only via the
    # delete_slideshow route.
    os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
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

    # Assign selected target clients (checkboxes: target_clients = list of client IDs)
    selected_client_ids = request.form.getlist('target_clients')
    if selected_client_ids:
        for cid in selected_client_ids:
            client = ClientDevice.query.get(int(cid))
            if client:
                slideshow.target_clients.append(client)
    else:
        # No selection = broadcast to all clients
        all_clients = ClientDevice.query.all()
        for client in all_clients:
            slideshow.target_clients.append(client)

    db.session.commit()

    # Run locally
    run_presentation()

    # Broadcast ONLY to the assigned Pi clients
    assigned_sids = {c.socket_id for c in slideshow.target_clients.all() if c.socket_id and c.socket_id in PI_CLIENT_SIDS}
    if assigned_sids:
        for sid in assigned_sids:
            socketio.emit('new_presentation_available', {
                'filename': stored_name,
                'original_filename': filename,
                'url': url_for('download_presentation', _external=True)
            }, room=sid)
    else:
        # Fallback: no assigned clients with active SIDs — broadcast to all known Pis
        # This covers single-client setups and cases where target_clients is empty
        broadcast_to_clients('new_presentation_available', {
            'filename': stored_name,
            'original_filename': filename,
            'url': url_for('download_presentation', _external=True)
        })

    target_count = slideshow.target_clients.count()
    if selected_client_ids:
        flash(f'Presentation "{filename}" uploaded and sent to {target_count} selected client(s)!', 'success')
    else:
        flash(f'Presentation "{filename}" uploaded and broadcast to all clients!', 'success')
    return redirect(url_for('dashboard'))


# ── Routes: Set Active Presentation ───────────────────────────────────────────
@app.route('/slideshow/<int:sid>/activate', methods=['POST'])
@login_required
@admin_required
def activate_slideshow(sid):
    slideshow = Slideshow.query.get_or_404(sid)
    Slideshow.query.update({Slideshow.is_active: False})
    slideshow.is_active = True

    # Update target clients from form (admin can reassign on activate)
    selected_client_ids = request.form.getlist('target_clients')
    if selected_client_ids:
        slideshow.target_clients = []
        for cid in selected_client_ids:
            client = ClientDevice.query.get(int(cid))
            if client:
                slideshow.target_clients.append(client)

    db.session.commit()

    # Run locally if the file still exists on disk
    src = os.path.join(app.config['UPLOAD_FOLDER'], slideshow.filename)
    if os.path.exists(src):
        clear_uploads()  # Clear old local display file
        shutil.copy2(src, os.path.join(app.config['UPLOAD_FOLDER'], slideshow.filename))
        run_presentation()
    else:
        flash('Warning: file for this presentation is missing from disk.', 'error')

    # Broadcast to assigned clients only
    assigned_sids = {c.socket_id for c in slideshow.target_clients.all() if c.socket_id and c.socket_id in PI_CLIENT_SIDS}
    for ws_sid in assigned_sids:
        socketio.emit('new_presentation_available', {
            'filename': slideshow.filename,
            'original_filename': slideshow.original_filename,
            'url': url_for('download_presentation', _external=True)
        }, room=ws_sid)

    target_count = slideshow.target_clients.count()
    flash(f'Presentation "{slideshow.original_filename}" activated for {target_count} client(s).', 'success')
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
    # Use send_from_directory to prevent path traversal -- it validates the
    # filename stays within UPLOAD_FOLDER and won't follow ../ escapes
    return send_from_directory(app.config['UPLOAD_FOLDER'], active.filename, as_attachment=True)


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


@app.route('/api/register', methods=['POST'])
def api_register():
    """Pre-register a client device and return an API key.

    Security: If a client_id is claimed and the caller does not provide
    the matching api_key, the registration is rejected. This prevents
    an attacker from hijacking a registered device by guessing its client_id.

    POST JSON: {
        "client_id": "library-north",   # optional
        "name": "Library North Display", # optional
        "mac_address": "aa:bb:cc:dd:ee:ff",  # optional
        "api_key": "existing-key-for-re-registration"  # required for re-registration
    }
    """
    data = request.get_json(silent=True) or {}
    client_id = data.get('client_id', '').strip()
    name = data.get('name', 'Unnamed Device')
    mac = data.get('mac_address', '')
    api_key = data.get('api_key', '').strip()

    # Look up existing
    client = None
    if api_key:
        client = ClientDevice.query.filter_by(api_key=api_key).first()
    if not client and client_id:
        client = ClientDevice.query.filter_by(client_id=client_id).first()

    # Security: If we found a client by client_id but NOT by api_key,
    # the caller doesn't own this client_id. Reject.
    if client and not api_key:
        return jsonify({'error': 'client_id is already registered. Provide api_key to re-register.'}), 403

    is_new = False
    if not client:
        client = ClientDevice(name=name, mac_address=mac)
        is_new = True

    client.name = name
    if client_id:
        client.client_id = client_id
    if mac:
        client.mac_address = mac
    if is_new or not client.api_key:
        client.api_key = secrets.token_hex(32)
        client.registered_at = datetime.utcnow()

    if is_new:
        db.session.add(client)

    db.session.commit()

    return jsonify({
        'status': 'ok',
        'client_id': client.id,
        'api_key': client.api_key,
        'is_new': is_new,
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


@app.route('/users/<int:uid>/edit', methods=['POST'])
@login_required
@admin_required
def edit_user(uid):
    """Admin can change another user's password and role."""
    user = User.query.get_or_404(uid)
    if user.id == current_user.id:
        flash('Use the profile page to change your own password.', 'error')
        return redirect(url_for('manage_users'))

    new_password = request.form.get('password', '').strip()
    new_role = request.form.get('role', user.role)

    if new_password:
        user.password_hash = generate_password_hash(new_password)
    if new_role in ('admin', 'operator'):
        user.role = new_role

    db.session.commit()
    flash(f'User "{user.username}" updated.', 'success')
    return redirect(url_for('manage_users'))


# ── Routes: Profile (any logged-in user) ────────────────────────────────────
@app.route('/profile')
@login_required
def profile():
    return render_template('profile.html')


@app.route('/profile/password', methods=['POST'])
@login_required
def change_password():
    current_pw = request.form.get('current_password', '')
    new_pw = request.form.get('new_password', '')
    confirm_pw = request.form.get('confirm_password', '')

    if not current_user.check_password(current_pw):
        flash('Current password is incorrect', 'error')
        return redirect(url_for('profile'))

    if len(new_pw) < 6:
        flash('New password must be at least 6 characters', 'error')
        return redirect(url_for('profile'))

    if new_pw != confirm_pw:
        flash('New passwords do not match', 'error')
        return redirect(url_for('profile'))

    current_user.password_hash = generate_password_hash(new_pw)
    db.session.commit()
    flash('Password changed successfully', 'success')
    return redirect(url_for('profile'))


# ── Routes: Fleet Management (Admin only) ─────────────────────────────────────
@app.route('/fleet')
@login_required
@admin_required
def fleet_management():
    clients = ClientDevice.query.all()
    return render_template('fleet.html', clients=clients)


@app.route('/fleet/<int:cid>/delete', methods=['POST'])
@login_required
@admin_required
def delete_client(cid):
    client = ClientDevice.query.get_or_404(cid)
    # Remove from Pi client SID set if connected
    if client.socket_id:
        PI_CLIENT_SIDS.discard(client.socket_id)
    name = client.client_id or client.name
    # Remove from any slideshow assignments (many-to-many)
    client.assigned_slideshows = []
    db.session.delete(client)
    db.session.commit()
    flash(f'Device "{name}" removed from fleet.', 'success')
    return redirect(url_for('fleet_management'))


# ── WebSocket Events ──────────────────────────────────────────────────────────
# Track which WebSocket SIDs belong to registered Pi clients
# (versus dashboard browsers). This prevents broadcasting presentation
# URLs to unauthenticated connections.
PI_CLIENT_SIDS = set()


@socketio.on('connect')
def handle_connect():
    print(f'WebSocket connected: {request.sid}')


@socketio.on('disconnect')
def handle_disconnect():
    # Remove from Pi client set
    PI_CLIENT_SIDS.discard(request.sid)

    # Mark client offline
    client = ClientDevice.query.filter_by(socket_id=request.sid).first()
    if client:
        client.is_online = False
        client.socket_id = None
        db.session.commit()
    print(f'WebSocket disconnected: {request.sid}')


@socketio.on('client_register')
def handle_client_register(data):
    """Pi client registers itself on connection.

    Expected data: {
        'name': 'Display Name',
        'client_id': 'library-north',  # optional, user-assigned
        'mac_address': 'aa:bb:cc:dd:ee:ff',
        'api_key': 'optional-pre-registered-key'
    }

    If api_key is provided and matches an existing client, that client is
    updated. Otherwise a new client is created and issued a fresh API key.
    """
    name = data.get('name', 'Unnamed Device')
    ip = request.remote_addr
    mac = data.get('mac_address', '')
    client_id = data.get('client_id', '').strip()
    api_key = data.get('api_key', '').strip()

    client = None

    # 1. Look up by API key (pre-registered clients)
    if api_key:
        client = ClientDevice.query.filter_by(api_key=api_key).first()

    # 2. Look up by client_id
    if not client and client_id:
        client = ClientDevice.query.filter_by(client_id=client_id).first()

    # 3. Look up by MAC address
    if not client and mac:
        client = ClientDevice.query.filter_by(mac_address=mac).first()

    # 4. Create new client
    is_new = False
    if not client:
        client = ClientDevice(name=name, mac_address=mac)
        is_new = True

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

    # Generate API key for new clients
    if is_new or not client.api_key:
        client.api_key = secrets.token_hex(32)
        client.registered_at = datetime.utcnow()

    if is_new:
        db.session.add(client)

    db.session.commit()

    # Mark this SID as a known Pi client (not a dashboard browser)
    PI_CLIENT_SIDS.add(request.sid)

    print(f'[REGISTER] client_id={client.client_id or "unregistered"}, '
          f'name={client.name}, ip={ip}, new={is_new}, key={client.api_key[:8]}...')

    emit('registration_ack', {
        'status': 'ok',
        'client_id': client.id,
        'api_key': client.api_key,  # Client stores this for future connections
        'is_new': is_new,
    })


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
    """Admin sends a command to a specific client.

    Requires an admin API token in the payload for authentication.
    Flask-Login sessions are unreliable in WebSocket context, so we
    validate a server-side admin token instead.
    """
    # Require admin_token for auth (WebSocket doesn't carry Flask sessions reliably)
    admin_token = data.get('admin_token', '')
    # Check against the server's secret key as a shared admin token
    if admin_token != app.config['SECRET_KEY']:
        emit('error', {'message': 'Unauthorized'})
        return

    target_sid = data.get('socket_id')
    command = data.get('command')

    if command not in ('reboot', 'reload'):
        emit('error', {'message': 'Invalid command'})
        return

    if target_sid and target_sid in PI_CLIENT_SIDS:
        emit('command', {'command': command}, room=target_sid)
    else:
        emit('error', {'message': 'Target client not found or not a Pi client'})


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

    # Exempt API routes from CSRF (they use API key auth, not session cookies)
    for rule in app.url_map.iter_rules():
        if rule.rule.startswith('/api/'):
            view_func = app.view_functions.get(rule.endpoint)
            if view_func:
                csrf.exempt(view_func)

    run_presentation()
    check_thread = threading.Thread(target=crash_protection, daemon=True)
    check_thread.start()
    socketio.run(app, host='0.0.0.0', port=5000)


# Also exempt at import time (for test clients, etc.)
for rule in app.url_map.iter_rules():
    if rule.rule.startswith('/api/'):
        view_func = app.view_functions.get(rule.endpoint)
        if view_func:
            csrf.exempt(view_func)
