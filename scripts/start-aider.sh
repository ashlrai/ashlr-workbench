#!/bin/bash
# start-aider.sh — Launch Aider with the workbench config against LM Studio.
#
# Usage:
#   ./scripts/start-aider.sh                      # run in cwd
#   ./scripts/start-aider.sh /path/to/repo        # run in that repo
#   ./scripts/start-aider.sh . --model openai/qwen3-235b-a22b-thinking-2507
#                                                 # pass extra args after the dir
#
# Contract: first arg is the project directory (default = pwd). Anything after
# is forwarded to aider verbatim.

set -euo pipefail

# shellcheck source=lib/config.sh
. "$(dirname "$0")/lib/config.sh"
# shellcheck source=lib/llm-router.sh
. "$(dirname "$0")/lib/llm-router.sh"
CONFIG="$WORKBENCH/agents/aider/aider.conf.yml"

# Resolve target project dir (first positional arg, default cwd)
PROJECT_DIR="${1:-$(pwd)}"
if [ $# -ge 1 ]; then shift; fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "start-aider: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

# LLM router: probe all endpoints, select best for aider, gracefully degrade.
llm_router_init
llm_router_select aider

if [ "${LLM_PRIMARY_BACKEND:-none}" = "none" ]; then
  echo "start-aider: no LLM endpoints available." >&2
  echo "  Start LM Studio (port 1234) or Ollama (ollama serve), then retry." >&2
  exit 1
fi

echo "start-aider: routing → primary=${LLM_PRIMARY} (${LLM_PRIMARY_MS}ms)" >&2
if [ "${LLM_FALLBACK_BACKEND:-none}" != "none" ]; then
  echo "start-aider: fallback → ${LLM_FALLBACK} (${LLM_FALLBACK_MS}ms, threshold=${FALLBACK_THRESHOLD}ms)" >&2
fi

# Derive aider endpoint + model from the selected primary (or fallback if over threshold).
_AIDER_PRIMARY_MS="${LLM_PRIMARY_MS:-99999}"
_AIDER_THRESHOLD="${FALLBACK_THRESHOLD:-2000}"
if [ "$_AIDER_PRIMARY_MS" -gt "$_AIDER_THRESHOLD" ] && [ "${LLM_FALLBACK_BACKEND:-none}" != "none" ]; then
  echo "start-aider: primary latency ${_AIDER_PRIMARY_MS}ms > ${_AIDER_THRESHOLD}ms threshold — switching to fallback ${LLM_FALLBACK}" >&2
  _AIDER_BACKEND="$LLM_FALLBACK_BACKEND"
  _AIDER_MODEL="$LLM_FALLBACK_MODEL"
  _AIDER_BASE_URL="$LLM_FALLBACK_URL"
else
  _AIDER_BACKEND="$LLM_PRIMARY_BACKEND"
  _AIDER_MODEL="$LLM_PRIMARY_MODEL"
  _AIDER_BASE_URL="$LLM_PRIMARY_URL"
fi

# Build aider model flag based on selected backend.
case "$_AIDER_BACKEND" in
  lmstudio|ollama)
    AIDER_MODEL_FLAG="openai/${_AIDER_MODEL}"
    AIDER_API_BASE="${_AIDER_BASE_URL}"
    ;;
  xai)
    AIDER_MODEL_FLAG="${_AIDER_MODEL}"
    AIDER_API_BASE="${_AIDER_BASE_URL}"
    ;;
  anthropic)
    AIDER_MODEL_FLAG="${_AIDER_MODEL}"
    AIDER_API_BASE=""
    ;;
  *)
    AIDER_MODEL_FLAG="openai/${LM_STUDIO_MODEL}"
    AIDER_API_BASE="${LM_STUDIO_URL}"
    ;;
esac
export AIDER_MODEL_FLAG AIDER_API_BASE OPENAI_BASE_URL="${AIDER_API_BASE}"

ENDPOINT="${_AIDER_BASE_URL:-${LM_STUDIO_URL}}"

# Session log (cross-agent trace). Aider is interactive, so session_end fires
# when the user quits the REPL.
# shellcheck source=lib/session-log.sh
. "$(dirname "$0")/lib/session-log.sh"
# shellcheck source=lib/session-events.sh
. "$(dirname "$0")/lib/session-events.sh"
# shellcheck source=lib/session-replay-log.sh
. "$(dirname "$0")/lib/session-replay-log.sh"
log_session_start aider "$PROJECT_DIR"
_SE_AIDER_START="$(date +%s)"
# Determine MCP count from aider config (yaml entries under mcp-servers key)
_SE_AIDER_MCP=0
if command -v python3 >/dev/null 2>&1 && [ -f "$CONFIG" ]; then
  _SE_AIDER_MCP="$(python3 -c "
import sys
try:
    data = open('$CONFIG').read()
    import re
    m = re.search(r'mcp[-_]?servers\s*:\s*\n((?:[ \t]+\S.*\n?)*)', data)
    if m:
        entries = [l for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith('#')]
        print(len(entries))
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
fi
on_agent_start "aider" "$$" "${_AIDER_BACKEND}/${_AIDER_MODEL}" "$_SE_AIDER_MCP"
replay_session_init "aider" "${_AIDER_BACKEND}/${_AIDER_MODEL}" "$_SE_AIDER_MCP" "$PROJECT_DIR"
trap '
  _SE_AIDER_RC=$?
  _SE_AIDER_DUR=$(( $(date +%s) - _SE_AIDER_START ))
  if [ "$_SE_AIDER_RC" -ne 0 ]; then
    on_agent_error "aider" "$_SE_AIDER_RC" "exit code $_SE_AIDER_RC"
    on_session_end "aider" "$_SE_AIDER_DUR" "error"
    replay_session_end "aider" "$_SE_AIDER_DUR" "error"
  else
    on_session_end "aider" "$_SE_AIDER_DUR" "ok"
    replay_session_end "aider" "$_SE_AIDER_DUR" "ok"
  fi
  log_session_end aider "$PROJECT_DIR"
' EXIT

cd "$PROJECT_DIR"
# Run (don't exec) so the EXIT trap fires and writes session_end.
# Pass routed model + API base; --model and --openai-api-base can be overridden
# by the caller via extra args (they appear after, so they win).
if [ -n "${AIDER_API_BASE:-}" ]; then
  aider --config "$CONFIG" --model "$AIDER_MODEL_FLAG" --openai-api-base "$AIDER_API_BASE" "$@"
else
  aider --config "$CONFIG" --model "$AIDER_MODEL_FLAG" "$@"
fi
exit $?
