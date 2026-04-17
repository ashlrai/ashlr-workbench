#!/usr/bin/env bash
# parallel.sh — 3 aw panes (one per repo) + 1 Claude Code overseer.
# Use when driving the same change across multiple repos or working 3
# independent issues at once. Claude Code in pane 4 = review + coordinate.
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <dir1> <dir2> <dir3>
  Starts 3 aw sessions (one per dir) + 1 Claude Code overseer in dir1.
  Requires cmux (\$CMUX_SOCKET_PATH set) or tmux as fallback.
EOF
  exit 1
}

case "${1:-}" in -h|--help) usage ;; esac
[ $# -eq 3 ] || usage
D1="$(cd "$1" && pwd)"; D2="$(cd "$2" && pwd)"; D3="$(cd "$3" && pwd)"

SESSION="parallel-$$"

A1="cd \"$D1\" && echo '=== [P1] aw — $(basename "$D1") ===' && aw"
A2="cd \"$D2\" && echo '=== [P2] aw — $(basename "$D2") ===' && aw"
A3="cd \"$D3\" && echo '=== [P3] aw — $(basename "$D3") ===' && aw"
OVERSEER="cd \"$D1\" && cat <<'MSG'
=== [OVERSEER] Claude Code ===
You are coordinating 3 aw sessions working in parallel:
  pane 1: $D1
  pane 2: $D2
  pane 3: $D3
Your job: review their diffs, catch duplication, make merge decisions,
and coordinate cross-repo API contracts. aw panes run local Qwen3-Coder-30B.
MSG
claude"

if [ -n "${CMUX_SOCKET_PATH:-}" ] && command -v cmux >/dev/null 2>&1; then
  WS_JSON=$(cmux new-workspace --cwd "$D1" --command "$A1" 2>&1 | tail -1)
  WS_REF=$(printf '%s\n' "$WS_JSON" | grep -oE 'workspace:[0-9]+' | head -1 || echo "workspace:1")
  cmux new-split right --workspace "$WS_REF" >/dev/null
  cmux new-split down  --workspace "$WS_REF" >/dev/null
  cmux new-split down  --workspace "$WS_REF" >/dev/null
  cat <<EOF
[parallel] cmux workspace $WS_REF created.
If panes didn't auto-run, paste:
  P1 (aw $D1):     $A1
  P2 (aw $D2):     $A2
  P3 (aw $D3):     $A3
  P4 (overseer):   claude
EOF
  exit 0
fi

if command -v tmux >/dev/null 2>&1; then
  tmux new-session  -d -s "$SESSION" -n main -c "$D1" "$A1"
  tmux split-window -h -t "$SESSION:0"   -c "$D2" "$A2"
  tmux split-window -v -t "$SESSION:0.0" -c "$D3" "$A3"
  tmux split-window -v -t "$SESSION:0.1" -c "$D1" "$OVERSEER"
  tmux select-layout -t "$SESSION:0" tiled
  tmux attach -t "$SESSION"
  exit 0
fi

echo "error: neither cmux nor tmux is available." >&2
exit 1
