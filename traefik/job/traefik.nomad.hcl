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
#!/usr/bin/env bash

log() {
  local level="$1"
  local source="$2"
  local msg="$3"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo -e "$timestamp $level $source > $msg}"
}
log_dbg() { log "DBG" "acme-challenge-watcher.sh:$LINENO[0]" "$1"; }
log_inf() { log "INF" "acme-challenge-watcher.sh:$LINENO[0]" "$1"; }
log_err() { log "ERR" "acme-challenge-watcher.sh:$LINENO[0]" "$1"; }

LOG_FILE="${NOMAD_ALLOC_DIR}/logs/.traefik.stdout.fifo"
DYNAMIC_CONFIG_DIR="/mnt/glusterfs/traefik/dynamic"
ACME_FILES="/mnt/glusterfs/traefik/acme-stag.json /mnt/glusterfs/traefik/acme-prod.json"
INSTANCE_IP=$(hostname -I | awk '{print $1}')

mkdir -p "$DYNAMIC_CONFIG_DIR"

# Improved inotifywait parsing and debounce
(
  inotifywait -m -e close_write $ACME_FILES | while read -r line; do
    filename=$(echo "$line" | awk '{print $NF}')
    log_dbg "Detected change in $filename (raw: $line)"
    # No restart logic needed; Traefik reloads configs automatically
    # Touch a flag file to signal main loop
    touch "$DYNAMIC_CONFIG_DIR/.acme_changed"
  done
) &

(
  while true; do
    find "$DYNAMIC_CONFIG_DIR" -name 'acme-challenge-*.yaml' -mmin +1 -exec rm -f {} \;
    sleep 60
  done
) &

while true; do
  # Wait for either a log FIFO or an ACME file change signal
  if [ -p "$LOG_FILE" ]; then
    cat "$LOG_FILE" | while read -r line; do
      echo "$line" | grep -o '\[[a-zA-Z0-9.-]\+\.[a-zA-Z]\+\]' | sed 's/^\[\(.*\)\]$/\1/' | while read -r DOMAIN; do
        [ -z "$DOMAIN" ] && continue
        SAFE_DOMAIN=$(echo "$DOMAIN" | tr '.' '-')
        CONFIG_FILE="$DYNAMIC_CONFIG_DIR/acme-challenge-$SAFE_DOMAIN.yaml"
        tmpfile=$(mktemp)
        cat > "$tmpfile" <<YAML
http:
  routers:
    acme-challenge-$SAFE_DOMAIN:
      rule: "Host(\`$DOMAIN\`) && PathPrefix(\`/.well-known/acme-challenge/\`)"
      service: acme-challenge-service-$SAFE_DOMAIN
      entryPoints:
        - web
      priority: 1000

  services:
    acme-challenge-service-$SAFE_DOMAIN:
      loadBalancer:
        servers:
          - url: "http://$INSTANCE_IP:80"
YAML
        if ! cmp -s "$tmpfile" "$CONFIG_FILE"; then
          mv "$tmpfile" "$CONFIG_FILE"
          log_dbg "Updated domain-based ACME challenge route config_file=\"$CONFIG_FILE\" domain=\"$DOMAIN\" ip=\"$INSTANCE_IP\""
        else
          rm "$tmpfile"
          log_dbg "No change for config_file=\"$CONFIG_FILE\" domain=\"$DOMAIN\""
        fi
      done
    done
  elif [ -f "$DYNAMIC_CONFIG_DIR/.acme_changed" ]; then
    # ACME file changed, but no log lines to process, just sleep briefly
    sleep 1
    rm -f "$DYNAMIC_CONFIG_DIR/.acme_changed"
  else
    log_dbg "FIFO $LOG_FILE not found, waiting..."
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
