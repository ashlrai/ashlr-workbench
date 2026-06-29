#!/usr/bin/env bash
# mcp-perf-dashboard.sh — MCP Tool Latency Dashboard
#
# Reads ~/.ashlr-workbench/mcp-perf.jsonl, computes per-tool statistics
# (p50/p95/p99, mean, trend), and renders a human-readable table or CSV
# agent × tool heatmap with color-coded SLA threshold violations.
#
# Usage:
#   bash scripts/mcp-perf-dashboard.sh [options]
#
# Options:
#   --csv              emit CSV matrix (agent × tool latency) instead of table
#   --log <path>       override JSONL log path
#   --sla <ms>         SLA threshold in ms for color coding (default 2000)
#   --warn <ms>        warning threshold in ms (default 1000)
#   --last <N>         only consider the last N records per tool (default: all)
#   --server <name>    filter to a specific server
#   --agent <name>     filter to a specific agent
#   --help             show this help
#
# Exit codes:
#   0  dashboard rendered (or no data yet)
#   1  SLA violations detected
#
# Designed for macOS bash 3.2 + python3 — no jq, no GNU tools.

set -uo pipefail

# ─── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
MCP_PERF_LOG="${MCP_PERF_LOG:-$HOME/.ashlr-workbench/mcp-perf.jsonl}"
SLA_MS="${MCP_PERF_SLA_MS:-2000}"
WARN_MS="${MCP_PERF_WARN_MS:-1000}"
LAST_N=""
FILTER_SERVER=""
FILTER_AGENT=""
OUTPUT_MODE="table"  # table | csv

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

die()  { printf "%sError:%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
info() { printf "%s•%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --csv)              OUTPUT_MODE="csv" ;;
    --log)              shift; MCP_PERF_LOG="${1:-$MCP_PERF_LOG}" ;;
    --sla)              shift; SLA_MS="${1:-$SLA_MS}" ;;
    --warn)             shift; WARN_MS="${1:-$WARN_MS}" ;;
    --last)             shift; LAST_N="${1:-}" ;;
    --server)           shift; FILTER_SERVER="${1:-}" ;;
    --agent)            shift; FILTER_AGENT="${1:-}" ;;
    --help|-h)
      cat <<EOF
${C_BOLD}mcp-perf-dashboard.sh${C_RESET} — MCP Tool Latency Dashboard

${C_BOLD}USAGE${C_RESET}
  bash scripts/mcp-perf-dashboard.sh [options]

${C_BOLD}OPTIONS${C_RESET}
  --csv            Emit CSV matrix (agent×tool) instead of human table
  --log <path>     JSONL log path (default: ~/.ashlr-workbench/mcp-perf.jsonl)
  --sla <ms>       SLA threshold ms — violations colored red (default: 2000)
  --warn <ms>      Warning threshold ms — colored yellow (default: 1000)
  --last <N>       Use only the last N records per tool (default: all)
  --server <name>  Filter to one server (efficiency|sql|bash|...)
  --agent <name>   Filter to one agent (openhands|goose|aider|ashlrcode)
  --help           Show this help

${C_BOLD}ENVIRONMENT${C_RESET}
  MCP_PERF_LOG       Override log file path
  MCP_PERF_SLA_MS    SLA threshold in ms
  MCP_PERF_WARN_MS   Warning threshold in ms

${C_BOLD}LOG FORMAT${C_RESET}
  JSONL at \$MCP_PERF_LOG:
  {"ts":"…","agent":"…","server":"…","tool":"…","args_hash":"…","latency_ms":N,"result_size":N,"status":"ok"}

${C_BOLD}EXAMPLES${C_RESET}
  # Human table (default)
  bash scripts/mcp-perf-dashboard.sh

  # CSV matrix for bash server only
  bash scripts/mcp-perf-dashboard.sh --csv --server bash

  # SLA check: fail if any p95 > 500ms
  bash scripts/mcp-perf-dashboard.sh --sla 500
EOF
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# ─── Check log exists ─────────────────────────────────────────────────────────
if [ ! -f "$MCP_PERF_LOG" ]; then
  printf "%s(no perf log yet at %s)%s\n" "$C_DIM" "$MCP_PERF_LOG" "$C_RESET"
  printf "Run %saw health --perf%s or %smcp_perf_baseline_all%s to collect data.\n" \
    "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
  exit 0
fi

LINE_COUNT="$(wc -l < "$MCP_PERF_LOG" | tr -d ' ')"
if [ "${LINE_COUNT:-0}" -eq 0 ]; then
  printf "%s(perf log exists but is empty)%s\n" "$C_DIM" "$MCP_PERF_LOG"
  exit 0
fi

# ─── Python analysis engine ───────────────────────────────────────────────────
# All stats computation is done in a single python3 invocation to avoid
# multiple file reads and external tools (awk/sort with -n not portable).
python3 - \
  "$MCP_PERF_LOG" \
  "$OUTPUT_MODE" \
  "${SLA_MS}" \
  "${WARN_MS}" \
  "${LAST_N:-0}" \
  "${FILTER_SERVER:-}" \
  "${FILTER_AGENT:-}" \
  "${NO_COLOR:-}" \
  "${C_RESET}" "${C_BOLD}" "${C_DIM}" "${C_RED}" "${C_GREEN}" "${C_YELLOW}" "${C_CYAN}" \
  <<'PYEOF'
import json, sys, math, os
from collections import defaultdict
from datetime import datetime, timezone

log_path    = sys.argv[1]
mode        = sys.argv[2]
sla_ms      = int(sys.argv[3])
warn_ms     = int(sys.argv[4])
last_n      = int(sys.argv[5])
flt_server  = sys.argv[6]
flt_agent   = sys.argv[7]
no_color    = sys.argv[8]

C_RESET  = sys.argv[9]  if not no_color else ""
C_BOLD   = sys.argv[10] if not no_color else ""
C_DIM    = sys.argv[11] if not no_color else ""
C_RED    = sys.argv[12] if not no_color else ""
C_GREEN  = sys.argv[13] if not no_color else ""
C_YELLOW = sys.argv[14] if not no_color else ""
C_CYAN   = sys.argv[15] if not no_color else ""

AGENTS  = ["openhands", "goose", "aider", "ashlrcode"]
SERVERS = ["efficiency", "sql", "bash", "tree", "http", "diff", "logs", "genome", "orient", "github"]

def pct(data, p):
    if not data: return 0
    s = sorted(data)
    i = (p / 100) * (len(s) - 1)
    lo, hi = int(i), min(int(i) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (i - lo)

def color_ms(ms, sla, warn):
    if ms <= 0: return C_DIM + "-" + C_RESET
    if ms >= sla: return C_RED + str(ms) + C_RESET
    if ms >= warn: return C_YELLOW + str(ms) + C_RESET
    return C_GREEN + str(ms) + C_RESET

# key: (agent, server, tool) → list of latency_ms (ok only)
records = defaultdict(list)
all_records = []  # for trend computation: (ts, agent, server, tool, latency_ms)

with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
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
        agent   = o.get("agent", "?")
        server  = o.get("server", "?")
        tool    = o.get("tool", "?")
        lat     = o.get("latency_ms", 0)
        status  = o.get("status", "ok")
        ts      = o.get("ts", "")

        if flt_server and server != flt_server:
            continue
        if flt_agent and agent != flt_agent:
            continue
        if status not in ("ok",):
            continue  # Only count successful probes in stats

        records[(agent, server, tool)].append((ts, lat))
        all_records.append((ts, agent, server, tool, lat))

# Apply last_n trimming per (agent, server, tool) key.
trimmed = {}
for key, vals in records.items():
    vals_sorted = sorted(vals, key=lambda x: x[0])
    if last_n > 0:
        vals_sorted = vals_sorted[-last_n:]
    trimmed[key] = [v[1] for v in vals_sorted]

records = trimmed

# ─── Compute per-tool stats ────────────────────────────────────────────────────
def stats(lats):
    if not lats:
        return None
    s = sorted(lats)
    mean = sum(s) / len(s)
    return {
        "n":    len(s),
        "mean": int(mean),
        "p50":  int(pct(s, 50)),
        "p95":  int(pct(s, 95)),
        "p99":  int(pct(s, 99)),
        "min":  s[0],
        "max":  s[-1],
    }

# Aggregate across all agents per (server, tool) for summary view.
global_stats = defaultdict(list)
for (agent, server, tool), lats in records.items():
    global_stats[(server, tool)].extend(lats)

# ─── CSV mode ─────────────────────────────────────────────────────────────────
if mode == "csv":
    # Header: tool, then one column per agent (p50_ms).
    agents_seen = sorted(set(a for (a, s, t) in records.keys()))
    if not agents_seen:
        print("(no data)")
        sys.exit(0)

    header = ["server", "tool"] + [a + "_p50ms" for a in agents_seen]
    print(",".join(header))

    all_tools = sorted(set((s, t) for (a, s, t) in records.keys()))
    for (server, tool) in all_tools:
        row = [server, tool]
        for agent in agents_seen:
            lats = records.get((agent, server, tool), [])
            st = stats(lats)
            row.append(str(st["p50"]) if st else "-")
        print(",".join(row))
    sys.exit(0)

# ─── Table mode ───────────────────────────────────────────────────────────────
if not records:
    print(C_DIM + "(no matching records)" + C_RESET)
    sys.exit(0)

print()
print(C_BOLD + "MCP Tool Latency Dashboard" + C_RESET)
print(C_DIM + "  log: " + log_path + C_RESET)
print(C_DIM + "  SLA: " + str(sla_ms) + "ms  warn: " + str(warn_ms) + "ms" + C_RESET)

# ─── Per-server × per-tool table ──────────────────────────────────────────────
servers_seen = sorted(set(s for (a, s, t) in records.keys()))
violations = 0

for server in servers_seen:
    print()
    print(C_BOLD + "  " + server.upper() + C_RESET)
    print(C_DIM + "  {:<32s}  {:>5s}  {:>5s}  {:>5s}  {:>5s}  {:>6s}  {:>4s}".format(
        "tool", "p50", "p95", "p99", "mean", "max", "n") + C_RESET)
    print("  " + "─" * 70)

    tools_seen = sorted(set(t for (a, sv, t) in records.keys() if sv == server))
    for tool in tools_seen:
        lats = global_stats.get((server, tool), [])
        st = stats(lats)
        if not st:
            continue
        p50  = st["p50"]
        p95  = st["p95"]
        p99  = st["p99"]
        mean = st["mean"]
        mx   = st["max"]
        n    = st["n"]

        # Color the p95 column as the primary SLA indicator.
        p50c  = color_ms(p50,  sla_ms, warn_ms)
        p95c  = color_ms(p95,  sla_ms, warn_ms)
        p99c  = color_ms(p99,  sla_ms, warn_ms)
        meanc = color_ms(mean, sla_ms, warn_ms)
        mxc   = color_ms(mx,   sla_ms, warn_ms)

        if p95 >= sla_ms:
            violations += 1

        print("  {:<32s}  {:>5s}  {:>5s}  {:>5s}  {:>5s}  {:>6s}  {:>4d}".format(
            tool,
            p50c, p95c, p99c, meanc, mxc, n
        ))

# ─── Agent × tool heatmap (p50 ms) ────────────────────────────────────────────
all_tools_sorted = sorted(set((s, t) for (a, s, t) in records.keys()))
agents_seen      = sorted(set(a for (a, s, t) in records.keys()))

if len(agents_seen) > 1 and all_tools_sorted:
    print()
    print(C_BOLD + "  Agent × Tool Heatmap (p50 ms)" + C_RESET)

    # Compute column widths.
    max_tool_col = max(len(t) for (s, t) in all_tools_sorted)
    max_tool_col = max(max_tool_col, 30)
    col_w = 10

    header_row = "  " + "{:<{w}}".format("tool", w=max_tool_col)
    for agent in agents_seen:
        header_row += "  {:>{w}}".format(agent[:col_w], w=col_w)
    print(C_DIM + header_row + C_RESET)
    print("  " + "─" * (max_tool_col + (col_w + 2) * len(agents_seen) + 2))

    for (server, tool) in all_tools_sorted:
        row = "  " + "{:<{w}}".format(tool, w=max_tool_col)
        for agent in agents_seen:
            lats = records.get((agent, server, tool), [])
            st   = stats(lats)
            if st:
                cell = color_ms(st["p50"], sla_ms, warn_ms)
                # Pad after the escape codes for alignment.
                row += "  {:>{w}}".format(st["p50"], w=col_w)
            else:
                row += "  " + C_DIM + "{:>{w}}".format("-", w=col_w) + C_RESET
        print(row)

# ─── Legend ───────────────────────────────────────────────────────────────────
print()
print("  " + C_DIM + "Legend: " + C_RESET +
      C_GREEN + "■ ok (<" + str(warn_ms) + "ms)" + C_RESET + "  " +
      C_YELLOW + "■ warn (<" + str(sla_ms) + "ms)" + C_RESET + "  " +
      C_RED + "■ SLA violation (≥" + str(sla_ms) + "ms)" + C_RESET)

# ─── Summary + trend ──────────────────────────────────────────────────────────
total_probes = sum(len(v) for v in records.values())
all_lats = [l for v in records.values() for l in v]
if all_lats:
    overall_p50 = int(pct(sorted(all_lats), 50))
    overall_p95 = int(pct(sorted(all_lats), 95))
    print()
    print(C_BOLD + "  Summary" + C_RESET)
    print("  total probes: {:d}   overall p50: {:d}ms   p95: {:d}ms   violations: {:d}".format(
        total_probes, overall_p50, overall_p95, violations))

if violations > 0:
    sys.exit(1)
else:
    sys.exit(0)
PYEOF

DASHBOARD_EXIT=$?
exit $DASHBOARD_EXIT
