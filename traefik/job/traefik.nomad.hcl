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

    network {
      port "http" {
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
        ports = ["http", "https"]
        mounts = [
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik"
            target      = "/etc/traefik"
            readonly   = false
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
