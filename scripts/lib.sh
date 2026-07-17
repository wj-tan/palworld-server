#!/usr/bin/env bash
# Shared helpers for the Palworld-on-OCI scripts. Sourced by every script.
set -euo pipefail

# --- Resolve project root (this file lives in <root>/scripts) ---
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"
STATE_DIR="$ROOT_DIR/state"
BUILD_DIR="$ROOT_DIR/build"
mkdir -p "$STATE_DIR" "$BUILD_DIR"

# --- Make the OCI CLI reachable + quiet its key-permission warning ---
# (Python Scripts dir on Windows, plus common *nix locations. $HOME-based so it
#  doesn't depend on $USER being exported.)
for _py in "$HOME"/AppData/Local/Programs/Python/Python*/Scripts; do
  [ -d "$_py" ] && PATH="$PATH:$_py"
done
export PATH="$PATH:$HOME/.local/bin"
export SUPPRESS_LABEL_WARNING=True

log()  { printf '\033[0;36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Load config.env ---
load_config() {
  [ -f "$ROOT_DIR/config.env" ] || die "config.env not found. Copy config.env.example to config.env and edit it."
  # shellcheck disable=SC1090
  source "$ROOT_DIR/config.env"
  command -v oci >/dev/null 2>&1 || die "oci CLI not found on PATH. Install with: pip install oci-cli"
  # Compartment defaults to the tenancy (root).
  if [ -z "${COMPARTMENT_OCID:-}" ]; then
    COMPARTMENT_OCID="$(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null || true)"
    [ -n "$COMPARTMENT_OCID" ] || COMPARTMENT_OCID="$(grep -E '^tenancy' "$HOME/.oci/config" | head -1 | cut -d= -f2 | tr -d ' ')"
  fi
  [ -n "${COMPARTMENT_OCID:-}" ] || die "Could not resolve COMPARTMENT_OCID."
}

# --- Auto-detect the first availability domain if not set ---
resolve_ad() {
  if [ -z "${AVAILABILITY_DOMAIN:-}" ]; then
    AVAILABILITY_DOMAIN="$(oci iam availability-domain list -c "$COMPARTMENT_OCID" --query 'data[0].name' --raw-output)"
    log "Auto-detected availability domain: $AVAILABILITY_DOMAIN"
  fi
}

# --- Map ARCH -> shape ---
shape_for_arch() {
  case "${ARCH:-arm}" in
    arm) echo "VM.Standard.A1.Flex" ;;
    x86) echo "VM.Standard.E5.Flex" ;;
    *)   die "ARCH must be 'arm' or 'x86' (got '$ARCH')" ;;
  esac
}

# --- Latest Ubuntu 22.04 image OCID for the current shape ---
latest_ubuntu_image() {
  local shape; shape="$(shape_for_arch)"
  oci compute image list -c "$COMPARTMENT_OCID" \
    --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
    --shape "$shape" --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output
}

# --- state/*.env read/write helpers ---
state_set() { # state_set <file> <KEY> <VALUE>
  local f="$STATE_DIR/$1"; local k="$2"; local v="$3"
  touch "$f"; grep -v "^${k}=" "$f" > "$f.tmp" 2>/dev/null || true
  echo "${k}=\"${v}\"" >> "$f.tmp"; mv "$f.tmp" "$f"
}
state_load() { # state_load <file>
  local f="$STATE_DIR/$1"; [ -f "$f" ] && source "$f" || true
}

# --- SSH/SCP wrappers to the current instance ---
ssh_key() { eval echo "${SSH_PRIVATE_KEY}"; }
server_ssh() { # server_ssh "<remote command>"
  state_load instance.env
  [ -n "${PUBLIC_IP:-}" ] || die "No PUBLIC_IP in state/instance.env. Launch the instance first."
  ssh -i "$(ssh_key)" -o StrictHostKeyChecking=no -o ConnectTimeout=20 "ubuntu@${PUBLIC_IP}" "$@"
}
server_scp() { # server_scp <local> <remote>
  state_load instance.env
  scp -i "$(ssh_key)" -o StrictHostKeyChecking=no "$1" "ubuntu@${PUBLIC_IP}:$2"
}
