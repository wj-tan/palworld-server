#!/usr/bin/env bash
# Create (or reuse) the VCN, internet gateway, route table, security list and
# subnet for the Palworld server. Idempotent: safe to re-run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

log "Looking for existing VCN '$VCN_NAME'..."
VCN_ID="$(oci network vcn list -c "$COMPARTMENT_OCID" --display-name "$VCN_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)"

if [ -z "$VCN_ID" ] || [ "$VCN_ID" = "null" ]; then
  log "Creating VCN..."
  read -r VCN_ID RT_ID SL_ID <<<"$(oci network vcn create -c "$COMPARTMENT_OCID" \
    --display-name "$VCN_NAME" --cidr-blocks "[\"$VCN_CIDR\"]" --dns-label "palworld" \
    --wait-for-state AVAILABLE \
    --query 'data.[id,"default-route-table-id","default-security-list-id"]' --raw-output \
    | tr -d '[],"' )"

  log "Creating internet gateway..."
  IGW_ID="$(oci network internet-gateway create -c "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
    --is-enabled true --display-name "palworld-igw" --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"

  log "Routing 0.0.0.0/0 -> internet gateway..."
  oci network route-table update --rt-id "$RT_ID" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" \
    >/dev/null

  log "Opening ports (SSH 22, Palworld UDP 8211, query TCP 27015)..."
  oci network security-list update --security-list-id "$SL_ID" --force \
    --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' \
    --ingress-security-rules '[
      {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}},"description":"SSH"},
      {"source":"0.0.0.0/0","protocol":"17","isStateless":false,"udpOptions":{"destinationPortRange":{"min":8211,"max":8211}},"description":"Palworld game"},
      {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":27015,"max":27015}},"description":"Palworld query"}
    ]' >/dev/null

  log "Creating public subnet..."
  SUBNET_ID="$(oci network subnet create -c "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
    --display-name "palworld-subnet" --cidr-block "$SUBNET_CIDR" \
    --route-table-id "$RT_ID" --security-list-ids "[\"$SL_ID\"]" --dns-label "palsub" \
    --prohibit-public-ip-on-vnic false --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"
else
  log "Reusing existing VCN: $VCN_ID"
  SUBNET_ID="$(oci network subnet list -c "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
    --query 'data[0].id' --raw-output)"
fi

state_set network.env VCN_ID "$VCN_ID"
state_set network.env SUBNET_ID "$SUBNET_ID"
log "Network ready. Subnet: $SUBNET_ID"
log "Saved to state/network.env"
