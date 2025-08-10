job "traefik" {
  type = "system"
  namespace = "traefik"
  datacenters = ["dc1"]



  group "traefik" {

    network {
      port "http" {
        static = 80
      }
      port "https" {
        static = 443
      }
    }

    task "init-traefik-dynamic-dir" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "mkdir"
        args    = ["-p", "/mnt/glusterfs/traefik/dynamic"]
      }
      resources {
        cpu    = 10
        memory = 10
      }
    }

    task "init-traefik-acme-files" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = ["-c", "touch /mnt/glusterfs/traefik/acme-stag.json /mnt/glusterfs/traefik/acme-prod.json  && chmod 644 /mnt/glusterfs/traefik/acme-*.json"]
      }
      resources {
        cpu = 10
        memory = 10
      }
    }

    task "render-acme-redirect" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = [
          "-c",
          <<EOT
echo "DEBUG: Running as user: $(whoami)"
echo "DEBUG: Directory listing for /mnt/glusterfs/traefik/dynamic:"
ls -ld /mnt/glusterfs/traefik/dynamic

# Get leader from Consul KV or default to traefik-0 for initial setup
CONSUL_ADDR="consul.service.consul:8500"
LEADER_KEY="traefik/leader"
LEADER_NODE=$(curl -s "http://$CONSUL_ADDR/v1/kv/$LEADER_KEY?raw" 2>/dev/null || echo "")

# If no leader is set in Consul yet, try to determine it or use fallback
if [ -z "$LEADER_NODE" ]; then
  echo "No leader found in Consul KV, using traefik-0 as fallback"
  LEADER_NODE="traefik-0"
fi

echo "DEBUG: Using leader node: $LEADER_NODE"
echo "DEBUG: Attempting to write acme-redirect.yaml..."

cat <<EOF > /mnt/glusterfs/traefik/dynamic/acme-redirect.yaml
http:
  routers:
    acme-challenge-redirect:
      rule: PathPrefix(\`/.well-known/acme-challenge/\`)
      entryPoints:
        - web
      priority: 10000
      service: acme-leader-forward

  services:
    acme-leader-forward:
      loadBalancer:
        servers:
          - url: "http://$LEADER_NODE.service.consul:80"
EOF

echo "DEBUG: ACME redirect configured for leader: $LEADER_NODE"
EOT
        ]
      }
      resources {
        cpu    = 10
        memory = 10
      }
    }

    task "leader-election" {
      driver = "raw_exec"
      lifecycle {
        hook = "prestart"
      }
      config {
        command = "bash"
        args = ["-c", <<EOT
# Leader election logic
CONSUL_ADDR="consul.service.consul:8500"
LEADER_KEY="traefik/leader"
NODE_NAME="${NOMAD_NODE_NAME}"
ALLOC_INDEX="${NOMAD_ALLOC_INDEX}"

echo "DEBUG: Node: $NODE_NAME, Alloc Index: $ALLOC_INDEX"

# Get current leader
CURRENT_LEADER=$(curl -s "http://$CONSUL_ADDR/v1/kv/$LEADER_KEY?raw" 2>/dev/null || echo "")

if [ -z "$CURRENT_LEADER" ]; then
  # No leader exists, try to become leader
  echo "No leader found, attempting to become leader..."

  # Use Consul's atomic CAS operation for leader election
  SUCCESS=$(curl -s -X PUT -d "$NODE_NAME" "http://$CONSUL_ADDR/v1/kv/$LEADER_KEY?cas=0")

  if [ "$SUCCESS" = "true" ]; then
    echo "Successfully became leader"
  else
    echo "Failed to become leader, another node was faster"
  fi
else
  echo "Current leader is: $CURRENT_LEADER"

  # If this node was the previous leader and is restarting, reclaim leadership
  if [ "$CURRENT_LEADER" = "$NODE_NAME" ]; then
    echo "This node was the previous leader, maintaining leadership"
  fi
fi

# Final leader check
FINAL_LEADER=$(curl -s "http://$CONSUL_ADDR/v1/kv/$LEADER_KEY?raw" 2>/dev/null || echo "")
echo "Final leader: $FINAL_LEADER"

if [ "$FINAL_LEADER" = "$NODE_NAME" ]; then
  echo "This node is the ACME leader"
  echo "true" > /tmp/is_leader
else
  echo "This node is a follower"
  echo "false" > /tmp/is_leader
fi
EOT
        ]
      }
      resources {
        cpu    = 10
        memory = 10
      }
    }

    task "traefik" {
      driver = "docker"

      template {
        data = <<EOF
entryPoints:
  web:
    address: ":80"
    {{ if ne (env "NOMAD_ALLOC_INDEX") "0" }}
    allowACMEByPass: true
    {{ end }}

  websecure:
    address: ":443"

ping:
  entryPoint: web

log:
  level: DEBUG

api:
  dashboard: true
  insecure: false

providers:
  providersThrottleDuration: 1s
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
  nomad:
    endpoint:
      address: "http://nomad.service.consul:4646"
      token: "{{ key "nomad/traefik-token" }}"
    watch: true
    namespaces:
      - "nomad-ops"
      - "default"
  consulCatalog:
    endpoint:
        address: "consul.service.consul:8500"
    watch: true

certificatesResolvers:
{{ if eq (env "NOMAD_ALLOC_INDEX") "0" }}
  cert-prod:
    acme:
      email: trustos@gmail.com
      storage: /etc/traefik/acme-prod.json
      httpChallenge:
        entryPoint: web
  cert-stag:
    acme:
      email: trustos@gmail.com
      storage: /etc/traefik/acme-stag.json
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      httpChallenge:
        entryPoint: web
{{ else }}
  cert-prod:
    acme:
      email: "no-reply@example.com"
      storage: /etc/traefik/acme-prod.json
      httpChallenge: {}
  cert-stag:
    acme:
      email: "no-reply@example.com"
      storage: /etc/traefik/acme-stag.json
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      httpChallenge: {}
{{ end }}

EOF
        destination = "local/traefik.yaml"
        change_mode = "restart"
      }
      config {
        image = "traefik:v3.4.3"
        ports = ["http", "https"]
        mounts = [
          {
            type        = "bind"
            source      = "local/traefik.yaml"
            target      = "/etc/traefik/traefik.yaml"
            readonly    = true
          },
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik/acme-stag.json"
            target      = "/etc/traefik/acme-stag.json"
            readonly    = false
          },
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik/acme-prod.json"
            target      = "/etc/traefik/acme-prod.json"
            readonly    = false
          },
          {
            type        = "bind"
            source      = "/mnt/glusterfs/traefik/dynamic"
            target      = "/etc/traefik/dynamic"
            readonly    = false
          }
        ]
      }
      service {
        name = "traefik-${NOMAD_ALLOC_INDEX}"
        port = "http"
        tags = [
          "acme",
          "role=${NOMAD_ALLOC_INDEX}"
        ]
        check {
          type     = "http"
          path     = "/ping"
          interval = "10s"
          timeout  = "2s"
        }
        enable_tag_override = true
      }
      resources {
        cpu    = 384
        memory = 512
      }
    }


  }

  group "acme-watcher" {
    count = 1
    task "acme-follower-restart-watcher" {
      driver = "raw_exec"
      config {
        command = "bash"
        args = ["-c", <<EOT
ACME_DIR="/mnt/glusterfs/traefik"
ACME_FILE1="$ACME_DIR/acme-prod.json"
ACME_FILE2="$ACME_DIR/acme-stag.json"
DEBOUNCE_SECONDS=60
POLL_INTERVAL=10

if [ -f "$ACME_FILE1" ]; then
  LAST_HASH1=$(md5sum "$ACME_FILE1" | awk '{print $1}')
else
  LAST_HASH1=""
fi

if [ -f "$ACME_FILE2" ]; then
  LAST_HASH2=$(md5sum "$ACME_FILE2" | awk '{print $1}')
else
  LAST_HASH2=""
fi

while true; do
  CHANGED=0

  if [ -f "$ACME_FILE1" ]; then
    NEW_HASH1=$(md5sum "$ACME_FILE1" | awk '{print $1}')
    if [ "$LAST_HASH1" != "$NEW_HASH1" ]; then
      echo "$(date) - Detected change in $ACME_FILE1, restarting follower allocations..."
      LAST_HASH1="$NEW_HASH1"
      CHANGED=1
    fi
  else
    echo "$(date) - WARNING: $ACME_FILE1 does not exist!"
  fi

  if [ -f "$ACME_FILE2" ]; then
    NEW_HASH2=$(md5sum "$ACME_FILE2" | awk '{print $1}')
    if [ "$LAST_HASH2" != "$NEW_HASH2" ]; then
      echo "$(date) - Detected change in $ACME_FILE2, restarting follower allocations..."
      LAST_HASH2="$NEW_HASH2"
      CHANGED=1
    fi
  else
    echo "$(date) - WARNING: $ACME_FILE2 does not exist!"
  fi

  if [ $CHANGED -eq 1 ]; then
    echo "$(date) - Certificate change detected, waiting for files to stabilize..."

    # Wait for files to stabilize (not modified in the last 30 seconds)
    STABLE=0
    while [ $STABLE -eq 0 ]; do
      STABLE=1
      if [ -f "$ACME_FILE1" ] && [ $(find "$ACME_FILE1" -mmin -0.5 2>/dev/null | wc -l) -gt 0 ]; then
        echo "$(date) - $ACME_FILE1 still being modified, waiting..."
        STABLE=0
      fi
      if [ -f "$ACME_FILE2" ] && [ $(find "$ACME_FILE2" -mmin -0.5 2>/dev/null | wc -l) -gt 0 ]; then
        echo "$(date) - $ACME_FILE2 still being modified, waiting..."
        STABLE=0
      fi
      if [ $STABLE -eq 0 ]; then
        sleep 10
      fi
    done

    echo "$(date) - Files stabilized, proceeding with follower restarts..."
    NOMAD_ALLOCS_JSON=$(NOMAD_ADDR="http://nomad.service.consul:4646" NOMAD_TOKEN="${MGMT_TOKEN}" nomad job allocs -json --namespace=traefik traefik 2>&1)
    echo "NOMAD job allocs output:"
    echo "$NOMAD_ALLOCS_JSON"

    # Use Consul KV to determine the leader
    CONSUL_ADDR="consul.service.consul:8500"
    LEADER_KEY="traefik/leader"

    # Get current leader from Consul KV
    CURRENT_LEADER=$(curl -s "http://$CONSUL_ADDR/v1/kv/$LEADER_KEY?raw" 2>/dev/null || echo "")

    # Get all running allocations
    RUNNING_ALLOCS=$(echo "$NOMAD_ALLOCS_JSON" | jq -r '.[] | select(.TaskGroup=="traefik" and .ClientStatus=="running") | "\(.NodeName):\(.ID)"')
    RUNNING_NODES=$(echo "$RUNNING_ALLOCS" | cut -d: -f1 | sort)

    # Check if current leader is still running
    if [ -n "$CURRENT_LEADER" ] && echo "$RUNNING_NODES" | grep -q "^$CURRENT_LEADER$"; then
      LEADER_NODE="$CURRENT_LEADER"
      echo "Current leader $LEADER_NODE is still running"
    else
      # Select new leader (lexicographically first running node)
      LEADER_NODE=$(echo "$RUNNING_NODES" | head -n1)
      echo "Electing new leader: $LEADER_NODE"

      # Update leader in Consul KV
      curl -s -X PUT -d "$LEADER_NODE" "http://$CONSUL_ADDR/v1/kv/$LEADER_KEY" || echo "Failed to update leader in Consul"
    fi

    echo "Leader node: $LEADER_NODE"

    # Get follower allocation IDs (all nodes except the leader)
    ALLOC_IDS=$(echo "$NOMAD_ALLOCS_JSON" | jq -r --arg leader "$LEADER_NODE" '.[] | select(.TaskGroup=="traefik" and .ClientStatus=="running" and .NodeName != $leader) | .ID')

    if [ -n "$ALLOC_IDS" ]; then
      echo "Follower allocation IDs to restart:"
      echo "$ALLOC_IDS"
    else
      echo "No follower allocations found to restart (single-node setup)"
    fi

    for alloc_id in $ALLOC_IDS; do
      echo "Restarting follower allocation: $alloc_id"

      # Retry logic for allocation restart
      RETRY_COUNT=0
      MAX_RETRIES=3
      RESTART_SUCCESS=0

      while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ $RESTART_SUCCESS -eq 0 ]; do
        if [ $RETRY_COUNT -gt 0 ]; then
          echo "Retry attempt $RETRY_COUNT for allocation $alloc_id"
          sleep $((RETRY_COUNT * 5))  # Exponential backoff
        fi

        RESTART_OUTPUT=$(NOMAD_ADDR="http://nomad.service.consul:4646" NOMAD_TOKEN="${MGMT_TOKEN}" nomad alloc restart "$alloc_id" 2>&1)
        RESTART_EXIT_CODE=$?

        echo "Restart output for $alloc_id (attempt $((RETRY_COUNT + 1))):"
        echo "$RESTART_OUTPUT"

        if [ $RESTART_EXIT_CODE -eq 0 ]; then
          echo "Successfully restarted allocation $alloc_id"
          RESTART_SUCCESS=1
        else
          echo "ERROR: Failed to restart allocation $alloc_id (exit code $RESTART_EXIT_CODE)"
          RETRY_COUNT=$((RETRY_COUNT + 1))

          # Check if it's a transient error worth retrying
          if echo "$RESTART_OUTPUT" | grep -q -E "(connection refused|timeout|temporary failure)"; then
            echo "Detected transient error, will retry..."
          elif [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            echo "CRITICAL: Failed to restart allocation $alloc_id after $MAX_RETRIES attempts"
            # Log to system log for monitoring
            logger "TRAEFIK-WATCHER: Failed to restart allocation $alloc_id after $MAX_RETRIES attempts"
          fi
        fi
      done
    done

    echo "$(date) - Debouncing for $DEBOUNCE_SECONDS seconds..."
    sleep $DEBOUNCE_SECONDS
  else
    sleep $POLL_INTERVAL
  fi
done
EOT
        ]
      }

      template {
         data = <<EOH
     MGMT_TOKEN={{ key "nomad/bootstrap-token" }}
     EOH
         destination = "secrets/env"
         env         = true
       }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
