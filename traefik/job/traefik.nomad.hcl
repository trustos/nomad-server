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
      config {
        command = "bash"
        args = [
          "-c",
          <<EOF
LOG_FILE="${NOMAD_ALLOC_DIR}/logs/.traefik.stdout.fifo"
DYNAMIC_CONFIG_DIR="/mnt/glusterfs/traefik/dynamic"
INSTANCE_IP=$(hostname -I | awk '{print $1}')

mkdir -p "$DYNAMIC_CONFIG_DIR"

# Start cleanup loop in background to delete challenge routes older than 10 minutes
# No need for per-token cleanup with single route

while true; do
  if [ -p "$LOG_FILE" ]; then
    cat "$LOG_FILE" | while read line; do
      echo "LOG: $line" # Debug: print every line
      if [[ "$line" =~ Retrieving\ the\ ACME\ challenge ]]; then
        echo "MATCHED: $line" # Debug: print matched line
        # Extract token and domain from the log line
        TOKEN=$(echo "$line" | grep -o 'token "[^"]*"' | awk -F'"' '{print $2}')
        DOMAIN=$(echo "$line" | grep -o 'for [^ ]*' | awk '{print $2}')
        CONFIG_FILE="$DYNAMIC_CONFIG_DIR/acme-challenge.yaml"
        cat > "$CONFIG_FILE" <<YAML
http:
  routers:
    acme-challenge:
      rule: "PathPrefix(\`/.well-known/acme-challenge/\`)"
      service: acme-challenge-service
      entryPoints:
        - web
      priority: 1000

  services:
    acme-challenge-service:
      loadBalancer:
        servers:
          - url: "http://$INSTANCE_IP:80"
YAML
        echo "Updated dynamic route for ACME challenge: $CONFIG_FILE (domain: $DOMAIN, token: $TOKEN, ip: $INSTANCE_IP)"
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
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
    providersThrottleDuration: 1s
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
