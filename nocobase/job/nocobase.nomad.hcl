job "nocobase" {
  datacenters = ["dc1"]
  type        = "service"

  group "nocobase" {
    count = 1

    # Prestart task to initialize secrets in Consul KV
    task "init-secrets" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "raw_exec"

      config {
        command = "bash"
        args = [
          "-c",
          <<-EOT
          #!/bin/bash
          set -e

          # Set NocoBase DB user
          if ! consul kv get nocobase/db_user > /dev/null 2>&1; then
            user="nocobaseuser"
            consul kv put nocobase/db_user "$user"
          fi

          # Set NocoBase DB password
          if ! consul kv get nocobase/db_password > /dev/null 2>&1; then
            pw=$(openssl rand -base64 24)
            consul kv put nocobase/db_password "$pw"
          fi

          # Set NocoBase DB name
          if ! consul kv get nocobase/db_name > /dev/null 2>&1; then
            consul kv put nocobase/db_name "nocobase"
          fi
          EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

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
