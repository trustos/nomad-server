job "pocketbase" {
  datacenters = ["dc1"]

  group "pocketbase" {
    count = 1

    volume "pocketbase_data" {
      type      = "host"
      read_only = false
      source    = "pocketbase_data"
    }

    task "pocketbase" {
      driver = "docker"

      config {
        image = "ghcr.io/trustos/pocketbase:0.28.3"
        ports = ["http"]
        volumes = [
          "nomad/pocketbase_data:/pb_data"
        ]
      }

      resources {
        cpu    = 500
        memory = 256
        network {
          port "http" {
            static = 8090
          }
        }
      }

      volume_mount {
        volume      = "pocketbase_data"
        destination = "/pb_data"
        read_only   = false
      }
    }
  }
}
