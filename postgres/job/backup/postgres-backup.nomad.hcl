job "postgres-backup" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    crons = [
      "*/2 * * * *"
    ]
    prohibit_overlap = true
    time_zone = "UTC"
  }

  group "backup" {
    count = 1

    task "prepare-backup-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = [
          "-c",
          "mkdir -p /mnt/glusterfs/postgres/backups && chown -R 999:999 /mnt/glusterfs/postgres/backups"
        ]
      }
      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "pgdump" {
      driver = "docker"
      config {
        image = "postgres:16"
        command = "bash"
        args = [
          "-c",
          <<-EOT
          pg_dumpall -h postgres.service.consul -U "$PGUSER" > /backups/postgres-backup-$(date +%F-%H%M%S).sql
          EOT
        ]
        mounts = [
          {
            type     = "bind"
            source   = "/mnt/glusterfs/postgres/backups"
            target   = "/backups"
            readonly = false
          }
        ]
      }
      template {
        data = <<EOH
PGUSER={{ key "postgres/adminuser" }}
PGPASSWORD={{ key "postgres/adminpassword" }}
EOH
        destination = "secrets/env"
        env         = true
      }
      resources {
        cpu    = 200
        memory = 256
      }
    }

    task "upload-to-oci" {
      driver = "raw_exec"
      user = "root"

      config {
        command = "bash"
        args = [
          "-c",
          <<-EOT
          echo "Current user: $(whoami)"
          id
          export PATH=$PATH:/root/.local/bin
          echo "PATH: $PATH"
          which oci
          export OCI_CLI_AUTH=instance_principal
          COMPARTMENT_ID=$(curl -sL http://169.254.169.254/opc/v1/instance/metadata/COMPARTMENT_OCID)
          NAMESPACE=$(oci os ns get --query "data" --raw-output)
          BUCKET_NAME="postgres"

          # Check if bucket exists using jq for robust JSON handling
          BUCKET_JSON=$(oci os bucket list --compartment-id "$COMPARTMENT_ID" --namespace-name "$NAMESPACE" --query "data[?name=='$BUCKET_NAME']")
          BUCKET_COUNT=$(echo "$BUCKET_JSON" | jq 'length')

          if [ "$BUCKET_COUNT" -eq 0 ]; then
            echo "Bucket '$BUCKET_NAME' does not exist. Creating it..."
            oci os bucket create --compartment-id "$COMPARTMENT_ID" --namespace-name "$NAMESPACE" --name "$BUCKET_NAME"
          else
            echo "Bucket '$BUCKET_NAME' exists."
          fi

          latest_backup=$(ls -t /mnt/glusterfs/postgres/backups/postgres-backup-*.sql | head -n1)
          if [ -f "$latest_backup" ]; then
            oci os object put -bn "$BUCKET_NAME" --file "$latest_backup" --name "$(basename $latest_backup)"
          else
            echo "No backup file found to upload."
            exit 1
          fi
          EOT
        ]
      }
      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
