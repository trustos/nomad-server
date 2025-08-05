job "nomad-ops" {
  namespace = "nomad-ops"

  datacenters = ["dc1"]

  type = "service"

  # Specify this job to have rolling updates, two-at-a-time, with
  # 30 second intervals.
  update {
    stagger      = "30s"
    max_parallel = 2
  }

  # A group defines a series of tasks that should be co-located
  # on the same client (host). All tasks within a group will be
  # placed on the same host.
  group "nomad-ops-group" {
    count = 1

    task "init-nomad-ops-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "mkdir"
        args    = ["-p", "/mnt/glusterfs/nomad-ops"]
      }
      resources {
        cpu    = 50
        memory = 32
      }
    }

    network {
      port "http" {
        to = 8080
      }
    }

    service {
      name = "nomad-ops"
      tags = [
        "http",
        "view",
        //Enable this service in Traefik
        "traefik.enable=true",

        // Define the http router for the service
        "traefik.http.routers.nomadops.rule=Host(`ops.rs-estates`)",
        "traefik.http.routers.nomadops.entrypoints=web",
        "traefik.http.routers.nomadops.middlewares=auth@file",

        // Define the http service for the api
        "traefik.http.routers.nomadops-api.rule=Host(`ops.rs-estates`) && PathPrefix(`/api`)",
        "traefik.http.routers.nomadops-api.entrypoints=web",
      ]

      port = "http"

      check {
        type     = "http"
        path     = "/api/health"
        interval = "10s"
        timeout  = "2s"
      }
    }


    # Create an individual task (unit of work). This particular
    # task utilizes a Docker container to front a web application.
    task "operator" {
      # Specify the driver to be "docker". Nomad supports
      # multiple drivers.
      driver = "docker"

      # available with nomad >=v1.5.0
      # use manually supplied NOMAD_TOKEN before that
      identity {
        # Expose Workload Identity in NOMAD_TOKEN env var
        #env = true

        # Expose Workload Identity in ${NOMAD_SECRETS_DIR}/nomad_token file
        file = true
      }

      env {

        NOMAD_OPS_LOCAL_REPO_DIR = "/data/repos"

        # Adjust accordingly
        NOMAD_ADDR = "http://${NOMAD_IP_http}:4646"
        NOMAD_TOKEN = "${NOMAD_TOKEN}"

        TRACE = "FALSE"
      }

      # Configuration is specific to each driver.
      config {
        image = "ghcr.io/trustos/nomad-ops:latest"
        args = [
          "serve",
          "--http", "0.0.0.0:8080",
          "--dir", "/data/pb_data"
        ]

        ports = [
          "http",
        ]

        mounts = [
          {
            type = "bind"
            source = "/mnt/glusterfs/nomad-ops"
            target = "/data"
            readonly   = false
          }
        ]
      }

      # Specify the maximum resources required to run the task,
      # include CPU, memory, and bandwidth.
      resources {
        cpu    = 200 # MHz
        memory = 500 # MB
      }
    }
  }
}
