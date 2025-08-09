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

    task "init-nocobase-database" {
      driver = "docker"

      lifecycle {
        hook = "prestart"
        sidecar = false
      }

      config {
        image = "postgres:16"
        command = "bash"
        args = [
          "-c",
          <<-EOT
          #!/bin/bash
          set -e

          # Get credentials from Consul
          POSTGRES_ADMIN_USER=$(consul kv get postgres/adminuser)
          POSTGRES_ADMIN_PASSWORD=$(consul kv get postgres/adminpassword)
          NOCOBASE_DB_USER=$(consul kv get nocobase/db_user)
          NOCOBASE_DB_PASSWORD=$(consul kv get nocobase/db_password)
          NOCOBASE_DB_NAME=$(consul kv get nocobase/db_name)

          export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"

          # Check if database exists, create if not
          if ! psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$NOCOBASE_DB_NAME'" | grep -q 1; then
            echo "Creating database: $NOCOBASE_DB_NAME"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d postgres -c "CREATE DATABASE \"$NOCOBASE_DB_NAME\";"
          else
            echo "Database $NOCOBASE_DB_NAME already exists"
          fi

          # Check if user exists, create if not
          if ! psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$NOCOBASE_DB_USER'" | grep -q 1; then
            echo "Creating user: $NOCOBASE_DB_USER"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d postgres -c "CREATE USER \"$NOCOBASE_DB_USER\" WITH PASSWORD '$NOCOBASE_DB_PASSWORD';"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE \"$NOCOBASE_DB_NAME\" TO \"$NOCOBASE_DB_USER\";"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d "$NOCOBASE_DB_NAME" -c "GRANT ALL ON SCHEMA public TO \"$NOCOBASE_DB_USER\";"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d "$NOCOBASE_DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"$NOCOBASE_DB_USER\";"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d "$NOCOBASE_DB_NAME" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$NOCOBASE_DB_USER\";"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d "$NOCOBASE_DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$NOCOBASE_DB_USER\";"
            psql -h postgres.service.consul -U "$POSTGRES_ADMIN_USER" -d "$NOCOBASE_DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$NOCOBASE_DB_USER\";"
          else
            echo "User $NOCOBASE_DB_USER already exists"
          fi
          EOT
        ]
      }

      resources {
        cpu    = 200
        memory = 128
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
