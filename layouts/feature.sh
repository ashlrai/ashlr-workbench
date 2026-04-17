#!/usr/bin/env bash
# feature.sh — 2x2 layout for building a feature.
#   TL: Claude Code (architect)   TR: aw (local implementer)
#   BL: test runner (watch)       BR: git + session log watch
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <dir>
  Launches a 2x2 feature-build layout (Claude Code / aw / tests / git+log).
  Requires cmux (\$CMUX_SOCKET_PATH set) or tmux as fallback.
EOF
  exit 1
}

case "${1:-}" in -h|--help) usage ;; esac
[ $# -ge 1 ] || usage
DIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "bad dir: $1" >&2; exit 1; }
SESSION="feat-$(basename "$DIR")"

# Pick a test-watch command based on what the repo has.
pick_test_cmd() {
  local d="$1"
  if [ -f "$d/bun.lockb" ] || [ -f "$d/bun.lock" ]; then echo "bun test --watch"; return; fi
  if [ -f "$d/package.json" ]; then
    if grep -q '"test"' "$d/package.json" 2>/dev/null; then echo "npm test -- --watch"; return; fi
  fi
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/pytest.ini" ] || compgen -G "$d/test_*.py" >/dev/null; then
    echo "pytest -f || ptw"; return
  fi
  echo "echo 'no test runner detected; run your watcher manually'"
}

TEST_CMD="$(pick_test_cmd "$DIR")"
GIT_CMD="watch -n 5 'git status --short && echo && git log --oneline -3 && echo && aw log recent 3'"
CLAUDE_CMD="cd \"$DIR\" && echo '=== [TL] Claude Code — architect ===' && claude"
AW_CMD="cd \"$DIR\" && echo '=== [TR] aw — local Qwen3-Coder-30B implementer ===' && aw"
TEST_FULL="cd \"$DIR\" && echo '=== [BL] tests (watch) ===' && $TEST_CMD"
GIT_FULL="cd \"$DIR\" && echo '=== [BR] git + session log ===' && $GIT_CMD"

if [ -n "${CMUX_SOCKET_PATH:-}" ] && command -v cmux >/dev/null 2>&1; then
  WS_JSON=$(cmux new-workspace --cwd "$DIR" --command "$CLAUDE_CMD" 2>&1 | tail -1)
  WS_REF=$(printf '%s\n' "$WS_JSON" | grep -oE 'workspace:[0-9]+' | head -1 || true)
  [ -n "$WS_REF" ] || WS_REF="workspace:1"
  cmux new-split right --workspace "$WS_REF" >/dev/null
  cmux new-split down  --workspace "$WS_REF" >/dev/null
  cmux new-split down  --workspace "$WS_REF" >/dev/null
  cat <<EOF
[feature] cmux workspace $WS_REF created in $DIR.
If panes didn't auto-run, paste:
  TL (Claude Code):  $CLAUDE_CMD
  TR (aw):           $AW_CMD
  BL (tests):        $TEST_FULL
  BR (git+log):      $GIT_FULL
EOF
  exit 0
fi

if command -v tmux >/dev/null 2>&1; then
  tmux new-session  -d -s "$SESSION" -n main -c "$DIR" "$CLAUDE_CMD"
  tmux split-window -h -t "$SESSION:0" -c "$DIR" "$AW_CMD"
  tmux split-window -v -t "$SESSION:0.0" -c "$DIR" "$TEST_FULL"
  tmux split-window -v -t "$SESSION:0.1" -c "$DIR" "$GIT_FULL"
  tmux select-layout -t "$SESSION:0" tiled
  tmux select-pane -t "$SESSION:0.0" -T "claude"
  tmux select-pane -t "$SESSION:0.1" -T "tests"
  tmux select-pane -t "$SESSION:0.2" -T "aw"
  tmux select-pane -t "$SESSION:0.3" -T "git"
  tmux attach -t "$SESSION"
  exit 0
fi

echo "error: neither cmux (\$CMUX_SOCKET_PATH) nor tmux is available." >&2
exit 1
