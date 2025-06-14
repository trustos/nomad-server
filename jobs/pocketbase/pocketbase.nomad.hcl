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
          source    = "pocketbase-data-vol"
      }

      task "pocketbase" {
          driver = "docker"

          config {
              image = "ghcr.io/trustos/pocketbase:0.28.3"
              ports = ["http"]

              # This is the correct and confirmed syntax
              volumes = [
                "pocketbase_data:/pb_data" # "volume_stanza_name:container_path"
              ]
          }

          resources {
              cpu    = 500
              memory = 256
          }
      }
  }
}
