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
          source      = "pocketbase-data-vol"
          read_only   = false
          # You might want to add sticky = true here for persistent data with single allocations
          sticky      = true
      }

      task "pocketbase" {
          driver = "docker"

          config {
              image = "ghcr.io/trustos/pocketbase:0.28.3"
              ports = ["http"]
          }

          volume_mount {
              volume      = "pocketbase_data"
              destination = "/pb_data"
          }

          resources {
              cpu    = 500
              memory = 256
          }
      }
  }
}
