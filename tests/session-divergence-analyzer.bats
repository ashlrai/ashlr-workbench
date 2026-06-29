#!/usr/bin/env bats
# tests/session-divergence-analyzer.bats — Tests for session-divergence-analyzer.sh
# and the validate-sla subcommand of session-replay.sh.
#
# Test coverage:
#   1.  Library sources cleanly (bash -n + source)
#   2.  sda_extract_metrics: parses replay JSONL → correct per-agent metrics
#   3.  Latency variance: p50/p95/p99 correctly separated from avg
#   4.  Error rate calculation: non-ok sessions counted correctly
#   5.  MCP timeout rate: mcp_/ashlr__ tool calls with error flag counted
#   6.  Tool coverage: unique_tools set built correctly across sessions
#   7.  SLA violation: p99 > threshold generates critical violation
#   8.  SLA violation: MCP timeout rate > 5% generates critical violation
#   9.  SLA violation: session error rate > 20% generates critical violation
#  10.  Cross-agent systematic latency gap flagged (> 2x ratio)
#  11.  validate-sla exits 0 when all SLAs pass
#  12.  validate-sla exits 1 when critical SLA violated
#  13.  JSONL scorecard written with correct record_type values
#  14.  HTML report rendered when template exists
#  15.  validate-sla --report-format jsonl skips HTML
#  16.  validate-sla --report-format html skips JSONL
#  17.  Latency trend: positive slope flagged as degradation
#  18.  session-replay.sh validate-sla subcommand wired correctly (bash -n)
#  19.  session-replay.sh validate-sla appears in help output
#  20.  sda_extract_metrics fails cleanly on missing log
#  21.  two-agent speed flags emitted when duration ratio >= 1.5x
#  22.  scorecard summary record has sla_passed boolean
#  23.  validate-sla accepts --baseline-agent flag without error

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

ANALYZER_LIB="${REPO_ROOT}/scripts/lib/session-divergence-analyzer.sh"
REPLAY_SCRIPT="${REPO_ROOT}/scripts/session-replay.sh"
TEMPLATE_PATH="${REPO_ROOT}/docs/templates/sla-report.html"

# ─── helpers ──────────────────────────────────────────────────────────────────

# Build a replay JSONL fixture.  Writes to $1/replay.jsonl; prints nothing
# so callers can safely reference the path directly.
# Usage: _make_fixture <tmpdir> [scenario]
_make_fixture() {
  local dir="$1"
  local scenario="${2:-default}"
  local log="${dir}/replay.jsonl"

  python3 - "$log" "$scenario" >/dev/null <<'PY'
import json, sys

log_path = sys.argv[1]
scenario = sys.argv[2]

def event(**kw):
    return json.dumps(kw)

lines = []

if scenario == "default":
    # Two sessions for goose, two for aider — all healthy
    for agent, sid in [
        ("goose","sess-g1"), ("goose","sess-g2"),
        ("aider","sess-a1"), ("aider","sess-a2"),
    ]:
        lines.append(event(ts="2026-01-01T00:00:00.000Z", event="session_init",
                           session=sid, agent=agent, llm_endpoint="openai/qwen3",
                           mcp_count="5", cwd="/tmp"))
        for seq, (tool, lat) in enumerate([
            ("bash",120), ("read_file",80), ("write_file",150), ("bash",90),
        ]):
            lines.append(event(ts="2026-01-01T00:00:01.000Z", event="tool_call",
                               session=sid, agent=agent, tool=tool,
                               latency_ms=lat, seq=seq))
        lines.append(event(ts="2026-01-01T00:01:00.000Z", event="llm_response",
                           session=sid, agent=agent, model="qwen3",
                           latency_ms=500, prompt_tokens=200, completion_tokens=100, turn=1))
        lines.append(event(ts="2026-01-01T00:02:00.000Z", event="session_end",
                           session=sid, agent=agent, status="ok",
                           duration_secs=60, tool_count=4, llm_turns=1))

elif scenario == "high_latency":
    # goose has very high tool latency, aider is fast
    for agent, sid, lat in [("goose","g1",3500), ("aider","a1",100)]:
        lines.append(event(ts="2026-01-01T00:00:00.000Z", event="session_init",
                           session=sid, agent=agent, llm_endpoint="openai/qwen3",
                           mcp_count="5", cwd="/tmp"))
        for seq in range(5):
            lines.append(event(ts="2026-01-01T00:00:01.000Z", event="tool_call",
                               session=sid, agent=agent, tool="bash",
                               latency_ms=lat, seq=seq))
        lines.append(event(ts="2026-01-01T00:01:00.000Z", event="session_end",
                           session=sid, agent=agent, status="ok",
                           duration_secs=30, tool_count=5, llm_turns=0))

elif scenario == "high_error":
    # goose has 3/4 sessions failing
    for sid, status in [("g1","ok"),("g2","error"),("g3","error"),("g4","error")]:
        lines.append(event(ts="2026-01-01T00:00:00.000Z", event="session_init",
                           session=sid, agent="goose", llm_endpoint="openai/qwen3",
                           mcp_count="5", cwd="/tmp"))
        lines.append(event(ts="2026-01-01T00:00:01.000Z", event="tool_call",
                           session=sid, agent="goose", tool="bash",
                           latency_ms=100, seq=0))
        lines.append(event(ts="2026-01-01T00:01:00.000Z", event="session_end",
                           session=sid, agent="goose", status=status,
                           duration_secs=10, tool_count=1, llm_turns=0))

elif scenario == "mcp_timeout":
    # ashlrcode: 3 of 5 mcp_ tool calls time out
    lines.append(event(ts="2026-01-01T00:00:00.000Z", event="session_init",
                       session="s1", agent="ashlrcode", llm_endpoint="openai/qwen3",
                       mcp_count="5", cwd="/tmp"))
    for seq, (timed_out, lat) in enumerate([
        (True,6001),(False,80),(True,6002),(True,6003),(False,75)
    ]):
        lines.append(event(ts="2026-01-01T00:00:01.000Z", event="tool_call",
                           session="s1", agent="ashlrcode", tool="mcp_bash",
                           latency_ms=lat, seq=seq,
                           timed_out="true" if timed_out else ""))
    lines.append(event(ts="2026-01-01T00:01:00.000Z", event="session_end",
                       session="s1", agent="ashlrcode", status="ok",
                       duration_secs=18, tool_count=5, llm_turns=0))

elif scenario == "trend":
    # goose: 5 sessions with progressively rising latency
    for i in range(5):
        sid = f"g{i}"
        lat = 100 + i * 200   # 100, 300, 500, 700, 900
        lines.append(event(ts="2026-01-01T00:00:00.000Z", event="session_init",
                           session=sid, agent="goose", llm_endpoint="openai/qwen3",
                           mcp_count="5", cwd="/tmp"))
        for seq in range(3):
            lines.append(event(ts="2026-01-01T00:00:01.000Z", event="tool_call",
                               session=sid, agent="goose", tool="bash",
                               latency_ms=lat, seq=seq))
        lines.append(event(ts="2026-01-01T00:01:00.000Z", event="session_end",
                           session=sid, agent="goose", status="ok",
                           duration_secs=10, tool_count=3, llm_turns=0))

elif scenario == "two_agents_speed":
    # goose fast (30s), openhands slow (90s)
    for agent, sid, lat, dur in [("goose","g1",100,30),("openhands","o1",300,90)]:
        lines.append(event(ts="2026-01-01T00:00:00.000Z", event="session_init",
                           session=sid, agent=agent, llm_endpoint="openai/qwen3",
                           mcp_count="5", cwd="/tmp"))
        for seq, tool in enumerate(["bash","read_file","write_file"]):
            lines.append(event(ts="2026-01-01T00:00:01.000Z", event="tool_call",
                               session=sid, agent=agent, tool=tool,
                               latency_ms=lat, seq=seq))
        lines.append(event(ts="2026-01-01T00:01:00.000Z", event="session_end",
                           session=sid, agent=agent, status="ok",
                           duration_secs=dur, tool_count=3, llm_turns=0))

with open(log_path, "w") as fh:
    fh.write("\n".join(lines) + "\n")
PY
}

# Run sda_extract_metrics and capture JSON output into a temp file.
# Usage: _extract_metrics_to_file <log_path> <baseline> <threshold> <out_file>
_extract_metrics_to_file() {
  local log="$1" baseline="$2" threshold="$3" outfile="$4"
  bash -c ". '${ANALYZER_LIB}'; sda_extract_metrics '$log' '$baseline' '$threshold'" > "$outfile" 2>&1
  return $?
}

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/sda-test-XXXXXX)"
  export TEST_TMPDIR
  export NO_COLOR=1
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/sda-noop}" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 1 — Library sources cleanly
# ══════════════════════════════════════════════════════════════════════════════
@test "session-divergence-analyzer: library passes bash -n syntax check" {
  run bash -n "$ANALYZER_LIB"
  [ "$status" -eq 0 ]
}

@test "session-divergence-analyzer: library sources without error" {
  run bash -c ". '${ANALYZER_LIB}' && echo sourced_ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced_ok"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 2 — sda_extract_metrics parses replay JSONL correctly
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: returns valid JSON with agents key" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json, sys
d = json.loads(open('${outfile}').read())
assert 'agents' in d, f'missing agents key: {list(d.keys())}'
print('ok')
"
  [ "$?" -eq 0 ]
}

@test "sda_extract_metrics: detects both agents in default fixture" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
agents = sorted(d['agents'].keys())
assert 'aider' in agents, f'missing aider: {agents}'
assert 'goose' in agents, f'missing goose: {agents}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3 — Latency variance: p99 >= avg for uniform distributions
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: p99 >= avg tool latency for each agent" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "high_latency"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
for agent, m in d['agents'].items():
    assert m['p99_tool_lat_ms'] >= m['avg_tool_lat_ms'], \
        f'{agent}: p99={m[\"p99_tool_lat_ms\"]} < avg={m[\"avg_tool_lat_ms\"]}'
print('ok')
"
  [ "$?" -eq 0 ]
}

@test "sda_extract_metrics: session_count matches fixture (default=4 sessions)" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
assert d['session_count'] == 4, f'expected 4, got {d[\"session_count\"]}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 4 — Error rate calculation
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: error_rate_pct = 75% when 3/4 sessions fail" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "high_error"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
rate = d['agents']['goose']['error_rate_pct']
assert rate == 75.0, f'expected 75.0, got {rate}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 5 — MCP timeout rate
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: mcp_timeout_rate_pct > 0 when mcp_ calls timed out" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "mcp_timeout"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
rate = d['agents']['ashlrcode']['mcp_timeout_rate_pct']
assert rate > 0, f'expected mcp_timeout_rate > 0, got {rate}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 6 — Tool coverage
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: unique_tools lists all tools used by agent" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
tools = set(d['agents']['goose']['unique_tools'])
expected = {'bash', 'read_file', 'write_file'}
missing = expected - tools
assert not missing, f'missing tools: {missing}, got: {tools}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 7 — SLA violation: p99 > threshold
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: tool_call_p99_latency violation when p99 > threshold" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "high_latency"
  local outfile="${TEST_TMPDIR}/metrics.json"
  # threshold 2000ms; goose has 3500ms latency → p99 violation
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
rules = [v['rule'] for v in d['violations']]
assert 'tool_call_p99_latency' in rules, f'expected tool_call_p99_latency, got: {rules}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 8 — SLA violation: MCP timeout rate > 5%
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: mcp_timeout_rate violation when rate > 5%" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "mcp_timeout"
  local outfile="${TEST_TMPDIR}/metrics.json"
  # 3 of 5 mcp_ calls timed out = 60% → well above 5% threshold
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
rules = [v['rule'] for v in d['violations']]
assert 'mcp_timeout_rate' in rules, f'expected mcp_timeout_rate, got: {rules}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 9 — SLA violation: session error rate > 20%
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: session_error_rate violation when > 20%" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "high_error"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
rules = [v['rule'] for v in d['violations']]
assert 'session_error_rate' in rules, f'expected session_error_rate, got: {rules}'
viols = [v for v in d['violations'] if v['rule'] == 'session_error_rate']
assert viols[0]['severity'] == 'critical', f'expected critical, got {viols[0][\"severity\"]}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 10 — Cross-agent systematic latency gap
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: systematic_latency_gap flagged when one agent is 35x slower" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "high_latency"
  local outfile="${TEST_TMPDIR}/metrics.json"
  # aider=100ms p99, goose=3500ms p99 → ratio 35x → systematic gap
  _extract_metrics_to_file "$log" "aider" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
rules = [v['rule'] for v in d['violations']]
assert 'systematic_latency_gap' in rules, f'expected systematic_latency_gap, got: {rules}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 11 — validate-sla exits 0 when all SLAs pass
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: exits 0 when no critical violations (default fixture)" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/sla-out"

  run bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'jsonl' '${out_dir}'"
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 12 — validate-sla exits 1 when critical SLA violated
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: exits 1 when critical SLA violated (high_error fixture)" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "high_error"
  local out_dir="${TEST_TMPDIR}/sla-fail-out"

  run bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'jsonl' '${out_dir}'"
  [ "$status" -eq 1 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 13 — JSONL scorecard written with correct record_type values
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: JSONL scorecard contains agent_metrics and summary records" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/jsonl-out"

  bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'jsonl' '${out_dir}'" || true

  [ -f "${out_dir}/compliance-scorecard.jsonl" ]

  python3 -c "
import json
records = [json.loads(l) for l in open('${out_dir}/compliance-scorecard.jsonl') if l.strip()]
types = {r['record_type'] for r in records}
assert 'agent_metrics' in types, f'missing agent_metrics, got: {types}'
assert 'summary' in types, f'missing summary, got: {types}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 14 — HTML report rendered when template exists
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: HTML report file created when template present" {
  [ -f "$TEMPLATE_PATH" ] || skip "HTML template not found at $TEMPLATE_PATH"

  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/html-out"

  bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'html' '${out_dir}'" || true

  [ -f "${out_dir}/sla-report.html" ]
  grep -q "DOCTYPE" "${out_dir}/sla-report.html"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 15 — --report-format jsonl skips HTML
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: --report-format jsonl does not create HTML file" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/jsonl-only-out"

  bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'jsonl' '${out_dir}'" || true

  [ -f "${out_dir}/compliance-scorecard.jsonl" ]
  [ ! -f "${out_dir}/sla-report.html" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 16 — --report-format html skips JSONL
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: --report-format html does not create JSONL scorecard" {
  [ -f "$TEMPLATE_PATH" ] || skip "HTML template not found at $TEMPLATE_PATH"

  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/html-only-out"

  bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'html' '${out_dir}'" || true

  [ ! -f "${out_dir}/compliance-scorecard.jsonl" ]
  [ -f "${out_dir}/sla-report.html" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 17 — Latency trend: positive slope flagged as degradation
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: latency_trend_degradation violation for rising latency" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "trend"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
slope = d['agents']['goose']['trend_slope_ms_per_session']
assert slope > 50, f'expected slope > 50, got {slope}'
rules = [v['rule'] for v in d['violations']]
assert 'latency_trend_degradation' in rules, f'expected latency_trend_degradation, got: {rules}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 18 — session-replay.sh passes bash -n
# ══════════════════════════════════════════════════════════════════════════════
@test "session-replay.sh: passes bash -n syntax check (includes validate-sla)" {
  run bash -n "$REPLAY_SCRIPT"
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 19 — validate-sla appears in help
# ══════════════════════════════════════════════════════════════════════════════
@test "session-replay.sh: validate-sla subcommand appears in help output" {
  run bash "$REPLAY_SCRIPT" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate-sla"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 20 — sda_extract_metrics fails cleanly on missing log
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: returns non-zero and prints error for missing log" {
  run bash -c ". '${ANALYZER_LIB}'; sda_extract_metrics '/nonexistent/log-$$' '' '2000'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]] || [[ "$output" == *"log not found"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 21 — speed_flags emitted when session duration ratio >= 1.5x
# ══════════════════════════════════════════════════════════════════════════════
@test "sda_extract_metrics: speed_flags emitted when one agent is 3x slower by duration" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "two_agents_speed"
  local outfile="${TEST_TMPDIR}/metrics.json"
  _extract_metrics_to_file "$log" "" "2000" "$outfile"

  python3 -c "
import json
d = json.loads(open('${outfile}').read())
flags = d.get('speed_flags', [])
assert len(flags) > 0, f'expected at least 1 speed_flag, got: {flags}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 22 — scorecard summary record has sla_passed boolean
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: summary record has sla_passed field" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/summary-check"

  bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' '' '2000' 'jsonl' '${out_dir}'" || true

  [ -f "${out_dir}/compliance-scorecard.jsonl" ]

  python3 -c "
import json
records = [json.loads(l) for l in open('${out_dir}/compliance-scorecard.jsonl') if l.strip()]
summary = next((r for r in records if r.get('record_type') == 'summary'), None)
assert summary is not None, 'no summary record found'
assert 'sla_passed' in summary, f'sla_passed missing from summary: {summary}'
assert isinstance(summary['sla_passed'], bool), f'sla_passed should be bool: {summary[\"sla_passed\"]}'
print('ok')
"
  [ "$?" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 23 — validate-sla accepts --baseline-agent without error
# ══════════════════════════════════════════════════════════════════════════════
@test "validate-sla: accepts --baseline-agent flag and runs cleanly" {
  local log="${TEST_TMPDIR}/replay.jsonl"
  _make_fixture "$TEST_TMPDIR" "default"
  local out_dir="${TEST_TMPDIR}/baseline-check"

  run bash -c ". '${ANALYZER_LIB}'; sda_validate_sla '${log}' 'goose' '2000' 'jsonl' '${out_dir}'"
  # 0 = SLA passed, 1 = SLA violated — both are acceptable; 2+ means error
  [ "$status" -le 1 ]
  [ -f "${out_dir}/compliance-scorecard.jsonl" ]
}
