#!/usr/bin/env bash
# Set up off-site backups: create an Object Storage bucket with a retention
# lifecycle policy, a write-only pre-authenticated request (PAR), and a cron
# job on the server that uploads compressed save snapshots. Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
state_load instance.env
[ -n "${PUBLIC_IP:-}" ] || die "No running instance. Launch first."

NS="$(oci os ns get --query 'data' --raw-output)"
REGION="$OCI_REGION"
log "Namespace: $NS"

# --- Bucket ---
if ! oci os bucket get --namespace "$NS" --name "$BACKUP_BUCKET" >/dev/null 2>&1; then
  log "Creating bucket $BACKUP_BUCKET..."
  oci os bucket create -c "$COMPARTMENT_OCID" --namespace "$NS" --name "$BACKUP_BUCKET" \
    --storage-tier Standard --public-access-type NoPublicAccess >/dev/null
else
  log "Bucket $BACKUP_BUCKET already exists."
fi

# --- IAM service policy required for lifecycle (create if missing) ---
if ! oci iam policy list -c "$COMPARTMENT_OCID" --query 'data[?name==`palworld-objectstorage-lifecycle`].name' --raw-output | grep -q palworld; then
  log "Creating Object Storage service policy for lifecycle..."
  oci iam policy create -c "$COMPARTMENT_OCID" --name "palworld-objectstorage-lifecycle" \
    --description "Allow Object Storage service to manage objects for lifecycle" \
    --statements "[\"Allow service objectstorage-${REGION} to manage object-family in tenancy where target.bucket.name='${BACKUP_BUCKET}'\"]" >/dev/null || warn "policy create skipped/failed (may already exist)"
fi

# --- Lifecycle policy: auto-delete backups older than N days ---
log "Setting lifecycle retention: ${BACKUP_RETENTION_DAYS} days..."
for i in 1 2 3 4 5; do
  if oci os object-lifecycle-policy put --namespace "$NS" --bucket-name "$BACKUP_BUCKET" --force \
      --items "[{\"name\":\"expire-old-backups\",\"action\":\"DELETE\",\"timeAmount\":${BACKUP_RETENTION_DAYS},\"timeUnit\":\"DAYS\",\"isEnabled\":true,\"target\":\"objects\"}]" >/dev/null 2>&1; then
    break; else warn "lifecycle not ready (policy propagating), retry $i..."; sleep 15; fi
done

# --- Write-only PAR (1 year) ---
EXPIRY="$(python -c "import datetime;print((datetime.datetime.utcnow()+datetime.timedelta(days=365)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
PAR_URI="$(oci os preauth-request create --namespace "$NS" --bucket-name "$BACKUP_BUCKET" \
  --name "palworld-backup-upload-$(date +%s)" --access-type AnyObjectWrite --time-expires "$EXPIRY" \
  --query 'data."access-uri"' --raw-output)"
PAR_URL="https://objectstorage.${REGION}.oraclecloud.com${PAR_URI}"
state_set instance.env PAR_URL "$PAR_URL"
state_set instance.env PAR_EXPIRES "$EXPIRY"
log "PAR created (expires $EXPIRY)."

# --- Install upload script + cron on the server ---
log "Installing backup script + cron on the server..."
server_ssh "cat > /home/ubuntu/palworld/offsite-backup.sh" <<EOF
#!/bin/bash
set -euo pipefail
SAVE_DIR="/home/ubuntu/palworld/data/Pal/Saved/SaveGames"
PAR_BASE="${PAR_URL}"
STAMP=\$(date -u +%Y%m%d-%H%M%S)
OBJECT="palworld-save_\$(hostname)_\${STAMP}.tar.gz"
TMP="/tmp/\${OBJECT}"
tar --exclude="*/backup/*" -czf "\$TMP" -C "\$(dirname "\$SAVE_DIR")" "\$(basename "\$SAVE_DIR")"
CODE=\$(curl -s -o /dev/null -w "%{http_code}" -T "\$TMP" "\${PAR_BASE}\${OBJECT}")
rm -f "\$TMP"
[ "\$CODE" = "200" ] && echo "\$(date -u +%FT%TZ) OK \${OBJECT}" || { echo "\$(date -u +%FT%TZ) FAIL http=\${CODE}" >&2; exit 1; }
EOF
server_ssh "chmod +x /home/ubuntu/palworld/offsite-backup.sh && \
  ( crontab -l 2>/dev/null | grep -v offsite-backup.sh; echo '${BACKUP_CRON} /home/ubuntu/palworld/offsite-backup.sh >> /home/ubuntu/palworld/offsite-backup.log 2>&1' ) | crontab - && \
  /home/ubuntu/palworld/offsite-backup.sh"

log "Off-site backups configured. First backup uploaded."
log "Verify: oci os object list --namespace $NS --bucket-name $BACKUP_BUCKET --output table"
