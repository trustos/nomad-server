NomadServer/cloud_init.sh
#!/bin/bash
#cloud-config

# Set variables
NOMAD_VERSION="1.10.1" # Replace with desired Nomad version
DATA_DIR="/opt/nomad" # Replace if you want a different data directory
LOG_LEVEL="INFO" # The log level to use for log streaming. Defaults to info. Possible values include trace, debug, info, warn, error

# Function to create a nomad user and ensure docker group membership
create_nomad_user() {
  echo "Creating nomad user and ensuring docker group membership..."

  # Create nomad user if it doesn't exist
  if ! id nomad &>/dev/null; then
    useradd -r -s /bin/false nomad
    echo "Nomad user created."
  else
    echo "Nomad user already exists."
  fi

  # Ensure docker group exists
  if ! getent group docker > /dev/null; then
    echo "docker group does not exist. Creating docker group..."
    groupadd docker
  else
    echo "docker group already exists."
  fi

  # Add nomad user to docker group
  usermod -aG docker nomad
  echo "Nomad user added to docker group."

  # Always restart Docker to ensure it uses the correct group
  if systemctl is-active --quiet docker; then
    echo "Restarting Docker to ensure group membership is correct..."
    systemctl restart docker
  fi
}

# Function to install Nomad using the specified version
install_nomad() {
  echo "Installing Nomad version $NOMAD_VERSION..."

  # Install dependencies
  if command -v apt-get &> /dev/null; then
    apt-get update -y && apt-get install -y wget unzip curl
  elif command -v yum &> /dev/null; then
    yum install -y wget unzip curl
  elif command -v dnf &> /dev/null; then
    dnf install -y wget unzip curl
  else
    echo "Unsupported Linux distribution. Please install wget, unzip, and curl manually."
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
  unzip -o "$NOMAD_ZIP"
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
  mkdir -p /etc/nomad.d
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

# Function to wait for Nomad API to be available
wait_for_nomad() {
  echo "Waiting for Nomad API to be available at http://127.0.0.1:4646 ..."
  for i in {1..30}; do
    if curl -s http://127.0.0.1:4646/v1/status/leader >/dev/null; then
      echo "Nomad API is available."
      return 0
    fi
    sleep 2
  done
  echo "Nomad API did not become available in time."
  exit 1
}

# Function to install nomad-ops from source and deploy via Nomad job
install_nomad_ops() {
  echo "Installing nomad-ops from source..."

  # Ensure git is installed
  if ! command -v git &> /dev/null; then
    echo "git not found. Installing git..."
    if command -v apt-get &> /dev/null; then
      apt-get update -y && apt-get install -y git
    elif command -v yum &> /dev/null; then
      yum install -y git
    elif command -v dnf &> /dev/null; then
      dnf install -y git
    else
      echo "Unsupported Linux distribution. Please install git manually."
      exit 1
    fi
  fi

  # Clone nomad-ops repo if not already present
  if [ ! -d "/opt/nomad-ops" ]; then
    git clone https://github.com/nomad-ops/nomad-ops.git /opt/nomad-ops
  fi

  cd /opt/nomad-ops

  # Wait for Nomad to be ready
  wait_for_nomad

  # Ensure Nomad namespace exists
  nomad namespace apply nomad-ops

  # Deploy nomad-ops job
  if [ -f ".deployment/nomad/docker.hcl" ]; then
    nomad job run .deployment/nomad/docker.hcl
    echo "nomad-ops deployment via Nomad job complete."
  else
    echo "Nomad-ops job file .deployment/nomad/docker.hcl not found!"
  fi
}

# Main script execution
echo "Starting Nomad setup..."

# Create nomad user and ensure docker group membership
create_nomad_user

# Install Nomad
install_nomad

# Configure Nomad
configure_nomad

# Always restart Nomad after user/group/docker changes to ensure permissions are correct
if systemctl is-active --quiet nomad; then
  echo "Restarting Nomad agent to ensure group membership and permissions are correct..."
  systemctl restart nomad
fi

# Install nomad-ops
install_nomad_ops

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
KillSignal=SIG
