#!/usr/bin/env bash
# Destroy the deployment. By default terminates the instance (and its boot
# volume). Pass --all to also delete the network (VCN/subnet/etc) and the
# backup bucket. Usage: scripts/teardown.sh [--all]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

printf '\033[0;31mThis terminates the instance'
[ "${1:-}" = "--all" ] && printf ' AND deletes the network + backup bucket'
printf '.\033[0m\n'
read -r -p "Type 'destroy' to confirm: " ans
[ "$ans" = "destroy" ] || die "Aborted."

state_load instance.env
if [ -n "${INSTANCE_ID:-}" ]; then
  log "Terminating instance (deleting boot volume)..."
  oci compute instance terminate --instance-id "$INSTANCE_ID" --preserve-boot-volume false --force >/dev/null || true
  until [ "$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)" = "TERMINATED" ]; do sleep 8; done
  log "Instance terminated."
  : > "$STATE_DIR/instance.env"
fi

if [ "${1:-}" = "--all" ]; then
  NS="$(oci os ns get --query 'data' --raw-output)"
  log "Deleting backup bucket contents + bucket..."
  oci os object bulk-delete --namespace "$NS" --bucket-name "$BACKUP_BUCKET" --force >/dev/null 2>&1 || true
  oci os bucket delete --namespace "$NS" --name "$BACKUP_BUCKET" --force >/dev/null 2>&1 || true

  state_load network.env
  if [ -n "${VCN_ID:-}" ]; then
    log "Deleting network (subnet, gateways, VCN)... this can take a minute."
    [ -n "${SUBNET_ID:-}" ] && oci network subnet delete --subnet-id "$SUBNET_ID" --force --wait-for-state TERMINATED >/dev/null 2>&1 || true
    for igw in $(oci network internet-gateway list -c "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" --query 'data[].id' --raw-output 2>/dev/null | tr -d '[],"'); do
      [ -n "$igw" ] && oci network internet-gateway delete --ig-id "$igw" --force --wait-for-state TERMINATED >/dev/null 2>&1 || true
    done
    oci network vcn delete --vcn-id "$VCN_ID" --force --wait-for-state TERMINATED >/dev/null 2>&1 || true
    : > "$STATE_DIR/network.env"
    log "Network deleted."
  fi
fi
log "Teardown complete."
