#!/usr/bin/env bash
# session-summary.sh — print a summary of the most recent session.
#
# Reads ~/.ashlr/session-log.jsonl and outputs a 5-10 line human-readable
# summary of what happened in the last session: tool calls, files touched,
# duration, and outcome.
#
# Usage:
#   aw summary             # human-readable summary
#   aw summary --json      # machine-readable JSON
#   aw summary --help      # show help

set -uo pipefail

LOG_PATH="${ASHLR_SESSION_LOG_PATH:-$HOME/.ashlr/session-log.jsonl}"

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

bad()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; }
info() { printf "  %s•%s %s\n" "$C_CYAN"   "$C_RESET" "$*"; }

# ─── Help ─────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
${C_BOLD}aw summary${C_RESET} — summarize the most recent session

${C_BOLD}USAGE${C_RESET}
  aw summary             human-readable summary of the last session
  aw summary --json      machine-readable JSON output
  aw summary --help      show this help

${C_BOLD}OUTPUT${C_RESET}
  Shows session ID, agent, project, duration, tool call breakdown,
  main files touched, and the last action taken.

${C_BOLD}SEE ALSO${C_RESET}
  aw resume              resume where you left off
  aw log stats           aggregate statistics across all sessions
EOF
}

# ─── Args ─────────────────────────────────────────────────────────────────────
JSON_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json|-j)   JSON_MODE=1; shift ;;
    --help|-h)   cmd_help; exit 0 ;;
    *)           bad "unknown option: $1"; echo; cmd_help; exit 2 ;;
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

# ─── Generate summary via python3 ────────────────────────────────────────────
python3 - "$LOG_PATH" "$JSON_MODE" <<'PY'
import json, sys, os
from datetime import datetime, timezone
from collections import Counter

log_path = sys.argv[1]
json_mode = sys.argv[2] == "1"

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

if not entries:
    if json_mode:
        print(json.dumps({"error": "no entries in session log"}))
    else:
        print("  (no entries in session log)")
    sys.exit(0)

# Find the last session by walking backward for the most recent session_end
# or session_start.
last_session_id = None
for entry in reversed(entries):
    event = entry.get("event", "")
    if event in ("session_end", "session_start"):
        last_session_id = entry.get("session", "")
        break

# If no session boundary found, use the session field of the last entry
if not last_session_id:
    last_session_id = entries[-1].get("session", "unknown")

# Gather all entries for this session
session_entries = [e for e in entries if e.get("session") == last_session_id]

if not session_entries:
    if json_mode:
        print(json.dumps({"error": "no entries found for session", "session_id": last_session_id}))
    else:
        print(f"  (no entries found for session {last_session_id})")
    sys.exit(0)

# Extract metadata
agent = session_entries[0].get("agent", "unknown")
cwd = session_entries[0].get("cwd", "unknown")
project_name = os.path.basename(cwd) if cwd != "unknown" else "unknown"

# Timestamps
timestamps = []
for e in session_entries:
    ts = e.get("ts", "")
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        timestamps.append(dt)
    except Exception:
        pass

start_ts = min(timestamps) if timestamps else None
end_ts = max(timestamps) if timestamps else None
duration_str = "unknown"
if start_ts and end_ts:
    delta = end_ts - start_ts
    secs = int(delta.total_seconds())
    if secs < 60:
        duration_str = f"{secs}s"
    elif secs < 3600:
        duration_str = f"{secs // 60}m {secs % 60}s"
    else:
        h = secs // 3600
        m = (secs % 3600) // 60
        duration_str = f"{h}h {m}m"

# Tool call breakdown
tool_calls = [e for e in session_entries if e.get("event") == "tool_call"]
tool_counts = Counter(tc.get("tool", "unknown") for tc in tool_calls)

# Files touched (from path field in tool_call entries)
files_touched = set()
for tc in tool_calls:
    path = tc.get("path", "")
    if path:
        files_touched.add(path)

# Last action
last_tool = None
for e in reversed(session_entries):
    if e.get("event") == "tool_call":
        last_tool = e.get("tool", "unknown")
        break

# Time ago
time_ago = "unknown"
if end_ts:
    delta = datetime.now(timezone.utc) - end_ts
    secs = int(delta.total_seconds())
    if secs < 60: time_ago = f"{secs}s ago"
    elif secs < 3600: time_ago = f"{secs // 60}m ago"
    elif secs < 86400: time_ago = f"{secs // 3600}h ago"
    else: time_ago = f"{secs // 86400}d ago"

# Event breakdown
event_counts = Counter(e.get("event", "unknown") for e in session_entries)

if json_mode:
    result = {
        "session_id": last_session_id,
        "agent": agent,
        "project": project_name,
        "cwd": cwd,
        "started": start_ts.isoformat() if start_ts else None,
        "ended": end_ts.isoformat() if end_ts else None,
        "duration": duration_str,
        "time_ago": time_ago,
        "total_entries": len(session_entries),
        "tool_calls": len(tool_calls),
        "tool_counts": dict(tool_counts.most_common()),
        "files_touched": sorted(files_touched),
        "last_tool": last_tool,
        "event_counts": dict(event_counts.most_common()),
    }
    print(json.dumps(result, indent=2))
else:
    # Human-readable summary
    print(f"\033[1mSession {last_session_id}\033[0m ({time_ago})")
    print(f"  Agent:     {agent}")
    print(f"  Project:   ~/{os.path.relpath(cwd, os.path.expanduser('~')) if cwd.startswith(os.path.expanduser('~')) else cwd}")
    print(f"  Duration:  {duration_str}")
    print(f"  Entries:   {len(session_entries)} ({len(tool_calls)} tool calls)")
    if tool_counts:
        top_tools = ", ".join(f"{t} ({n})" for t, n in tool_counts.most_common(5))
        print(f"  Tools:     {top_tools}")
    if files_touched:
        shown = sorted(files_touched)[:5]
        suffix = f" (+{len(files_touched) - 5} more)" if len(files_touched) > 5 else ""
        for f in shown:
            # Shorten paths relative to cwd
            display = os.path.relpath(f, cwd) if f.startswith(cwd) else f
            print(f"  File:      {display}")
        if suffix:
            print(f"             {suffix}")
    if last_tool:
        print(f"  Last:      {last_tool}")
PY
