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

      config {
        image = "traefik:v3.4.3"
        ports = ["web", "https"]
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
