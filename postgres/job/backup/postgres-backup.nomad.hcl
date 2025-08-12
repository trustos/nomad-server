job "postgres-backup" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["*/2 * * * *"]
    prohibit_overlap = true
    time_zone        = "UTC"
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
        args    = [
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
        image   = "postgres:16"
        command = "bash"
        args    = ["local/backup.sh"]

        mounts = [
          {
            type     = "bind"
            source   = "/mnt/glusterfs/postgres/backups"
            target   = "/backups"
            readonly = false
          }
        ]
      }

      # Script template
      template {
        data = <<-EOH
          #!/bin/bash
          set -euo pipefail

          for DB in $(psql -h postgres.service.consul -U "$PGUSER" -d postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres')"); do
            DB=$(echo "$DB" | xargs) # Trim whitespace
            if [ -n "$DB" ]; then
              echo "Dumping database: $DB"
              pg_dump -h postgres.service.consul -U "$PGUSER" "$DB" > /backups/${DB}-backup-$(date +%F-%H%M%S).sql
            fi
          done
        EOH
        destination = "local/backup.sh"
        perms       = "755"
      }

      # Environment secrets
      template {
        data = <<-EOH
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
      user   = "root"

      config {
        command = "bash"
        args    = ["local/upload.sh"]
      }

      template {
        data = <<-EOH
          #!/bin/bash
          set -euo pipefail

          export PATH=$PATH:/root/.local/bin
          export OCI_CLI_AUTH=instance_principal

          COMPARTMENT_ID=$(curl -sL http://169.254.169.254/opc/v1/instance/metadata/COMPARTMENT_OCID)
          NAMESPACE=$(oci os ns get --query "data" --raw-output)
          BUCKET_NAME="postgres"

          # Check if bucket exists
          BUCKET_JSON=$(oci os bucket list --compartment-id "$COMPARTMENT_ID" --namespace-name "$NAMESPACE" --query "data[?name=='$BUCKET_NAME']")
          BUCKET_COUNT=$(echo "$BUCKET_JSON" | jq 'length')

          if [ "$BUCKET_COUNT" -eq 0 ]; then
            echo "Bucket '$BUCKET_NAME' does not exist. Creating it..."
            oci os bucket create --compartment-id "$COMPARTMENT_ID" --namespace-name "$NAMESPACE" --name "$BUCKET_NAME"
          else
            echo "Bucket '$BUCKET_NAME' exists."
          fi

          BACKUP_DIR="/mnt/glusterfs/postgres/backups"

          # Check if there are SQL files
          if compgen -G "$BACKUP_DIR/*.sql" > /dev/null; then
            echo "Found backup files, starting upload..."

            for backup_file in "$BACKUP_DIR"/*.sql; do
              echo "Uploading $(basename "$backup_file") ..."
              oci os object put -bn "$BUCKET_NAME" --file "$backup_file" --name "$(basename "$backup_file")"
            done

            echo "All files uploaded successfully. Cleaning up local backups..."
            rm -f "$BACKUP_DIR"/*.sql
            echo "Cleanup complete."

            # Keep only last 7 backups in the bucket
            for DB in $(psql -h postgres.service.consul -U "$PGUSER" -d postgres -t -c \
              "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres')"); do
              DB=$(echo "$DB" | xargs)
              if [ -n "$DB" ]; then
                echo "Checking old backups for $DB ..."
                backup_objects=$(oci os object list -bn "$BUCKET_NAME" \
                  --query "data[?starts_with(&name, '${DB}-backup-')].name" \
                  --raw-output | sort -r)

                echo "$backup_objects" | tail -n +8 | while read -r obj; do
                  [ -n "$obj" ] && echo "Deleting old backup: $obj" && \
                    oci os object delete -bn "$BUCKET_NAME" --name "$obj" --force
                done
              fi
            done

          else
            echo "No backup files found to upload."
            exit 0
          fi

        EOH
        destination = "local/upload.sh"
        perms       = "755"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
