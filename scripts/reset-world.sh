#!/usr/bin/env bash
# Wipe all save data so the server generates a brand-new world on next start.
# Keeps the instance, IP, game install and settings. Optionally purges off-site
# backups too.  Usage: scripts/reset-world.sh [--purge-offsite]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
state_load instance.env
[ -n "${PUBLIC_IP:-}" ] || die "No running instance."

printf '\033[0;31mThis permanently deletes the world + all character saves.\033[0m\n'
read -r -p "Type 'reset' to confirm: " ans
[ "$ans" = "reset" ] || die "Aborted."

log "Stopping container..."
server_ssh 'cd /home/ubuntu/palworld && sudo docker compose stop'

log "Deleting save data..."
server_ssh 'sudo rm -rf /home/ubuntu/palworld/data/Pal/Saved/SaveGames /home/ubuntu/palworld/data/backups/*'

if [ "${1:-}" = "--purge-offsite" ]; then
  NS="$(oci os ns get --query 'data' --raw-output)"
  log "Purging off-site backups in $BACKUP_BUCKET..."
  oci os object bulk-delete --namespace "$NS" --bucket-name "$BACKUP_BUCKET" --force >/dev/null 2>&1 || warn "nothing to purge / bucket empty"
fi

log "Starting container (fresh world)..."
server_ssh 'cd /home/ubuntu/palworld && sudo docker compose start'
log "Done. A new world generates on first join. Server: ${PUBLIC_IP}:8211"
