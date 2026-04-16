#!/usr/bin/env bash
# stop-openhands.sh — stop and remove the ashlr-openhands container.

set -uo pipefail

CONTAINER_NAME="ashlr-openhands"

log() { printf "\033[36m[stop]\033[0m %s\n" "$*"; }

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found" >&2; exit 1
fi

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  log "Stopping $CONTAINER_NAME ..."
  docker stop --time=15 "$CONTAINER_NAME" >/dev/null || true
  log "Removing $CONTAINER_NAME ..."
  docker rm "$CONTAINER_NAME" >/dev/null || true
  log "Done."
else
  log "$CONTAINER_NAME not found (already stopped)."
fi
