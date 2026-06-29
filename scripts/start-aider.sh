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
CONFIG="$WORKBENCH/agents/aider/aider.conf.yml"
ENDPOINT="$LM_STUDIO_URL"

# Resolve target project dir (first positional arg, default cwd)
PROJECT_DIR="${1:-$(pwd)}"
if [ $# -ge 1 ]; then shift; fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "start-aider: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

# Sanity check: LM Studio endpoint reachable
if ! curl -fsS "$ENDPOINT/models" >/dev/null 2>&1; then
  echo "start-aider: LM Studio endpoint $ENDPOINT not responding." >&2
  echo "  Start LM Studio and load qwen/qwen3-coder-30b, then retry." >&2
  exit 1
fi

# Session log (cross-agent trace). Aider is interactive, so session_end fires
# when the user quits the REPL.
# shellcheck source=lib/session-log.sh
. "$(dirname "$0")/lib/session-log.sh"
# shellcheck source=lib/session-events.sh
. "$(dirname "$0")/lib/session-events.sh"
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
on_agent_start "aider" "$$" "lm-studio/qwen3-coder-30b" "$_SE_AIDER_MCP"
trap '
  _SE_AIDER_RC=$?
  _SE_AIDER_DUR=$(( $(date +%s) - _SE_AIDER_START ))
  if [ "$_SE_AIDER_RC" -ne 0 ]; then
    on_agent_error "aider" "$_SE_AIDER_RC" "exit code $_SE_AIDER_RC"
    on_session_end "aider" "$_SE_AIDER_DUR" "error"
  else
    on_session_end "aider" "$_SE_AIDER_DUR" "ok"
  fi
  log_session_end aider "$PROJECT_DIR"
' EXIT

cd "$PROJECT_DIR"
# Run (don't exec) so the EXIT trap fires and writes session_end.
aider --config "$CONFIG" "$@"
exit $?
