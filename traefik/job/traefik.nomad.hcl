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

      # Prestart task: create union dynamic config directory and symlink shared and private configs
      task "init-dynamic-union-dir" {
        driver = "raw_exec"
        lifecycle {
          hook = "prestart"
        }
        config {
          command = "bash"
          args = [
            "-c",
            <<EOF
  set -e
  UNION_DIR="/mnt/glusterfs/traefik/dynamic-union-${NOMAD_ALLOC_INDEX}"
  SHARED_DIR="/mnt/glusterfs/traefik/dynamic"
  PRIVATE_DIR="/mnt/glusterfs/traefik/dynamic-private-${NOMAD_ALLOC_INDEX}"

  mkdir -p "$UNION_DIR"
  mkdir -p "$SHARED_DIR"
  mkdir -p "$PRIVATE_DIR"

  # Symlink shared configs
  if [ ! -e "$UNION_DIR/shared" ]; then
    ln -s "$SHARED_DIR" "$UNION_DIR/shared"
  fi

  # Symlink private configs
  if [ ! -e "$UNION_DIR/private" ]; then
    ln -s "$PRIVATE_DIR" "$UNION_DIR/private"
  fi

  # Optionally, flatten all .yaml files into the union dir root for Traefik to see them directly
  find "$SHARED_DIR" -maxdepth 1 -name '*.yaml' -exec ln -sf {} "$UNION_DIR/" \;
  find "$PRIVATE_DIR" -maxdepth 1 -name '*.yaml' -exec ln -sf {} "$UNION_DIR/" \;
  EOF
          ]
        }
        resources {
          cpu    = 10
          memory = 10
        }
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

    # Prestart task: create private dynamic config directory for this allocation
    task "init-private-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "mkdir"
        args    = ["-p", "/mnt/glusterfs/traefik/dynamic-private-${NOMAD_ALLOC_INDEX}"]
      }
      resources {
        cpu    = 10
        memory = 10
      }
    }

    # Prestart task: create union dynamic config directory and symlink shared and private configs
    task "init-dynamic-union-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = [
          "-c",
          <<EOF
set -e
UNION_DIR="/mnt/glusterfs/traefik/dynamic-union-${NOMAD_ALLOC_INDEX}"
SHARED_DIR="/mnt/glusterfs/traefik/dynamic"
PRIVATE_DIR="/mnt/glusterfs/traefik/dynamic-private-${NOMAD_ALLOC_INDEX}"

mkdir -p "$UNION_DIR"
mkdir -p "$SHARED_DIR"
mkdir -p "$PRIVATE_DIR"

# Symlink shared configs
if [ ! -e "$UNION_DIR/shared" ]; then
  ln -s "$SHARED_DIR" "$UNION_DIR/shared"
fi

# Symlink private configs
if [ ! -e "$UNION_DIR/private" ]; then
  ln -s "$PRIVATE_DIR" "$UNION_DIR/private"
fi

# Optionally, flatten all .yaml files into the union dir root for Traefik to see them directly
find "$SHARED_DIR" -maxdepth 1 -name '*.yaml' -exec ln -sf {} "$UNION_DIR/" \;
find "$PRIVATE_DIR" -maxdepth 1 -name '*.yaml' -exec ln -sf {} "$UNION_DIR/" \;
EOF
        ]
      }
      resources {
        cpu    = 10
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

    # Sidecar task: watches acme-start.log and creates dynamic routes for all requests to matched domain,
    # but now writes only to the private dynamic config directory for this instance.
    task "acme-private-dynamic-watcher" {
      driver = "raw_exec"
      config {
        command = "bash"
        args = [
          "-c",
          <<EOF
#!/usr/bin/env bash

ACME_START_LOG="/mnt/glusterfs/traefik/acme-start.log"
# Determine private config dir: use NOMAD_ALLOC_INDEX if set, else fallback to hostname
if [ -n "${NOMAD_ALLOC_INDEX}" ]; then
  PRIVATE_CONFIG_DIR="/mnt/glusterfs/traefik/dynamic-private-${NOMAD_ALLOC_INDEX}"
else
  PRIVATE_CONFIG_DIR="/mnt/glusterfs/traefik/dynamic-private-$(hostname)"
fi
DEBUG_ROUTE_LOG="/mnt/glusterfs/traefik/acme-private-route-debug.log"
THROTTLE_DIR="/tmp/acme-private-route-throttle"
CONFIG_TTL_MINUTES=5

mkdir -p "$PRIVATE_CONFIG_DIR"
mkdir -p "$THROTTLE_DIR"
touch "$DEBUG_ROUTE_LOG"

MY_IP=$(hostname -I | awk '{print $1}')

(
  while true; do
    find "$PRIVATE_CONFIG_DIR" -name 'acme-challenge-*.yaml' -mmin +$CONFIG_TTL_MINUTES -exec rm -f {} \;
    sleep 60
  done
) &

tail -Fn0 "$ACME_START_LOG" | while read -r line; do
  echo "DEBUG: Read line: $line" >> "$DEBUG_ROUTE_LOG"

  DOMAIN=$(echo "$line" | grep -oP 'domain=\K[^ ]+')
  CHALLENGE_IP=$(echo "$line" | grep -oP 'ip=\K[^ ]+')

  [ -z "$DOMAIN" ] && echo "DEBUG: No domain found, skipping" >> "$DEBUG_ROUTE_LOG" && continue
  [ -z "$CHALLENGE_IP" ] && echo "DEBUG: No IP found, skipping" >> "$DEBUG_ROUTE_LOG" && continue

  if [ "$CHALLENGE_IP" = "$MY_IP" ]; then
    echo "DEBUG: Challenge owner is self ($MY_IP), skipping" >> "$DEBUG_ROUTE_LOG"
    continue
  fi

  SAFE_DOMAIN=$(echo "$DOMAIN" | tr '.' '-')
  CONFIG_FILE="$PRIVATE_CONFIG_DIR/acme-challenge-$SAFE_DOMAIN.yaml"
  THROTTLE_FILE="$THROTTLE_DIR/$SAFE_DOMAIN.last"
  NOW=$(date +%s)
  LAST=0
  if [ -f "$THROTTLE_FILE" ]; then
    LAST=$(cat "$THROTTLE_FILE")
  fi
  if [ $((NOW - LAST)) -lt 5 ]; then
    echo "DEBUG: Throttling update for $DOMAIN, only $((NOW - LAST))s since last update" >> "$DEBUG_ROUTE_LOG"
    continue
  fi
  echo "$NOW" > "$THROTTLE_FILE"

  TMP_FILE="$CONFIG_FILE.tmp"
  cat > "$TMP_FILE" <<YAML
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
          - url: "http://$CHALLENGE_IP:80"
YAML
  mv "$TMP_FILE" "$CONFIG_FILE"
  echo "DEBUG: Updated dynamic route for $DOMAIN to $CHALLENGE_IP in $CONFIG_FILE" >> "$DEBUG_ROUTE_LOG"
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
            source      = "/mnt/glusterfs/traefik/dynamic-union-${NOMAD_ALLOC_INDEX}"
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
