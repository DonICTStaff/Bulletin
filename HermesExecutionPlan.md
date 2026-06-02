# Hermes Execution Plan: Flask Kiosk Slideshow System

This document breaks down the high-level project phases into granular, sequential tasks for the Hermes agent to execute.

## Phase 1: Server Environment & Authentication (Ubuntu Server)
**Goal:** Establish the foundation of the Flask app and secure it with Role-Based Access Control (RBAC).
* **Step 1.1:** Initialize the Flask project structure (app routing, static folders, template directories, configuration files).
* **Step 1.2:** Set up the database (SQLite for development, PostgreSQL for production) and integrate SQLAlchemy. Create the `User` model.
* **Step 1.3:** Implement `Flask-Login` for session management and user authentication.
* **Step 1.4:** Implement RBAC. Define `Admin` and `Operator` roles (using custom decorators or a library like `Flask-Principal`).
* **Step 1.5:** Create login, logout, and user creation routes. Build the base HTML template for the protected dashboard.

## Phase 2: File Handling & UI (Ubuntu Server)
**Goal:** Allow users to upload `.pptx` files and manage the active presentation.
* **Step 2.1:** Configure secure file upload parameters in Flask (enforce `.pptx` extension, set `MAX_CONTENT_LENGTH` to handle potentially large presentations).
* **Step 2.2:** Create a `Slideshow` database model to track file metadata (filename, upload date, uploader ID, and active status).
* **Step 2.3:** Implement the file upload route, including saving the file to a secure directory and creating the database record.
* **Step 2.4:** Build the UI for the dashboard:
    * *Operators:* Can see the upload form and current active presentation.
    * *Admins:* Can see the upload form, presentation history, and user management.
* **Step 2.5:** Implement backend logic to set a specific `.pptx` file as the system-wide "Active" presentation.

## Phase 3: Client Base Application (Raspberry Pi OS)
**Goal:** Create a standalone Python script capable of fetching and displaying the presentation.
* **Step 3.1:** Write a Python script (`client_daemon.py`) that performs an HTTP GET request to a server API endpoint to download the active `.pptx` file to a local cache.
* **Step 3.2:** Implement the display logic using the `subprocess` module to launch LibreOffice Impress in kiosk mode (e.g., `libreoffice --show presentation.pptx --norestore --nologo`).
* **Step 3.3:** Implement process management logic to securely identify and terminate (kill) existing LibreOffice presentation processes before launching a newly downloaded file to prevent overlay issues.

## Phase 4: Fleet Synchronization (WebSockets)
**Goal:** Push real-time updates from the server to all connected clients simultaneously.
* **Step 4.1:** Integrate `Flask-SocketIO` into the Ubuntu Server backend.
* **Step 4.2:** Update the "Set Active Presentation" route (from Step 2.5) to emit a `new_presentation_available` WebSocket broadcast event.
* **Step 4.3:** Integrate the `python-socketio` client library into the Raspberry Pi `client_daemon.py`.
* **Step 4.4:** Create an event listener on the Pi client that intercepts the `new_presentation_available` event, triggers the file download function, and restarts the LibreOffice process seamlessly.

## Phase 5: Remote Administration & Telemetry
**Goal:** Add health monitoring and remote command execution to the fleet.
* **Step 5.1:** Add a telemetry loop to the Pi client. Use the `psutil` library and socket modules to gather IP address, MAC address, uptime, CPU temperature, and active LibreOffice status.
* **Step 5.2:** Configure the Pi client to emit a `telemetry_update` WebSocket event every 60 seconds containing the gathered data as a JSON payload.
* **Step 5.3:** Create a Fleet Management view on the server's Admin Dashboard to render incoming telemetry data in a live updating table.
* **Step 5.4:** Add "Reboot Device" and "Reload Presentation" action buttons to each client row in the Admin UI.
* **Step 5.5:** Implement server-side routes to emit targeted WebSocket commands (`execute_command`) using the client's unique WebSocket Session ID (SID).
* **Step 5.6:** Implement the command listener on the Pi client to parse incoming actions and execute the corresponding local system calls (e.g., `os.system('sudo reboot')`).

## Phase 6: Deployment & System Hardening
**Goal:** Make the system resilient, secure, and fully automated at the OS level.
* **Step 6.1:** Write a `systemd` service file (`kiosk-daemon.service`) for the Raspberry Pi to ensure the Python script starts automatically on boot and restarts automatically on failure.
* **Step 6.2:** Configure the Raspberry Pi `sudoers` file (`visudo`) to safely allow the specific user running the daemon to execute `/sbin/reboot` without being prompted for a password.
* **Step 6.3:** Implement robust exception handling in the Pi client, including exponential backoff for WebSocket reconnections during Wi-Fi/network drops.
* **Step 6.4:** Finalize the Ubuntu Server deployment configuration (e.g., setting up Gunicorn with an asynchronous worker class like Eventlet/Gevent to handle WebSockets, placed behind an Nginx reverse proxy).
