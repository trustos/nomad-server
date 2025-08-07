job "postgres-stack" {
  datacenters = ["dc1"]

  group "postgres" {
    count = 1

    # Prestart task to ensure directories exist
    task "prepare-dirs" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "raw_exec"

      config {
        command = "bash"
        args = [
          "-c",
          "mkdir -p /mnt/glusterfs/postgres/data16 && mkdir -p /mnt/glusterfs/postgres/pgadmin && chown -R 999:999 /mnt/glusterfs/postgres/data16 && chown -R 5050:5050 /mnt/glusterfs/postgres/pgadmin"
        ]
      }

      resources {
        cpu    = 100
        memory = 64
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

          # Check and set POSTGRES_USER
          if ! consul kv get postgres/adminuser > /dev/null 2>&1; then
            user="adminuser"
            consul kv put postgres/adminuser "$user"
          fi

          # Check and set POSTGRES_PASSWORD
          if ! consul kv get postgres/adminpassword > /dev/null 2>&1; then
            pw=$(openssl rand -base64 24)
            consul kv put postgres/adminpassword "$pw"
          fi

          # Check and set PGADMIN_DEFAULT_EMAIL
          if ! consul kv get postgres/pgadminuser > /dev/null 2>&1; then
            user="adminuser"
            consul kv put postgres/pgadminuser "$user"
          fi

          # Check and set PGADMIN_DEFAULT_PASSWORD
          if ! consul kv get postgres/pgadminpassword > /dev/null 2>&1; then
            pw=$(openssl rand -base64 24)
            consul kv put postgres/pgadminpassword "$pw"
          fi
          EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    task "create-postgres-namespace" {
      driver = "raw_exec"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
         data = <<EOH
     NOMAD_TOKEN={{ key "nomad/bootstrap-token" }}
     EOH

         destination = "secrets/env"
         env         = true
      }

      config {
        command = "bash"
        args = [
          "-c",
          "NOMAD_TOKEN=$NOMAD_TOKEN nomad apply namespace --description='Postgres namespace' postgres"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    network {
      port "db" {
        static = 5432
      }
    }

    task "postgres16" {
      driver = "docker"

      config {
        image = "postgres:16"
        ports = ["db"]

        mounts = [
          {
            type     = "bind"
            source   = "/mnt/glusterfs/postgres/data16"
            target   = "/var/lib/postgresql/data"
            readonly = false
          }
        ]
      }

      template {
         data = <<EOH
     POSTGRES_USER={{ key "postgres/adminuser" }}
     POSTGRES_PASSWORD={{ key "postgres/adminpassword" }}
     EOH

         destination = "secrets/env"
         env         = true
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name = "postgres"
        port = "db"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.pg.rule=Host(`pg.rs-estates`)",
          "traefik.http.routers.pg.entrypoints=web",
        ]
      }
    }
  }

  group "pgadmin" {
    count = 1

    network {
      port "http" {
        to = 80
      }
    }

    task "pgadmin" {
      driver = "docker"

      config {
        image = "dpage/pgadmin4"
        ports = ["http"]

        mounts = [
          {
            type     = "bind"
            source   = "/mnt/glusterfs/postgres/pgadmin"
            target   = "/var/lib/pgadmin"
            readonly = false
          }
        ]
      }

      template {
         data = <<EOH
     PGADMIN_DEFAULT_EMAIL={{ key "postgres/pgadminuser" }}
     PGADMIN_DEFAULT_PASSWORD={{ key "postgres/pgadminpassword" }}
     EOH

         destination = "secrets/env"
         env         = true
       }

      resources {
        cpu    = 300
        memory = 256
      }

      service {
        name = "pgadmin"
        port = "http"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.pgadmin.rule=Host(`pgadmin.rs-estates`)",
          "traefik.http.routers.pgadmin.entrypoints=web",
        ]
      }
    }
  }
}
