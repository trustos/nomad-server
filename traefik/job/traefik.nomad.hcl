job "traefik" {
  namespace = "traefik"
  datacenters = ["dc1"]

  group "acme-redirect-cron" {
    count = 1

    task "acme-redirect-cron" {
      driver = "raw_exec"
      config {
        command = "bash"
        args = ["-c", <<EOT
FIRST_FOUND=0
DYNAMIC_CONFIG_PATH="/mnt/glusterfs/traefik/dynamic/acme-redirect.yaml"

while true; do
  TS="$(date '+%Y-%m-%d %H:%M:%S')"
  SERVICE_INFO=$(NOMAD_TOKEN="$TRAEFIK_TOKEN" nomad service info --namespace=traefik -json traefik-0 2>/dev/null)
  LEADER_IP=$(echo "$SERVICE_INFO" | jq -r '.[0].Address')
  ROLE=$(echo "$SERVICE_INFO" | jq -r '.[0].Tags[]' | grep '^role=' | cut -d= -f2)

  echo "$TS - Raw leader IP: $LEADER_IP, role tag: $ROLE"

  if [ -n "$LEADER_IP" ] && [ "$LEADER_IP" != "null" ] && [ "$ROLE" = "0" ]; then
    echo "$TS - Cron: Using leader IP: $LEADER_IP (confirmed role=0)"
    cat > "$DYNAMIC_CONFIG_PATH" <<EOF
http:
  routers:
    acme-challenge-redirect:
      rule: PathPrefix(\`/.well-known/acme-challenge/\`)
      entryPoints:
        - web
      priority: 10000
      service: acme-leader-forward

  services:
    acme-leader-forward:
      loadBalancer:
        servers:
          - url: "http://$LEADER_IP:80"
EOF
    FIRST_FOUND=1
  else
    echo "$TS - Leader IP not found or not role=0, will retry soon."
    if [ "$FIRST_FOUND" -eq 0 ] && [ -f "$DYNAMIC_CONFIG_PATH" ]; then
      rm -f "$DYNAMIC_CONFIG_PATH"
      echo "$TS - Removed stale dynamic config."
    fi
  fi

  if [ "$FIRST_FOUND" -eq 1 ]; then
    sleep 300
  else
    sleep 10
  fi
done
EOT
        ]
      }
      env {
        TRAEFIK_TOKEN = "${TRAEFIK_TOKEN}"
        NOMAD_ADDR    = "http://${NLB_IP}:4646"
      }
      resources {
        cpu    = 200
        memory = 128
      }
    }
  }

  group "traefik" {
    count = 2

    constraint {
      distinct_hosts = true
    }

    network {
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
        address: "http://${NLB_IP}:4646"
        token: "${TRAEFIK_TOKEN}"
      watch: true
      namespaces:
        - "nomad-ops"
        - "default"

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
        provider = "nomad"
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
ACME_FILES="acme-prod.json acme-stag.json"
DEBOUNCE_SECONDS=60

while true; do
  echo "Watching: $ACME_DIR/$ACME_FILES"
  ls -l $ACME_DIR/$ACME_FILES
  inotifywait -e close_write $ACME_DIR/$ACME_FILES
  echo "$(date) - Detected change in ACME file(s), restarting follower allocations..."

  NOMAD_ADDR="http://${NLB_IP}:4646" NOMAD_TOKEN="${TRAEFIK_TOKEN}" nomad job allocs -json traefik | jq -r '.[] | select(.TaskGroup=="traefik" and .ClientStatus=="running" and (.Name | test("\\[0\\]$") | not)) | .ID' | while read alloc_id; do
    echo "Restarting follower allocation: $alloc_id"
    NOMAD_ADDR="http://${NLB_IP}:4646" NOMAD_TOKEN="${TRAEFIK_TOKEN}" nomad alloc restart "$alloc_id"
  done

  echo "$(date) - Debouncing for $DEBOUNCE_SECONDS seconds..."
  sleep $DEBOUNCE_SECONDS
done
EOT
        ]
      }
      env {
        NLB_IP = "${NLB_IP}"
        MGMT_TOKEN = "${MGMT_TOKEN}"
      }
      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
