job "traefik" {
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
        BASIC_AUTH_HASH = "$apr1$kLt1pTnQ$ak2k1hFphBsEqx0Vep1aY1"  # Use htpasswd
      }

      config {
        image = "traefik:v3.4.3"
        ports = ["web", "https"]
      }

      template {
        source      = "traefik.yaml"
        destination = "local/traefik.yaml"
        change_mode = "restart"
      }

      template {
        source      = "nomad_ui.yaml"
        destination = "local/dynamic/nomad_ui.yaml"
        change_mode = "restart"
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
