#!/usr/bin/env bash
# session-divergence-analyzer.sh — Core metric extraction + SLA enforcement for
# cross-agent session divergence analysis.
#
# Sourced by session-replay.sh to provide the validate-sla subcommand.
#
# Public functions:
#   sda_load_sessions        LOG_PATH — parse all sessions from a JSONL replay log
#   sda_extract_metrics      LOG_PATH BASELINE_AGENT THRESHOLD_MS — compute per-agent metrics
#   sda_check_sla            METRICS_JSON THRESHOLD_MS — flag SLA violations
#   sda_render_scorecard     METRICS_JSON FORMAT OUT_PATH — write JSONL + HTML scorecard
#   sda_validate_sla         LOG_PATH BASELINE_AGENT THRESHOLD_MS FORMAT OUT_DIR
#
# Contract:
#   - Bash 3.2-safe. No mapfile, no GNU-only flags.
#   - Never aborts the caller — all errors are surfaced as non-zero returns with
#     a message to stderr.
#   - Honors ASHLR_REPLAY_LOG_PATH for the replay log location.
#   - All heavy lifting is done in embedded python3 (same pattern as session-replay.sh).

# Guard against double-sourcing.
if [ -n "${_ASHLR_SDA_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_SDA_SOURCED=1

# ─── Internal helpers ─────────────────────────────────────────────────────────

_sda_ts() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)"
  case "$ts" in
    *3NZ|"") ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" ;;
  esac
  printf '%s' "$ts"
}

_sda_die() { printf "ERROR: %s\n" "$*" >&2; return 1; }

# ─── Python core ──────────────────────────────────────────────────────────────
# All metric extraction is performed by a single embedded Python script so that
# complex statistics (p50/p95/p99, trend detection, tool-coverage diff) are
# computed correctly without adding external dependencies.

# sda_extract_metrics LOG_PATH BASELINE_AGENT THRESHOLD_MS
# Prints a JSON blob: { agents: {name: {metrics}}, violations: [...], generated_at: ... }
sda_extract_metrics() {
  local log_path="${1:-}"
  local baseline_agent="${2:-}"
  local threshold_ms="${3:-2000}"

  [ -f "$log_path" ] || { _sda_die "log not found: $log_path"; return 1; }

  python3 - "$log_path" "$baseline_agent" "$threshold_ms" <<'PY'
import sys, json, math
from collections import defaultdict

log_path       = sys.argv[1]
baseline_agent = sys.argv[2]        # may be empty → first agent with data
threshold_ms   = float(sys.argv[3])

# ── Parse JSONL ───────────────────────────────────────────────────────────────
sessions = {}   # sid -> {agent, model, tool_seq[], tool_lats[], llm_lats[],
                #          llm_turns, status, duration, tool_errors, mcp_timeouts,
                #          tools_used set, prompt_tokens, completion_tokens}
order = []

with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        sid = o.get("session", "")
        if not sid:
            continue
        if sid not in sessions:
            sessions[sid] = {
                "agent": "?", "model": "?",
                "tool_seq": [], "tool_lats": [], "llm_lats": [],
                "llm_turns": 0, "status": "running", "duration": 0,
                "tool_errors": 0, "mcp_timeouts": 0,
                "tools_used": set(),
                "prompt_tokens": 0, "completion_tokens": 0,
                "ts_start": None,
            }
            order.append(sid)
        s = sessions[sid]
        ev = o.get("event", "")

        if ev == "session_init":
            s["agent"]  = o.get("agent", s["agent"])
            s["model"]  = o.get("llm_endpoint", s["model"])
            s["ts_start"] = o.get("ts")

        elif ev == "tool_call":
            tool_name = o.get("tool", "?")
            s["tool_seq"].append(tool_name)
            s["tools_used"].add(tool_name)
            try:
                s["tool_lats"].append(float(o.get("latency_ms", 0)))
            except (ValueError, TypeError):
                pass
            # classify MCP timeout: tool calls that use mcp_ prefix and have
            # high latency or an explicit error field
            if tool_name.startswith("mcp_") or tool_name.startswith("ashlr__"):
                if o.get("error") or o.get("timed_out"):
                    s["mcp_timeouts"] += 1
                elif s["tool_lats"] and s["tool_lats"][-1] > threshold_ms * 3:
                    s["mcp_timeouts"] += 1
            if o.get("error") or o.get("exit_code", 0) not in (0, None, "0", ""):
                s["tool_errors"] += 1

        elif ev == "llm_response":
            s["llm_turns"] += 1
            try:
                s["llm_lats"].append(float(o.get("latency_ms", 0)))
            except (ValueError, TypeError):
                pass
            try:
                s["prompt_tokens"] += int(o.get("prompt_tokens", 0))
                s["completion_tokens"] += int(o.get("completion_tokens", 0))
            except (ValueError, TypeError):
                pass

        elif ev == "session_end":
            s["status"] = o.get("status", s["status"])
            try:
                s["duration"] = float(o.get("duration_secs", 0))
            except (ValueError, TypeError):
                pass

# ── Per-agent aggregation ─────────────────────────────────────────────────────

def percentile(data, p):
    if not data:
        return 0.0
    sd = sorted(data)
    idx = (p / 100.0) * (len(sd) - 1)
    lo = int(idx)
    hi = min(lo + 1, len(sd) - 1)
    frac = idx - lo
    return sd[lo] + frac * (sd[hi] - sd[lo])

def stdev(data):
    if len(data) < 2:
        return 0.0
    mean = sum(data) / len(data)
    return math.sqrt(sum((x - mean) ** 2 for x in data) / (len(data) - 1))

by_agent = defaultdict(list)
for sid in order:
    s = sessions[sid]
    if s["agent"] != "?":
        by_agent[s["agent"]].append(s)

agents_out = {}
for agent, ss in by_agent.items():
    n = len(ss)
    all_tool_lats  = [l for s in ss for l in s["tool_lats"]]
    all_llm_lats   = [l for s in ss for l in s["llm_lats"]]
    all_tools_used = set()
    for s in ss:
        all_tools_used.update(s["tools_used"])
    durations = [s["duration"] for s in ss if s["duration"] > 0]
    errors    = sum(1 for s in ss if s["status"] not in ("ok", "success", "running"))
    mcp_to    = sum(s["mcp_timeouts"] for s in ss)
    tool_errs = sum(s["tool_errors"] for s in ss)
    total_calls = sum(len(s["tool_seq"]) for s in ss)
    mcp_timeout_rate = (mcp_to / total_calls * 100) if total_calls > 0 else 0.0
    tool_error_rate  = (tool_errs / total_calls * 100) if total_calls > 0 else 0.0

    # Trend: compute per-session avg latency and see if it's increasing
    # (positive slope means degradation over time)
    session_avg_lats = []
    for s in ss:
        if s["tool_lats"]:
            session_avg_lats.append(sum(s["tool_lats"]) / len(s["tool_lats"]))
    trend_slope = 0.0
    if len(session_avg_lats) >= 3:
        n_t = len(session_avg_lats)
        xs  = list(range(n_t))
        mx  = sum(xs) / n_t
        my  = sum(session_avg_lats) / n_t
        num = sum((xs[i] - mx) * (session_avg_lats[i] - my) for i in range(n_t))
        den = sum((x - mx) ** 2 for x in xs)
        trend_slope = num / den if den != 0 else 0.0

    agents_out[agent] = {
        "sessions":           n,
        "avg_tool_lat_ms":    round(sum(all_tool_lats) / len(all_tool_lats), 2) if all_tool_lats else 0.0,
        "p50_tool_lat_ms":    round(percentile(all_tool_lats, 50), 2),
        "p95_tool_lat_ms":    round(percentile(all_tool_lats, 95), 2),
        "p99_tool_lat_ms":    round(percentile(all_tool_lats, 99), 2),
        "stdev_tool_lat_ms":  round(stdev(all_tool_lats), 2),
        "avg_llm_lat_ms":     round(sum(all_llm_lats) / len(all_llm_lats), 2) if all_llm_lats else 0.0,
        "p99_llm_lat_ms":     round(percentile(all_llm_lats, 99), 2),
        "avg_duration_s":     round(sum(durations) / len(durations), 2) if durations else 0.0,
        "avg_tools_per_session": round(total_calls / n, 2),
        "avg_llm_turns":      round(sum(s["llm_turns"] for s in ss) / n, 2),
        "error_rate_pct":     round(errors / n * 100, 2),
        "mcp_timeout_rate_pct": round(mcp_timeout_rate, 2),
        "tool_error_rate_pct":  round(tool_error_rate, 2),
        "unique_tools":       sorted(list(all_tools_used)),
        "trend_slope_ms_per_session": round(trend_slope, 4),
        "total_tool_calls":   total_calls,
        "total_llm_calls":    sum(s["llm_turns"] for s in ss),
        "total_prompt_tokens":     sum(s["prompt_tokens"] for s in ss),
        "total_completion_tokens": sum(s["completion_tokens"] for s in ss),
    }

# ── SLA violation detection ───────────────────────────────────────────────────

violations = []
agents_list = list(agents_out.keys())

# Resolve baseline
bl = baseline_agent if baseline_agent in agents_out else (agents_list[0] if agents_list else None)

for agent, m in agents_out.items():

    # 1. Tool-call latency p99 > threshold_ms
    if m["p99_tool_lat_ms"] > threshold_ms:
        violations.append({
            "agent":   agent,
            "rule":    "tool_call_p99_latency",
            "message": f"{agent}: tool-call p99 latency {m['p99_tool_lat_ms']:.0f}ms exceeds threshold {threshold_ms:.0f}ms",
            "value":   m["p99_tool_lat_ms"],
            "threshold": threshold_ms,
            "severity": "critical" if m["p99_tool_lat_ms"] > threshold_ms * 2 else "warning",
        })

    # 2. MCP timeout rate > 5 %
    if m["mcp_timeout_rate_pct"] > 5.0:
        violations.append({
            "agent":   agent,
            "rule":    "mcp_timeout_rate",
            "message": f"{agent}: MCP timeout rate {m['mcp_timeout_rate_pct']:.1f}% exceeds 5% threshold",
            "value":   m["mcp_timeout_rate_pct"],
            "threshold": 5.0,
            "severity": "critical" if m["mcp_timeout_rate_pct"] > 15 else "warning",
        })

    # 3. Session error rate > 20 %
    if m["error_rate_pct"] > 20.0:
        violations.append({
            "agent":   agent,
            "rule":    "session_error_rate",
            "message": f"{agent}: session error rate {m['error_rate_pct']:.1f}% exceeds 20% threshold",
            "value":   m["error_rate_pct"],
            "threshold": 20.0,
            "severity": "critical",
        })

    # 4. Latency trend degradation: slope > 50 ms/session
    if m["trend_slope_ms_per_session"] > 50:
        violations.append({
            "agent":   agent,
            "rule":    "latency_trend_degradation",
            "message": f"{agent}: tool-call latency is trending up at {m['trend_slope_ms_per_session']:.1f}ms/session",
            "value":   m["trend_slope_ms_per_session"],
            "threshold": 50.0,
            "severity": "warning",
        })

# 5. Cross-agent systematic divergence (requires >= 2 agents)
if bl and len(agents_list) >= 2:
    bl_m = agents_out[bl]

    for agent in agents_list:
        if agent == bl:
            continue
        m = agents_out[agent]

        # Speed gap: an agent always faster/slower than baseline by > 2x p99
        if bl_m["p99_tool_lat_ms"] > 0 and m["p99_tool_lat_ms"] > 0:
            ratio = m["p99_tool_lat_ms"] / bl_m["p99_tool_lat_ms"]
            if ratio > 2.0:
                violations.append({
                    "agent": agent,
                    "rule":  "systematic_latency_gap",
                    "message": (f"{agent} p99 tool latency is {ratio:.1f}x slower than baseline "
                                f"{bl} ({m['p99_tool_lat_ms']:.0f}ms vs {bl_m['p99_tool_lat_ms']:.0f}ms)"),
                    "value": ratio,
                    "threshold": 2.0,
                    "severity": "warning",
                })

        # Tool-coverage gap: agent uses far fewer distinct tools
        bl_tools = set(bl_m["unique_tools"])
        ag_tools = set(m["unique_tools"])
        missing_tools = bl_tools - ag_tools
        if bl_tools and len(missing_tools) / len(bl_tools) > 0.3:
            violations.append({
                "agent": agent,
                "rule":  "tool_coverage_gap",
                "message": (f"{agent} is missing {len(missing_tools)}/{len(bl_tools)} "
                            f"tools used by baseline {bl}: {sorted(missing_tools)[:5]}"),
                "value": len(missing_tools),
                "threshold": int(len(bl_tools) * 0.3),
                "severity": "warning",
            })

# ── Systematic speed flags (non-SLA, informational) ──────────────────────────
speed_flags = []
if len(agents_list) >= 2:
    sorted_by_avg = sorted(agents_out.items(), key=lambda x: x[1]["avg_duration_s"])
    if sorted_by_avg[-1][1]["avg_duration_s"] > 0 and sorted_by_avg[0][1]["avg_duration_s"] > 0:
        ratio = sorted_by_avg[-1][1]["avg_duration_s"] / sorted_by_avg[0][1]["avg_duration_s"]
        if ratio >= 1.5:
            speed_flags.append(
                f"{sorted_by_avg[0][0]} consistently faster than {sorted_by_avg[-1][0]} "
                f"({ratio:.1f}x by avg session duration)"
            )

result = {
    "generated_at": "",   # filled by shell wrapper
    "log_path":     log_path,
    "baseline_agent": bl or "",
    "threshold_ms": threshold_ms,
    "agent_count":  len(agents_out),
    "session_count": len(sessions),
    "agents":       agents_out,
    "violations":   violations,
    "speed_flags":  speed_flags,
    "sla_passed":   len([v for v in violations if v["severity"] == "critical"]) == 0,
}
print(json.dumps(result))
PY
}

# ─── HTML report renderer ─────────────────────────────────────────────────────

# sda_render_html METRICS_JSON TEMPLATE_PATH OUT_PATH
# Renders the metrics JSON into an HTML report using the template.
sda_render_html() {
  local metrics_json="$1"
  local template_path="$2"
  local out_path="$3"

  python3 - "$metrics_json" "$template_path" "$out_path" <<'PY'
import sys, json, os, re
from datetime import datetime

metrics_json  = sys.argv[1]
template_path = sys.argv[2]
out_path      = sys.argv[3]

data = json.loads(metrics_json)

with open(template_path, "r", encoding="utf-8") as fh:
    tmpl = fh.read()

# ── Build per-agent table rows ────────────────────────────────────────────────
agent_rows = []
for agent, m in sorted(data["agents"].items()):
    sla_ok = not any(
        v["agent"] == agent and v["severity"] == "critical"
        for v in data["violations"]
    )
    badge = '<span class="badge badge-pass">PASS</span>' if sla_ok else \
            '<span class="badge badge-fail">FAIL</span>'
    trend_cls = "trend-up" if m["trend_slope_ms_per_session"] > 10 else \
                "trend-down" if m["trend_slope_ms_per_session"] < -10 else "trend-flat"
    trend_sym = "↑" if m["trend_slope_ms_per_session"] > 10 else \
                "↓" if m["trend_slope_ms_per_session"] < -10 else "→"
    agent_rows.append(f"""
      <tr>
        <td class="agent-name">{agent}</td>
        <td>{m['sessions']}</td>
        <td>{m['avg_tool_lat_ms']:.0f}</td>
        <td>{m['p50_tool_lat_ms']:.0f}</td>
        <td>{m['p95_tool_lat_ms']:.0f}</td>
        <td class="{'sla-breach' if m['p99_tool_lat_ms'] > data['threshold_ms'] else ''}">{m['p99_tool_lat_ms']:.0f}</td>
        <td class="{'sla-breach' if m['mcp_timeout_rate_pct'] > 5 else ''}">{m['mcp_timeout_rate_pct']:.1f}%</td>
        <td class="{'sla-breach' if m['error_rate_pct'] > 20 else ''}">{m['error_rate_pct']:.1f}%</td>
        <td>{m['avg_duration_s']:.1f}s</td>
        <td class="{trend_cls}">{trend_sym} {m['trend_slope_ms_per_session']:.1f}</td>
        <td>{len(m['unique_tools'])}</td>
        <td>{badge}</td>
      </tr>""")

agent_table_html = "\n".join(agent_rows)

# ── Build violations list ──────────────────────────────────────────────────────
if data["violations"]:
    viol_items = []
    for v in data["violations"]:
        cls = "violation-critical" if v["severity"] == "critical" else "violation-warning"
        viol_items.append(
            f'<li class="{cls}"><strong>[{v["severity"].upper()}]</strong> '
            f'<code>{v["rule"]}</code> — {v["message"]}</li>'
        )
    violations_html = "<ul>" + "\n".join(viol_items) + "</ul>"
else:
    violations_html = '<p class="all-pass">✓ No SLA violations detected.</p>'

# ── Speed flags ──────────────────────────────────────────────────────────────
speed_flags_html = ""
if data.get("speed_flags"):
    flags = "".join(f"<li>{f}</li>" for f in data["speed_flags"])
    speed_flags_html = f"<ul class='speed-flags'>{flags}</ul>"
else:
    speed_flags_html = '<p class="all-pass">No systematic speed divergences.</p>'

# ── Tool coverage matrix ──────────────────────────────────────────────────────
all_tools = sorted({t for m in data["agents"].values() for t in m["unique_tools"]})
tool_header = "".join(f"<th>{t}</th>" for t in all_tools)
tool_rows = []
for agent, m in sorted(data["agents"].items()):
    cells = "".join(
        f'<td class="tool-present">✓</td>' if t in m["unique_tools"]
        else f'<td class="tool-absent">✗</td>'
        for t in all_tools
    )
    tool_rows.append(f"<tr><td class='agent-name'>{agent}</td>{cells}</tr>")
tool_matrix_html = f"""
<table class="tool-matrix">
  <thead><tr><th>Agent</th>{tool_header}</tr></thead>
  <tbody>{"".join(tool_rows)}</tbody>
</table>"""

# ── Summary statistics ────────────────────────────────────────────────────────
overall_status = "PASS" if data["sla_passed"] else "FAIL"
overall_cls    = "status-pass" if data["sla_passed"] else "status-fail"
generated_at   = data.get("generated_at", datetime.utcnow().isoformat() + "Z")
critical_count = sum(1 for v in data["violations"] if v["severity"] == "critical")
warning_count  = sum(1 for v in data["violations"] if v["severity"] == "warning")

replacements = {
    "{{GENERATED_AT}}":      generated_at,
    "{{LOG_PATH}}":          data["log_path"],
    "{{BASELINE_AGENT}}":    data["baseline_agent"] or "auto",
    "{{THRESHOLD_MS}}":      str(int(data["threshold_ms"])),
    "{{AGENT_COUNT}}":       str(data["agent_count"]),
    "{{SESSION_COUNT}}":     str(data["session_count"]),
    "{{OVERALL_STATUS}}":    overall_status,
    "{{OVERALL_STATUS_CLS}}": overall_cls,
    "{{CRITICAL_COUNT}}":    str(critical_count),
    "{{WARNING_COUNT}}":     str(warning_count),
    "{{AGENT_TABLE_ROWS}}":  agent_table_html,
    "{{VIOLATIONS_HTML}}":   violations_html,
    "{{SPEED_FLAGS_HTML}}":  speed_flags_html,
    "{{TOOL_MATRIX_HTML}}":  tool_matrix_html,
}

html = tmpl
for placeholder, value in replacements.items():
    html = html.replace(placeholder, value)

os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(html)

print(f"ok:{out_path}")
PY
}

# ─── Public: sda_validate_sla ─────────────────────────────────────────────────
# sda_validate_sla LOG_PATH BASELINE_AGENT THRESHOLD_MS FORMAT OUT_DIR
#
# Orchestrates the full validate-sla pipeline:
#   1. Extract metrics from the replay log.
#   2. Write compliance-scorecard.jsonl to OUT_DIR.
#   3. Optionally render HTML report (when FORMAT includes html).
#   4. Print a summary to stdout.
#   5. Return exit code 1 if any critical SLA violations were found.
sda_validate_sla() {
  local log_path="${1:-}"
  local baseline_agent="${2:-}"
  local threshold_ms="${3:-2000}"
  local report_format="${4:-both}"  # jsonl | html | both
  local out_dir="${5:-.}"

  [ -f "$log_path" ] || { _sda_die "replay log not found: $log_path"; return 1; }

  local ts_now
  ts_now="$(_sda_ts)"

  # Step 1: extract metrics
  local metrics_json
  metrics_json="$(sda_extract_metrics "$log_path" "$baseline_agent" "$threshold_ms")" \
    || { _sda_die "metric extraction failed"; return 1; }

  # Inject generated_at
  metrics_json="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
data['generated_at'] = '${ts_now}'
print(json.dumps(data))
" <<< "$metrics_json")"

  mkdir -p "$out_dir"

  local jsonl_path="${out_dir}/compliance-scorecard.jsonl"
  local html_path="${out_dir}/sla-report.html"

  # Step 2: write JSONL scorecard
  if [[ "$report_format" == "jsonl" || "$report_format" == "both" ]]; then
    python3 - "$metrics_json" "$jsonl_path" <<'PY'
import json, sys
data    = json.loads(sys.argv[1])
outpath = sys.argv[2]
lines = []
# One summary record per agent
for agent, m in data["agents"].items():
    rec = {"record_type": "agent_metrics", "generated_at": data["generated_at"],
           "agent": agent, "baseline": data["baseline_agent"],
           "threshold_ms": data["threshold_ms"]}
    rec.update(m)
    rec["unique_tools"] = ",".join(rec["unique_tools"])
    lines.append(json.dumps(rec))
# One record per violation
for v in data["violations"]:
    rec = {"record_type": "sla_violation", "generated_at": data["generated_at"]}
    rec.update(v)
    lines.append(json.dumps(rec))
# Summary record
lines.append(json.dumps({
    "record_type":     "summary",
    "generated_at":    data["generated_at"],
    "log_path":        data["log_path"],
    "agent_count":     data["agent_count"],
    "session_count":   data["session_count"],
    "violation_count": len(data["violations"]),
    "critical_count":  sum(1 for v in data["violations"] if v["severity"] == "critical"),
    "warning_count":   sum(1 for v in data["violations"] if v["severity"] == "warning"),
    "sla_passed":      data["sla_passed"],
}))
with open(outpath, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
print(f"ok:{outpath}")
PY
    [ $? -eq 0 ] || { _sda_die "JSONL scorecard write failed"; return 1; }
  fi

  # Step 3: render HTML if requested
  if [[ "$report_format" == "html" || "$report_format" == "both" ]]; then
    # Locate template — resolve relative to this script's directory
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local template_path="${script_dir}/../../docs/templates/sla-report.html"
    template_path="$(cd "$(dirname "$template_path")" && pwd)/$(basename "$template_path")"

    if [ -f "$template_path" ]; then
      local render_result
      render_result="$(sda_render_html "$metrics_json" "$template_path" "$html_path")" \
        || { _sda_die "HTML render failed"; return 1; }
    else
      printf "  (HTML template not found at %s — skipping HTML report)\n" "$template_path" >&2
    fi
  fi

  # Step 4: print summary to stdout
  python3 - "$metrics_json" "$threshold_ms" <<'PY'
import json, sys
data  = json.loads(sys.argv[1])
thr   = float(sys.argv[2])

BOLD  = "\033[1m"
RED   = "\033[31m"
GREEN = "\033[32m"
YELLOW= "\033[33m"
CYAN  = "\033[36m"
DIM   = "\033[2m"
RST   = "\033[0m"

import os
if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
    BOLD = RED = GREEN = YELLOW = CYAN = DIM = RST = ""

print()
print(f"{BOLD}SLA Compliance Scorecard{RST}")
print(f"{DIM}  Generated : {data['generated_at']}{RST}")
print(f"{DIM}  Log       : {data['log_path']}{RST}")
print(f"{DIM}  Baseline  : {data['baseline_agent'] or 'auto'}{RST}")
print(f"{DIM}  Threshold : {int(thr)}ms p99 tool latency{RST}")
print(f"{DIM}  Sessions  : {data['session_count']}  Agents: {data['agent_count']}{RST}")
print()

# Per-agent table
col = [14, 8, 10, 10, 10, 12, 12, 10, 11, 10]
hdr = ["AGENT", "SESSIONS", "AVG(ms)", "P50(ms)", "P95(ms)", "P99(ms)▶SLA",
       "MCP TIMEOUT", "ERR RATE", "AVG DUR(s)", "TREND"]
sep = "  ".join("-" * c for c in col)
fmt = "  ".join(f"{{:<{c}}}" for c in col)
print(f"  {BOLD}{fmt.format(*hdr)}{RST}")
print(f"  {sep}")

for agent, m in sorted(data["agents"].items()):
    p99_ok = m["p99_tool_lat_ms"] <= thr
    mcp_ok = m["mcp_timeout_rate_pct"] <= 5.0
    err_ok = m["error_rate_pct"] <= 20.0
    p99_s  = f"{m['p99_tool_lat_ms']:.0f} {'✓' if p99_ok else '✗'}"
    mcp_s  = f"{m['mcp_timeout_rate_pct']:.1f}% {'✓' if mcp_ok else '✗'}"
    err_s  = f"{m['error_rate_pct']:.1f}% {'✓' if err_ok else '✗'}"
    slope  = m["trend_slope_ms_per_session"]
    trend_s = f"↑{slope:.1f}" if slope > 10 else (f"↓{abs(slope):.1f}" if slope < -10 else f"→{slope:.1f}")
    p99_c  = GREEN if p99_ok else RED
    mcp_c  = GREEN if mcp_ok else RED
    err_c  = GREEN if err_ok else RED
    row = fmt.format(
        agent[:col[0]],
        str(m['sessions']),
        f"{m['avg_tool_lat_ms']:.0f}",
        f"{m['p50_tool_lat_ms']:.0f}",
        f"{m['p95_tool_lat_ms']:.0f}",
        p99_s[:col[5]],
        mcp_s[:col[6]],
        err_s[:col[7]],
        f"{m['avg_duration_s']:.1f}s",
        trend_s[:col[9]],
    )
    print(f"  {row}")

print()

# Violations
viols = data["violations"]
crits = [v for v in viols if v["severity"] == "critical"]
warns = [v for v in viols if v["severity"] == "warning"]
if crits:
    print(f"  {RED}{BOLD}CRITICAL SLA VIOLATIONS ({len(crits)}){RST}")
    for v in crits:
        print(f"    {RED}✗{RST} [{v['rule']}] {v['message']}")
if warns:
    print(f"  {YELLOW}{BOLD}WARNINGS ({len(warns)}){RST}")
    for v in warns:
        print(f"    {YELLOW}⚠{RST} [{v['rule']}] {v['message']}")
if not viols:
    print(f"  {GREEN}✓ All SLA checks passed{RST}")

if data.get("speed_flags"):
    print()
    print(f"  {CYAN}Speed flags:{RST}")
    for f in data["speed_flags"]:
        print(f"    • {f}")

print()
status_c = GREEN if data["sla_passed"] else RED
status_s = "PASSED" if data["sla_passed"] else "FAILED"
print(f"  {BOLD}Overall SLA: {status_c}{status_s}{RST}")
print()
PY

  # Step 5: return exit code reflecting SLA pass/fail
  local sla_passed
  sla_passed="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('1' if d['sla_passed'] else '0')" <<< "$metrics_json")"
  if [ "$sla_passed" = "0" ]; then
    return 1
  fi
  return 0
}
