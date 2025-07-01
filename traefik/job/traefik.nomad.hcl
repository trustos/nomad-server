job "traefik" {
  namespace = "traefik"
  datacenters = ["dc1"]

  group "traefik" {
    count = 1

    network {
      port "web" {
        static = 80
      }
      port "https" {
        static = 443
      }
    }

    task "traefik" {
      driver = "docker"

      env {
        BASIC_AUTH_HASH = "$apr1$kLt1pTnQ$ak2k1hFphBsEqx0Vep1aY1"
      }

      config {
        image = "traefik:v3.4.3"
        ports = ["web", "https"]
      }

      # Embedded traefik.yaml
      template {
        destination = "local/traefik.yaml"
        change_mode = "restart"
        data = <<EOT
entryPoints:
  web:
    address: ":80"
  https:
    address: ":443"

api:
  dashboard: true
  insecure: false

providers:
  file:
    directory: "/etc/traefik/dynamic"
    watch: true

certificatesResolvers:
  nomadcertresolver:
    acme:
      email: trustos@gmail.com
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
EOT
      }

      # Embedded nomad_ui.yaml
      template {
        destination = "local/dynamic/nomad_ui.yaml"
        change_mode = "restart"
        data = <<EOT
http:
  middlewares:
    auth:
      basicAuth:
        users:
          - '{{ env "BASIC_AUTH_HASH" }}'

  routers:
    dashboard:
      rule: "Host(`traefik.local`)"
      entryPoints:
        - "https"
      service: api@internal
      middlewares:
        - "auth"
      tls:
        certResolver: "nomadcertresolver"
EOT
      }

      volume_mount {
        volume      = "local"
        destination = "/etc/traefik"
        read_only   = false
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }

    volume "local" {
      type   = "host"
      source = "traefik-data-vol"
      read_only = false
      sticky = true
    }
  }
}
