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
ACME_START_LOG="/mnt/glusterfs/traefik/acme-start"
INSTANCE_IP=$(hostname -I | awk '{print $1}')

touch "$ACME_START_LOG"

while true; do
  if [ -p "$LOG_FILE" ]; then
    cat "$LOG_FILE" | while read -r line; do
      if [[ "$line" =~ Trying\ to\ challenge\ certificate\ for\ domain\ \[([a-zA-Z0-9.-]+)\] ]]; then
        DOMAIN="${BASH_REMATCH[1]}"
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        (
          flock -x 200
          echo "$TIMESTAMP domain=$DOMAIN ip=$INSTANCE_IP" >> "$ACME_START_LOG"
        ) 200>>"$ACME_START_LOG.lock"
      fi
    done
  else
    sleep 2
  fi
done
EOF
        ]
      }
      resources {
        cpu = 10
        memory = 16
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
      tlsChallenge: {}
  cert-stag:
    acme:
      email: trustos@gmail.com
      storage: /etc/traefik/acme-stag.json
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      tlsChallenge: {}

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
