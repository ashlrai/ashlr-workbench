#!/usr/bin/env bash
# session-resume.sh — restore last session context and relaunch ashlrcode.
#
# Reads ~/.ashlr/session-log.jsonl for the most recent session's activity,
# gathers git state and genome auto-observations, then launches ashlrcode
# with a structured resume prompt prepended as context.
#
# Usage:
#   aw resume              # resume the last session in cwd (or globally)
#   aw resume --global     # resume the last session regardless of project
#   aw resume --help       # show help

set -uo pipefail

# ─── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  link_target="$(readlink "$SCRIPT_PATH")"
  case "$link_target" in
    /*) SCRIPT_PATH="$link_target" ;;
    *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$link_target" ;;
  esac
done
SCRIPTS_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
WORKBENCH="$(cd "$SCRIPTS_DIR/.." && pwd)"

LOG_PATH="${ASHLR_SESSION_LOG_PATH:-$HOME/.ashlr/session-log.jsonl}"

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
bad()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; }
info() { printf "  %s•%s %s\n" "$C_CYAN"   "$C_RESET" "$*"; }
dim()  { printf "%s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }

# ─── Help ─────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
${C_BOLD}aw resume${C_RESET} — restore last session context and relaunch ashlrcode

${C_BOLD}USAGE${C_RESET}
  aw resume              resume the last session matching cwd
  aw resume --global     resume the last session from any project
  aw resume --help       show this help

${C_BOLD}WHAT GETS RESTORED${C_RESET}
  - Last 20 session-log entries from that session
  - Git state (branch, uncommitted changes, recent commits)
  - Genome auto-observations (knowledge/discoveries.md)
  - Project conventions (CLAUDE.md / AGENTS.md)

${C_BOLD}SEE ALSO${C_RESET}
  aw summary             summarize the most recent session
  docs/integration/session-resume.md
EOF
}

# ─── Args ─────────────────────────────────────────────────────────────────────
GLOBAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --global|-g)  GLOBAL=1; shift ;;
    --help|-h)    cmd_help; exit 0 ;;
    *)            bad "unknown option: $1"; echo; cmd_help; exit 2 ;;
  esac
done

# ─── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$LOG_PATH" ]; then
  bad "no session log found at $LOG_PATH"
  info "start a session first with: aw start ashlrcode"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 required but not found on PATH"
  exit 1
fi

# ─── Find last session ───────────────────────────────────────────────────────
# Extract the most recent session_end (or session_start if no end was logged)
# matching the current cwd. Falls back to any session if --global or no match.
LAST_SESSION_JSON="$(python3 - "$LOG_PATH" "$PWD" "$GLOBAL" <<'PY'
import json, sys, os

log_path, cwd, global_flag = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

entries = []
with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            continue

# Walk backwards to find the last session_end (or session_start).
last_session_id = None
last_session_cwd = None
last_session_ts = None
last_session_agent = None

for entry in reversed(entries):
    event = entry.get("event", "")
    if event not in ("session_end", "session_start"):
        continue
    entry_cwd = entry.get("cwd", "")
    if not global_flag and entry_cwd != cwd:
        continue
    last_session_id = entry.get("session", "")
    last_session_cwd = entry_cwd
    last_session_ts = entry.get("ts", "")
    last_session_agent = entry.get("agent", "")
    break

# If no cwd-specific match, fall back to global
if last_session_id is None and not global_flag:
    for entry in reversed(entries):
        event = entry.get("event", "")
        if event not in ("session_end", "session_start"):
            continue
        last_session_id = entry.get("session", "")
        last_session_cwd = entry.get("cwd", "")
        last_session_ts = entry.get("ts", "")
        last_session_agent = entry.get("agent", "")
        break

if last_session_id is None:
    print("{}")
    sys.exit(0)

# Gather all entries for that session
session_entries = [e for e in entries if e.get("session") == last_session_id]
# Take last 20
session_entries = session_entries[-20:]

# Count tool calls
tool_calls = [e for e in session_entries if e.get("event") == "tool_call"]
tool_counts = {}
for tc in tool_calls:
    t = tc.get("tool", "unknown")
    tool_counts[t] = tool_counts.get(t, 0) + 1

# Find the last tool call for the "ended with" summary
last_tool = None
for e in reversed(session_entries):
    if e.get("event") == "tool_call":
        last_tool = e.get("tool", "unknown")
        break

result = {
    "session_id": last_session_id,
    "cwd": last_session_cwd,
    "ts": last_session_ts,
    "agent": last_session_agent,
    "entries": session_entries,
    "tool_call_count": len(tool_calls),
    "tool_counts": tool_counts,
    "last_tool": last_tool,
    "total_entries": len(session_entries),
}
print(json.dumps(result))
PY
)"

# Check if we found anything
if [ "$LAST_SESSION_JSON" = "{}" ] || [ -z "$LAST_SESSION_JSON" ]; then
  bad "no previous session found in session log"
  info "start a session first with: aw start ashlrcode"
  exit 1
fi

# Parse key fields from the JSON
SESSION_ID="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))")"
SESSION_CWD="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))")"
SESSION_TS="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ts',''))")"
SESSION_AGENT="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent',''))")"
TOOL_CALL_COUNT="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_call_count',0))")"
LAST_TOOL="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_tool','') or 'n/a')")"

# ─── Compute time-ago string ─────────────────────────────────────────────────
TIME_AGO="$(python3 -c "
from datetime import datetime, timezone
ts = '$SESSION_TS'
try:
    dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = datetime.now(timezone.utc) - dt
    secs = int(delta.total_seconds())
    if secs < 60: print(f'{secs}s ago')
    elif secs < 3600: print(f'{secs // 60}m ago')
    elif secs < 86400: print(f'{secs // 3600}h ago')
    else: print(f'{secs // 86400}d ago')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"

# ─── Determine project dir ───────────────────────────────────────────────────
# Use the session's cwd as the project dir (cd there for git commands).
PROJECT_DIR="$SESSION_CWD"
if [ ! -d "$PROJECT_DIR" ]; then
  PROJECT_DIR="$PWD"
fi
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# ─── Build resume context sections ───────────────────────────────────────────

# 1. Session log activity
SESSION_ACTIVITY="$(printf '%s' "$LAST_SESSION_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
entries = d.get('entries', [])
lines = []
for e in entries:
    ts = e.get('ts', '')[0:19].replace('T', ' ')
    event = e.get('event', '?')
    tool = e.get('tool', '')
    summary = e.get('summary', '')
    if tool:
        lines.append(f'- [{ts}] {event}: {tool}')
    elif summary:
        lines.append(f'- [{ts}] {event}: {summary}')
    else:
        lines.append(f'- [{ts}] {event}')
print('\n'.join(lines) if lines else '(no activity logged)')
")"

# 2. Git state
GIT_STATE=""
if [ -d "$PROJECT_DIR/.git" ] || git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

  # Commits ahead of main/master
  GIT_DEFAULT=""
  for candidate in main master; do
    if git -C "$PROJECT_DIR" rev-parse --verify "$candidate" >/dev/null 2>&1; then
      GIT_DEFAULT="$candidate"
      break
    fi
  done
  GIT_AHEAD=""
  if [ -n "$GIT_DEFAULT" ] && [ "$GIT_BRANCH" != "$GIT_DEFAULT" ]; then
    ahead_count="$(git -C "$PROJECT_DIR" rev-list --count "$GIT_DEFAULT".."$GIT_BRANCH" 2>/dev/null || echo 0)"
    if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
      GIT_AHEAD=" ($ahead_count commits ahead of $GIT_DEFAULT)"
    fi
  fi

  GIT_LOG="$(git -C "$PROJECT_DIR" log --oneline -5 2>/dev/null || echo "(no commits)")"
  GIT_DIFF_STAT="$(git -C "$PROJECT_DIR" diff --stat 2>/dev/null)"
  GIT_STAGED="$(git -C "$PROJECT_DIR" diff --cached --stat 2>/dev/null)"

  UNCOMMITTED_COUNT="$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

  GIT_STATE="On branch: ${GIT_BRANCH}${GIT_AHEAD}
Uncommitted: ${UNCOMMITTED_COUNT} files modified

Recent commits:
${GIT_LOG}"

  if [ -n "$GIT_DIFF_STAT" ]; then
    GIT_STATE="${GIT_STATE}

Unstaged changes:
${GIT_DIFF_STAT}"
  fi
  if [ -n "$GIT_STAGED" ]; then
    GIT_STATE="${GIT_STATE}

Staged changes:
${GIT_STAGED}"
  fi
else
  GIT_STATE="(not a git repository)"
fi

# 3. Genome auto-observations
GENOME_OBS=""
GENOME_COUNT=0
# Check multiple possible genome locations
for genome_dir in \
  "$PROJECT_DIR/.ashlrcode/genome" \
  "$HOME/.ashlrcode/genome"; do
  discoveries="$genome_dir/knowledge/discoveries.md"
  if [ -f "$discoveries" ]; then
    GENOME_OBS="$(head -50 "$discoveries")"
    GENOME_COUNT="$(find "$genome_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
    break
  fi
done

# 4. Project conventions (CLAUDE.md or AGENTS.md)
CONVENTIONS=""
for conv_file in \
  "$PROJECT_DIR/CLAUDE.md" \
  "$PROJECT_DIR/AGENTS.md"; do
  if [ -f "$conv_file" ]; then
    # First 500 chars to keep the prompt lean
    CONVENTIONS="$(head -c 500 "$conv_file")"
    CONVENTIONS="$(printf "Source: %s\n%s" "$(basename "$conv_file")" "$CONVENTIONS")"
    break
  fi
done

# ─── Assemble the resume prompt ──────────────────────────────────────────────
RESUME_PROMPT="## Session Resume — ${PROJECT_NAME}

### Last session activity (from session log)
${SESSION_ACTIVITY}

### Git state since last session
${GIT_STATE}
"

if [ -n "$GENOME_OBS" ]; then
  RESUME_PROMPT="${RESUME_PROMPT}
### Auto-observations (from genome)
${GENOME_OBS}
"
fi

if [ -n "$CONVENTIONS" ]; then
  RESUME_PROMPT="${RESUME_PROMPT}
### Project conventions
${CONVENTIONS}
"
fi

RESUME_PROMPT="${RESUME_PROMPT}
---
You are resuming a previous coding session. Review the context above to
understand where the user left off. Acknowledge what you see and ask if
they want to continue where they stopped or start something new."

# ─── Write resume context to temp file ───────────────────────────────────────
RESUME_FILE="$(mktemp "${TMPDIR:-/tmp}/aw-resume-XXXXXX.md")"
printf '%s\n' "$RESUME_PROMPT" > "$RESUME_FILE"

# ─── Print banner ────────────────────────────────────────────────────────────
echo
printf "%s%sResuming session %s from %s%s\n" "$C_BOLD" "$C_CYAN" "$SESSION_ID" "$TIME_AGO" "$C_RESET"
info "Project: ${PROJECT_DIR} (branch: $(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "n/a"))"
info "Last activity: ${TOOL_CALL_COUNT} tool calls, ended with '${LAST_TOOL}'"
if [ "$GENOME_COUNT" -gt 0 ]; then
  info "Genome: ${GENOME_COUNT} auto-observations available"
fi
echo

# ─── Launch ashlrcode with resume context ─────────────────────────────────────
# Delegate to start-ashlrcode.sh with the resume prompt as a system message.
# ashlrcode supports --system-prompt-file for prepending context.
# If that flag isn't available, fall back to passing the content as a first
# message via --print and then entering interactive mode.
export ASHLR_RESUME_CONTEXT="$RESUME_FILE"

# Source session-log so the resumed session gets its own log entry
# shellcheck source=lib/session-log.sh
. "$SCRIPTS_DIR/lib/session-log.sh"
log_session_start ashlrcode "$PROJECT_DIR"
cleanup() {
  log_session_end ashlrcode "$PROJECT_DIR"
  rm -f "$RESUME_FILE" 2>/dev/null
}
trap cleanup EXIT

# cd into the project dir so ashlrcode operates in the right context
cd "$PROJECT_DIR" || true

# Load env the same way start-ashlrcode.sh does
WB_CONFIG_DIR="$WORKBENCH/agents/ashlrcode"
WB_SETTINGS="$WB_CONFIG_DIR/settings.json"
if [ -f "$WB_SETTINGS" ]; then
  export ASHLRCODE_CONFIG_DIR="$WB_CONFIG_DIR"
  export ASHLR_MCP_EXTRA="$WB_SETTINGS"
fi

# Source .env files for secrets (same order as start-ashlrcode.sh)
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

if [ -z "${XAI_API_KEY:-}" ] && [ -f "$HOME/.ashlrcode/settings.json" ]; then
  # shellcheck disable=SC2155
  export XAI_API_KEY="$(awk -F'"' '/"apiKey"[[:space:]]*:[[:space:]]*"xai-/ {print $4; exit}' "$HOME/.ashlrcode/settings.json" 2>/dev/null || true)"
fi

# Try --system-prompt-file first; fall back to --resume / -p for older builds
if ashlrcode --help 2>&1 | grep -q '\-\-system-prompt-file'; then
  ashlrcode --system-prompt-file "$RESUME_FILE"
elif ashlrcode --help 2>&1 | grep -q '\-\-resume'; then
  ashlrcode --resume "$RESUME_FILE"
else
  # Fallback: pass resume context as the initial prompt via -p
  ashlrcode -p "$(cat "$RESUME_FILE")"
fi
exit $?
