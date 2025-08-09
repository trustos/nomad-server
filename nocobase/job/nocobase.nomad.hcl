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

    task "init-nocobase-consul-kv" {
      driver = "raw_exec"

      lifecycle {
        hook = "prestart"
        sidecar = false
      }

      config {
        command = "bash"
        args = [
          "-c",
          <<-EOT
          #!/bin/bash
          set -e

          # Check and set NocoBase database user
          if ! consul kv get nocobase/db_user > /dev/null 2>&1; then
            user="nocobase"
            consul kv put nocobase/db_user "$user"
          fi

          # Check and set NocoBase database password
          if ! consul kv get nocobase/db_password > /dev/null 2>&1; then
            pw=$(openssl rand -base64 24)
            consul kv put nocobase/db_password "$pw"
          fi

          # Check and set NocoBase database name
          if ! consul kv get nocobase/db_name > /dev/null 2>&1; then
            dbname="nocobase"
            consul kv put nocobase/db_name "$dbname"
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
          "traefik.http.routers.nocobase-inet.tls=true",
          "traefik.http.routers.nocobase-inet.tls.certresolver=cert-stag",
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
