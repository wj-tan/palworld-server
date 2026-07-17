#!/usr/bin/env bash
# Day-to-day operations for the running server.
# Usage: scripts/manage.sh <command>
#   status   - instance state + container health + public IP
#   ip       - print the current public IP (refreshes from OCI)
#   start    - start (boot) the OCI instance
#   stop     - graceful stop of the OCI instance (saves credit; keeps disk)
#   ssh      - open an interactive SSH session to the instance
#   logs     - tail the Palworld container logs
#   restart  - restart the Palworld container (not the whole VM)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
state_load instance.env
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state/instance.env. Launch one first."

cmd="${1:-status}"
case "$cmd" in
  status)
    ST="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
    log "Instance: $ST"
    if [ "$ST" = "RUNNING" ]; then
      PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
      state_set instance.env PUBLIC_IP "$PUBLIC_IP"
      log "Public IP: $PUBLIC_IP"
      server_ssh 'sudo docker inspect --format "container: {{.State.Health.Status}}" palworld-server 2>/dev/null || echo "container: (not found)"' || true
    fi
    ;;
  ip)
    PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
    state_set instance.env PUBLIC_IP "$PUBLIC_IP"; echo "$PUBLIC_IP" ;;
  start)
    log "Starting instance..."; oci compute instance action --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
    PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
    state_set instance.env PUBLIC_IP "$PUBLIC_IP"; log "Running at $PUBLIC_IP (IP may have changed)." ;;
  stop)
    log "Gracefully stopping instance..."; oci compute instance action --instance-id "$INSTANCE_ID" --action SOFTSTOP --wait-for-state STOPPED >/dev/null
    log "Stopped. Compute billing halted (boot volume retained)." ;;
  ssh)
    exec ssh -i "$(ssh_key)" -o StrictHostKeyChecking=no "ubuntu@${PUBLIC_IP}" ;;
  logs)
    server_ssh 'sudo docker logs -f --tail 40 palworld-server' ;;
  restart)
    server_ssh 'cd /home/ubuntu/palworld && sudo docker compose restart'; log "Container restarted." ;;
  *)
    die "Unknown command '$cmd'. See header of this script for usage." ;;
esac
