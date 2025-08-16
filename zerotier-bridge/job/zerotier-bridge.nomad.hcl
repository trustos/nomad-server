job "zerotier-bridge" {
  namespace = "traefik"
  datacenters = ["dc1"]
  type = "system"

  group "zt-bridge" {

    task "zerotier-nat-forward" {
      driver = "raw_exec"

      user = "root"

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

echo "Found ZeroTier interface: $ZT_IFACE with IP: $ZT_IP"

# --- Wait for Traefik container and get its bridge IP ---
for i in {1..30}; do
  TRAEFIK_CONTAINER_ID=$(docker ps | awk '$2 ~ /^traefik/ {print $1}')
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

echo "Found Traefik container IP: $TRAEFIK_DOCKER_IP"

# --- Ensure IP forwarding is enabled ---
sysctl -w net.ipv4.ip_forward=1

# --- Clean up old rules (if any exist) ---
echo "Cleaning up old iptables rules..."
iptables -t nat -D PREROUTING -i $ZT_IFACE -p tcp --dport 80 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:80 2>/dev/null || true
iptables -t nat -D PREROUTING -i $ZT_IFACE -p tcp --dport 443 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:443 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.17.0.0/16 -o $ZT_IFACE -j MASQUERADE 2>/dev/null || true

# --- Add NAT rules ---
echo "Adding NAT forwarding rules..."
iptables -t nat -A PREROUTING -i $ZT_IFACE -p tcp --dport 80 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:80
iptables -t nat -A PREROUTING -i $ZT_IFACE -p tcp --dport 443 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:443
iptables -t nat -A POSTROUTING -s 172.17.0.0/16 -o $ZT_IFACE -j MASQUERADE

echo "ZeroTier bridge setup complete!"
echo "Forwarding ZeroTier ($ZT_IFACE/$ZT_IP) ports 80/443 to Traefik at $TRAEFIK_DOCKER_IP"

# --- Keep task alive and monitor for changes ---
while true; do
  # Check if Traefik container IP has changed
  NEW_TRAEFIK_CONTAINER_ID=$(docker ps | awk '$2 ~ /^traefik/ {print $1}')
  if [ -n "$NEW_TRAEFIK_CONTAINER_ID" ]; then
    NEW_TRAEFIK_DOCKER_IP=$(docker inspect "$NEW_TRAEFIK_CONTAINER_ID" | jq -r '.[].NetworkSettings.Networks.bridge.IPAddress')
    if [ -n "$NEW_TRAEFIK_DOCKER_IP" ] && [ "$NEW_TRAEFIK_DOCKER_IP" != "null" ] && [ "$NEW_TRAEFIK_DOCKER_IP" != "$TRAEFIK_DOCKER_IP" ]; then
      echo "Traefik IP changed from $TRAEFIK_DOCKER_IP to $NEW_TRAEFIK_DOCKER_IP, updating NAT rules..."

      # Clean up old rules
      iptables -t nat -D PREROUTING -i $ZT_IFACE -p tcp --dport 80 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:80 2>/dev/null || true
      iptables -t nat -D PREROUTING -i $ZT_IFACE -p tcp --dport 443 -j DNAT --to-destination $TRAEFIK_DOCKER_IP:443 2>/dev/null || true

      # Add new rules
      iptables -t nat -A PREROUTING -i $ZT_IFACE -p tcp --dport 80 -j DNAT --to-destination $NEW_TRAEFIK_DOCKER_IP:80
      iptables -t nat -A PREROUTING -i $ZT_IFACE -p tcp --dport 443 -j DNAT --to-destination $NEW_TRAEFIK_DOCKER_IP:443

      TRAEFIK_DOCKER_IP=$NEW_TRAEFIK_DOCKER_IP
      echo "NAT rules updated to new Traefik IP: $TRAEFIK_DOCKER_IP"
    fi
  fi

  sleep 30
done
EOT
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }

      restart {
        attempts = 5
        interval = "1m"
        delay    = "15s"
        mode     = "delay"
      }
    }
  }
}
