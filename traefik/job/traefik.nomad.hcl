job "traefik" {
  namespace = "traefik"
  datacenters = ["dc1"]

  group "traefik" {
    count = 2

    constraint {
      distinct_hosts = true
    }

    task "init-traefik-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "mkdir"
        args    = ["-p", "/mnt/glusterfs/traefik"]
      }
      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "init-traefik-acme-files" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = ["-c", "touch /mnt/glusterfs/traefik/acme-stag.json /mnt/glusterfs/traefik/acme-prod.json  && chmod 600 /mnt/glusterfs/traefik/acme-*.json"]
      }
      resources {
        cpu = 10
        memory = 10
      }
    }

    # Sidecar task: watches Traefik logs and generates dynamic ACME challenge routes
    task "acme-challenge-watcher" {
      driver = "raw_exec"
      env {
        MGMT_TOKEN = "${MGMT_TOKEN}"
      }
      config {
        command = "bash"
        args = [
          "-c",
          <<EOF
LOG_FILE="${NOMAD_ALLOC_DIR}/logs/.traefik.stdout.fifo"
DYNAMIC_CONFIG_DIR="/mnt/glusterfs/traefik/dynamic"
CONFIG_FILE="$DYNAMIC_CONFIG_DIR/acme-challenge.yaml"
ACME_FILES="/mnt/glusterfs/traefik/acme-stag.json /mnt/glusterfs/traefik/acme-prod.json"
INSTANCE_IP=$(hostname -I | awk '{print $1}')
NOMAD_ALLOC_ID="${NOMAD_ALLOC_ID}"
MGMT_TOKEN="${MGMT_TOKEN}"

mkdir -p "$DYNAMIC_CONFIG_DIR"

# Function to extract IP from acme-challenge.yaml
get_config_ip() {
  grep 'url:' "$CONFIG_FILE" | awk -F'//' '{print $2}' | awk -F':' '{print $1}'
}

# Start ACME file watcher in background
(
  inotifywait -m -e close_write $ACME_FILES | while read path action file; do
    echo "Detected change in $file"
    CONFIG_IP=$(get_config_ip)
    echo "Config IP: $CONFIG_IP, Instance IP: $INSTANCE_IP"
    if [[ "$CONFIG_IP" != "$INSTANCE_IP" ]]; then
      echo "Config IP does not match instance IP. Restarting allocation $NOMAD_ALLOC_ID..."
      NOMAD_TOKEN="$MGMT_TOKEN" nomad alloc restart --namespace=traefik --task=traefik "$NOMAD_ALLOC_ID"
    else
      echo "Config IP matches instance IP. No restart needed."
    fi
  done
) &

# Start cleanup loop in background to delete challenge routes older than 10 minutes
(
  while true; do
    find "$DYNAMIC_CONFIG_DIR" -name 'acme-challenge-*.yaml' -mmin +10 -exec rm -f {} \;
    sleep 60
  done
) &

while true; do
  if [ -p "$LOG_FILE" ]; then
    cat "$LOG_FILE" | while read line; do
      echo "LOG: $line" # Debug: print every line
      if [[ "$line" =~ Retrieving\ the\ ACME\ challenge ]]; then
        echo "MATCHED: $line" # Debug: print matched line
        # Extract token and domain from the log line
        TOKEN=$(echo "$line" | grep -o 'token "[^"]*"' | awk -F'"' '{print $2}')
        DOMAIN=$(echo "$line" | grep -o 'for [^ ]*' | awk '{print $2}')
        CONFIG_FILE="$DYNAMIC_CONFIG_DIR/acme-challenge-${TOKEN}.yaml"
        cat > "$CONFIG_FILE" <<YAML
http:
  routers:
    acme-challenge-${TOKEN}:
      rule: "PathPrefix(\`/.well-known/acme-challenge/${TOKEN}\`)"
      service: acme-challenge-service-${TOKEN}
      entryPoints:
        - web
      priority: 1000

  services:
    acme-challenge-service-${TOKEN}:
      loadBalancer:
        servers:
          - url: "http://$INSTANCE_IP:80"
YAML
        echo "Created dynamic route for ACME challenge: $CONFIG_FILE (domain: $DOMAIN, token: $TOKEN, ip: $INSTANCE_IP)"
      fi
    done
  else
    echo "FIFO $LOG_FILE not found, waiting..."
    sleep 2
  fi
done
EOF
        ]
      }
      resources {
        cpu = 10
        memory = 32
      }
    }

    network {
      port "http" {
        static = 80
      }
      port "https" {
        static = 443
      }
    }

    task "traefik" {
      driver = "docker"

      env {
        TRAEFIK_TOKEN = "${TRAEFIK_TOKEN}"
        NLB_IP = "${NLB_IP}"
      }

      template {
        data = <<EOF
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

log:
  level: DEBUG

api:
  dashboard: true
  insecure: false

providers:
  providersThrottleDuration: 1s
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
  nomad:
      endpoint:
        address: "http://${NLB_IP}:4646"
        token: "${TRAEFIK_TOKEN}"
      watch: true
      namespaces:
        - "nomad-ops"
        - "default"

certificatesResolvers:
  cert-prod:
    acme:
      email: trustos@gmail.com
      storage: /etc/traefik/acme-prod.json
      httpChallenge:
        entryPoint: web
  cert-stag:
    acme:
      email: trustos@gmail.com
      storage: /etc/traefik/acme-stag.json
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      httpChallenge:
        entryPoint: web
EOF
        destination = "local/traefik.yaml"
        change_mode = "restart"
      }

      config {
        image = "traefik:v3.4.3"
        ports = ["http", "https"]
        mounts = [
          {
            type        = "bind"
            source      = "local/traefik.yaml"
            target      = "/etc/traefik/traefik.yaml"
            readonly    = true
          },
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik/acme-stag.json"
            target      = "/etc/traefik/acme-stag.json"
            readonly    = false
          },
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik/acme-prod.json"
            target      = "/etc/traefik/acme-prod.json"
            readonly    = false
          },
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik/dynamic"
            target      = "/etc/traefik/dynamic"
            readonly    = false
          }
        ]
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }
  }
}
