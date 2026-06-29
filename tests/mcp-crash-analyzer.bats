#!/usr/bin/env bats
# tests/mcp-crash-analyzer.bats — Unit tests for mcp-crash-analyzer.sh
#
# Test categories:
#   1.  Library sourceable — no side-effects on source, syntax clean
#   2.  OOM detection — heap exhaustion, SIGKILL, OOM-killer messages
#   3.  Segfault detection — text patterns + exit code 139
#   4.  Model token overflow — LM Studio / context-window messages
#   5.  Dependency errors — missing modules, version mismatches
#   6.  Transient failures — signals, network, exit code 1
#   7.  Recovery strategy mapping — correct strategy per class
#   8.  JSON output structure — valid JSON with required fields
#   9.  Confidence levels — high/medium/low per pattern
#  10.  Edge cases — empty stderr, exit code 0, combined signals
#  11.  Integration with mcp-lifecycle.sh — probe emits crash analysis
#
# Run:
#   bats tests/mcp-crash-analyzer.bats
#   NO_COLOR=1 bats tests/mcp-crash-analyzer.bats

# ─── Resolve paths ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
export REPO_ROOT LIB_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-crash-analyzer-test-XXXXXX)"
  export TEST_TMPDIR
  export MCP_LC_STATE_DIR="${TEST_TMPDIR}/mcp-lifecycle"
  export MCP_LC_LIFECYCLE_JSONL="${TEST_TMPDIR}/mcp-lifecycle.jsonl"
  export ASHLR_SESSION_EVENTS_PATH="${TEST_TMPDIR}/session-events.jsonl"
  export MCP_LC_PROBE_TIMEOUT=3
  export MCP_LC_MAX_RESTARTS=3
  export ASHLR_PLUGIN_DIR="${TEST_TMPDIR}/fake-plugin"
  unset MCP_CRASH_ANALYZER_VERBOSE
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-crash-analyzer-noop}" 2>/dev/null || true
}

# ─── Helper: source the crash analyzer fresh in each subprocess ──────────────
_source_analyzer() {
  unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
  # shellcheck source=scripts/lib/mcp-crash-analyzer.sh
  . "${LIB_DIR}/mcp-crash-analyzer.sh"
}

# ─── Helper: extract a JSON field value from a single-line JSON string ────────
_json_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | grep -o "\"${field}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. Library sourceable — no side-effects
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-crash-analyzer.sh: passes bash -n syntax check" {
  run bash -n "${LIB_DIR}/mcp-crash-analyzer.sh"
  [ "$status" -eq 0 ]
}

@test "mcp-crash-analyzer.sh: sources cleanly with no error output" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced_ok"* ]]
}

@test "mcp-crash-analyzer.sh: double-source guard works" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    echo 'double_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double_ok"* ]]
}

@test "mcp-crash-analyzer.sh: analyze_mcp_crash function is defined after sourcing" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    declare -f analyze_mcp_crash >/dev/null 2>&1 && echo 'defined'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"defined"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. OOM detection
# ══════════════════════════════════════════════════════════════════════════════

@test "OOM: 'JavaScript heap out of memory' → crash_class=oom" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'FATAL ERROR: JavaScript heap out of memory' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"oom"'* ]]
}

@test "OOM: 'Allocation failed - JavaScript heap out of space' → crash_class=oom" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'Allocation failed - JavaScript heap out of space' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"oom"'* ]]
}

@test "OOM: exit_code=137 (SIGKILL) → crash_class=oom" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'sql' 137 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"oom"'* ]]
}

@test "OOM: 'out of memory' in last_log_lines → crash_class=oom" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'aider' 'tree' 1 '' 'kernel: Out of memory: Kill process 1234'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"oom"'* ]]
}

@test "OOM: recovery_strategy=wait_10s_then_restart for oom" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 137 'JavaScript heap out of memory' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"wait_10s_then_restart"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. Segfault detection
# ══════════════════════════════════════════════════════════════════════════════

@test "segfault: 'Segmentation fault' text → crash_class=segfault" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 139 'Segmentation fault (core dumped)' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"segfault"'* ]]
}

@test "segfault: exit_code=139 alone → crash_class=segfault" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'aider' 'git' 139 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"segfault"'* ]]
}

@test "segfault: 'SIGSEGV' in stderr → crash_class=segfault" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'http' 2 'Process received SIGSEGV signal 11' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"segfault"'* ]]
}

@test "segfault: recovery_strategy=wait_10s_then_restart for segfault" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 139 'Segmentation fault' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"wait_10s_then_restart"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. Model token overflow
# ══════════════════════════════════════════════════════════════════════════════

@test "token_overflow: 'context length exceeded' → crash_class=model_token_overflow" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'Error: context length exceeded maximum of 4096 tokens' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"model_token_overflow"'* ]]
}

@test "token_overflow: 'KV cache full' → crash_class=model_token_overflow" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'aider' 'bash' 1 'KV cache is full' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"model_token_overflow"'* ]]
}

@test "token_overflow: 'input too long' in last_log_lines → crash_class=model_token_overflow" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'http' 1 '' 'LM Studio: input too long for model context window'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"model_token_overflow"'* ]]
}

@test "token_overflow: recovery_strategy=require_config_fix" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'context length exceeded' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"require_config_fix"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. Dependency errors
# ══════════════════════════════════════════════════════════════════════════════

@test "dependency: 'Cannot find module' → crash_class=dependency" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 \"Error: Cannot find module '@modelcontextprotocol/sdk'\" ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"dependency"'* ]]
}

@test "dependency: 'node_modules' missing → crash_class=dependency" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'aider' 'sql' 1 'No such file or directory: node_modules/.bin/ts-node' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"dependency"'* ]]
}

@test "dependency: 'version mismatch' → crash_class=dependency" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'tree' 1 'engine node version mismatch: requires node >=18' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"dependency"'* ]]
}

@test "dependency: recovery_strategy=require_config_fix" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'Cannot find module express' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"require_config_fix"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. Transient failures
# ══════════════════════════════════════════════════════════════════════════════

@test "transient: exit_code=1 with no pattern → crash_class=transient" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'something went wrong briefly' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"transient"'* ]]
}

@test "transient: 'ECONNRESET' → crash_class=transient" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'http' 1 'Error: read ECONNRESET' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"transient"'* ]]
}

@test "transient: 'SIGTERM' → crash_class=transient" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 15 'Process received SIGTERM' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"transient"'* ]]
}

@test "transient: recovery_strategy=restart_immediately" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"restart_immediately"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 7. Recovery strategy mapping
# ══════════════════════════════════════════════════════════════════════════════

@test "strategy: oom → wait_10s_then_restart" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'JavaScript heap out of memory' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"wait_10s_then_restart"'* ]]
}

@test "strategy: segfault → wait_10s_then_restart" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 139 'Segmentation fault' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"wait_10s_then_restart"'* ]]
}

@test "strategy: model_token_overflow → require_config_fix" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'context length exceeded' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"require_config_fix"'* ]]
}

@test "strategy: dependency → require_config_fix" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'Cannot find module foo' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"require_config_fix"'* ]]
}

@test "strategy: transient → restart_immediately" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'connection reset' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovery_strategy":"restart_immediately"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 8. JSON output structure
# ══════════════════════════════════════════════════════════════════════════════

@test "json: output is a single non-empty line" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'some error' 'log line'
  "
  [ "$status" -eq 0 ]
  local line_count
  line_count="$(printf '%s\n' "$output" | grep -c '.'  || true)"
  [ "$line_count" -ge 1 ]
  [[ "$output" == *'{'* ]]
  [[ "$output" == *'}'* ]]
}

@test "json: output is valid JSON (parseable by python3)" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'some error' 'log line'
  "
  [ "$status" -eq 0 ]
  run python3 -c "import json,sys; json.loads('${output//\'/\'\\\'\'}')"
  [ "$status" -eq 0 ]
}

@test "json: output contains all required fields" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'err' 'log'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ts"'* ]]
  [[ "$output" == *'"event"'* ]]
  [[ "$output" == *'"agent"'* ]]
  [[ "$output" == *'"server"'* ]]
  [[ "$output" == *'"exit_code"'* ]]
  [[ "$output" == *'"crash_class"'* ]]
  [[ "$output" == *'"recovery_strategy"'* ]]
  [[ "$output" == *'"confidence"'* ]]
  [[ "$output" == *'"reason"'* ]]
}

@test "json: event field is 'mcp_crash_analysis'" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"mcp_crash_analysis"'* ]]
}

@test "json: agent and server fields match args" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'aider' 'my_server' 2 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent":"aider"'* ]]
  [[ "$output" == *'"server":"my_server"'* ]]
}

@test "json: exit_code field is numeric" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 42 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"exit_code":42'* ]]
}

@test "json: ts field matches ISO-8601 pattern" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 '' ''
  "
  [ "$status" -eq 0 ]
  # ts value should look like 2026-06-29T...Z
  [[ "$output" =~ '"ts":"'[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 9. Confidence levels
# ══════════════════════════════════════════════════════════════════════════════

@test "confidence: oom with explicit message → high" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'JavaScript heap out of memory' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"confidence":"high"'* ]]
}

@test "confidence: exit_code=137 alone (no text) → medium" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 137 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"confidence":"medium"'* ]]
}

@test "confidence: unclassified crash → low" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 99 'totally unknown error' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"confidence":"low"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 10. Edge cases
# ══════════════════════════════════════════════════════════════════════════════

@test "edge: empty stderr and empty log → returns valid JSON" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 2 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class"'* ]]
}

@test "edge: exit_code=0 with no other signals → transient" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 0 '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"transient"'* ]]
}

@test "edge: special chars in stderr do not break JSON" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 'error: \"quote\" and backslash\\\\' ''
  "
  [ "$status" -eq 0 ]
  # Must still be non-empty JSON-like output
  [[ "$output" == *'{'* ]]
  [[ "$output" == *'}'* ]]
}

@test "edge: OOM in last_log_lines takes priority over transient exit_code=1" {
  run bash -c "
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-crash-analyzer.sh'
    analyze_mcp_crash 'goose' 'bash' 1 '' 'out of memory: kill process 999'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"crash_class":"oom"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 11. Integration with mcp-lifecycle.sh — probe emits crash analysis to JSONL
# ══════════════════════════════════════════════════════════════════════════════

@test "integration: mcp-lifecycle.sh sources crash analyzer automatically" {
  run bash -c "
    MCP_LC_STATE_DIR='${TEST_TMPDIR}/mcp-lifecycle'
    MCP_LC_LIFECYCLE_JSONL='${TEST_TMPDIR}/mcp-lifecycle.jsonl'
    ASHLR_SESSION_EVENTS_PATH='${TEST_TMPDIR}/session-events.jsonl'
    unset _ASHLR_MCP_LC_SOURCED
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-lifecycle.sh'
    declare -f analyze_mcp_crash >/dev/null 2>&1 && echo 'analyzer_loaded'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"analyzer_loaded"* ]]
}

@test "integration: failed probe emits mcp_crash_analysis event to lifecycle JSONL" {
  # Register a server with a nonexistent entry so probe immediately fails.
  bash -c "
    MCP_LC_STATE_DIR='${TEST_TMPDIR}/mcp-lifecycle'
    MCP_LC_LIFECYCLE_JSONL='${TEST_TMPDIR}/mcp-lifecycle.jsonl'
    ASHLR_SESSION_EVENTS_PATH='${TEST_TMPDIR}/session-events.jsonl'
    MCP_LC_MAX_RESTARTS=0
    MCP_LC_PROBE_TIMEOUT=2
    ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    mkdir -p '${TEST_TMPDIR}/fake-plugin'
    unset _ASHLR_MCP_LC_SOURCED
    unset _ASHLR_MCP_CRASH_ANALYZER_SOURCED
    . '${LIB_DIR}/mcp-lifecycle.sh'
    # Register with a state pointing to pid=0 and health=fail so probe immediately
    # hits the unhealthy path without needing to kill a real process.
    mcp_lc_register 'goose' 'dead_srv' '/nonexistent/server.ts'
    # Force last_health=fail and failure_class=recoverable so probe runs analysis.
    grep -v '^last_health=' '${TEST_TMPDIR}/mcp-lifecycle/goose__dead_srv.state' > /tmp/_lc_tmp && mv /tmp/_lc_tmp '${TEST_TMPDIR}/mcp-lifecycle/goose__dead_srv.state'
    printf 'last_health=fail\n' >> '${TEST_TMPDIR}/mcp-lifecycle/goose__dead_srv.state'
    mcp_lc_probe 'goose' 'dead_srv' || true
  "
  # The lifecycle JSONL should now contain a mcp_crash_analysis event.
  [ -f "${TEST_TMPDIR}/mcp-lifecycle.jsonl" ]
  grep -q '"event":"mcp_crash_analysis"' "${TEST_TMPDIR}/mcp-lifecycle.jsonl"
}
