#!/bin/bash
#cloud-config

# Set variables
NOMAD_VERSION="1.10.1" # Replace with desired Nomad version
DATA_DIR="/opt/nomad" # Replace if you want a different data directory
LOG_LEVEL="INFO" # The log level to use for log streaming. Defaults to info. Possible values include trace, debug, info, warn, error

# Function to install Nomad using the specified version
install_nomad() {
  echo "Installing Nomad version $NOMAD_VERSION..."

  # Install dependencies
  if command -v apt-get &> /dev/null; then
    apt-get update -y && apt-get install -y wget unzip
  elif command -v yum &> /dev/null; then
    yum install -y wget unzip
  elif command -v dnf &> /dev/null; then
    dnf install -y wget unzip
  else
    echo "Unsupported Linux distribution. Please install wget and unzip manually."
    exit 1
  fi

  # Detect OS
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')

  # Detect architecture
  ARCH=$(uname -m)
  case "$ARCH" in
      x86_64)
          ARCH="amd64"
          ;;
      aarch64 | arm64)
          ARCH="arm64"
          ;;
      armv7l | armv6l | arm)
          ARCH="arm"
          ;;
      *)
          echo "Unsupported architecture: $ARCH"
          exit 1
          ;;
  esac

  # Compose the filename and URL
  NOMAD_ZIP="nomad_${NOMAD_VERSION}_${OS}_${ARCH}.zip"
  NOMAD_URL="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/${NOMAD_ZIP}"

  # Download and install Nomad
  cd /tmp
  echo "Downloading $NOMAD_URL"
  wget "$NOMAD_URL"
  unzip "$NOMAD_ZIP"
  mv nomad /usr/local/bin/
  chmod +x /usr/local/bin/nomad

  echo "Nomad $NOMAD_VERSION installation complete."
}

# Function to configure Nomad (minimal config)
configure_nomad() {
  echo "Configuring Nomad..."

  # Create data directory
  mkdir -p "$DATA_DIR"
  chown nomad:nomad "$DATA_DIR" # Assuming nomad user exists

  # Create minimal Nomad configuration file.  Adjust as needed.
  cat > /etc/nomad.d/nomad.hcl <<EOF
log_level = "$LOG_LEVEL"
data_dir = "$DATA_DIR"

server {
  enabled = true
  bootstrap_expect = 1
}

client {
  enabled = true
}

EOF

  chown nomad:nomad /etc/nomad.d/nomad.hcl # Assuming nomad user exists
  echo "Nomad configuration complete."
}

# Function to create a nomad user
create_nomad_user() {
  echo "Creating nomad user..."
  useradd -r -s /bin/false nomad
  echo "Nomad user created."
}

# Main script execution
echo "Starting Nomad setup..."

# Create nomad user
create_nomad_user

# Install Nomad
install_nomad

# Create /etc/nomad.d directory
mkdir -p /etc/nomad.d

# Configure Nomad
configure_nomad

# Check for systemd before proceeding with service setup
if pidof systemd &>/dev/null && [ -d /run/systemd/system ]; then
  echo "systemd detected. Proceeding with service setup..."

  # Write the Nomad systemd service file directly
  echo "Writing Nomad systemd service file to /etc/systemd/system/nomad.service..."
  cat > /etc/systemd/system/nomad.service <<EOF
[Unit]
Description=Nomad
Documentation=https://nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=nomad
Group=nomad
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
EOF

systemctl daemon-reload
systemctl enable nomad
systemctl restart nomad

echo "Nomad setup complete."
exit 0
fi
