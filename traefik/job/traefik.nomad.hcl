job "traefik" {
  namespace = "traefik"
  datacenters = ["dc1"]



  group "traefik" {
    count = 2

    constraint {
      distinct_hosts = true
    }

    network {
      mode = "host"

      port "http" {
        static = 80
      }
      port "https" {
        static = 443
      }
    }

    task "init-traefik-dynamic-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "mkdir"
        args    = ["-p", "/mnt/glusterfs/traefik/dynamic"]
      }
      resources {
        cpu    = 10
        memory = 10
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

    task "render-acme-redirect" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = [
          "-c",
          <<EOT
echo "DEBUG: Running as user: $(whoami)"
echo "DEBUG: Directory listing for /mnt/glusterfs/traefik/dynamic:"
ls -ld /mnt/glusterfs/traefik/dynamic
echo "DEBUG: Attempting to write acme-redirect.yaml..."
cat <<'EOF' > /mnt/glusterfs/traefik/dynamic/acme-redirect.yaml
http:
  routers:
    acme-challenge-redirect:
      rule: PathPrefix(`/.well-known/acme-challenge/`)
      entryPoints:
        - web
      priority: 10000
      service: acme-leader-forward

  services:
    acme-leader-forward:
      loadBalancer:
        servers:
          - url: "http://traefik-0.service.consul:80"
EOF
EOT
        ]
      }
      resources {
        cpu    = 10
        memory = 10
      }
    }

    task "traefik" {
      driver = "docker"
      env {
        TRAEFIK_TOKEN = "${TRAEFIK_TOKEN}"
      }



      template {
        data = <<EOF
entryPoints:
  web:
    address: ":80"
    {{ if ne (env "NOMAD_ALLOC_INDEX") "0" }}
    allowACMEByPass: true
    {{ end }}

  websecure:
    address: ":443"

ping:
  entryPoint: web

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
      address: "http://nomad.service.consul:4646"
      token: "${TRAEFIK_TOKEN}"
    watch: true
    namespaces:
      - "nomad-ops"
      - "default"
  consulCatalog:
    endpoint:
        address: "consul.service.consul:8500"

certificatesResolvers:
{{ if eq (env "NOMAD_ALLOC_INDEX") "0" }}
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
{{ else }}
  cert-prod:
    acme:
      email: "no-reply@example.com"
      storage: /etc/traefik/acme-prod.json
      httpChallenge: {}
  cert-stag:
    acme:
      email: "no-reply@example.com"
      storage: /etc/traefik/acme-stag.json
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      httpChallenge: {}
{{ end }}

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
      service {
        name = "traefik-${NOMAD_ALLOC_INDEX}"
        port = "http"
        tags = [
          "acme",
          "role=${NOMAD_ALLOC_INDEX}"
        ]
        check {
          type     = "http"
          path     = "/ping"
          interval = "10s"
          timeout  = "2s"
        }
        enable_tag_override = true
      }
      resources {
        cpu    = 384
        memory = 512
      }
    }


  }

  group "acme-watcher" {
    count = 1
    task "acme-follower-restart-watcher" {
      driver = "raw_exec"
      config {
        command = "bash"
        args = ["-c", <<EOT
ACME_DIR="/mnt/glusterfs/traefik"
ACME_FILE1="$ACME_DIR/acme-prod.json"
ACME_FILE2="$ACME_DIR/acme-stag.json"
DEBOUNCE_SECONDS=60
POLL_INTERVAL=10

if [ -f "$ACME_FILE1" ]; then
  LAST_HASH1=$(md5sum "$ACME_FILE1" | awk '{print $1}')
else
  LAST_HASH1=""
fi

if [ -f "$ACME_FILE2" ]; then
  LAST_HASH2=$(md5sum "$ACME_FILE2" | awk '{print $1}')
else
  LAST_HASH2=""
fi

while true; do
  CHANGED=0

  if [ -f "$ACME_FILE1" ]; then
    NEW_HASH1=$(md5sum "$ACME_FILE1" | awk '{print $1}')
    if [ "$LAST_HASH1" != "$NEW_HASH1" ]; then
      echo "$(date) - Detected change in $ACME_FILE1, restarting follower allocations..."
      LAST_HASH1="$NEW_HASH1"
      CHANGED=1
    fi
  else
    echo "$(date) - WARNING: $ACME_FILE1 does not exist!"
  fi

  if [ -f "$ACME_FILE2" ]; then
    NEW_HASH2=$(md5sum "$ACME_FILE2" | awk '{print $1}')
    if [ "$LAST_HASH2" != "$NEW_HASH2" ]; then
      echo "$(date) - Detected change in $ACME_FILE2, restarting follower allocations..."
      LAST_HASH2="$NEW_HASH2"
      CHANGED=1
    fi
  else
    echo "$(date) - WARNING: $ACME_FILE2 does not exist!"
  fi

  if [ $CHANGED -eq 1 ]; then
    NOMAD_ALLOCS_JSON=$(NOMAD_ADDR="http://nomad.service.consul:4646" NOMAD_TOKEN="${MGMT_TOKEN}" nomad job allocs -json traefik 2>&1)
    echo "NOMAD job allocs output:"
    echo "$NOMAD_ALLOCS_JSON"

    ALLOC_IDS=$(echo "$NOMAD_ALLOCS_JSON" | jq -r '.[] | select(.TaskGroup=="traefik" and .ClientStatus=="running" and (.Name | test("\\[0\\]$") | not)) | .ID')
    echo "Follower allocation IDs to restart:"
    echo "$ALLOC_IDS"

    for alloc_id in $ALLOC_IDS; do
      echo "Restarting follower allocation: $alloc_id"
      RESTART_OUTPUT=$(NOMAD_ADDR="http://nomad.service.consul:4646" NOMAD_TOKEN="${MGMT_TOKEN}" nomad alloc restart "$alloc_id" 2>&1)
      RESTART_EXIT_CODE=$?
      echo "Restart output for $alloc_id:"
      echo "$RESTART_OUTPUT"
      if [ $RESTART_EXIT_CODE -ne 0 ]; then
        echo "ERROR: Failed to restart allocation $alloc_id (exit code $RESTART_EXIT_CODE)"
      fi
    done

    echo "$(date) - Debouncing for $DEBOUNCE_SECONDS seconds..."
    sleep $DEBOUNCE_SECONDS
  else
    sleep $POLL_INTERVAL
  fi
done
EOT
        ]
      }
      env {
        MGMT_TOKEN = "${MGMT_TOKEN}"
      }
      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
