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

    task "zerotier-nat-forward" {
      driver = "raw_exec"
      lifecycle {
        hook = "poststart"
      }
      config {
        command = "bash"
        args = [
          "-c",
          <<EOT
set -e

# --- Wait for ZeroTier interface and IP (may require manual approval) ---
while true; do
  ZT_IFACE=$(ip -o -4 addr show | awk '$2 ~ /^zt/ {print $2; exit}')
  ZT_IP=$(ip -o -4 addr show | awk '$2 ~ /^zt/ {print $4; exit}' | cut -d/ -f1)
  if [ -n "$ZT_IFACE" ] && [ -n "$ZT_IP" ]; then
    break
  fi
  echo "Waiting for ZeroTier interface and IP (this may require manual approval in the ZeroTier admin console)..."
  sleep 10
done

# --- Wait for Traefik container and get its bridge IP ---
for i in {1..30}; do
  TRAEFIK_CONTAINER_ID=$(docker ps | awk '$2 == "traefik:v3.4.3" {print $1}')
  if [ -n "$TRAEFIK_CONTAINER_ID" ]; then
    TRAEFIK_DOCKER_IP=$(docker inspect "$TRAEFIK_CONTAINER_ID" | jq -r '.[].NetworkSettings.Networks.bridge.IPAddress')
    if [ -n "$TRAEFIK_DOCKER_IP" ] && [ "$TRAEFIK_DOCKER_IP" != "null" ]; then
      break
    fi
  fi
  echo "Waiting for Traefik container and bridge IP..."
  sleep 2
done
if [ -z "$TRAEFIK_DOCKER_IP" ] || [ "$TRAEFIK_DOCKER_IP" = "null" ]; then
  echo "Could not determine Traefik container IP!"
  exit 1
fi

# --- Enable IP forwarding ---
sudo sysctl -w net.ipv4.ip_forward=1
sudo grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# --- Clean up old rules ---
sudo iptables -t nat -D PREROUTING -i $ZT_IFACE -p tcp --dport 80 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:80 2>/dev/null || true
sudo iptables -t nat -D PREROUTING -i $ZT_IFACE -p tcp --dport 443 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:443 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 172.17.0.0/16 -o $ZT_IFACE -j MASQUERADE 2>/dev/null || true

# --- Add NAT rules ---
sudo iptables -t nat -A PREROUTING -i $ZT_IFACE -p tcp --dport 80 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:80
sudo iptables -t nat -A PREROUTING -i $ZT_IFACE -p tcp --dport 443 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:443
sudo iptables -t nat -A POSTROUTING -s 172.17.0.0/16 -o $ZT_IFACE -j MASQUERADE

echo "Forwarding ZeroTier ($ZT_IFACE/$ZT_IP) ports 80/443 to Traefik at $TRAEFIK_DOCKER_IP"

# --- Keep task alive ---
while true; do sleep 3600; done
EOT
        ]
      }
      resources {
        cpu    = 20
        memory = 32
      }
    }
  }
}
