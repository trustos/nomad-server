job "pocketbase" {
  datacenters = ["dc1"]

  group "pocketbase" {
      count = 1

      network {
          port "http" {
              static = 8090
          }
      }

      volume "pocketbase_data" {
          type      = "host"
          read_only = false
          source    = "alloc"
      }

      task "pocketbase" {
          driver = "docker"

          config {
              image = "ghcr.io/trustos/pocketbase:0.28.3"
              ports = ["http"]
          }

          resources {
              cpu    = 500
              memory = 256
          }

          volume_mount {
              volume      = "pocketbase_data"
              destination = "/pb_data"
              read_only   = false
          }
      }
  }
}
