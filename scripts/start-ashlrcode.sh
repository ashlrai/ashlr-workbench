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

# shellcheck source=lib/config.sh
. "$(dirname "$0")/lib/config.sh"
# shellcheck source=lib/llm-router.sh
. "$(dirname "$0")/lib/llm-router.sh"
# shellcheck source=lib/llm-metrics.sh
[ -f "$(dirname "$0")/lib/llm-metrics.sh" ] && . "$(dirname "$0")/lib/llm-metrics.sh" && llm_metrics_inject_hook "ashlrcode"
# shellcheck source=lib/agent-lifecycle.sh
. "$(dirname "$0")/lib/agent-lifecycle.sh"
WB_CONFIG_DIR="$WORKBENCH/agents/ashlrcode"
WB_SETTINGS="$WB_CONFIG_DIR/settings.json"

if [ ! -f "$WB_SETTINGS" ]; then
  echo "start-ashlrcode: missing workbench settings at $WB_SETTINGS" >&2
  exit 1
fi

# ------------------------------------------------------------------
# MCP config pre-launch validation gate
# Validates MCP server configs before launching so misconfigurations
# are surfaced early rather than causing silent MCP startup failures.
# Set ASHLR_MCP_GATE_STRICT=1 to abort launch on validation errors.
# ------------------------------------------------------------------
# shellcheck source=lib/config-schema-registry.sh
. "$(dirname "$0")/lib/config-schema-registry.sh"
# shellcheck source=lib/mcp-prelaunch-validator.sh
. "$(dirname "$0")/lib/mcp-prelaunch-validator.sh"
_MCP_GATE_STRICT="${ASHLR_MCP_GATE_STRICT:-0}"
# Step 1: schema + config validation (existing gate)
if [ "$_MCP_GATE_STRICT" = "1" ]; then
  mcp_prelaunch_gate ashlrcode --abort-on-error || {
    echo "start-ashlrcode: MCP config validation failed (ASHLR_MCP_GATE_STRICT=1)" >&2
    exit 1
  }
else
  mcp_prelaunch_gate ashlrcode
fi
# Step 2: liveness probe + schema drift detection (new gate)
if [ "$_MCP_GATE_STRICT" = "1" ]; then
  mcp_prelaunch_run ashlrcode || {
    echo "start-ashlrcode: MCP liveness gate failed (ASHLR_MCP_GATE_STRICT=1)" >&2
    exit 1
  }
else
  mcp_prelaunch_run ashlrcode || true
fi
# Step 3: circuit-breaker health probe — detect failures before agent needs MCPs
# shellcheck source=lib/mcp-health-probe.sh
. "$(dirname "$0")/lib/mcp-health-probe.sh"
mcp_prelaunch_gate_with_circuit || true

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

# LLM router: probe all endpoints, select best for ashlrcode, gracefully degrade.
llm_router_init
llm_router_select ashlrcode

# Primary mechanism: tell ashlrcode to use the workbench config dir.
# (ashlrcode v2.1+ honors ASHLRCODE_CONFIG_DIR when set; falls back to ~/.ashlrcode.)
export ASHLRCODE_CONFIG_DIR="$WB_CONFIG_DIR"

# Advisory fallback: some ashlrcode builds read ASHLR_MCP_EXTRA as an extra
# MCP config path merged on top of ~/.ashlrcode/settings.json.
export ASHLR_MCP_EXTRA="$WB_SETTINGS"

# Session log (cross-agent trace).
# shellcheck source=lib/session-log.sh
. "$(dirname "$0")/lib/session-log.sh"
# shellcheck source=lib/session-events.sh
. "$(dirname "$0")/lib/session-events.sh"
# shellcheck source=lib/session-replay-log.sh
. "$(dirname "$0")/lib/session-replay-log.sh"
log_session_start ashlrcode "$PWD"

# Derive MCP count from workbench settings.json
_SE_AC_MCP=0
if command -v python3 >/dev/null 2>&1 && [ -f "$WB_SETTINGS" ]; then
  _SE_AC_MCP="$(python3 -c "
import json, sys
try:
    s = json.load(open('$WB_SETTINGS'))
    mcp = s.get('mcpServers', {})
    print(len(mcp))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
fi

_SE_AC_START="$(date +%s)"
on_agent_start "ashlrcode" "$$" "${AC_MODEL:-${LLM_PRIMARY:-unknown}}" "$_SE_AC_MCP"
replay_session_init "ashlrcode" "${AC_MODEL:-${LLM_PRIMARY:-unknown}}" "$_SE_AC_MCP" "$PWD"
# Register with lifecycle manager. NOTE: we intentionally do NOT call
# agent_lifecycle_install_traps here — it would install its own `trap … EXIT`
# which the script's combined EXIT trap below would silently overwrite (so
# lifecycle cleanup would never run). Instead we install ONE EXIT trap that
# performs session cleanup AND agent_lifecycle_cleanup, plus a matching INT
# trap so Ctrl-C is handled identically. agent_lifecycle_cleanup is
# idempotent (it only signals still-alive PIDs), so the INT→EXIT double call
# is harmless.
agent_lifecycle_register "ashlrcode" "$$"
trap '
  _SE_AC_RC=$?
  _SE_AC_DUR=$(( $(date +%s) - _SE_AC_START ))
  if [ "$_SE_AC_RC" -ne 0 ]; then
    on_agent_error "ashlrcode" "$_SE_AC_RC" "exit code $_SE_AC_RC"
    on_session_end "ashlrcode" "$_SE_AC_DUR" "error"
    replay_session_end "ashlrcode" "$_SE_AC_DUR" "error"
  else
    on_session_end "ashlrcode" "$_SE_AC_DUR" "ok"
    replay_session_end "ashlrcode" "$_SE_AC_DUR" "ok"
  fi
  log_session_end ashlrcode "$PWD"
  agent_lifecycle_cleanup
' EXIT
trap 'exit 130' INT

# ------------------------------------------------------------------
# MCP Capability Negotiation — discover live tool surface at startup.
# Probes all 10 MCP servers, emits per-agent capability matrix to
# $WORKBENCH/.cache/mcp-capabilities-ashlrcode-<timestamp>.json.
# Runs with --quiet so it does not clutter interactive output.
# Non-fatal: errors are suppressed so the agent always starts.
# ------------------------------------------------------------------
_MCN_LIB="$(dirname "$0")/lib/mcp-capability-negotiation.sh"
if [ -f "$_MCN_LIB" ]; then
  # shellcheck source=lib/mcp-capability-negotiation.sh
  . "$_MCN_LIB"
  if declare -f mcp_cap_run_discovery >/dev/null 2>&1; then
    mcp_cap_run_discovery ashlrcode --quiet 2>/dev/null || true
  fi
fi

# Run (don't exec) so the EXIT trap fires and writes session_end.
ashlrcode "$@"
exit $?
