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

WORKBENCH="/Users/masonwyatt/Desktop/ashlr-workbench"
CONFIG="$WORKBENCH/agents/aider/aider.conf.yml"
ENDPOINT="http://localhost:1234/v1"

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
log_session_start aider "$PROJECT_DIR"
trap 'log_session_end aider "$PROJECT_DIR"' EXIT

cd "$PROJECT_DIR"
# Run (don't exec) so the EXIT trap fires and writes session_end.
aider --config "$CONFIG" "$@"
exit $?
