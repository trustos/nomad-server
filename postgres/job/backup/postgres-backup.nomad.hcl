job "postgres-backup" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    crons            = ["0 4 * * *"]
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

          # Clean up old backup files first
          echo "Cleaning up old backup files..."
          find /backups -name "*.sql" -mtime +0 -delete 2>/dev/null || true

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

      lifecycle {
        hook = "poststart"
      }

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

            # Only upload the newest backup files (created in the last 5 minutes)
            for backup_file in "$BACKUP_DIR"/*.sql; do
              # Check if file was created in the last 5 minutes
              if [ $(find "$backup_file" -newermt "5 minutes ago" | wc -l) -gt 0 ]; then
                echo "Uploading $(basename "$backup_file") ..."
                oci os object put -bn "$BUCKET_NAME" --file "$backup_file" --name "$(basename "$backup_file")" --force
              else
                echo "Skipping old backup file: $(basename "$backup_file")"
              fi
            done

            echo "All files uploaded successfully. Starting retention cleanup..."

            # Get all backup files from bucket and extract unique database names
            ALL_BACKUPS=$(oci os object list -bn "$BUCKET_NAME" --query "data[].name" --raw-output | jq -r '.[]')
            DB_NAMES=$(echo "$ALL_BACKUPS" | grep -E '.*-backup-.*\.sql$' | sed -E 's/-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.sql$//' | sort -u)

            for DB_NAME in $DB_NAMES; do
              echo "Processing retention for database: $DB_NAME"

              # Get all backup files for this database from the previously fetched list
              BACKUP_FILES=$(echo "$ALL_BACKUPS" | grep "^${DB_NAME}-backup-.*\.sql$" | sort -r)

              # Check if we got any results and count them properly
              if [ -n "$BACKUP_FILES" ]; then
                BACKUP_COUNT=$(echo "$BACKUP_FILES" | wc -l)
                echo "Found $BACKUP_COUNT backups for $DB_NAME"

                if [ "$BACKUP_COUNT" -gt 7 ]; then
                  echo "Keeping newest 7, deleting $(($BACKUP_COUNT - 7)) old backups..."

                  # Skip first 7 (newest) and delete the rest
                  FILES_TO_DELETE=$(echo "$BACKUP_FILES" | tail -n +8)

                  for file_to_delete in $FILES_TO_DELETE; do
                    if [ -n "$file_to_delete" ]; then
                      echo "Deleting old backup: $file_to_delete"
                      oci os object delete -bn "$BUCKET_NAME" --object-name "$file_to_delete" --force
                    fi
                  done
                else
                  echo "No cleanup needed for $DB_NAME (has $BACKUP_COUNT backups, keeping all)"
                fi
              else
                echo "No backups found for database: $DB_NAME"
              fi
            done

            echo "Retention cleanup complete. Cleaning up uploaded local backups..."
            # Only remove files that were successfully uploaded (newer than 5 minutes ago)
            find "$BACKUP_DIR" -name "*.sql" -newermt "5 minutes ago" -delete
            echo "Local cleanup complete."

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
