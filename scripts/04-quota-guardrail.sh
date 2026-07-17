#!/usr/bin/env bash
# Create/update a compartment quota policy that HARD-CAPS the tenancy to the
# Always Free allowances. This is a guardrail: even a mistaken script or a stray
# console click cannot provision paid compute.
#
# Why this matters: on a Pay-As-You-Go account Oracle RAISES your service limits
# (e.g. A1 cores 2 -> 250, E5 cores 0 -> 83). Nothing then stops an expensive
# deployment. Quotas put the free-tier ceiling back, by policy.
#
# Verify with:  oci limits resource-availability get --service-name compute \
#                 --limit-name standard-a1-core-count -c <tenancy> --availability-domain <AD>
#               -> look at "effective-quota-value" (NOT `limits value list`, which
#                  shows the raw service limit and will still look large).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

QUOTA_NAME="always-free-guardrail"
STMT_FILE="$BUILD_DIR/quota-statements.json"

# NOTE: quota families differ per resource:
#   cores  -> compute-core     memory -> compute-memory     storage -> block-storage
# `standard-e2-micro-core-count` is deliberately NOT zeroed: VM.Standard.E2.1.Micro
# (2 instances) is itself Always Free.
cat > "$STMT_FILE" <<EOF
[
  "set compute-core quota standard-a1-core-count to ${OCPUS} in tenancy",
  "set compute-memory quota standard-a1-memory-count to ${MEMORY_GB} in tenancy",
  "set block-storage quota total-storage-gb to 200 in tenancy",
  "zero compute-core quota standard-e2-core-count in tenancy",
  "zero compute-core quota standard-e4-core-count in tenancy",
  "zero compute-core quota standard-e5-core-count in tenancy",
  "zero compute-core quota standard-e5t-lm-v2-core-count in tenancy",
  "zero compute-core quota standard-e6-core-count in tenancy",
  "zero compute-core quota standard-e6-ax-core-count in tenancy",
  "zero compute-core quota standard-e6-hm-ax-core-count in tenancy",
  "zero compute-core quota standard-a2-core-count in tenancy",
  "zero compute-core quota standard-a4-core-count in tenancy",
  "zero compute-core quota standard-a4-ax-core-count in tenancy",
  "zero compute-core quota standard-b1-core-count in tenancy",
  "zero compute-core quota standard-x12-ax-core-count in tenancy",
  "zero compute-core quota standard1-core-count in tenancy",
  "zero compute-core quota standard2-core-count in tenancy",
  "zero compute-core quota standard3-core-count in tenancy"
]
EOF

# The OCI CLI on Windows needs a native path for file:// arguments.
if command -v cygpath >/dev/null 2>&1; then
  STMT_URI="file://$(cygpath -m "$STMT_FILE")"
else
  STMT_URI="file://$STMT_FILE"
fi

EXISTING="$(oci limits quota list -c "$COMPARTMENT_OCID" --name "$QUOTA_NAME" --query 'data[0].id' --raw-output 2>/dev/null || true)"

if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
  log "Updating existing quota policy $QUOTA_NAME..."
  oci limits quota update --quota-id "$EXISTING" --statements "$STMT_URI" --force \
    --query 'data.{name:name,state:"lifecycle-state"}' --output json
else
  log "Creating quota policy $QUOTA_NAME..."
  oci limits quota create -c "$COMPARTMENT_OCID" --name "$QUOTA_NAME" \
    --description "Enforce Always Free: A1 capped at ${OCPUS} OCPU/${MEMORY_GB}GB, block storage 200GB, paid compute shapes zeroed (E2.1.Micro preserved)" \
    --statements "$STMT_URI" \
    --query 'data.{name:name,state:"lifecycle-state"}' --output json
fi

log "Effective quotas now:"
resolve_ad
for q in standard-a1-core-count standard-a1-memory-count standard-e5-core-count; do
  J="$(oci limits resource-availability get --service-name compute --limit-name "$q" \
        -c "$COMPARTMENT_OCID" --availability-domain "$AVAILABILITY_DOMAIN" --query 'data' --output json 2>/dev/null || true)"
  E="$(echo "$J" | grep -o '"effective-quota-value": *[0-9.]*' | grep -o '[0-9.]*$')"
  U="$(echo "$J" | grep -o '"used": *[0-9]*' | grep -o '[0-9]*$')"
  printf '  %-30s effective=%-8s used=%s\n' "$q" "${E:-<none>}" "${U:-?}"
done
log "Guardrail active. To intentionally allow paid resources, edit or delete this policy."
