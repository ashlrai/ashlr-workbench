#!/bin/bash
# start-ashlrcode.sh — Launch ashlrcode with the workbench settings overlay.
#
# ashlrcode reads provider + MCP config from ~/.ashlrcode/settings.json by
# default. To avoid clobbering Mason's personal config, this script points
# ashlrcode at the workbench's own config dir via ASHLRCODE_CONFIG_DIR (if
# supported) while also exporting ASHLR_MCP_EXTRA as an advisory fallback.
#
# Usage:
#   ./scripts/start-ashlrcode.sh                 # interactive REPL
#   ./scripts/start-ashlrcode.sh "fix the bug"   # one-shot message
#   ./scripts/start-ashlrcode.sh --help          # ashlrcode help
#   ./scripts/start-ashlrcode.sh --continue      # resume last session

set -euo pipefail

WORKBENCH="/Users/masonwyatt/Desktop/ashlr-workbench"
WB_CONFIG_DIR="$WORKBENCH/agents/ashlrcode"
WB_SETTINGS="$WB_CONFIG_DIR/settings.json"

if [ ! -f "$WB_SETTINGS" ]; then
  echo "start-ashlrcode: missing workbench settings at $WB_SETTINGS" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Secrets: settings.json references ${XAI_API_KEY}, ${SUPABASE_ACCESS_TOKEN},
# ${SUPABASE_PROJECT_REF}. Source them from a gitignored .env if present.
# Search order:
#   1. $WORKBENCH/.env                  (workbench-local, gitignored)
#   2. ~/.ashlrcode/.env                (user-global)
# Existing env vars are NOT overwritten.
# ------------------------------------------------------------------
load_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}
load_env_file "$WORKBENCH/.env"
load_env_file "$HOME/.ashlrcode/.env"

# Last-resort fallback: pull XAI_API_KEY out of the user's global settings.json
# (works because the user's ~/.ashlrcode/settings.json embeds the key directly).
if [ -z "${XAI_API_KEY:-}" ] && [ -f "$HOME/.ashlrcode/settings.json" ]; then
  # shellcheck disable=SC2155
  export XAI_API_KEY="$(awk -F'"' '/"apiKey"[[:space:]]*:[[:space:]]*"xai-/ {print $4; exit}' "$HOME/.ashlrcode/settings.json" 2>/dev/null || true)"
fi

# Primary mechanism: tell ashlrcode to use the workbench config dir.
# (ashlrcode v2.1+ honors ASHLRCODE_CONFIG_DIR when set; falls back to ~/.ashlrcode.)
export ASHLRCODE_CONFIG_DIR="$WB_CONFIG_DIR"

# Advisory fallback: some ashlrcode builds read ASHLR_MCP_EXTRA as an extra
# MCP config path merged on top of ~/.ashlrcode/settings.json.
export ASHLR_MCP_EXTRA="$WB_SETTINGS"

# Session log (cross-agent trace).
# shellcheck source=lib/session-log.sh
. "$(dirname "$0")/lib/session-log.sh"
log_session_start ashlrcode "$PWD"
trap 'log_session_end ashlrcode "$PWD"' EXIT

# Run (don't exec) so the EXIT trap fires and writes session_end.
ashlrcode "$@"
exit $?
