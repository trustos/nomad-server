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

install_docker() {
    # Uninstall old versions
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y $pkg || true
    done

    # Add Docker's official GPG key:
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update

    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Function to configure Nomad (minimal config)
configure_nomad() {
  echo "Configuring Nomad..."

  # Create data directory
  mkdir -p "$DATA_DIR"
  mkdir -p "$DATA_DIR/alloc"
  chown nomad:nomad "$DATA_DIR" # Assuming nomad user exists
  chown nomad:nomad "$DATA_DIR/alloc" # Assuming nomad user exists

  # Create minimal Nomad configuration file.  Adjust as needed.
  cat > /etc/nomad.d/nomad.hcl <<EOF
log_level = "$LOG_LEVEL"
data_dir = "$DATA_DIR"

acl {
  enabled    = true
  token_ttl  = "30s"
  policy_ttl = "60s"
  role_ttl   = "60s"
}

server {
  enabled = true
  bootstrap_expect = 1
}

bind_addr = "0.0.0.0"

client {
  enabled = true
}

plugin "docker" {
  config {
    volumes {
      enabled = true
    }
  }
}

EOF

  chown nomad:nomad /etc/nomad.d/nomad.hcl # Assuming nomad user exists
  echo "Nomad configuration complete."
}

# Function to create a nomad user
create_nomad_user() {
  echo "Creating nomad user..."
  useradd -r -s /bin/false nomad

  # Ensure docker group exists
  if ! getent group docker > /dev/null; then
    echo "docker group does not exist. Creating docker group..."
    groupadd docker
    # Restart Docker to ensure it uses the correct group
    if systemctl is-active --quiet docker; then
      systemctl restart docker
    fi
  fi

  # Add nomad user to docker group so it can interact with Docker
  usermod -aG docker nomad
  echo "Nomad user created and added to docker group."
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

# Function to automate Nomad ACL setup for nomad-ops
setup_nomad_acl() {
  echo "Setting up Nomad ACLs and tokens for nomad-ops..."

  # Ensure jq is installed for JSON parsing
  if ! command -v jq &> /dev/null; then
    if command -v apt-get &> /dev/null; then
      apt-get update -y && apt-get install -y jq
    elif command -v yum &> /dev/null; then
      yum install -y jq
    elif command -v dnf &> /dev/null; then
      dnf install -y jq
    else
      echo "Please install jq manually."
      exit 1
    fi
  fi

  # Wait for Nomad to be ready
  wait_for_nomad

  # Bootstrap ACL system if not already done
  if [ ! -f /etc/nomad.d/nomad-bootstrap-token ]; then
    nomad acl bootstrap -json > /etc/nomad.d/nomad-bootstrap-token
  fi

  MGMT_TOKEN=$(jq -r .SecretID /etc/nomad.d/nomad-bootstrap-token)

  # Create the nomad-ops namespace (idempotent)
  NOMAD_TOKEN=$MGMT_TOKEN nomad namespace apply nomad-ops

  # Write the ACL policy definition to a non-config directory
  mkdir -p /opt/nomad/policies
  cat > /opt/nomad/policies/nomad-ops-policy.hcl <<EOF
namespace "nomad-ops" {
  policy = "write"
}
node {
  policy = "read"
}
EOF

  # Apply the policy (idempotent)
  NOMAD_TOKEN=$MGMT_TOKEN nomad acl policy apply nomad-ops-policy /opt/nomad/policies/nomad-ops-policy.hcl

  # Create a token for nomad-ops (idempotent: check if already created)
  if [ ! -f /etc/nomad.d/nomad-ops-token ]; then
    NOMAD_TOKEN=$MGMT_TOKEN nomad acl token create -name="nomad-ops" -policy="nomad-ops-policy" -json > /etc/nomad.d/nomad-ops-token
  fi
  NOMAD_OPS_TOKEN=$(jq -r .SecretID /etc/nomad.d/nomad-ops-token)

  # Write the token to the expected location for the job
  echo "$NOMAD_OPS_TOKEN" > /etc/nomad.d/nomad_token
  chmod 600 /etc/nomad.d/nomad_token
  chown nomad:nomad /etc/nomad.d/nomad_token

  echo "Nomad ACL setup for nomad-ops complete."
}

# Function to install nomad-ops from source and deploy via Nomad job
install_nomad_ops() {
  echo "Installing nomad-ops from source..."

  # Ensure git is installed before proceeding
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

  # Deploy nomad-ops job
  NOMAD_TOKEN=$(cat /etc/nomad.d/nomad_token)
  NOMAD_TOKEN=$NOMAD_TOKEN nomad job run .deployment/nomad/docker.hcl

  echo "nomad-ops deployment via Nomad job complete."
}

# Setting up Docker if not already installed
if ! command -v docker &> /dev/null; then
  echo "Docker not found. Installing Docker..."
  install_docker
else
  echo "Docker is already installed."
fi

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

# Always restart Nomad after user/group/docker changes to ensure permissions are correct
if systemctl is-active --quiet nomad; then
 systemctl restart nomad
fi

# Always write the Nomad systemd service file and enable/start Nomad

if pidof systemd &>/dev/null && [ -d /run/systemd/system ]; then
  echo "systemd detected. Proceeding with service setup..."

  echo "Writing Nomad systemd service file to /etc/systemd/system/nomad.service..."
  cat > /etc/systemd/system/nomad.service <<EOF
[Unit]
Description=Nomad
Documentation=https://nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable nomad
  systemctl restart nomad

  echo "Nomad setup complete."
fi

# Setup Nomad ACLs and tokens for nomad-ops
setup_nomad_acl

# Create the nomad-ops-data volume required by the job
if [ -f "/opt/nomad-ops/jobs/nomad-ops/nomad-ops.volume.hcl" ]; then
  NOMAD_TOKEN=$(cat /etc/nomad.d/nomad_token) nomad volume create /opt/nomad-ops/jobs/nomad-ops/nomad-ops.volume.hcl
else
  echo "WARNING: /opt/nomad-ops/jobs/nomad-ops/nomad-ops.volume.hcl not found. Skipping volume creation."
fi

# Install nomad-ops
install_nomad_ops

exit 0
