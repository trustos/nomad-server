job "traefik" {
  namespace = "traefik"
  datacenters = ["dc1"]

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

    # Prestart task: ensure the dynamic config directory exists for all dynamic configs
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

    task "acme-redirect-cron" {
      driver = "docker"
      config {
        image = "bitnami/nomad:latest"
        command = "bash"
        args = ["-c", <<EOT
while true; do
  LEADER_IP=$(NOMAD_TOKEN="${TRAEFIK_TOKEN}" nomad service info --namespace=traefik -json traefik-0 2>/dev/null | jq -r '.[0].Address')
  if [ -z "$LEADER_IP" ] || [ "$LEADER_IP" = "null" ]; then
    LEADER_IP="127.0.0.1"
  fi
  echo "Cron: Using leader IP: $LEADER_IP"
  cat > /mnt/glusterfs/traefik/dynamic/acme-redirect.yaml <<EOF
http:
  routers:
    acme-challenge-redirect:
      rule: PathPrefix(\`/.well-known/acme-challenge/\`)
      entryPoints:
        - web
      priority: 10000
      service: acme-leader-forward
      middlewares:
        - strip-challenge

  middlewares:
    strip-challenge:
      stripPrefix:
        prefixes:
          - "/.well-known/acme-challenge"

  services:
    acme-leader-forward:
      loadBalancer:
        servers:
          - url: "http://$LEADER_IP:80"
EOF
  sleep 60
done
EOT
        ]
        mounts = [
          {
            type     = "bind"
            source   = "/mnt/glusterfs/traefik/dynamic"
            target   = "/mnt/glusterfs/traefik/dynamic"
            readonly = false
          }
        ]
      }
      env {
        TRAEFIK_TOKEN = "${TRAEFIK_TOKEN}"
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

      # Register traefik-leader service only on leader allocation
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
}
