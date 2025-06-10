# nomad-server

## Overview

This repository provides scripts to automate the installation and uninstallation of a HashiCorp Nomad server on a Linux system.

---

## cloud_init.sh

This script automates the installation and configuration of Nomad as a systemd service. It is suitable for use as a cloud-init script or for manual execution on any modern Linux distribution that uses systemd.

**What it does:**
- Detects your Linux distribution and architecture.
- Installs required dependencies (`wget`, `unzip`).
- Downloads the specified version of Nomad directly from HashiCorp releases, matching your system architecture.
- Creates a dedicated `nomad` user.
- Sets up the Nomad data directory (`/opt/nomad`) and configuration directory (`/etc/nomad.d`).
- Writes a minimal Nomad configuration file.
- Installs a systemd service unit for Nomad at `/etc/systemd/system/nomad.service`.
- Reloads systemd, enables, and starts the Nomad service.

**How to use:**
1. Make the script executable:  
   `chmod +x cloud_init.sh`
2. Run as root (or with sudo):  
   `sudo ./cloud_init.sh`

---

## uninstall_nomad.sh

This script completely removes Nomad and all related files and users/groups created by the install script.

**What it does:**
- Stops and disables the Nomad systemd service.
- Removes all Nomad binaries found in your PATH (including `/usr/local/bin/nomad`).
- Deletes the Nomad configuration directory (`/etc/nomad.d`) and data directory (`/opt/nomad`).
- Removes the systemd service file (`/etc/systemd/system/nomad.service`).
- Reloads the systemd daemon.
- Removes the `nomad` user and group (in the correct order to avoid errors).

**How to use:**
1. Make the script executable:  
   `chmod +x uninstall_nomad.sh`
2. Run as root (or with sudo):  
   `sudo ./uninstall_nomad.sh`

---

## Notes

- Both scripts must be run as root or with sudo to function correctly.
- The install script is designed for systemd-based Linux distributions.
- The uninstall script is robust and will not error if some components are already missing.

