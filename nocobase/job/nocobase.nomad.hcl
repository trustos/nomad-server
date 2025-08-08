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

          # Check and set INIT_ROOT_EMAIL
          if ! consul kv get nocobase/init_root_email > /dev/null 2>&1; then
            useremail="admin@nocobase.rs-estates"
            consul kv put nocobase/init_root_email "$useremail"
          fi

          # Check and set INIT_ROOT_PASSWORD
          if ! consul kv get nocobase/init_root_password > /dev/null 2>&1; then
            pw=$(openssl rand -base64 24)
            consul kv put nocobase/init_root_password "$pw"
          fi

          # Check and set INIT_ROOT_NICKNAME
          if ! consul kv get nocobase/init_root_nickname > /dev/null 2>&1; then
            nickname="Admin Nocobase RS Estates"
            consul kv put nocobase/init_root_nickname "$nickname"
          fi

          # Check and set INIT_ROOT_USERNAME
          if ! consul kv get nocobase/init_root_username > /dev/null 2>&1; then
            username="nocoadmin"
            consul kv put nocobase/init_root_username "$username"
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
      DB_TYPE     = postgres
      DB_HOST     = postgres.service.consul
      DB_PORT     = 5432
      DB_DIALECT  = postgres
      TZ          = Europe/Sofia
      NODE_ENV    = production
      DB_USER={{ key "nocobase/db_user" }}
      DB_PASSWORD={{ key "nocobase/db_password" }}
      DB_DATABASE={{ key "nocobase/db_name" }}
      INIT_ROOT_EMAIL={{ key "nocobase/init_root_email" }}
      INIT_ROOT_PASSWORD={{ key "nocobase/init_root_password" }}
      INIT_ROOT_NICKNAME={{ key "nocobase/init_root_nickname" }}
      INIT_ROOT_USERNAME={{ key "nocobase/init_root_username" }}
      EOH
          destination = "secrets/env"
          env         = true
        }

      # env {
      #   DB_TYPE     = "postgres"
      #   DB_HOST     = "postgres.service.consul"
      #   DB_PORT     = "5432"
      #   DB_DIALECT  = "postgres"
      #   # Time zone
      #   TZ          = "Europe/Sofia"
      #   NODE_ENV    = "production"
      #   # PORT will be set dynamically by Nomad
      # }

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
