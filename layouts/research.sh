#!/usr/bin/env bash
# research.sh — explore an unfamiliar codebase.
#   Left 50%:    OpenHands UI launcher + shell
#   Right top:   aw --model gemma (deep reasoning Q&A)
#   Right bot:   README / docs viewer
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <dir>
  Launches a research layout (OpenHands + gemma Q&A + docs viewer).
  Requires cmux (\$CMUX_SOCKET_PATH set) or tmux as fallback.
EOF
  exit 1
}

case "${1:-}" in -h|--help) usage ;; esac
[ $# -ge 1 ] || usage
DIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "bad dir: $1" >&2; exit 1; }
SESSION="research-$(basename "$DIR")"

# Pick reference viewer
if   command -v glow >/dev/null 2>&1 && [ -f "$DIR/README.md" ]; then REF="glow \"$DIR/README.md\""
elif [ -f "$DIR/README.md" ];                                    then REF="less \"$DIR/README.md\""
elif [ -f "$DIR/README" ];                                       then REF="less \"$DIR/README\""
else                                                                  REF="echo 'no README found in $DIR'; ls -la \"$DIR\""
fi

LEFT="cd \"$DIR\" && cat <<'MSG'
=== [LEFT] OpenHands ===
Opening http://localhost:3000 in your browser.
Use the OpenHands UI for autonomous, long-horizon exploration tasks.
If OpenHands isn't running: aw start openhands
MSG
open http://localhost:3000 || true
exec \$SHELL"

RT="cd \"$DIR\" && echo '=== [RT] aw --model gemma — deep reasoning Q&A ===' && aw --model gemma"
RB="cd \"$DIR\" && echo '=== [RB] reference ===' && $REF"

if [ -n "${CMUX_SOCKET_PATH:-}" ] && command -v cmux >/dev/null 2>&1; then
  WS_JSON=$(cmux new-workspace --cwd "$DIR" --command "$LEFT" 2>&1 | tail -1)
  WS_REF=$(printf '%s\n' "$WS_JSON" | grep -oE 'workspace:[0-9]+' | head -1 || echo "workspace:1")
  cmux new-split right --workspace "$WS_REF" >/dev/null
  cmux new-split down  --workspace "$WS_REF" >/dev/null
  cat <<EOF
[research] cmux workspace $WS_REF created.
If panes didn't auto-run, paste:
  LEFT (OpenHands): open http://localhost:3000
  RT  (aw gemma):   $RT
  RB  (reference):  $RB
EOF
  exit 0
fi

if command -v tmux >/dev/null 2>&1; then
  tmux new-session  -d  -s "$SESSION" -n main -c "$DIR" "$LEFT"
  tmux split-window -h  -p 50 -t "$SESSION:0.0" -c "$DIR" "$RT"
  tmux split-window -v  -p 50 -t "$SESSION:0.1" -c "$DIR" "$RB"
  tmux attach -t "$SESSION"
  exit 0
fi

echo "error: neither cmux nor tmux is available." >&2
exit 1
