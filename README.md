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

---

## Makefile: Building and Versioning PocketBase

This repository includes a Makefile for building and publishing PocketBase and Nomad Ops Docker images, as well as for managing dependencies and build environments.

### Building a Specific PocketBase Version

You can specify the PocketBase version you want to build by setting the `PB_VERSION` environment variable:

```sh
PB_VERSION=0.29.0 make pocketbase-all
```

- This command will build and push a Docker image for PocketBase version `0.29.0`.
- The image will be tagged as `ghcr.io/<your_github_username>/pocketbase:0.29.0`.

**Important:**  
If you have a `.env` file in the repository, its `PB_VERSION` value may override the version you set in your shell. To ensure the correct version is built, either update the `.env` file or set the environment variable explicitly in your shell as shown above.

---

### Makefile Commands Reference

#### Dependency & Environment Setup

- `install-deps`: Installs required dependencies (`brew`, `docker`, `colima`, `docker-buildx`).  
  Ensures your system is ready for Docker builds.

- `docker-check`: Verifies Docker daemon is running and dependencies are installed.  
  Prompts to start Colima or another Docker daemon if not running.

- `docker-login`: Logs in to GitHub Container Registry (`ghcr.io`) using your GitHub credentials.  
  Requires `GITHUB_TOKEN` and `GITHUB_USERNAME` environment variables.

- `buildx-init`: Initializes and configures Docker buildx builder for multi-architecture builds.

#### PocketBase Build & Publish

- `pb-docker-build`: Builds and pushes the PocketBase Docker image for the specified version and architectures (`amd64`, `arm64`).  
  Uses the `PB_VERSION` variable for versioning.

- `pocketbase-all`: Runs `buildx-init`, `docker-login`, and `pb-docker-build` in sequence.  
  This is the main target for building and publishing PocketBase images.

#### Nomad Ops Build & Publish

- `nomad-ops-clone`: Clones the Nomad Ops repository into a local build directory.

- `nomad-ops-docker-build`: Builds and pushes the Nomad Ops Docker image for `arm64` architecture.  
  Uses the latest build number by default.

- `nomad-ops-docker-all`: Runs `buildx-init`, `docker-login`, and `nomad-ops-docker-build` in sequence.  
  This is the main target for building and publishing Nomad Ops images.

---

**Summary of Main Targets:**

- `install-deps`: Prepare your system for Docker builds.
- `pocketbase-all`: Build and publish a PocketBase Docker image for a specific version.
- `nomad-ops-docker-all`: Build and publish a Nomad Ops Docker image.

For advanced usage, you can run individual steps as needed. Most users will only need `pocketbase-all` or `nomad-ops-docker-all` for typical workflows.



