## 1. Project Overview
The objective of this project is to develop a scalable, client-server digital signage solution using Python and Flask. The system allows authenticated users to upload and manage **.pptx (PowerPoint)** slideshow files via a central server management webpage. Connected clients will automatically download the active slideshow, display it in full-screen kiosk mode, and dynamically update their display whenever a new file is deployed. Additionally, the server provides real-time remote administration capabilities to monitor and manage the fleet of display devices.

## 2. Infrastructure & Environment
* **Server OS:** Ubuntu Server 26.04
* **Client OS:** Raspberry Pi OS
* **Scale:** Designed for an initial rollout of ~4 clients, with architectural support for future expansion.

## 3. Technology Stack
* **Backend Server:** Python, Flask (Web framework)
* **Authentication:** Flask-Login / Flask-Principal (Role-Based Access Control)
* **Client Script:** Python (Display daemon, background listener, and telemetry reporter)
* **Display Engine:** A `.pptx` capable kiosk viewer for Raspberry Pi (e.g., LibreOffice Impress launched via command line in presentation mode).
* **Communication:** HTTP/REST (file transfers) and WebSockets (real-time push notifications, remote commands, and telemetry tracking).

## 4. Architecture & Components

### 4.1. Server Module (Ubuntu Server)
* **Role-Based Admin Dashboard:** A web interface requiring authentication. 
    * **Administrator Level:** Can manage users, adjust server settings, upload/manage slideshows, and access **Remote Client Administration** (reboot devices, force presentation reloads, view fleet telemetry).
    * **Operator Level:** Restricted to uploading/activating slideshows and viewing basic client online/offline status.
* **File Management System:** Secure storage and validation for uploaded `.pptx` files.
* **Broadcast & Command Engine:** WebSocket server to push update events to all clients and route specific administrative commands (e.g., "reboot") to targeted devices.

### 4.2. Client Module (Raspberry Pi OS)
* **Kiosk Display Engine:** An automated viewer script that forces the `.pptx` file to open in full-screen presentation mode without desktop UI elements.
* **Sync & Command Daemon:** A background Python service that maintains a connection to the server.
    * **Telemetry Reporter:** Periodically sends network info (IP address, MAC, Wi-Fi/LAN status) and device health (uptime, CPU temp, active presentation status) to the server.
    * **Command Listener:** Executes remote administrative commands (e.g., safely executing `sudo reboot` or terminating/relaunching the Impress presentation process).
* **Update Protocol:** Upon receiving an update notification, the daemon downloads the new `.pptx` file to a local cache, gracefully terminates the current presentation process, and launches the new file seamlessly.

## 5. Core Workflows
1. **Authentication:** User logs into the Flask server. UI restricts capabilities based on Admin vs. Operator roles.
2. **Upload & Sync:** User uploads a new `.pptx`. Server saves it and broadcasts a "new file" signal. Clients download and restart the presentation loop.
3. **Remote Administration:** An Admin selects a specific Pi from the dashboard and clicks "Restart Device" or "Reload Presentation". The server sends a targeted WebSocket command to that specific client, which then intercepts it and executes the requested system-level action.
4. **Telemetry Gathering:** Every minute, clients push a JSON payload with their network details and health status to the server, updating the Admin Dashboard's live fleet view.

## 6. Development Milestones
* [ ] **Phase 1: Environment & Auth.** Set up Ubuntu Server Flask environment, implement Admin/Operator login system.
* [ ] **Phase 2: File Handling & UI.** Create the dashboard for uploading and managing `.pptx` files.
* [ ] **Phase 3: Pi Client Base.** Develop the Raspberry Pi OS script to download a `.pptx` and successfully launch it in unattended kiosk mode.
* [ ] **Phase 4: Fleet Synchronization.** Implement WebSockets to instantly trigger `.pptx` updates across all 4+ clients either simultaneously or individually.
* [ ] **Phase 5: Remote Administration & Telemetry.** Implement device health reporting (network info, uptime) and remote command execution (reboot, reload) from the Admin dashboard over WebSockets.
* [ ] **Phase 6: Deployment & Hardening.** Auto-start on boot for the Pi clients, error handling for network drops, sudoer configuration for Pi reboots without password prompts, and final security checks on the server.
