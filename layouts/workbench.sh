#!/usr/bin/env bash
# workbench.sh — default "just code" layout.
#   Left top (60%):   aw interactive session (Qwen3-Coder-30B)
#   Left bottom (40%): plain shell for git, build commands
#   Right (40% width): aw log tail (live cross-agent feed)
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 [dir]
  Launches the default workbench layout (aw session + log tail + shell).
  Defaults to current directory if no dir is given.
  Requires cmux (\$CMUX_SOCKET_PATH set) or tmux as fallback.
EOF
  exit 1
}

case "${1:-}" in -h|--help) usage ;; esac

DIR="${1:-$(pwd)}"
DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "bad dir: ${1:-}" >&2; exit 1; }
SESSION="wb-$(basename "$DIR")"

AW_CMD="cd \"$DIR\" && echo '=== [TL] aw — interactive session (Qwen3-Coder-30B) ===' && aw"
SHELL_CMD="cd \"$DIR\" && echo '=== [BL] shell ===' && exec \$SHELL"
LOG_CMD="echo '=== [R] aw log tail — live feed ===' && aw log tail"

if [ -n "${CMUX_SOCKET_PATH:-}" ] && command -v cmux >/dev/null 2>&1; then
  WS_JSON=$(cmux new-workspace --cwd "$DIR" --command "$AW_CMD" 2>&1 | tail -1)
  WS_REF=$(printf '%s\n' "$WS_JSON" | grep -oE 'workspace:[0-9]+' | head -1 || true)
  [ -n "$WS_REF" ] || WS_REF="workspace:1"
  cmux new-split right --workspace "$WS_REF" >/dev/null
  cmux new-split down  --workspace "$WS_REF" >/dev/null
  cat <<EOF
[workbench] cmux workspace $WS_REF created in $DIR.
If panes didn't auto-run, paste:
  TL (aw session):  $AW_CMD
  BL (shell):       $SHELL_CMD
  R  (log tail):    $LOG_CMD
EOF
  exit 0
fi

if command -v tmux >/dev/null 2>&1; then
  tmux new-session  -d -s "$SESSION" -n main -c "$DIR" "$AW_CMD"
  tmux split-window -h -p 40 -t "$SESSION:0.0" -c "$DIR" "$LOG_CMD"
  tmux split-window -v -p 40 -t "$SESSION:0.0" -c "$DIR" "$SHELL_CMD"
  tmux select-pane -t "$SESSION:0.0" -T "aw"
  tmux select-pane -t "$SESSION:0.1" -T "log"
  tmux select-pane -t "$SESSION:0.2" -T "shell"
  tmux attach -t "$SESSION"
  exit 0
fi

echo "error: neither cmux (\$CMUX_SOCKET_PATH) nor tmux is available." >&2
exit 1
