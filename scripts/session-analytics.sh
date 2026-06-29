#!/usr/bin/env bash
# session-analytics.sh — Session analytics reader for ashlr-workbench.
#
# Reads ~/.ashlr-workbench/session-events.jsonl (written by
# scripts/lib/session-events.sh) and produces human-readable session
# retrospectives.
#
# Exposed via `aw log stats` (wired in bin/aw-log). Can also be called
# directly:
#   ./scripts/session-analytics.sh           # full analytics report
#   ./scripts/session-analytics.sh --help    # this help
#
# Reports:
#   1. Agent uptime per session (duration from agent_start → session_end)
#   2. MCP server crash frequency (agent_error events correlated with mcp context)
#   3. Error clustering  ("Aider failed 3x with TOML parse errors")
#   4. Session shape     ("OpenHands + 2 Goose, 45min total")
#
# Design:
#   - Zero external deps. Pure bash + python3. No jq.
#   - Bash 3.2-safe. No mapfile.
#   - Respects ASHLR_SESSION_EVENTS_PATH and NO_COLOR.
#   - Never crashes the caller on a malformed log.

set -uo pipefail

# ─── Resolve paths ────────────────────────────────────────────────────────────
EVENTS_FILE="${ASHLR_SESSION_EVENTS_PATH:-$HOME/.ashlr-workbench/session-events.jsonl}"

# ─── Colors (NO_COLOR-aware, TTY-aware) ───────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_BLUE=""
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'; C_BLUE=$'\033[34m'
fi

die()  { printf "%ssession-analytics:%s %s\n" "$C_RED"  "$C_RESET" "$*" >&2; exit 1; }
info() { printf "%s•%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
dim()  { printf "%s%s%s\n"   "$C_DIM" "$*" "$C_RESET"; }

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
  cat <<EOF
${C_BOLD}session-analytics.sh${C_RESET} — workbench session retrospective

${C_BOLD}USAGE${C_RESET}
  ./scripts/session-analytics.sh          # full report
  aw log stats                            # same, via the aw CLI
  ./scripts/session-analytics.sh --help  # this help

${C_BOLD}REPORTS${C_RESET}
  1. Agent uptime per session
  2. MCP server crash frequency
  3. Error clustering
  4. Session shape summary

${C_BOLD}FILE${C_RESET}
  $EVENTS_FILE
  (override via \$ASHLR_SESSION_EVENTS_PATH)

${C_BOLD}SEE ALSO${C_RESET}
  scripts/lib/session-events.sh   event emitter (sourced by start-*.sh)
  bin/aw-log                      raw session log viewer
EOF
}

# ─── Guard: events file must exist ───────────────────────────────────────────
ensure_events_readable() {
  if [ ! -f "$EVENTS_FILE" ]; then
    dim "(no session events log yet at $EVENTS_FILE)"
    dim "Start a workbench agent to begin recording events."
    return 1
  fi
  return 0
}

# ─── Main analytics (python3) ─────────────────────────────────────────────────
# All four reports are computed in a single Python pass for efficiency.
run_analytics() {
  python3 - "$EVENTS_FILE" <<'PYEOF'
import json, sys, os
from collections import defaultdict, Counter
from datetime import datetime, timezone

path = sys.argv[1]

# ── Parse all events ────────────────────────────────────────────────────────
sessions   = {}          # session_id -> {agent, start_ts, end_ts, duration, status}
errors     = []          # list of {agent, session, exit_code, stderr, ts}
mcp_spawns = Counter()   # server_name -> count
agent_runs = Counter()   # agent -> total session count
error_clusters = defaultdict(list)  # normalized_msg -> [agent, ...]

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

total_lines = 0
bad_lines   = 0

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        total_lines += 1
        try:
            ev = json.loads(raw)
        except Exception:
            bad_lines += 1
            continue
        if not isinstance(ev, dict):
            bad_lines += 1
            continue

        event   = ev.get("event", "")
        agent   = ev.get("agent", "?")
        session = ev.get("session", "")
        ts_raw  = ev.get("ts", "")
        ts      = parse_ts(ts_raw)

        if event == "agent_start":
            agent_runs[agent] += 1
            sessions[session] = {
                "agent":    agent,
                "model":    ev.get("model", "?"),
                "mcp_count": ev.get("mcp_count", "?"),
                "start_ts": ts,
                "end_ts":   None,
                "duration": None,
                "status":   "running",
            }

        elif event == "session_end":
            if session not in sessions:
                # orphan end event — create minimal entry
                sessions[session] = {
                    "agent": agent, "model": "?", "mcp_count": "?",
                    "start_ts": None, "end_ts": ts,
                    "duration": None, "status": "?",
                }
            try:
                dur = int(ev.get("duration", 0))
            except (ValueError, TypeError):
                dur = None
            sessions[session]["end_ts"]   = ts
            sessions[session]["duration"] = dur
            sessions[session]["status"]   = ev.get("status", "ok")

        elif event == "agent_error":
            errors.append({
                "agent":   agent,
                "session": session,
                "exit_code": ev.get("exit_code", "?"),
                "stderr":    ev.get("stderr", ""),
                "ts":        ts,
            })
            # Normalize stderr for clustering:
            #  - strip hex addresses, line numbers, file paths
            msg = ev.get("stderr", "")
            import re
            msg = re.sub(r'0x[0-9a-fA-F]+', '0xADDR', msg)
            msg = re.sub(r'line \d+', 'line N', msg)
            msg = re.sub(r'/[^\s:]+', 'PATH', msg)
            msg = msg.strip()[:120]
            if msg:
                error_clusters[msg].append(agent)

        elif event == "mcp_server_spawn":
            srv = ev.get("server", "?")
            mcp_spawns[srv] += 1

# ── Section 1: Agent uptime per session ─────────────────────────────────────
print("=" * 64)
print("1. AGENT UPTIME PER SESSION")
print("=" * 64)
if not sessions:
    print("  (no sessions recorded)")
else:
    # Sort by start_ts (None sorts last)
    def sort_key(item):
        st = item[1]["start_ts"]
        if st is None:
            return datetime.max.replace(tzinfo=timezone.utc)
        return st

    for sid, s in sorted(sessions.items(), key=sort_key, reverse=True):
        agent = s["agent"]
        dur   = s["duration"]
        st    = s["status"]
        model = s["model"]
        if dur is not None:
            mins, secs = divmod(int(dur), 60)
            dur_str = f"{mins}m{secs:02d}s"
        elif s["start_ts"] and s["end_ts"]:
            delta = s["end_ts"] - s["start_ts"]
            total_s = max(0, int(delta.total_seconds()))
            mins, secs = divmod(total_s, 60)
            dur_str = f"{mins}m{secs:02d}s (computed)"
        else:
            dur_str = "unknown"
        ts_label = s["start_ts"].strftime("%Y-%m-%d %H:%M") if s["start_ts"] else "?"
        print(f"  [{ts_label}]  {agent:<12}  {dur_str:<14}  status={st}  model={model}")
print()

# ── Section 2: MCP server crash frequency ───────────────────────────────────
print("=" * 64)
print("2. MCP SERVER SPAWN FREQUENCY")
print("=" * 64)
# For crash frequency: errors that mention mcp or server in stderr
mcp_errors = [e for e in errors if "mcp" in e["stderr"].lower()
              or "server" in e["stderr"].lower()
              or "spawn" in e["stderr"].lower()]
if not mcp_spawns and not mcp_errors:
    print("  (no MCP server events recorded)")
else:
    if mcp_spawns:
        print("  Spawn counts by server:")
        for srv, n in mcp_spawns.most_common():
            print(f"    {srv:<40} spawned {n}x")
    if mcp_errors:
        print()
        print(f"  MCP-related errors: {len(mcp_errors)}")
        # Group by agent
        mcp_err_by_agent = Counter(e["agent"] for e in mcp_errors)
        for agent, cnt in mcp_err_by_agent.most_common():
            print(f"    {agent:<12} {cnt} MCP-related error(s)")
    else:
        print("  No MCP-related errors recorded.")
print()

# ── Section 3: Error clustering ──────────────────────────────────────────────
print("=" * 64)
print("3. ERROR CLUSTERING")
print("=" * 64)
if not errors:
    print("  (no errors recorded)")
else:
    total_errors = len(errors)
    print(f"  Total errors: {total_errors}")
    print()
    if error_clusters:
        print("  Recurring error patterns (2+ occurrences):")
        shown = 0
        for msg, agents in sorted(error_clusters.items(),
                                   key=lambda x: -len(x[1])):
            if len(agents) < 2:
                continue
            agent_counts = Counter(agents)
            agent_str = ", ".join(
                f"{a} x{n}" if n > 1 else a
                for a, n in agent_counts.most_common()
            )
            # Truncate long messages
            display_msg = msg[:80] + ("…" if len(msg) > 80 else "")
            print(f"    [{len(agents)}x] ({agent_str}): {display_msg}")
            shown += 1
        if shown == 0:
            print("  All errors are unique (no recurring patterns).")
    else:
        print("  No clusterable error patterns found.")

    # Show most recent errors regardless
    print()
    print("  Most recent errors:")
    recent_errs = sorted(
        [e for e in errors if e["ts"] is not None],
        key=lambda x: x["ts"],
        reverse=True
    )[:5]
    for e in recent_errs:
        ts_label = e["ts"].strftime("%Y-%m-%d %H:%M") if e["ts"] else "?"
        snippet  = e["stderr"][:70].replace("\n", " ")
        print(f"    [{ts_label}] {e['agent']:<12} exit={e['exit_code']}  {snippet}")
print()

# ── Section 4: Session shape ─────────────────────────────────────────────────
print("=" * 64)
print("4. SESSION SHAPE")
print("=" * 64)
if not sessions:
    print("  (no sessions recorded)")
else:
    # Compute totals
    total_dur = 0
    dur_known = 0
    for s in sessions.values():
        d = s.get("duration")
        if d is not None:
            total_dur += int(d)
            dur_known += 1
        elif s.get("start_ts") and s.get("end_ts"):
            delta = s["end_ts"] - s["start_ts"]
            total_dur += max(0, int(delta.total_seconds()))
            dur_known += 1

    total_mins = total_dur // 60
    total_secs = total_dur % 60

    # Build agent mix description
    agent_counts_map = Counter(s["agent"] for s in sessions.values())
    parts = []
    # Sort by count desc, name asc for deterministic output
    for agent, cnt in sorted(agent_counts_map.items(),
                              key=lambda x: (-x[1], x[0])):
        if cnt == 1:
            parts.append(agent)
        else:
            parts.append(f"{cnt}x {agent}")
    agent_mix = " + ".join(parts)

    dur_label = f"{total_mins}m{total_secs:02d}s total" if dur_known else "duration unknown"

    print(f"  {agent_mix}, {dur_label}")
    print()
    print(f"  Sessions by agent:")
    for agent, cnt in sorted(agent_counts_map.items(), key=lambda x: (-x[1], x[0])):
        runs = agent_runs.get(agent, cnt)
        print(f"    {agent:<12}  {cnt} session(s)")
    print()
    print(f"  Log: {path}  ({total_lines} lines, {bad_lines} unparseable)")
print()
PYEOF
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-report}"
  case "$cmd" in
    -h|--help|help) show_help; return 0 ;;
    report|"")       : ;;
    *) die "unknown argument '$cmd' — try --help" ;;
  esac

  ensure_events_readable || return 0

  printf "\n%sashlr-workbench session analytics%s\n" "$C_BOLD" "$C_RESET"
  dim  "  log: $EVENTS_FILE"
  printf "\n"
  run_analytics
}

main "$@"
