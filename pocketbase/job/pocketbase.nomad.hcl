job "pocketbase" {
  namespace = "default"
  datacenters = ["dc1"]

  group "pocketbase" {
      count = 1

      network {
          port "http" {
             to = 8090
          }
      }

      task "pocketbase" {
          driver = "docker"

          config {
              image = "ghcr.io/trustos/pocketbase:0.28.4"
              ports = ["http"]
              mounts = [
                {
                  type = "bind"
                  source = "/mnt/glusterfs/pocketbase"
                  target = "/pb/pb_data"
                  readonly   = false
                }
              ]
          }

          resources {
              cpu    = 500
              memory = 256
          }
      }
  }
}
