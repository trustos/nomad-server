job "nocobase" {
  datacenters = ["dc1"]
  type        = "service"

  group "nocobase" {
    count = 1

    network {
      port "web" {
        # Uncomment the next line for static port, or remove for dynamic assignment
        # static = 13000
        to     = 13000
        # dynamic = true
      }
    }

    task "init-nocobase-dir" {
      driver = "raw_exec"

      lifecycle {
        hook = "prestart"
        sidecar = false
      }
      config {
        command = "mkdir"
        args    = ["-p", "/mnt/glusterfs/nocobase/storage"]
      }
      resources {
        cpu    = 50
        memory = 32
      }
    }

    # Main NocoBase task
    task "nocobase" {
      driver = "docker"

      config {
        image = "nocobase/nocobase:latest"
        ports = ["web"]
        mounts = [
          {
            type     = "bind"
            source   = "/mnt/glusterfs/nocobase/storage"
            target   = "/app/nocobase/storage"
            readonly = false
          },
        ]
      }

      template {
          data = <<EOH
      DB_USER={{ key "nocobase/db_user" }}
      DB_PASSWORD={{ key "nocobase/db_password" }}
      DB_DATABASE={{ key "nocobase/db_name" }}
      EOH
          destination = "secrets/env"
          env         = true
        }

      env {
        DB_TYPE     = "postgres"
        DB_HOST     = "postgres.service.consul"
        DB_PORT     = "5432"
        DB_DIALECT  = "postgres"
        # Time zone
        TZ          = "Europe/Sofia"
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name = "nocobase"
        port = "web"
        tags = [
          "nocobase",
          "traefik.enable=true",
          "traefik.http.routers.nocobase.rule=Host(`crm.rs-estates`)",
          "traefik.http.routers.nocobase.entrypoints=web",

          "traefik.http.routers.nocobase-inet.rule=Host(`crm.rs-estates.com`)",
          "traefik.http.routers.nocobase-inet.entrypoints=web,websecure",
          # "traefik.http.routers.nocobase-inet.tls=true",
          # "traefik.http.routers.nocobase-inet.tls.certresolver=cert-stag",
        ]
        check {
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
