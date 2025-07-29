job "zerotier" {
  datacenters = ["dc1"]

  group "zt" {
    count = 1

    task "zerotier" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args = ["-c", <<EOT
set -e

# Clean up /tmp in case previous runs left files
sudo rm -f /tmp/zt-gpg-key /tmp/zt-sources-list

# 1. Install ZeroTier if not present
if ! command -v zerotier-one >/dev/null 2>&1; then
  echo "Installing ZeroTier..."
  curl -s https://install.zerotier.com | sudo bash
fi

# 2. Join the network (replace with your actual network ID)
NETWORK_ID="35c192ce9b9bd219"
if command -v zerotier-cli >/dev/null 2>&1; then
  if ! sudo zerotier-cli listnetworks | grep -q "$NETWORK_ID"; then
    echo "Joining ZeroTier network $NETWORK_ID"
    sudo zerotier-cli join "$NETWORK_ID"
  fi
else
  echo "zerotier-cli not found, install may have failed."
  exit 1
fi

# 3. Keep the task alive (optional, or just let it exit)
sleep infinity
EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 512
      }

      restart {
        attempts = 3
        interval = "30s"
        delay    = "15s"
        mode     = "fail"
      }
    }
  }
}
