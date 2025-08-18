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

          # Check and set DEFAULT_USER_EMAIL
          if ! consul kv get nomad-ops/adminuseremail > /dev/null 2>&1; then
            useremail="admin@nomad-ops.rs-estates"
            consul kv put nomad-ops/adminuseremail "$useremail"
          fi

          # Check and set DEFAULT_USER_PASSWORD
          if ! consul kv get nomad-ops/adminpassword > /dev/null 2>&1; then
            pw=$(openssl rand -base64 24)
            consul kv put nomad-ops/adminpassword "$pw"
          fi
          EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    task "init-ssh-known-hosts" {
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

          # Ensure the nomad-ops directory exists
          mkdir -p /mnt/glusterfs/nomad-ops/.ssh

          # Also create system-wide SSH directory for fallback
          mkdir -p /etc/ssh

          # Create SSH known_hosts file with correct and complete host keys
          # Create it in multiple locations to ensure go-git can find it
          cat > /mnt/glusterfs/nomad-ops/.ssh/known_hosts << 'EOF'
# GitHub
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl

# GitLab
gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2bNKTBSpIYDEGk9KxsGh3mySTRgMtXL583qmBpzeQ+jqCMRgBqB98u3z++J1sKlXHWfM9dyhSevkMwSbhoR8XIq/U0tCNyokEi/ueaBMCvbcTHhO7FcwzY92WK4Yt0aGROY5qX2UKSeOvuP4D6TPqKF1onrSzH9bx9XUf2lEdWT/ia1NEKjunUqu1xOB/StKDHMoX4/OKyIzuS0q/T1zOATthvasJFoPrAjkohTyaDUz2LN5JoH839hViyEG82yB+MjcFV5MU3N1l1QL3cVUCh93xSaua1N85qivl+siMkPGbO5xR/En4iEY6K2XPASUEMaieWVNTRCtJ4S8H+9
gitlab.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFSMqzJeV9rUzU4kWitGjeR4PWSa29SPqJ1fVkhtj3Hw9xjLVXVYrU9QlYWrOLXBpQ6KWjbjTDTdDkoohFzgbEY=
gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf

# Bitbucket
bitbucket.org ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDQeJzhupRu0u0cdegZIa8e86EG2qOCsIsD1Xw0xSeiPDlCr7kq97NLmMbpKTX6Esc30NuoqEEHCuc7yWtwp8dI76EEEB1VqY9QJq6vk+aySyboD5QF61I/1WeTwu+deCbgKMGbUijeXhtfbxSxm6JwGrXrhBdofTsbKRUsrN1WoNgUa8uqN1Vx6WAJw1JHPhglEGGHea6QICwJOAr/6mrui/oB7pkaWKHj3z7d1IC4KWLtY47elvjbaTlkN04Kc/5LFEirorGYVbt15kAUlqGM65pk6ZBxtaO3+30LVlORZkxOh+LKL/BvbZ/iRNhItLqNyieoQj/uh/7Iv4uyH/cV/0b4WDSd3DptigWq84lJubb9t/DnZlrJazxyDCulTmKdOR7vs9gMTo+uoIrPSb8ScTtvw65+odKAlBj59dhnVp9zd7QUojOpXlL62Aw56U4oO+FALuevvMjiWeavKhJqlR7i5n9srYcrNV7ttmDw7kf/97P5zauIhxcjX+xHv4M=
bitbucket.org ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPIQmuzMBuKdWeF4+a2sjSSpBK0iqitSQ+5BM9KhpexuGt20JpTVM7u5BDZngncgrqDMbWdxMWWOGtZ9UgbqgZE=
bitbucket.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO
EOF

          # Copy to system-wide location as fallback
          cp /mnt/glusterfs/nomad-ops/.ssh/known_hosts /etc/ssh/ssh_known_hosts

          # Set proper permissions
          chmod 600 /mnt/glusterfs/nomad-ops/.ssh/known_hosts
          chmod 700 /mnt/glusterfs/nomad-ops/.ssh
          chmod 644 /etc/ssh/ssh_known_hosts

          # Verify the file exists in both locations
          ls -la /mnt/glusterfs/nomad-ops/.ssh/known_hosts
          ls -la /etc/ssh/ssh_known_hosts
          echo "SSH known_hosts file initialized successfully in multiple locations"
          EOT
        ]
      }

      resources {
        cpu    = 100
        memory = 64
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

      template {
         data = <<EOH
     DEFAULT_USER_EMAIL={{ key "nomad-ops/adminuseremail" }}
     DEFAULT_USER_PASSWORD={{ key "nomad-ops/adminpassword" }}
     NOMAD_TOKEN={{ key "nomad/bootstrap-token" }}
     EOH

         destination = "secrets/env"
         env         = true
      }

      env {
        NOMAD_OPS_LOCAL_REPO_DIR = "/data/repos"

        # Adjust accordingly
        NOMAD_ADDR = "http://${NOMAD_IP_http}:4646"

        TRACE = "FALSE"

        SSH_KNOWN_HOSTS = "/data/.ssh/known_hosts:/etc/ssh/ssh_known_hosts"
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
