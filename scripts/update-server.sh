#!/usr/bin/env bash
# Update the Palworld server to the latest game build.
#
# Pulls the newest thijsvanloef/palworld-server-docker image and recreates the
# container. Because the compose file sets UPDATE_ON_BOOT=true, SteamCMD fetches
# the latest Palworld server build on boot. Save data lives on the ./data volume,
# which is preserved across the update.
#
# A fresh off-site backup is taken first (unless --no-backup). On ARM/box64 the
# SteamCMD verify step can fall back to a full ~5 GB re-download, so the wait can
# take 10-30+ minutes; the update keeps running on the server even if you stop
# waiting.
#
# Usage: scripts/update-server.sh [--no-backup] [--no-wait]
#   --no-backup  Skip the pre-update off-site backup (hourly local backups still apply).
#   --no-wait    Kick off the update and return immediately (watch: scripts/manage.sh logs).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
state_load instance.env
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state/instance.env. Launch one first."

NO_BACKUP=false; NO_WAIT=false
for a in "$@"; do
  case "$a" in
    --no-backup) NO_BACKUP=true ;;
    --no-wait)   NO_WAIT=true ;;
    -h|--help)   awk 'NR==1&&/^#!/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *)           die "Unknown option '$a' (see --help)" ;;
  esac
done

# --- Ensure the instance is running and refresh its (ephemeral) public IP ---
ST="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
[ "$ST" = "RUNNING" ] || die "Instance is $ST, not RUNNING. Start it first: scripts/manage.sh start"
PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
state_set instance.env PUBLIC_IP "$PUBLIC_IP"
log "Server at $PUBLIC_IP"

# --- Record the version we're on now (from the currently-running container) ---
BEFORE="$(server_ssh 'sudo docker logs palworld-server 2>&1 | grep -E "Game version is" | tail -1' 2>/dev/null || true)"
[ -n "$BEFORE" ] && log "Current build: ${BEFORE##*Game version is }"

# --- Take a fresh off-site backup before touching anything ---
if [ "$NO_BACKUP" = false ]; then
  log "Taking a fresh off-site backup before updating..."
  server_ssh 'if [ -x /home/ubuntu/palworld/offsite-backup.sh ]; then timeout 120 bash /home/ubuntu/palworld/offsite-backup.sh; else echo "(no offsite-backup.sh; relying on hourly local backups)"; fi'
else
  warn "Skipping pre-update backup (--no-backup). Hourly local backups still apply."
fi

# --- Pull the latest image and recreate the container ---
log "Pulling latest image and recreating the container..."
server_ssh 'cd /home/ubuntu/palworld && sudo docker compose pull && sudo docker compose up -d'
log "Container recreated. SteamCMD is fetching the latest build on boot."
log "On ARM/box64 the verify step may trigger a full ~5 GB re-download (slow, expected)."

# --- Wait for the server to come back healthy ---
if [ "$NO_WAIT" = true ]; then
  log "Not waiting (--no-wait). Watch progress with: scripts/manage.sh logs"
  exit 0
fi

log "Waiting for the server to become healthy (safe to Ctrl-C; the update keeps running)..."
last_health=""; last_bytes=""; stall=0; nudges=0
for i in $(seq 1 120); do   # up to ~60 min (30s * 120)
  H="$(server_ssh 'sudo docker inspect --format "{{.State.Health.Status}}" palworld-server 2>/dev/null' 2>/dev/null || echo unreachable)"
  if [ "$H" = "healthy" ]; then
    AFTER="$(server_ssh 'sudo docker logs palworld-server 2>&1 | grep -E "Game version is" | tail -1' 2>/dev/null || true)"
    log "Server is healthy. Now on build: ${AFTER##*Game version is }"
    exit 0
  fi

  # SteamCMD occasionally freezes mid-download under box64. Detect a stalled
  # download (byte count not advancing) and nudge it with a container restart,
  # which resumes from Steam's partial download. Capped so we never loop forever.
  bytes="$(server_ssh 'sudo docker logs --tail 40 palworld-server 2>&1 | grep -oE "downloading, progress: [0-9.]+ \([0-9]+" | tail -1 | grep -oE "[0-9]+$"' 2>/dev/null || true)"
  if [ -n "$bytes" ] && [ "$bytes" = "$last_bytes" ]; then stall=$((stall+1)); else stall=0; fi
  last_bytes="$bytes"
  if [ "$stall" -ge 6 ] && [ "$nudges" -lt 3 ]; then   # ~3 min without progress
    nudges=$((nudges+1))
    warn "Download stalled at ${bytes} bytes; restarting container to resume (nudge ${nudges}/3)."
    server_ssh 'cd /home/ubuntu/palworld && sudo docker compose restart' >/dev/null 2>&1 || true
    stall=0; last_bytes=""; sleep 20; continue
  fi

  # Log on change, and a heartbeat every ~5 min, so output stays readable.
  if [ "$H" != "$last_health" ] || [ $((i % 10)) -eq 0 ]; then
    log "  still updating (health=$H${bytes:+, ${bytes} bytes downloaded})"
    last_health="$H"
  fi
  sleep 30
done

warn "Server not healthy after ~60 min. Check logs: scripts/manage.sh logs"
exit 1
