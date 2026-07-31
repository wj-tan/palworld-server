#!/usr/bin/env bash
# Load an existing Palworld world (e.g. a single-player save converted for a
# dedicated server) into the running server.
#
# Accepts a .zip, a .tar.gz/.tgz, or a directory. The save root is found by
# locating Level.sav inside it, so archives that wrap the files in a folder --
# or in a full SaveGames/0/<WorldID> tree -- work as-is.
#
# The files are installed into the world folder the server is already configured
# to load (DedicatedServerName in GameUserSettings.ini), so the world ID, server
# settings and off-site backup cron all keep working untouched.
#
# Safety: takes an in-game save + off-site backup + a local rollback tarball
# before stopping the container, and prints the exact rollback command at the end.
#
# Two files in a converted save are skipped by default:
#   WorldOption.sav  overrides PalWorldSettings.ini on a dedicated server, so
#                    importing it silently discards your config.env game settings.
#                    Pass --with-world-option if you do want the world's own settings.
#   LocalData.sav    single-player-only file; a dedicated server never reads it.
#
# Usage: scripts/import-save.sh <save.zip|save.tar.gz|dir> [options]
#   --with-world-option  Also import WorldOption.sav (world settings win over the server ini).
#   --keep-players       Keep player saves already on the server; import only the world.
#   --world <ID>         Target a specific world folder instead of the configured one.
#   --no-backup          Skip the pre-import off-site backup (rollback tarball is still made).
#   --yes                Don't ask for confirmation (for scripted use).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
state_load instance.env
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state/instance.env. Run scripts/init-state.sh, or launch one first."

SAVE_DIR_REMOTE="/home/ubuntu/palworld/data/Pal/Saved"
WORLDS_REMOTE="$SAVE_DIR_REMOTE/SaveGames/0"
GUS_REMOTE="$SAVE_DIR_REMOTE/Config/LinuxServer/GameUserSettings.ini"
ROLLBACK_REMOTE="/home/ubuntu/palworld/import-rollback"

SRC_ARG=""; WITH_WORLD_OPTION=false; KEEP_PLAYERS=false; NO_BACKUP=false; ASSUME_YES=false; WORLD_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-world-option) WITH_WORLD_OPTION=true ;;
    --keep-players)      KEEP_PLAYERS=true ;;
    --no-backup)         NO_BACKUP=true ;;
    --yes|-y)            ASSUME_YES=true ;;
    --world)             shift; WORLD_ID="${1:-}"; [ -n "$WORLD_ID" ] || die "--world needs a world ID" ;;
    -h|--help)           awk 'NR==1&&/^#!/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*)                  die "Unknown option '$1' (see --help)" ;;
    *)                   [ -z "$SRC_ARG" ] || die "Only one save path expected (got '$SRC_ARG' and '$1')"; SRC_ARG="$1" ;;
  esac
  shift
done
[ -n "$SRC_ARG" ] || die "No save given. Usage: scripts/import-save.sh <save.zip|save.tar.gz|dir> (see --help)"
[ -e "$SRC_ARG" ] || die "Save not found: $SRC_ARG"

# --- Stage the save locally so we can validate it before touching the server ---
STAGE="$(mktemp -d "$BUILD_DIR/import.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

case "$SRC_ARG" in
  *.zip)
    log "Extracting $(basename "$SRC_ARG")..."
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$SRC_ARG" -d "$STAGE"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$SRC_ARG" "$STAGE"
    else
      die "Need 'unzip' or 'python3' to read a .zip. Extract it yourself and pass the folder."
    fi ;;
  *.tar.gz|*.tgz)
    log "Extracting $(basename "$SRC_ARG")..."
    tar -xzf "$SRC_ARG" -C "$STAGE" ;;
  *)
    [ -d "$SRC_ARG" ] || die "Unsupported save '$SRC_ARG' (expected .zip, .tar.gz or a directory)."
    cp -r "$SRC_ARG/." "$STAGE/" ;;
esac

# --- Find the save root: the (shallowest) directory containing Level.sav ---
mapfile -t LEVELS < <(find "$STAGE" -type f -name 'Level.sav' -printf '%d %p\n' | sort -n | cut -d' ' -f2-)
[ "${#LEVELS[@]}" -gt 0 ] || die "No Level.sav found in '$SRC_ARG'. Is this a Palworld save?"
[ "${#LEVELS[@]}" -eq 1 ] || warn "Found ${#LEVELS[@]} Level.sav files; using the shallowest one."
SRC="$(dirname "${LEVELS[0]}")"

[ -f "$SRC/LevelMeta.sav" ] || warn "No LevelMeta.sav in the save (the server will regenerate it)."
PLAYER_COUNT=0
[ -d "$SRC/Players" ] && PLAYER_COUNT="$(find "$SRC/Players" -maxdepth 1 -type f -name '*.sav' | wc -l | tr -d ' ')"
[ "$PLAYER_COUNT" -gt 0 ] || warn "No player saves in the archive; players will start as new characters."

# --- Build the file list to import ---
IMPORT=(Level.sav)
[ -f "$SRC/LevelMeta.sav" ] && IMPORT+=(LevelMeta.sav)
{ [ "$KEEP_PLAYERS" = false ] && [ "$PLAYER_COUNT" -gt 0 ]; } && IMPORT+=(Players)
if [ "$WITH_WORLD_OPTION" = true ]; then
  [ -f "$SRC/WorldOption.sav" ] && IMPORT+=(WorldOption.sav) \
    || warn "--with-world-option given but the save has no WorldOption.sav."
fi

# --- Ensure the instance is running and refresh its (ephemeral) public IP ---
ST="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)"
[ "$ST" = "RUNNING" ] || die "Instance is $ST, not RUNNING. Start it first: scripts/manage.sh start"
PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)"
state_set instance.env PUBLIC_IP "$PUBLIC_IP"
log "Server at $PUBLIC_IP"

# --- Resolve the target world folder ---
if [ -z "$WORLD_ID" ]; then
  WORLD_ID="$(server_ssh "grep -oP '^DedicatedServerName=\K.*' '$GUS_REMOTE' 2>/dev/null | tr -d '\r'" || true)"
  if [ -z "$WORLD_ID" ]; then
    FOUND="$(server_ssh "ls '$WORLDS_REMOTE' 2>/dev/null | tr '\n' ' '" || true)"
    set -- $FOUND
    [ "$#" -le 1 ] || warn "$# world folders on the server; using the first ($1). Pass --world <ID> to pick another."
    WORLD_ID="${1:-}"
  fi
fi
[ -n "$WORLD_ID" ] || die "Could not resolve a world folder. Start the server once so it creates one, then re-run (or pass --world <ID>)."
WORLD_REMOTE="$WORLDS_REMOTE/$WORLD_ID"
server_ssh "[ -d '$WORLD_REMOTE' ]" \
  || die "World folder '$WORLD_ID' does not exist on the server. Start the server once to create it, or pass --world <ID>."
log "Target world: $WORLD_ID"

# --- Refuse to clobber an active session by surprise ---
ONLINE="$(server_ssh 'sudo docker exec palworld-server rcon-cli "ShowPlayers" 2>/dev/null | awk "NR>1&&NF{n++}END{print n+0}"' || echo 0)"
[ "$ONLINE" = "0" ] || warn "$ONLINE player(s) are online right now; they will be disconnected."

# --- Confirm ---
printf '\033[0;33mImporting %s -> world %s\033[0m\n' "$(basename "$SRC_ARG")" "$WORLD_ID"
printf '  files: %s\n' "${IMPORT[*]}"
[ "$KEEP_PLAYERS" = true ]       && printf '  keeping the player saves already on the server\n'
[ "$WITH_WORLD_OPTION" = false ] && printf '  WorldOption.sav skipped: PalWorldSettings.ini stays in control\n'
printf '\033[0;31mThis replaces the world currently on the server (a rollback tarball is made first).\033[0m\n'
if [ "$ASSUME_YES" = false ]; then
  read -r -p "Type 'import' to confirm: " ans
  [ "$ans" = "import" ] || die "Aborted."
fi

# --- Flush the live world to disk, then back it up ---
log "Flushing the live world to disk..."
server_ssh 'sudo docker exec palworld-server rcon-cli "Save" || true'
if [ "$NO_BACKUP" = false ]; then
  log "Taking a fresh off-site backup..."
  server_ssh 'if [ -x /home/ubuntu/palworld/offsite-backup.sh ]; then timeout 120 bash /home/ubuntu/palworld/offsite-backup.sh; else echo "(no offsite-backup.sh; relying on local backups)"; fi'
else
  warn "Skipping the off-site backup (--no-backup)."
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
ROLLBACK="$ROLLBACK_REMOTE/pre-import-$STAMP.tar.gz"
log "Writing rollback tarball to $ROLLBACK ..."
server_ssh "sudo mkdir -p '$ROLLBACK_REMOTE' && \
  sudo tar --exclude='*/backup/*' -czf '$ROLLBACK' -C '$SAVE_DIR_REMOTE' SaveGames && \
  ls -t '$ROLLBACK_REMOTE'/pre-import-*.tar.gz | tail -n +6 | xargs -r sudo rm -f"

# --- Swap in the new world (container down: the server rewrites Level.sav on exit) ---
log "Stopping the game container..."
server_ssh 'cd /home/ubuntu/palworld && sudo docker compose stop'

log "Uploading the save..."
tar -czf "$STAGE/payload.tar.gz" -C "$SRC" "${IMPORT[@]}"
server_scp "$STAGE/payload.tar.gz" /home/ubuntu/import-payload.tar.gz

log "Installing into $WORLD_ID ..."
RM_PLAYERS=""
[ "$KEEP_PLAYERS" = false ] && RM_PLAYERS="sudo rm -f '$WORLD_REMOTE'/Players/*.sav;"
KEEP_WO=""
# Any WorldOption.sav left behind would keep overriding PalWorldSettings.ini.
[ "$WITH_WORLD_OPTION" = false ] && KEEP_WO="sudo rm -f '$WORLD_REMOTE/WorldOption.sav';"
server_ssh "set -e
  sudo rm -f '$WORLD_REMOTE'/Level.sav '$WORLD_REMOTE'/LevelMeta.sav
  $RM_PLAYERS
  $KEEP_WO
  sudo tar -xzf /home/ubuntu/import-payload.tar.gz -C '$WORLD_REMOTE'
  rm -f /home/ubuntu/import-payload.tar.gz
  sudo chown -R 1000:1000 '$WORLD_REMOTE'
  sudo find '$WORLD_REMOTE' -maxdepth 2 -type d -exec chmod 775 {} +
  sudo find '$WORLD_REMOTE' -maxdepth 2 -type f -exec chmod 664 {} +"

log "Starting the game container..."
server_ssh 'cd /home/ubuntu/palworld && sudo docker compose start'

# --- Wait for health, then sanity-check the boot log ---
# The restart re-runs SteamCMD (UPDATE_ON_BOOT), so a boot that picks up a new
# Palworld build takes far longer than a plain restart -- allow for it.
log "Waiting for the server to become healthy (safe to Ctrl-C; the world is already installed)..."
for i in $(seq 1 80); do   # up to ~20 min
  H="$(server_ssh 'sudo docker inspect --format "{{.State.Health.Status}}" palworld-server 2>/dev/null' 2>/dev/null || echo unreachable)"
  if [ "$H" = "healthy" ]; then
    log "Server is healthy."
    break
  fi
  [ $((i % 4)) -eq 0 ] && log "  still starting (health=$H)"
  sleep 15
done
[ "${H:-}" = "healthy" ] || warn "Server not healthy yet. Watch it with: scripts/manage.sh logs"

BAD="$(server_ssh 'sudo docker logs --tail 300 palworld-server 2>&1 | grep -iE "corrupt|failed to load|Fatal error" | grep -viE "S_API|sentry|minidump" | tail -5' || true)"
[ -z "$BAD" ] || warn "Suspicious lines in the boot log:"$'\n'"$BAD"

log "Imported. Connect via direct connect to ${PUBLIC_IP}:8211"
log "Join and confirm the world looks right. To roll back:"
printf '  scripts/manage.sh ssh\n'
printf '  cd ~/palworld && sudo docker compose stop\n'
printf '  sudo tar -xzf %s -C %s\n' "$ROLLBACK" "$SAVE_DIR_REMOTE"
printf '  sudo chown -R 1000:1000 %s/SaveGames && sudo docker compose start\n' "$SAVE_DIR_REMOTE"
