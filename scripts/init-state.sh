#!/usr/bin/env bash
# Rebuild state/*.env from what already exists in OCI.
#
# Use this when you have a running server but not the state files - a fresh
# clone, a second machine, or a deleted state/ directory. state/ is gitignored,
# so it never travels with the repo.
#
# Usage: scripts/init-state.sh [--instance-id <ocid>]
#   --instance-id   skip discovery and use this instance (for when the display
#                   name no longer matches INSTANCE_NAME in config.env)
#
# Idempotent: safe to re-run. Only rewrites the keys it can resolve.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Parse arguments before load_config, so --help works without OCI configured.
INSTANCE_ID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --instance-id) INSTANCE_ID_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[ -z "$INSTANCE_ID_ARG" ] || case "$INSTANCE_ID_ARG" in
  ocid1.instance.*) ;;
  *) die "--instance-id expects an instance OCID (ocid1.instance...), got: $INSTANCE_ID_ARG" ;;
esac

load_config

if cmp -s "$ROOT_DIR/config.env" "$ROOT_DIR/config.env.example"; then
  warn "config.env is still an unedited copy of config.env.example."
  warn "Discovery uses INSTANCE_NAME and VCN_NAME from it, so edit it first if your server differs."
fi

# --- Instance ------------------------------------------------------------
if [ -n "$INSTANCE_ID_ARG" ]; then
  INSTANCE_ID="$INSTANCE_ID_ARG"
  oci compute instance get --instance-id "$INSTANCE_ID" --query 'data.id' --raw-output >/dev/null 2>&1 \
    || die "No instance found with OCID: $INSTANCE_ID"
  log "Using instance from --instance-id."
else
  log "Looking for instance '$INSTANCE_NAME' in the compartment..."
  # TERMINATED instances linger in the list API for a while; ignore them.
  mapfile -t FOUND < <(oci compute instance list -c "$COMPARTMENT_OCID" \
    --display-name "$INSTANCE_NAME" --all \
    --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].id' \
    --raw-output 2>/dev/null | tr -d '[]", ' | sed '/^$/d')

  case "${#FOUND[@]}" in
    0) die "No live instance named '$INSTANCE_NAME'. Check INSTANCE_NAME in config.env, or pass --instance-id <ocid>." ;;
    1) INSTANCE_ID="${FOUND[0]}" ;;
    *)
      warn "Found ${#FOUND[@]} live instances named '$INSTANCE_NAME':"
      for id in "${FOUND[@]}"; do
        warn "  $id  ($(oci compute instance get --instance-id "$id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo '?'))"
      done
      die "Ambiguous. Re-run with --instance-id <ocid>."
      ;;
  esac
fi

STATE="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
state_set instance.env INSTANCE_ID "$INSTANCE_ID"
log "INSTANCE_ID=$INSTANCE_ID ($STATE)"

if [ "$STATE" = "RUNNING" ]; then
  PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
    --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
  if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
    state_set instance.env PUBLIC_IP "$PUBLIC_IP"
    log "PUBLIC_IP=$PUBLIC_IP"
  else
    warn "Instance is RUNNING but has no public IP on its first VNIC."
  fi
else
  log "Instance is $STATE, so no public IP to record. 'manage.sh start' will fetch one."
fi

# --- Network (only needed by 02-launch.sh and teardown.sh --all) ----------
log "Looking for VCN '$VCN_NAME'..."
VCN_ID="$(oci network vcn list -c "$COMPARTMENT_OCID" --display-name "$VCN_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)"

if [ -n "$VCN_ID" ] && [ "$VCN_ID" != "null" ]; then
  SUBNET_ID="$(oci network subnet list -c "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
    --query 'data[0].id' --raw-output 2>/dev/null || true)"
  state_set network.env VCN_ID "$VCN_ID"
  log "VCN_ID=$VCN_ID"
  if [ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "null" ]; then
    state_set network.env SUBNET_ID "$SUBNET_ID"
    log "SUBNET_ID=$SUBNET_ID"
  else
    warn "VCN found but it has no subnet. Re-run scripts/01-network.sh if you need one."
  fi
else
  warn "No VCN named '$VCN_NAME'. Only 02-launch.sh and 'teardown.sh --all' need it, so this is fine for day-to-day use."
fi

# --- What this script cannot recover -------------------------------------
KEY="$(ssh_key)"
echo
log "================================================================"
log " State written to state/instance.env and state/network.env"
log "================================================================"
if [ -f "$KEY" ]; then
  log "SSH key found: $KEY"
  log "Next: scripts/manage.sh status"
else
  warn "SSH private key NOT found: $KEY"
  warn "It cannot be recovered from OCI - copy it from the machine that launched"
  warn "the server, or add a new public key to the instance's authorized_keys."
  warn "Without it these still work:  manage.sh ip | start | stop"
  warn "and these do not:             manage.sh ssh | logs | restart,"
  warn "                              import-save.sh, update-server.sh"
fi

# Off-site backup state is not recoverable either: the PAR write token is only
# returned by the API at creation time.
state_load instance.env
if [ -z "${PAR_URL:-}" ]; then
  log "No off-site backup PAR in state. Re-run scripts/03-backup-setup.sh to create one."
fi
