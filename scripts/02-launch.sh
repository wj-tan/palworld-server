#!/usr/bin/env bash
# Render cloud-init from config, then launch the instance. Retries through
# "Out of host capacity" (common for free ARM) and 429 rate-limits.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
resolve_ad
state_load network.env
[ -n "${SUBNET_ID:-}" ] || die "No subnet in state. Run scripts/01-network.sh first."

SHAPE="$(shape_for_arch)"
IMAGE_ID="$(latest_ubuntu_image)"
log "Shape=$SHAPE  OCPU=$OCPUS  MEM=${MEMORY_GB}GB  image=$IMAGE_ID"

# --- Render cloud-init from the template ---
RENDERED="$BUILD_DIR/cloud-init.rendered.sh"
if [ "$ARCH" = "arm" ]; then
  ARM_LINE='      ARM64_DEVICE: "generic"   # box64 target; try "adlink" if it crashes'
else
  ARM_LINE=''
fi
sed -e "s|@@TZ@@|$TZ|g" \
    -e "s|@@ARM64_DEVICE_LINE@@|$ARM_LINE|g" \
    -e "s|@@PLAYERS@@|$PLAYERS|g" \
    -e "s|@@SERVER_NAME@@|$SERVER_NAME|g" \
    -e "s|@@SERVER_DESCRIPTION@@|$SERVER_DESCRIPTION|g" \
    -e "s|@@ADMIN_PASSWORD@@|$ADMIN_PASSWORD|g" \
    -e "s|@@SERVER_PASSWORD@@|$SERVER_PASSWORD|g" \
    -e "s|@@RCON_PASSWORD@@|$RCON_PASSWORD|g" \
    -e "s|@@COMMUNITY_SERVER@@|$COMMUNITY_SERVER|g" \
    "$ROOT_DIR/cloud-init/cloud-init.tmpl.sh" > "$RENDERED"
log "Rendered cloud-init -> $RENDERED"

# --- Launch with retry ---
SSH_PUB="$(eval echo "$SSH_PUBLIC_KEY")"
[ -f "$SSH_PUB" ] || die "SSH public key not found: $SSH_PUB (generate with: ssh-keygen -t ed25519 -f \"${SSH_PRIVATE_KEY}\")"

INST_ID=""
for i in $(seq 1 240); do
  OUT="$(oci compute instance launch \
    -c "$COMPARTMENT_OCID" --availability-domain "$AVAILABILITY_DOMAIN" --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true \
    --display-name "$INSTANCE_NAME" --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --ssh-authorized-keys-file "$SSH_PUB" --user-data-file "$RENDERED" \
    --query 'data.id' --raw-output 2>&1)"
  if echo "$OUT" | grep -q "ocid1.instance"; then
    INST_ID="$OUT"; log "Launched: $INST_ID"; break
  elif echo "$OUT" | grep -qiE "Out of host capacity|TooManyRequests|429|timed out|InternalError|ServiceUnavailable"; then
    warn "attempt $i: transient/capacity error, retrying in 45s..."; sleep 45
  else
    die "Launch failed: $OUT"
  fi
done
[ -n "$INST_ID" ] || die "Gave up after many attempts (still no capacity)."

log "Waiting for RUNNING..."
oci compute instance get --instance-id "$INST_ID" --wait-for-state RUNNING >/dev/null 2>&1 || \
  until [ "$(oci compute instance get --instance-id "$INST_ID" --query 'data."lifecycle-state"' --raw-output)" = "RUNNING" ]; do sleep 8; done

PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INST_ID" --query 'data[0]."public-ip"' --raw-output)"
state_set instance.env INSTANCE_ID "$INST_ID"
state_set instance.env PUBLIC_IP "$PUBLIC_IP"

log "================================================================"
log " Instance RUNNING at $PUBLIC_IP"
log " Palworld will finish self-deploying in a few minutes"
log " (ARM/box64 first-boot download is slow — watch: scripts/manage.sh logs)"
log " Connect:  ${PUBLIC_IP}:8211   password: ${SERVER_PASSWORD:-<none>}"
log "================================================================"
