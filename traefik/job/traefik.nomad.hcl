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

    network {
      port "http" {
        static = 80
      }
      port "https" {
        static = 443
      }
    }

    # Sidecar task: logs ACME challenge starts to shared file
    task "acme-challenge-log-watcher" {
      driver = "raw_exec"
      config {
        command = "bash"
        args = [
          "-c",
          <<EOF
#!/usr/bin/env bash

LOG_FILE="${NOMAD_ALLOC_DIR}/logs/.traefik.stdout.fifo"
ACME_START_LOG="/mnt/glusterfs/traefik/acme-start.log"
DEBUG_LOG="/mnt/glusterfs/traefik/acme-debug.log"
INSTANCE_IP=$(hostname -I | awk '{print $1}')

touch "$ACME_START_LOG"
touch "$DEBUG_LOG"

while true; do
  # Wait for the FIFO to exist and be a pipe
  if [ ! -p "$LOG_FILE" ]; then
    echo "DEBUG: $LOG_FILE not found or not a pipe, sleeping..." >> "$DEBUG_LOG"
    sleep 2
    continue
  fi

  # Use cat to read from the FIFO, so the loop restarts if the writer disconnects
  cat "$LOG_FILE" | while read -r line; do
    echo "DEBUG: $line" >> "$DEBUG_LOG"
    DOMAIN=$(echo "$line" | grep -oP 'Trying to challenge certificate for domain \[\K[a-zA-Z0-9.-]+(?=\])')
    if [ -n "$DOMAIN" ]; then
      echo "MATCHED: $DOMAIN" >> "$DEBUG_LOG"
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      (
        flock -x 200
        echo "$TIMESTAMP domain=$DOMAIN ip=$INSTANCE_IP" >> "$ACME_START_LOG"
      ) 200>>"$ACME_START_LOG.lock"
    fi
  done

  # If cat exits (e.g., FIFO writer disconnects), loop and retry
  echo "DEBUG: cat exited, retrying..." >> "$DEBUG_LOG"
  sleep 1
done
EOF
        ]
      }

      resources {
        cpu = 10
        memory = 64
      }
    }

    # Sidecar task: watches acme-start.log and creates dynamic routes for all requests to matched domain
    task "acme-dynamic-route-watcher" {
      driver = "raw_exec"
      config {
        command = "bash"
        args = [
          "-c",
          <<EOF
#!/usr/bin/env bash

ACME_START_LOG="/mnt/glusterfs/traefik/acme-start.log"
DYNAMIC_CONFIG_DIR="/mnt/glusterfs/traefik/dynamic"
DEBUG_ROUTE_LOG="/mnt/glusterfs/traefik/acme-route-debug.log"

touch "$DEBUG_ROUTE_LOG"

# Cleanup old dynamic routes (older than 5 minutes)
(
  while true; do
    find "$DYNAMIC_CONFIG_DIR" -name 'acme-challenge-*.yaml' -mmin +5 -exec rm -f {} \;
    sleep 60
  done
) &

while true; do
  inotifywait -e close_write "$ACME_START_LOG" >/dev/null 2>&1

  # Get the last line (most recent event)
  last_line=$(tail -n 1 "$ACME_START_LOG")
  echo "DEBUG: Detected change, last_line: $last_line" >> "$DEBUG_ROUTE_LOG"

  # Extract domain and ip
  domain=$(echo "$last_line" | grep -oP 'domain=\K[^ ]+')
  ip=$(echo "$last_line" | grep -oP 'ip=\K[^ ]+')

  [ -z "$domain" ] && echo "DEBUG: No domain found, skipping" >> "$DEBUG_ROUTE_LOG" && continue
  [ -z "$ip" ] && echo "DEBUG: No IP found, skipping" >> "$DEBUG_ROUTE_LOG" && continue

  safe_domain=$(echo "$domain" | tr '.' '-')
  config_file="$DYNAMIC_CONFIG_DIR/acme-challenge-$safe_domain.yaml"

  # Throttle: Only allow update if 5s have passed since last update of the YAML file
  if [ -f "$config_file" ]; then
    last_mod=$(stat -c %Y "$config_file")
    now=$(date +%s)
    if [ $((now - last_mod)) -lt 5 ]; then
      echo "DEBUG: Throttling update for $domain, only $((now - last_mod))s since last update" >> "$DEBUG_ROUTE_LOG"
      continue
    fi
  fi

  # Check if the config file exists and if the IP matches
  current_ip=""
  if [ -f "$config_file" ]; then
    current_ip=$(grep -m1 'url:' "$config_file" | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
  fi

  if [ "$ip" = "$current_ip" ]; then
    echo "DEBUG: IP unchanged for $domain ($ip), skipping update" >> "$DEBUG_ROUTE_LOG"
    continue
  fi

  # Write the dynamic route config (routes only ACME challenge path for the domain) atomically
  tmpfile=$(mktemp)
  cat > "$tmpfile" <<YAML
http:
  routers:
    acme-challenge-$safe_domain:
      rule: "Host(\`$domain\`) && PathPrefix(\`/.well-known/acme-challenge/\`)"
      service: acme-challenge-service-$safe_domain
      entryPoints:
        - web
        - websecure
      priority: 1000

  services:
    acme-challenge-service-$safe_domain:
      loadBalancer:
        servers:
          - url: "http://$ip:80"
YAML
  mv "$tmpfile" "$config_file"

  echo "DEBUG: Updated dynamic route for $domain to $ip" >> "$DEBUG_ROUTE_LOG"
done
EOF
        ]
      }
      resources {
        cpu = 10
        memory = 32
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
    allowACMEByPass: true
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
        cpu    = 384
        memory = 512
      }
    }
  }
}
