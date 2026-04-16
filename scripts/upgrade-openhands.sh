#!/usr/bin/env bash
# upgrade-openhands.sh — one-command upgrade from OpenHands 0.38 to 1.6.x
#
# What this does:
#   1. Detects any running OpenHands container (default name `openhands-app`)
#      and prints its version.
#   2. Gracefully stops + removes it.
#   3. Backs up the old state dir `~/.openhands-state/` to a timestamped sibling.
#      OpenHands 1.x uses `~/.openhands/`. We copy (not move) the old state so
#      the 0.x install remains restorable.
#   4. Seeds `~/.openhands/` from the backup if it doesn't already exist, so
#      conversation history carries over where the schema is compatible.
#   5. Pulls the new image: ghcr.io/openhands/openhands:1.6.0
#      (Note: the GitHub org moved from `all-hands-ai` to `openhands` in the
#      1.x line. We use the canonical ghcr.io/openhands/openhands path.)
#   6. Prints next step.
#
# Idempotent: safe to re-run. If nothing is running, it still pulls the image
# and ensures the backup + state-seed steps have happened.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NEW="ghcr.io/openhands/openhands:1.6.0"
OLD_STATE="$HOME/.openhands-state"
NEW_STATE="$HOME/.openhands"
BACKUP_DIR="$HOME/.openhands-state.backup-$(date +%Y%m%d-%H%M%S)"

log() { printf "\033[36m[upgrade]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[upgrade]\033[0m %s\n" "$*"; }
err() { printf "\033[31m[upgrade]\033[0m %s\n" "$*" >&2; }

if ! command -v docker >/dev/null 2>&1; then
  err "Docker CLI not found on PATH. Install Docker Desktop and retry."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  err "Docker daemon is not running. Start Docker Desktop and retry."
  exit 1
fi

# 1. Detect running OpenHands container(s)
log "Scanning for running OpenHands containers..."
# Match any container whose image repo contains "openhands" (legacy all-hands-ai
# and the new openhands org both qualify). bash 3.2 compatible (no mapfile).
RUNNING_RAW="$(docker ps --format '{{.Names}}|{{.Image}}' | awk -F'|' 'tolower($2) ~ /openhands/{print $1"|"$2}')"

if [ -z "$RUNNING_RAW" ]; then
  log "No running OpenHands container found. Skipping stop step."
else
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    name="${row%%|*}"
    image="${row##*|}"
    log "Found: $name ($image)"
    log "Stopping $name (graceful, 30s timeout)..."
    docker stop --time=30 "$name" >/dev/null || warn "docker stop $name returned non-zero; continuing"
    log "Removing $name..."
    docker rm "$name" >/dev/null 2>&1 || true
  done <<< "$RUNNING_RAW"
fi

# 2. Back up old 0.x state dir
if [ -d "$OLD_STATE" ]; then
  log "Backing up $OLD_STATE -> $BACKUP_DIR"
  cp -a "$OLD_STATE" "$BACKUP_DIR"
  log "Backup complete."
else
  log "No $OLD_STATE to back up (skipping)."
fi

# 3. Seed new state dir from old if empty
if [ ! -d "$NEW_STATE" ]; then
  if [ -d "$OLD_STATE" ]; then
    log "Seeding $NEW_STATE from $OLD_STATE (V1 uses new path; see docs)."
    cp -a "$OLD_STATE" "$NEW_STATE"
  else
    log "Creating empty $NEW_STATE"
    mkdir -p "$NEW_STATE"
  fi
else
  log "$NEW_STATE already exists (not overwriting)."
fi

# 4. Pull new image
log "Pulling $IMAGE_NEW ..."
if ! docker pull "$IMAGE_NEW"; then
  err "Failed to pull $IMAGE_NEW"
  err "If you saw 'manifest unknown', the tag may have moved. Try:"
  err "  docker pull docker.openhands.dev/openhands/openhands:1.6"
  exit 1
fi

# 5. Summary
printf '\n\033[32m[upgrade] OpenHands 1.6.0 image is ready.\033[0m\n\n'
cat <<EOF
Old state backed up at: ${BACKUP_DIR:-(none — no old state to back up)}
New state dir:          $NEW_STATE
Image:                  $IMAGE_NEW

Next step:
  $REPO_ROOT/scripts/start-openhands.sh

EOF
