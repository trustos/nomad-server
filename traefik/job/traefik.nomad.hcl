job "traefik" {
  datacenters = ["dc1"]

  group "traefik" {
    count = 1

    network {
      port "web" {
        static = 80
      }
    }

    task "traefik" {
      driver = "docker"

      env {
        BASIC_AUTH_HASH = "$apr1$kLt1pTnQ$ak2k1hFphBsEqx0Vep1aY1"  # Use htpasswd
      }

      config {
        image = "traefik:v3.0"
        ports = ["web"]
        volumes = [
          "local/traefik.toml:/etc/traefik/traefik.toml",
          "local/dynamic:/etc/traefik/dynamic"
        ]
      }

      template {
        source      = "local/nomad_ui.yml.tpl"
        destination = "local/dynamic/nomad_ui.yml"
        change_mode = "restart"
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }

    volume "local" {
      type   = "host"
      source = "traefik-config"
    }
  }
}
