#!/usr/bin/env bash
# session-replay.sh — Cross-agent session replay & divergence detector.
#
# Records every agent session into ~/.ashlr-workbench/session-replay.jsonl and
# provides a replay harness to inspect divergence between agents solving the
# same prompt.
#
# Subcommands:
#   list                        show all recorded sessions (newest first)
#   show <session-id>           print all events for one session
#   compare <id1> <id2>         side-by-side tool-call sequences + latencies
#   diff <session-id>           variance vs. baseline (first session on record)
#   export <session-id>         export events  [--format csv|json]
#   analyze-divergence          detect systematic agent-to-agent gaps
#   validate-sla                SLA compliance scorecard across agents
#                               [--baseline-agent NAME] [--threshold-ms MS]
#                               [--report-format jsonl|html|both] [--out-dir DIR]
#   help                        show this message
#
# Environment:
#   ASHLR_REPLAY_LOG_PATH   override log file (default ~/.ashlr-workbench/session-replay.jsonl)
#   NO_COLOR                disable ANSI output
#
# Usage:
#   ./scripts/session-replay.sh list
#   ./scripts/session-replay.sh compare <id1> <id2>
#   ./scripts/session-replay.sh diff <id>
#   ./scripts/session-replay.sh export <id> --format csv
#   ./scripts/session-replay.sh validate-sla --baseline-agent goose --threshold-ms 2000
#   ./scripts/session-replay.sh validate-sla --report-format html --out-dir /tmp/sla-out

set -uo pipefail

REPLAY_LOG="${ASHLR_REPLAY_LOG_PATH:-$HOME/.ashlr-workbench/session-replay.jsonl}"

# ─── Load divergence analyzer library ────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/session-divergence-analyzer.sh
if [ -f "${_SCRIPT_DIR}/lib/session-divergence-analyzer.sh" ]; then
  . "${_SCRIPT_DIR}/lib/session-divergence-analyzer.sh"
fi

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
fi

die()   { printf "%sERROR:%s %s\n" "$C_RED"  "$C_RESET" "$*" >&2; exit 1; }
title() { printf "\n%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
dim()   { printf "%s%s%s\n"   "$C_DIM"  "$*" "$C_RESET"; }
info()  { printf "  %s•%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }

agent_color() {
  case "$1" in
    aider)      printf '%s' "$C_GREEN"   ;;
    goose)      printf '%s' "$C_YELLOW"  ;;
    openhands)  printf '%s' "$C_MAGENTA" ;;
    ashlrcode)  printf '%s' "$C_BLUE"    ;;
    *)          printf '%s' "$C_CYAN"    ;;
  esac
}

ensure_log_readable() {
  if [ ! -f "$REPLAY_LOG" ]; then
    printf "%s(no replay log yet at %s)%s\n" "$C_DIM" "$REPLAY_LOG" "$C_RESET"
    return 1
  fi
  return 0
}

# ─── Python helpers (inline) ──────────────────────────────────────────────────
# All JSON parsing is done via python3 (no jq dependency, same approach as the
# rest of the repo).

# _py_load_session SESSION_ID — print all events for session as JSON array
_py_load_session() {
  local sid="$1"
  python3 - "$REPLAY_LOG" "$sid" <<'PY'
import sys, json
path, sid = sys.argv[1], sys.argv[2]
events = []
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if isinstance(o, dict) and o.get("session") == sid:
            events.append(o)
print(json.dumps(events))
PY
}

# _py_list_sessions — print session summaries as TSV: id\tagent\tts\tmodel\tmcp\tstatus\tduration
_py_list_sessions() {
  python3 - "$REPLAY_LOG" <<'PY'
import sys, json
path = sys.argv[1]
sessions = {}   # id -> dict
order = []
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        sid = o.get("session", "")
        if not sid:
            continue
        if sid not in sessions:
            sessions[sid] = {"id": sid, "agent": "", "ts": "", "model": "",
                             "mcp": "0", "status": "running", "duration": "0",
                             "tool_count": "0", "llm_turns": "0", "cwd": ""}
            order.append(sid)
        s = sessions[sid]
        ev = o.get("event", "")
        if ev == "session_init":
            s["agent"]  = o.get("agent", s["agent"])
            s["ts"]     = o.get("ts",    s["ts"])
            s["model"]  = o.get("llm_endpoint", s["model"])
            s["mcp"]    = o.get("mcp_count",    s["mcp"])
            s["cwd"]    = o.get("cwd",           s["cwd"])
        elif ev == "session_end":
            s["status"]    = o.get("status",     s["status"])
            s["duration"]  = o.get("duration_secs", s["duration"])
            s["tool_count"] = o.get("tool_count",  s["tool_count"])
            s["llm_turns"]  = o.get("llm_turns",   s["llm_turns"])
# Newest first
for sid in reversed(order):
    s = sessions[sid]
    print("\t".join([s["id"], s["agent"], s["ts"], s["model"],
                     s["mcp"], s["status"], s["duration"],
                     s["tool_count"], s["llm_turns"], s["cwd"]]))
PY
}

# ─── cmd: list ────────────────────────────────────────────────────────────────
cmd_list() {
  ensure_log_readable || return 0
  title "Session Replay — All Sessions"
  dim "  Log: $REPLAY_LOG"
  echo

  local line agent ts model mcp status duration tools turns cwd
  local id ac col_w=13

  printf "%s%-${col_w}s  %-11s  %-30s  %-4s  %-8s  %7s  %5s  %5s%s\n" \
    "$C_BOLD" "SESSION" "AGENT" "LLM ENDPOINT" "MCP" "STATUS" "DUR(s)" "TOOLS" "TURNS" "$C_RESET"

  _py_list_sessions | while IFS=$'\t' read -r id agent ts model mcp status duration tools turns cwd; do
    ac="$(agent_color "$agent")"
    printf "%-${col_w}s  %s%-11s%s  %-30s  %-4s  %-8s  %7s  %5s  %5s\n" \
      "$id" "$ac" "$agent" "$C_RESET" \
      "${model:0:30}" "$mcp" "$status" "$duration" "$tools" "$turns"
  done
}

# ─── cmd: show ────────────────────────────────────────────────────────────────
cmd_show() {
  local sid="${1:-}"
  [ -n "$sid" ] || die "show: session-id required"
  ensure_log_readable || return 0

  title "Session: $sid"

  python3 - "$REPLAY_LOG" "$sid" <<'PY'
import sys, json
path, sid = sys.argv[1], sys.argv[2]
found = 0
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if isinstance(o, dict) and o.get("session") == sid:
            found += 1
            ev    = o.get("event", "?")
            ts    = o.get("ts", "")
            agent = o.get("agent", "?")
            # Build a summary per event type
            if ev == "session_init":
                extra = f"llm={o.get('llm_endpoint','?')} mcp={o.get('mcp_count','?')} cwd={o.get('cwd','?')}"
            elif ev == "tool_call":
                extra = f"tool={o.get('tool','?')} args={o.get('args','')!r} latency={o.get('latency_ms','?')}ms seq={o.get('seq','?')}"
            elif ev == "llm_response":
                extra = f"model={o.get('model','?')} prompt={o.get('prompt_tokens','?')} completion={o.get('completion_tokens','?')} latency={o.get('latency_ms','?')}ms turn={o.get('turn','?')}"
            elif ev == "session_end":
                extra = f"status={o.get('status','?')} duration={o.get('duration_secs','?')}s tools={o.get('tool_count','?')} turns={o.get('llm_turns','?')}"
            else:
                extra = json.dumps({k: v for k, v in o.items()
                                    if k not in ("ts","agent","event","session")})
            print(f"  {ts}  {ev:<16}  {agent:<12}  {extra}")
if found == 0:
    print(f"  (no events found for session '{sid}')")
PY
}

# ─── cmd: compare ─────────────────────────────────────────────────────────────
cmd_compare() {
  local sid1="${1:-}" sid2="${2:-}"
  [ -n "$sid1" ] || die "compare: session-id-1 required"
  [ -n "$sid2" ] || die "compare: session-id-2 required"
  ensure_log_readable || return 0

  title "Comparing sessions: $sid1  vs  $sid2"

  python3 - "$REPLAY_LOG" "$sid1" "$sid2" <<'PY'
import sys, json
from collections import defaultdict

path, sid1, sid2 = sys.argv[1], sys.argv[2], sys.argv[3]

def load_session(log_path, sid):
    events = []
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if isinstance(o, dict) and o.get("session") == sid:
                events.append(o)
    return events

evts1 = load_session(path, sid1)
evts2 = load_session(path, sid2)

def get_meta(evts, key, default="?"):
    for e in evts:
        if e.get("event") == "session_init":
            return e.get(key, default)
    return default

def get_end(evts, key, default="?"):
    for e in evts:
        if e.get("event") == "session_end":
            return e.get(key, default)
    return default

agent1  = get_meta(evts1, "agent", sid1[:8])
agent2  = get_meta(evts2, "agent", sid2[:8])
model1  = get_meta(evts1, "llm_endpoint", "?")
model2  = get_meta(evts2, "llm_endpoint", "?")
dur1    = get_end(evts1, "duration_secs", "?")
dur2    = get_end(evts2, "duration_secs", "?")
status1 = get_end(evts1, "status", "?")
status2 = get_end(evts2, "status", "?")
tools1  = get_end(evts1, "tool_count", "?")
tools2  = get_end(evts2, "tool_count", "?")
turns1  = get_end(evts1, "llm_turns", "?")
turns2  = get_end(evts2, "llm_turns", "?")

# ── Header ──────────────────────────────────────────────────────────────────
W = 38
print()
print(f"  {'Attribute':<22}  {'Session 1':<{W}}  {'Session 2':<{W}}")
print(f"  {'-'*22}  {'-'*W}  {'-'*W}")
print(f"  {'Session ID':<22}  {sid1:<{W}}  {sid2:<{W}}")
print(f"  {'Agent':<22}  {agent1:<{W}}  {agent2:<{W}}")
print(f"  {'LLM endpoint':<22}  {model1:<{W}}  {model2:<{W}}")
print(f"  {'Duration (s)':<22}  {dur1:<{W}}  {dur2:<{W}}")
print(f"  {'Status':<22}  {status1:<{W}}  {status2:<{W}}")
print(f"  {'Tool calls':<22}  {tools1:<{W}}  {tools2:<{W}}")
print(f"  {'LLM turns':<22}  {turns1:<{W}}  {turns2:<{W}}")

# ── Tool call sequences ──────────────────────────────────────────────────────
tc1 = [e for e in evts1 if e.get("event") == "tool_call"]
tc2 = [e for e in evts2 if e.get("event") == "tool_call"]
max_rows = max(len(tc1), len(tc2), 1)

print()
print(f"  {'TOOL CALL SEQUENCE':}")
print(f"  {'#':<4}  {'Session 1 tool':<30}  {'lat1(ms)':<9}  {'Session 2 tool':<30}  {'lat2(ms)':<9}")
print(f"  {'-'*4}  {'-'*30}  {'-'*9}  {'-'*30}  {'-'*9}")
for i in range(max_rows):
    t1 = tc1[i] if i < len(tc1) else None
    t2 = tc2[i] if i < len(tc2) else None
    n1  = (t1.get("tool", "?") if t1 else "")
    l1  = (t1.get("latency_ms", "?") if t1 else "")
    n2  = (t2.get("tool", "?") if t2 else "")
    l2  = (t2.get("latency_ms", "?") if t2 else "")
    # Mark divergent rows
    mark = "!!" if (t1 and t2 and n1 != n2) else "  "
    print(f"  {mark}{i+1:<3}  {n1:<30}  {str(l1):<9}  {n2:<30}  {str(l2):<9}")

# ── Divergence summary ───────────────────────────────────────────────────────
same_positions = sum(
    1 for i in range(min(len(tc1), len(tc2)))
    if tc1[i].get("tool") == tc2[i].get("tool")
)
total_compared = min(len(tc1), len(tc2))
pct = (same_positions / total_compared * 100) if total_compared > 0 else 0.0

# Average latency per session
def avg_lat(tc):
    lats = []
    for t in tc:
        try:
            lats.append(int(t.get("latency_ms", 0)))
        except (ValueError, TypeError):
            pass
    return sum(lats) / len(lats) if lats else 0.0

avg1 = avg_lat(tc1)
avg2 = avg_lat(tc2)

print()
print("  DIVERGENCE SUMMARY")
print(f"  Tool-sequence agreement:  {same_positions}/{total_compared}  ({pct:.1f}%)")
print(f"  Avg tool latency session1: {avg1:.0f} ms")
print(f"  Avg tool latency session2: {avg2:.0f} ms")
if avg1 > 0 and avg2 > 0:
    ratio = avg1 / avg2
    slower = "session1" if ratio > 1 else "session2"
    print(f"  Relative latency:          {ratio:.2f}x  ({slower} is slower)")
PY
}

# ─── cmd: diff ────────────────────────────────────────────────────────────────
cmd_diff() {
  local sid="${1:-}"
  [ -n "$sid" ] || die "diff: session-id required"
  ensure_log_readable || return 0

  title "Divergence diff: $sid vs. baseline"

  python3 - "$REPLAY_LOG" "$sid" <<'PY'
import sys, json
from collections import Counter

path, target_sid = sys.argv[1], sys.argv[2]

sessions = {}     # sid -> list[event]
order    = []

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        sid = o.get("session", "")
        if not sid:
            continue
        if sid not in sessions:
            sessions[sid] = []
            order.append(sid)
        sessions[sid].append(o)

if target_sid not in sessions:
    print(f"  (session '{target_sid}' not found)")
    sys.exit(0)

# Baseline is the first-recorded session with at least one tool_call.
baseline_sid = None
for sid in order:
    if sid == target_sid:
        continue
    if any(e.get("event") == "tool_call" for e in sessions[sid]):
        baseline_sid = sid
        break

if baseline_sid is None:
    print("  (no baseline session found — need at least two sessions with tool calls)")
    sys.exit(0)

def tool_seq(evts):
    return [e.get("tool", "?") for e in evts if e.get("event") == "tool_call"]

def get_meta(evts, key, default="?"):
    for e in evts:
        if e.get("event") == "session_init":
            return e.get(key, default)
    return default

base_seq   = tool_seq(sessions[baseline_sid])
target_seq = tool_seq(sessions[target_sid])

base_agent   = get_meta(sessions[baseline_sid], "agent", baseline_sid[:8])
target_agent = get_meta(sessions[target_sid],   "agent", target_sid[:8])
base_model   = get_meta(sessions[baseline_sid], "llm_endpoint", "?")
target_model = get_meta(sessions[target_sid],   "llm_endpoint", "?")

print()
print(f"  Baseline: {baseline_sid}  agent={base_agent}  model={base_model}")
print(f"  Target:   {target_sid}  agent={target_agent}  model={target_model}")
print()

# Simple longest-common-subsequence length for agreement score
def lcs_len(a, b):
    m, n = len(a), len(b)
    # space-optimised O(m*n)
    prev = [0] * (n + 1)
    for i in range(1, m + 1):
        curr = [0] * (n + 1)
        for j in range(1, n + 1):
            if a[i-1] == b[j-1]:
                curr[j] = prev[j-1] + 1
            else:
                curr[j] = max(curr[j-1], prev[j])
        prev = curr
    return prev[n]

lcs = lcs_len(base_seq, target_seq)
total = max(len(base_seq), len(target_seq), 1)
agreement_pct = lcs / total * 100

print(f"  TOOL SELECTION VARIANCE")
print(f"  LCS agreement:   {lcs}/{total}  ({agreement_pct:.1f}%)")
print()

# Tool frequency comparison
base_counts   = Counter(base_seq)
target_counts = Counter(target_seq)
all_tools     = sorted(set(list(base_counts.keys()) + list(target_counts.keys())))

print(f"  {'TOOL':<32}  {'BASELINE':>8}  {'TARGET':>8}  {'DELTA':>8}")
print(f"  {'-'*32}  {'-'*8}  {'-'*8}  {'-'*8}")
for tool in all_tools:
    bc = base_counts.get(tool, 0)
    tc = target_counts.get(tool, 0)
    delta = tc - bc
    sign = "+" if delta > 0 else ""
    unique = " <-- unique to target" if bc == 0 else (" <-- not in target" if tc == 0 else "")
    print(f"  {tool:<32}  {bc:>8}  {tc:>8}  {sign}{delta:>7}{unique}")

# Positional divergences
print()
print("  POSITIONAL DIVERGENCES (positions where tool differs)")
max_len = max(len(base_seq), len(target_seq))
diverged = 0
for i in range(max_len):
    bt = base_seq[i]   if i < len(base_seq)   else "(end)"
    tt = target_seq[i] if i < len(target_seq) else "(end)"
    if bt != tt:
        diverged += 1
        print(f"    pos {i+1:>3}:  baseline={bt:<28}  target={tt}")
if diverged == 0:
    print("    (no positional divergences — sequences are identical)")
PY
}

# ─── cmd: export ──────────────────────────────────────────────────────────────
cmd_export() {
  local sid="${1:-}"
  local fmt="json"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) fmt="${2:-json}"; shift 2 ;;
      --format=*) fmt="${1#--format=}"; shift ;;
      *) die "export: unknown arg '$1'" ;;
    esac
  done
  [ -n "$sid" ] || die "export: session-id required"
  ensure_log_readable || return 0

  case "$fmt" in
    json|csv) ;;
    *) die "export: --format must be 'json' or 'csv'" ;;
  esac

  python3 - "$REPLAY_LOG" "$sid" "$fmt" <<'PY'
import sys, json, csv
path, sid, fmt = sys.argv[1], sys.argv[2], sys.argv[3]

events = []
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if isinstance(o, dict) and o.get("session") == sid:
            events.append(o)

if fmt == "json":
    print(json.dumps(events, indent=2))
else:
    # CSV — flatten all keys across all events into columns
    all_keys = []
    seen = set()
    for e in events:
        for k in e:
            if k not in seen:
                all_keys.append(k)
                seen.add(k)
    writer = csv.DictWriter(sys.stdout, fieldnames=all_keys, extrasaction="ignore",
                             lineterminator="\n")
    writer.writeheader()
    for e in events:
        writer.writerow({k: e.get(k, "") for k in all_keys})
PY
}

# ─── cmd: analyze-divergence ──────────────────────────────────────────────────
cmd_analyze_divergence() {
  ensure_log_readable || return 0

  title "Agent-to-Agent Divergence Analysis"
  dim "  Log: $REPLAY_LOG"

  python3 - "$REPLAY_LOG" <<'PY'
import sys, json
from collections import defaultdict, Counter

path = sys.argv[1]

sessions = {}   # sid -> {agent, model, tool_seq[], avg_tool_lat, llm_turns, status, duration}
order = []

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        sid = o.get("session", "")
        if not sid:
            continue
        if sid not in sessions:
            sessions[sid] = {
                "agent": "?", "model": "?", "tool_seq": [],
                "tool_lats": [], "llm_turns": 0,
                "status": "running", "duration": 0,
                "tool_count": 0
            }
            order.append(sid)
        s = sessions[sid]
        ev = o.get("event", "")
        if ev == "session_init":
            s["agent"] = o.get("agent", s["agent"])
            s["model"] = o.get("llm_endpoint", s["model"])
        elif ev == "tool_call":
            s["tool_seq"].append(o.get("tool", "?"))
            try:
                s["tool_lats"].append(int(o.get("latency_ms", 0)))
            except (ValueError, TypeError):
                pass
        elif ev == "llm_response":
            s["llm_turns"] = s["llm_turns"] + 1
        elif ev == "session_end":
            s["status"]     = o.get("status", s["status"])
            try:
                s["duration"] = int(o.get("duration_secs", 0))
            except (ValueError, TypeError):
                pass
            s["tool_count"] = len(s["tool_seq"])

if not sessions:
    print("  (no sessions recorded)")
    sys.exit(0)

# Group by agent
by_agent = defaultdict(list)
for sid in order:
    by_agent[sessions[sid]["agent"]].append(sessions[sid])

agents = sorted(by_agent.keys())

# ── Per-agent summary ────────────────────────────────────────────────────────
print()
print("  PER-AGENT SUMMARY")
print(f"  {'AGENT':<14}  {'SESSIONS':>8}  {'AVG TOOLS':>10}  {'AVG LAT(ms)':>12}  {'AVG DUR(s)':>11}  {'ERR RATE':>9}")
print(f"  {'-'*14}  {'-'*8}  {'-'*10}  {'-'*12}  {'-'*11}  {'-'*9}")

agent_stats = {}
for agent in agents:
    ss = by_agent[agent]
    n_sessions = len(ss)
    avg_tools  = sum(len(s["tool_seq"]) for s in ss) / n_sessions
    all_lats   = [l for s in ss for l in s["tool_lats"]]
    avg_lat    = sum(all_lats) / len(all_lats) if all_lats else 0.0
    avg_dur    = sum(s["duration"] for s in ss) / n_sessions
    errors     = sum(1 for s in ss if s["status"] != "ok")
    err_rate   = errors / n_sessions * 100
    agent_stats[agent] = {"avg_tools": avg_tools, "avg_lat": avg_lat,
                           "avg_dur": avg_dur, "err_rate": err_rate, "n": n_sessions}
    print(f"  {agent:<14}  {n_sessions:>8}  {avg_tools:>10.1f}  {avg_lat:>12.0f}  {avg_dur:>11.0f}  {err_rate:>8.1f}%")

# ── Tool preference matrix ───────────────────────────────────────────────────
print()
print("  TOOL PREFERENCE MATRIX  (top-3 tools per agent)")
print(f"  {'AGENT':<14}  TOOLS (by frequency)")
print(f"  {'-'*14}  {'-'*60}")
for agent in agents:
    ss = by_agent[agent]
    tool_counter = Counter()
    for s in ss:
        tool_counter.update(s["tool_seq"])
    top3 = ", ".join(f"{t}({c})" for t, c in tool_counter.most_common(3))
    print(f"  {agent:<14}  {top3}")

# ── Performance gap flags ───────────────────────────────────────────────────
print()
print("  PERFORMANCE GAP FLAGS")
flags = []
if len(agents) >= 2:
    # Find the fastest and slowest by avg_lat
    sorted_by_lat = sorted(agent_stats.items(), key=lambda x: x[1]["avg_lat"])
    fastest, slowest = sorted_by_lat[0], sorted_by_lat[-1]
    if slowest[1]["avg_lat"] > 0 and fastest[1]["avg_lat"] > 0:
        ratio = slowest[1]["avg_lat"] / fastest[1]["avg_lat"]
        if ratio >= 1.5:
            flags.append(f"LATENCY GAP: {slowest[0]} is {ratio:.1f}x slower than {fastest[0]} per tool call")
    # Find agents with high error rates
    for agent, stats in agent_stats.items():
        if stats["err_rate"] >= 20:
            flags.append(f"HIGH ERROR RATE: {agent} has {stats['err_rate']:.0f}% error sessions")
    # Find agents with very different tool counts
    avg_tool_vals = [(a, stats["avg_tools"]) for a, stats in agent_stats.items()]
    if len(avg_tool_vals) >= 2:
        min_a, min_v = min(avg_tool_vals, key=lambda x: x[1])
        max_a, max_v = max(avg_tool_vals, key=lambda x: x[1])
        if min_v > 0 and max_v / min_v >= 2.0:
            flags.append(f"TOOL COUNT GAP: {max_a} uses {max_v:.0f} tools/session vs {min_a}'s {min_v:.0f}")

if flags:
    for f in flags:
        print(f"    !! {f}")
else:
    print("    (no significant gaps detected)")

print()
print(f"  Total sessions analysed: {len(sessions)}")
PY
}

# ─── cmd: validate-sla ────────────────────────────────────────────────────────
cmd_validate_sla() {
  local baseline_agent=""
  local threshold_ms="2000"
  local report_format="both"
  local out_dir
  out_dir="${ASHLR_SLA_OUT_DIR:-$(pwd)/sla-reports}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --baseline-agent)    baseline_agent="${2:-}"; shift 2 ;;
      --baseline-agent=*)  baseline_agent="${1#--baseline-agent=}"; shift ;;
      --threshold-ms)      threshold_ms="${2:-2000}"; shift 2 ;;
      --threshold-ms=*)    threshold_ms="${1#--threshold-ms=}"; shift ;;
      --report-format)     report_format="${2:-both}"; shift 2 ;;
      --report-format=*)   report_format="${1#--report-format=}"; shift ;;
      --out-dir)           out_dir="${2:-}"; shift 2 ;;
      --out-dir=*)         out_dir="${1#--out-dir=}"; shift ;;
      *) die "validate-sla: unknown argument '$1'" ;;
    esac
  done

  ensure_log_readable || return 0

  # Validate report-format
  case "$report_format" in
    jsonl|html|both) ;;
    *) die "validate-sla: --report-format must be 'jsonl', 'html', or 'both'" ;;
  esac

  # Validate threshold
  case "$threshold_ms" in
    ''|*[!0-9]*) die "validate-sla: --threshold-ms must be a positive integer" ;;
  esac

  title "Session SLA Validation"
  dim "  Log            : $REPLAY_LOG"
  dim "  Baseline agent : ${baseline_agent:-auto}"
  dim "  Threshold      : ${threshold_ms}ms (tool-call p99)"
  dim "  Report format  : $report_format"
  dim "  Output dir     : $out_dir"

  # Check the analyzer library was loaded
  if ! command -v sda_validate_sla >/dev/null 2>&1; then
    die "session-divergence-analyzer.sh library not loaded — check scripts/lib/"
  fi

  sda_validate_sla \
    "$REPLAY_LOG" \
    "$baseline_agent" \
    "$threshold_ms" \
    "$report_format" \
    "$out_dir"
  local rc=$?

  if [ "$report_format" = "jsonl" ] || [ "$report_format" = "both" ]; then
    info "JSONL scorecard: ${out_dir}/compliance-scorecard.jsonl"
  fi
  if [ "$report_format" = "html" ] || [ "$report_format" = "both" ]; then
    info "HTML report    : ${out_dir}/sla-report.html"
  fi

  return $rc
}

# ─── cmd: help ────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
${C_BOLD}session-replay.sh${C_RESET} — cross-agent session replay & divergence detector

${C_BOLD}USAGE${C_RESET}
  session-replay.sh <subcommand> [args]

${C_BOLD}SUBCOMMANDS${C_RESET}
  ${C_CYAN}list${C_RESET}                           list all recorded sessions (newest first)
  ${C_CYAN}show${C_RESET} <session-id>              print all events for one session
  ${C_CYAN}compare${C_RESET} <id1> <id2>            side-by-side tool sequences + latencies
  ${C_CYAN}diff${C_RESET} <session-id>              variance vs. baseline (first recorded session)
  ${C_CYAN}export${C_RESET} <session-id>            export events as JSON (default)
  ${C_CYAN}export${C_RESET} <session-id> --format csv|json
  ${C_CYAN}analyze-divergence${C_RESET}             systematic agent-to-agent performance analysis
  ${C_CYAN}validate-sla${C_RESET}                   SLA compliance scorecard + HTML report
    ${C_DIM}--baseline-agent NAME${C_RESET}         agent to compare others against (default: auto)
    ${C_DIM}--threshold-ms MS${C_RESET}             tool-call p99 latency SLA ceiling (default: 2000)
    ${C_DIM}--report-format jsonl|html|both${C_RESET}  output format (default: both)
    ${C_DIM}--out-dir DIR${C_RESET}                 output directory (default: ./sla-reports)
  ${C_CYAN}help${C_RESET}                           show this message

${C_BOLD}LOG FILE${C_RESET}
  $REPLAY_LOG
  (override via \$ASHLR_REPLAY_LOG_PATH)

${C_BOLD}ENVIRONMENT${C_RESET}
  ASHLR_REPLAY_LOG        "0" disables all writes (kill switch)
  ASHLR_REPLAY_LOG_PATH   override log file location

${C_BOLD}EXAMPLES${C_RESET}
  aw replay list
  aw replay compare abc123 def456
  aw replay diff abc123
  aw replay export abc123 --format csv > session.csv
  aw replay analyze-divergence
  aw doctor --analyze-divergence
EOF
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift || true
  case "$cmd" in
    list)                cmd_list             "$@" ;;
    show)                cmd_show             "$@" ;;
    compare)             cmd_compare          "$@" ;;
    diff)                cmd_diff             "$@" ;;
    export)              cmd_export           "$@" ;;
    analyze-divergence|analyze_divergence|divergence)
                         cmd_analyze_divergence "$@" ;;
    validate-sla|validate_sla|sla)
                         cmd_validate_sla       "$@" ;;
    help|-h|--help)      cmd_help                  ;;
    *)
      printf "%sERROR:%s unknown subcommand '%s'\n" "$C_RED" "$C_RESET" "$cmd" >&2
      echo >&2
      cmd_help >&2
      exit 2
      ;;
  esac
}

main "$@"
