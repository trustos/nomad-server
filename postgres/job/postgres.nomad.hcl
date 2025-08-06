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

      env {
        POSTGRES_USER     = "nomaduser"
        POSTGRES_PASSWORD = "securepassword"
        POSTGRES_DB       = "nomaddb"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }

  group "pgadmin" {
    count = 1

    network {
      port "http" {
        static = 8080
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

      env {
        PGADMIN_DEFAULT_EMAIL    = "admin@example.com"
        PGADMIN_DEFAULT_PASSWORD = "adminpass"
      }

      resources {
        cpu    = 300
        memory = 256
      }
    }
  }
}
