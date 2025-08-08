job "nocobase" {
  datacenters = ["dc1"]
  type        = "service"

  group "nocobase" {
    count = 1

    # Main NocoBase task
    task "nocobase" {
      driver = "docker"

      config {
        image = "nocobase/nocobase:latest"
        ports = ["web"]
        volumes = [
          "/mnt/glusterfs/nocobase:/app/data"
        ]
      }

      env {
        DB_TYPE     = "postgres"
        DB_HOST     = "postgres.service.consul"
        DB_PORT     = "5432"
        DB_USER     = "${CONSUL_KEY(nocobase/db_user)}"
        DB_PASSWORD = "${CONSUL_KEY(nocobase/db_password)}"
        DB_DATABASE = "${CONSUL_KEY(nocobase/db_name)}"
        NODE_ENV    = "production"
        # PORT will be set dynamically by Nomad
      }

      resources {
        cpu    = 500
        memory = 1024

        network {
          port "web" {
            # Uncomment the next line for static port, or remove for dynamic assignment
            # static = 13000
            to     = 13000
            # dynamic = true
          }
        }
      }

      service {
        name = "nocobase"
        port = "web"
        tags = [
          "nocobase"
          "traefik.enable=true",
          "traefik.http.routers.nocobase.rule=Host(`crm.rs-estates`)",
          "traefik.http.routers.nocobase.entrypoints=web",
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
