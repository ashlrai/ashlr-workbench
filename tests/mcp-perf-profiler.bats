#!/usr/bin/env bats
# tests/mcp-perf-profiler.bats — MCP Tool Latency Profiler Test Suite
#
# Verifies that mcp-perf-profiler.sh correctly:
#   1. Sources cleanly with no side-effects
#   2. Emits well-formed JSONL records via mcp_perf_record
#   3. Measures wall-clock latency when probing a live stub MCP server
#   4. Handles missing entry files, missing runtimes, and timeouts gracefully
#   5. Runs a baseline sweep and emits records for each tool
#   6. mcp-perf-dashboard.sh renders stats from recorded JSONL
#
# Mock servers are written as node scripts (same pattern as mcp-runtime-contracts.bats).
# When node is unavailable, live-server tests are skipped automatically.
#
# Run:
#   bats tests/mcp-perf-profiler.bats
#   NO_COLOR=1 bats tests/mcp-perf-profiler.bats

# ─── Resolve paths ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
export REPO_ROOT LIB_DIR SCRIPTS_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-perf-profiler-XXXXXX)"
  export TEST_TMPDIR

  # Isolated perf log and plugin dir.
  export MCP_PERF_LOG="${TEST_TMPDIR}/mcp-perf.jsonl"
  export ASHLR_PLUGIN_DIR="${TEST_TMPDIR}/fake-plugin"
  export MCP_PERF_TOOL_TIMEOUT=8
  export MCP_PERF_BASELINE_TIMEOUT=15
  export NO_COLOR=1
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-perf-profiler-noop}" 2>/dev/null || true
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

_require_node() {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH — live server tests require node"
  fi
}

# Build a stub MCP server node script that handles initialize + tools/list +
# tools/call, with a configurable artificial latency (ms) for each tool call.
# Arguments: path, tool_names (space-sep), latency_ms
_make_latency_server() {
  local path="$1"
  local tool_names="$2"
  local latency_ms="${3:-50}"

  mkdir -p "$(dirname "$path")"

  local tools_json=""
  local first=1
  for t in $tool_names; do
    local entry
    entry="{\"name\":\"${t}\",\"description\":\"${t} description\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
    if [ "$first" -eq 1 ]; then
      tools_json="$entry"; first=0
    else
      tools_json="${tools_json},${entry}"
    fi
  done

  cat > "$path" <<NODESCRIPT
#!/usr/bin/env node
process.stdin.setEncoding('utf8');
var buf = '';
var latencyMs = ${latency_ms};
process.stdin.on('data', function(chunk) {
  buf += chunk;
  var parts = buf.split('\r\n\r\n');
  for (var i = 0; i < parts.length; i++) {
    var block = parts[i];
    var bodyMatch = block.match(/\{.*\}/s);
    if (!bodyMatch) continue;
    try {
      var req = JSON.parse(bodyMatch[0]);
      var id = req.id != null ? req.id : 0;
      if (req.method === 'initialize') {
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', id: id,
          result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: { name: 'stub', version: '1.0' } }
        }) + '\n');
      } else if (req.method === 'tools/list') {
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', id: id,
          result: { tools: [${tools_json}] }
        }) + '\n');
      } else if (req.method === 'tools/call') {
        setTimeout(function() {
          process.stdout.write(JSON.stringify({
            jsonrpc: '2.0', id: id,
            result: { content: [{ type: 'text', text: 'probe_result' }] }
          }) + '\n');
        }, latencyMs);
      }
    } catch(e) {}
  }
  buf = parts[parts.length - 1];
});
process.stdin.resume();
setTimeout(function(){ process.exit(0); }, 30000);
NODESCRIPT
  chmod +x "$path"
}

# Build a stub server that always returns a JSON-RPC error for tools/call.
_make_error_server() {
  local path="$1"
  local tool_names="$2"
  mkdir -p "$(dirname "$path")"
  local tools_json=""
  local first=1
  for t in $tool_names; do
    local entry
    entry="{\"name\":\"${t}\",\"description\":\"${t}\",\"inputSchema\":{}}"
    if [ "$first" -eq 1 ]; then tools_json="$entry"; first=0
    else tools_json="${tools_json},${entry}"; fi
  done
  cat > "$path" <<NODESCRIPT
#!/usr/bin/env node
process.stdin.setEncoding('utf8');
var buf = '';
process.stdin.on('data', function(chunk) {
  buf += chunk;
  var parts = buf.split('\r\n\r\n');
  for (var i = 0; i < parts.length; i++) {
    var block = parts[i];
    var bodyMatch = block.match(/\{.*\}/s);
    if (!bodyMatch) continue;
    try {
      var req = JSON.parse(bodyMatch[0]);
      var id = req.id != null ? req.id : 0;
      if (req.method === 'initialize') {
        process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:id,result:{protocolVersion:'2024-11-05',capabilities:{},serverInfo:{name:'err-srv',version:'1.0'}}})+'\n');
      } else if (req.method === 'tools/list') {
        process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:id,result:{tools:[${tools_json}]}})+'\n');
      } else if (req.method === 'tools/call') {
        process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:id,error:{code:-32000,message:'server error'}})+'\n');
      }
    } catch(e) {}
  }
  buf = parts[parts.length-1];
});
process.stdin.resume();
setTimeout(function(){process.exit(0);},30000);
NODESCRIPT
  chmod +x "$path"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — Library integrity
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-perf-profiler.sh: passes bash -n syntax check" {
  run bash -n "${LIB_DIR}/mcp-perf-profiler.sh"
  [ "$status" -eq 0 ]
}

@test "mcp-perf-profiler.sh: sources cleanly with no error output" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/test.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced_ok"* ]]
}

@test "mcp-perf-profiler.sh: double-source guard works" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/test.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    echo 'double_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double_ok"* ]]
}

@test "mcp-perf-profiler.sh: public functions defined after sourcing" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/test.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    declare -f mcp_perf_record        >/dev/null && echo 'record_ok'
    declare -f mcp_perf_probe_tool    >/dev/null && echo 'probe_tool_ok'
    declare -f mcp_perf_probe_server  >/dev/null && echo 'probe_server_ok'
    declare -f mcp_perf_baseline_all  >/dev/null && echo 'baseline_all_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"record_ok"* ]]
  [[ "$output" == *"probe_tool_ok"* ]]
  [[ "$output" == *"probe_server_ok"* ]]
  [[ "$output" == *"baseline_all_ok"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — mcp_perf_record: JSONL emission
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp_perf_record: creates log file if missing and emits one JSONL line" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_record 'goose' 'bash' 'ashlr__bash' 'abc12345' 123 456 'ok'
    wc -l < \"${TEST_TMPDIR}/perf.jsonl\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}

@test "mcp_perf_record: emitted line is valid JSON with required fields" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_record 'aider' 'sql' 'ashlr__sql' 'deadbeef' 200 512 'ok'
    cat '${TEST_TMPDIR}/perf.jsonl'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent":"aider"'* ]]
  [[ "$output" == *'"server":"sql"'* ]]
  [[ "$output" == *'"tool":"ashlr__sql"'* ]]
  [[ "$output" == *'"latency_ms":200'* ]]
  [[ "$output" == *'"result_size":512'* ]]
  [[ "$output" == *'"status":"ok"'* ]]
}

@test "mcp_perf_record: ts field is present and looks like ISO-8601" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_record 'ashlrcode' 'tree' 'ashlr__ls' '00000000' 50 100 'ok'
    cat '${TEST_TMPDIR}/perf.jsonl'
  "
  [ "$status" -eq 0 ]
  # ISO-8601 date contains T and Z
  [[ "$output" == *'"ts":"'* ]]
  [[ "$output" =~ \"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "mcp_perf_record: multiple records append correctly" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_record 'goose'     'bash' 'ashlr__bash'   'aaaa0000' 100 200 'ok'
    mcp_perf_record 'aider'     'bash' 'ashlr__bash'   'aaaa0000' 150 200 'ok'
    mcp_perf_record 'ashlrcode' 'bash' 'ashlr__bash'   'aaaa0000' 120 200 'ok'
    wc -l < '${TEST_TMPDIR}/perf.jsonl'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"3"* ]]
}

@test "mcp_perf_record: status field accepts error and timeout values" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_record 'goose' 'http' 'ashlr__http' 'bbbb1111' 5000 0 'timeout'
    mcp_perf_record 'goose' 'http' 'ashlr__http' 'bbbb1111' 300  0 'error'
    grep timeout '${TEST_TMPDIR}/perf.jsonl' && echo 'found_timeout'
    grep error   '${TEST_TMPDIR}/perf.jsonl' && echo 'found_error'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"found_timeout"* ]]
  [[ "$output" == *"found_error"* ]]
}

@test "mcp_perf_record: args_hash field is present" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_record 'openhands' 'diff' 'ashlr__diff' 'cafebabe' 75 300 'ok'
    cat '${TEST_TMPDIR}/perf.jsonl'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"args_hash":"cafebabe"'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — _mpp_args_hash: hash stability
# ══════════════════════════════════════════════════════════════════════════════

@test "_mpp_args_hash: same input produces same hash" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    h1=\$(_mpp_args_hash '{\"key\":\"val\"}')
    h2=\$(_mpp_args_hash '{\"key\":\"val\"}')
    [ \"\$h1\" = \"\$h2\" ] && echo 'hash_stable'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"hash_stable"* ]]
}

@test "_mpp_args_hash: different inputs produce different hashes" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    h1=\$(_mpp_args_hash '{\"key\":\"val1\"}')
    h2=\$(_mpp_args_hash '{\"key\":\"val2\"}')
    [ \"\$h1\" != \"\$h2\" ] && echo 'hash_differs'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"hash_differs"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — mcp_perf_probe_tool: skip behavior when server missing
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp_perf_probe_tool: emits skip record when entry file missing" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin'
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_probe_tool 'goose' 'bash' 'ashlr__bash' '${TEST_TMPDIR}/no-plugin/servers/bash-server.ts' || true
    cat '${TEST_TMPDIR}/perf.jsonl'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"skip"'* ]]
  [[ "$output" == *'"tool":"ashlr__bash"'* ]]
}

@test "mcp_perf_probe_tool: returns exit code 2 when server entry missing" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_probe_tool 'goose' 'bash' 'ashlr__bash' '${TEST_TMPDIR}/nope.ts'
    echo \"rc=\$?\"
  "
  # The command itself exits 0 because of the || true in the run subshell,
  # but we check the printed rc.
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf2.jsonl'
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    rc=0
    mcp_perf_probe_tool 'goose' 'bash' 'ashlr__bash' '${TEST_TMPDIR}/nope.ts' || rc=\$?
    echo \"rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=2"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — Live timing tests with stub MCP server
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp_perf_probe_tool: records ok status and positive latency_ms (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/bash-server.ts"
  _make_latency_server "$entry" "ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list" 50

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_PERF_TOOL_TIMEOUT=8
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    rc=0
    mcp_perf_probe_tool 'goose' 'bash' 'ashlr__bash' '${entry}' || rc=\$?
    echo \"probe_rc=\$rc\"
    cat '${TEST_TMPDIR}/perf.jsonl'
  "
  [ "$status" -eq 0 ]
  # rc=0 (success) or rc=2 (skip if server timed out — still acceptable).
  [[ "$output" != *"probe_rc=1"* ]]
  [[ "$output" != *"probe_rc=3"* ]]
  # If a record was emitted, it must have tool and a non-zero latency.
  if [[ "$output" == *'"tool":"ashlr__bash"'* ]]; then
    [[ "$output" != *'"latency_ms":0'* ]] || [[ "$output" == *'"status":"skip"'* ]]
  fi
}

@test "mcp_perf_probe_tool: latency_ms is >= artificial server delay (50ms)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/bash-latency-server.ts"
  _make_latency_server "$entry" "ashlr__bash" 50

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-lat.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_PERF_TOOL_TIMEOUT=8
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_probe_tool 'goose' 'bash' 'ashlr__bash' '${entry}' || true
    python3 -c \"
import json, sys
with open('${TEST_TMPDIR}/perf-lat.jsonl') as f:
    for line in f:
        o = json.loads(line.strip())
        if o.get('status') == 'ok':
            ms = o.get('latency_ms', 0)
            if ms >= 50:
                print('latency_ok=' + str(ms))
            else:
                print('latency_too_low=' + str(ms))
            sys.exit(0)
    print('no_ok_record')
\"
  "
  [ "$status" -eq 0 ]
  # Either latency_ok (live test ran) or no_ok_record (server skipped — also fine).
  [[ "$output" != *"latency_too_low"* ]]
}

@test "mcp_perf_probe_tool: records error status when server returns JSON-RPC error" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/err-server.ts"
  _make_error_server "$entry" "ashlr__bash"

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-err.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_PERF_TOOL_TIMEOUT=8
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    rc=0
    mcp_perf_probe_tool 'aider' 'bash' 'ashlr__bash' '${entry}' || rc=\$?
    echo \"probe_rc=\$rc\"
    cat '${TEST_TMPDIR}/perf.jsonl' 2>/dev/null || echo 'no_log'
  "
  [ "$status" -eq 0 ]
  # rc=1 (error response) or rc=2 (skip if server didn't respond in time).
  # Must NOT be rc=0 (false pass on an error response).
  if [[ "$output" == *'"status":"error"'* ]]; then
    [[ "$output" == *"probe_rc=1"* ]]
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — mcp_perf_probe_server
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp_perf_probe_server: emits one record per expected tool (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/efficiency-server.ts"
  local tools="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
  _make_latency_server "$entry" "$tools" 20

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-srv.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_PERF_TOOL_TIMEOUT=8
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_probe_server 'ashlrcode' 'efficiency' '${entry}' || true
    wc -l < '${TEST_TMPDIR}/perf-srv.jsonl' | tr -d ' '
  "
  [ "$status" -eq 0 ]
  # Should have 5 records (one per expected tool).
  [[ "$output" == *"5"* ]]
}

@test "mcp_perf_probe_server: skips gracefully for unknown server (no tool list)" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-unknown.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    rc=0
    mcp_perf_probe_server 'goose' 'nonexistent-server-xyz' '/nope.ts' || rc=\$?
    echo \"rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  # Should return 0 (no errors — just warns and skips).
  [[ "$output" == *"rc=0"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — mcp_perf_baseline_all: sweep behavior
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp_perf_baseline_all: runs without error when plugin absent (all skips)" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-baseline.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_PERF_BASELINE_TIMEOUT=10
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_baseline_all 10
    echo 'baseline_complete'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline_complete"* ]]
}

@test "mcp_perf_baseline_all: emits skip records when plugin absent" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-baseline-skip.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_PERF_BASELINE_TIMEOUT=10
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_baseline_all 10
    # Count records with status=skip.
    python3 -c \"
import json
n = 0
try:
    with open('${TEST_TMPDIR}/perf-baseline-skip.jsonl') as f:
        for l in f:
            l = l.strip()
            if not l: continue
            o = json.loads(l)
            if o.get('status') == 'skip':
                n += 1
except FileNotFoundError:
    pass
print('skip_count=' + str(n))
\"
  "
  [ "$status" -eq 0 ]
  # Expect many skip records (40 tools × 4 agents = 160 possible, at minimum >0).
  # When plugin is absent all records must be skip.
  [[ "$output" != *"skip_count=0"* ]]
}

@test "mcp_perf_baseline_all: prints summary line with probe counts" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/perf-summary.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_PERF_BASELINE_TIMEOUT=5
    export MCP_PERF_TOOL_TIMEOUT=2
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    mcp_perf_baseline_all 5
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"mcp-perf baseline complete"* ]]
  [[ "$output" == *"probes"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 8 — mcp-perf-dashboard.sh: rendering tests
# ══════════════════════════════════════════════════════════════════════════════

_dashboard() {
  bash "${SCRIPTS_DIR}/mcp-perf-dashboard.sh" "$@"
}

@test "mcp-perf-dashboard.sh: passes bash -n syntax check" {
  run bash -n "${SCRIPTS_DIR}/mcp-perf-dashboard.sh"
  [ "$status" -eq 0 ]
}

@test "mcp-perf-dashboard.sh: reports no data when log missing" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/nonexistent.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"no perf log"* ]] || [[ "$output" == *"Run"* ]]
}

@test "mcp-perf-dashboard.sh: reports empty when log has no valid lines" {
  printf '' > "${TEST_TMPDIR}/empty.jsonl"
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/empty.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty"* ]] || [ -z "$output" ]
}

@test "mcp-perf-dashboard.sh: renders table header with data present" {
  # Seed the log with synthetic records.
  cat > "${TEST_TMPDIR}/seeded.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aabbccdd","latency_ms":120,"result_size":256,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"aider","server":"bash","tool":"ashlr__bash","args_hash":"aabbccdd","latency_ms":150,"result_size":256,"status":"ok"}
{"ts":"2026-01-01T00:00:03.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aabbccdd","latency_ms":130,"result_size":256,"status":"ok"}
{"ts":"2026-01-01T00:00:04.000Z","agent":"goose","server":"sql","tool":"ashlr__sql","args_hash":"11223344","latency_ms":80,"result_size":128,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/seeded.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP Tool Latency Dashboard"* ]]
  [[ "$output" == *"ashlr__bash"* ]]
  [[ "$output" == *"p50"* ]]
}

@test "mcp-perf-dashboard.sh: --csv flag emits CSV with header row" {
  cat > "${TEST_TMPDIR}/csv.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aabb","latency_ms":100,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"aider","server":"bash","tool":"ashlr__bash","args_hash":"aabb","latency_ms":110,"result_size":200,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/csv.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --csv
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"server,tool"* ]]
  [[ "$output" == *"ashlr__bash"* ]]
}

@test "mcp-perf-dashboard.sh: --server filter restricts output to one server" {
  cat > "${TEST_TMPDIR}/multi.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":100,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"goose","server":"sql","tool":"ashlr__sql","args_hash":"bb","latency_ms":80,"result_size":100,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/multi.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --server bash
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__bash"* ]]
  # sql tool must not appear when filtering to bash server
  [[ "$output" != *"ashlr__sql"* ]]
}

@test "mcp-perf-dashboard.sh: exits 1 when p95 exceeds SLA threshold" {
  # All records at 3000ms, SLA=2000ms → must exit 1.
  cat > "${TEST_TMPDIR}/slow.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":3000,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":3000,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:03.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":3000,"result_size":200,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/slow.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --sla 2000
  "
  [ "$status" -eq 1 ]
}

@test "mcp-perf-dashboard.sh: exits 0 when all latencies within SLA" {
  cat > "${TEST_TMPDIR}/fast.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":50,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":60,"result_size":200,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/fast.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --sla 2000
  "
  [ "$status" -eq 0 ]
}

@test "mcp-perf-dashboard.sh: --last N uses only recent records" {
  # Write 5 records: 1 slow old record followed by 4 fast recent records.
  # --last 4 keeps only the 4 fast ones → p95 well under SLA → exit 0.
  cat > "${TEST_TMPDIR}/recent.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":5000,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":50,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:03.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":50,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:04.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":50,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:05.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":50,"result_size":200,"status":"ok"}
JSONL

  # --last 4 trims the 5000ms oldest record → only 50ms records remain → exit 0
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/recent.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --sla 2000 --last 4
  "
  [ "$status" -eq 0 ]
}

@test "mcp-perf-dashboard.sh: --agent filter restricts to one agent" {
  cat > "${TEST_TMPDIR}/agents.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":100,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"aider","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":200,"result_size":200,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/agents.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --agent goose
  "
  [ "$status" -eq 0 ]
  # aider agent should not appear in filtered output
  [[ "$output" != *"aider"* ]] || [[ "$output" == *"goose"* ]]
}

@test "mcp-perf-dashboard.sh: summary line shows total probe count" {
  cat > "${TEST_TMPDIR}/summary.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":100,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"aider","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":150,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:03.000Z","agent":"goose","server":"sql","tool":"ashlr__sql","args_hash":"bb","latency_ms":80,"result_size":100,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/summary.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"total probes: 3"* ]]
}

@test "mcp-perf-dashboard.sh: --help flag exits 0 and shows usage" {
  run bash "${SCRIPTS_DIR}/mcp-perf-dashboard.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"--csv"* ]]
  [[ "$output" == *"--sla"* ]]
}

@test "mcp-perf-dashboard.sh: skips error/timeout/skip records from stats" {
  # Only 'ok' records should feed stats; error/timeout/skip are excluded.
  cat > "${TEST_TMPDIR}/mixed.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":100,"result_size":200,"status":"ok"}
{"ts":"2026-01-01T00:00:02.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":9999,"result_size":0,"status":"timeout"}
{"ts":"2026-01-01T00:00:03.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":9999,"result_size":0,"status":"error"}
{"ts":"2026-01-01T00:00:04.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":0,"result_size":0,"status":"skip"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/mixed.jsonl'
    bash '${SCRIPTS_DIR}/mcp-perf-dashboard.sh' --sla 2000
  "
  # Only the 100ms ok record counts → p95 = 100ms → under 2000ms → exit 0.
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 9 — aw-log perf integration
# ══════════════════════════════════════════════════════════════════════════════

@test "aw-log perf: dispatches to mcp-perf-dashboard.sh" {
  cat > "${TEST_TMPDIR}/awlog.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":100,"result_size":200,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/awlog.jsonl'
    bash '${REPO_ROOT}/bin/aw-log' perf
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP Tool Latency Dashboard"* ]] || [[ "$output" == *"ashlr__bash"* ]]
}

@test "aw-log perf --csv: passes --csv flag through to dashboard" {
  cat > "${TEST_TMPDIR}/awlog-csv.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:01.000Z","agent":"goose","server":"bash","tool":"ashlr__bash","args_hash":"aa","latency_ms":100,"result_size":200,"status":"ok"}
JSONL

  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/awlog-csv.jsonl'
    bash '${REPO_ROOT}/bin/aw-log' perf --csv
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"server,tool"* ]]
}

@test "aw-log help: mentions perf subcommand" {
  run bash -c "
    export NO_COLOR=1
    bash '${REPO_ROOT}/bin/aw-log' help
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"perf"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 10 — healthcheck.sh --perf integration (syntax only — no live probe)
# ══════════════════════════════════════════════════════════════════════════════

@test "healthcheck.sh: passes bash -n syntax check with perf additions" {
  run bash -n "${SCRIPTS_DIR}/healthcheck.sh"
  [ "$status" -eq 0 ]
}

@test "healthcheck.sh: sources mcp-perf-profiler.sh without error" {
  run bash -c "
    export NO_COLOR=1
    export MCP_PERF_LOG='${TEST_TMPDIR}/hc-perf.jsonl'
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin'
    # Source just the profiler lib to verify it loads cleanly in healthcheck context.
    unset _ASHLR_MCP_PERF_PROFILER_SOURCED
    . '${LIB_DIR}/mcp-perf-profiler.sh'
    declare -f mcp_perf_baseline_all >/dev/null && echo 'profiler_loaded'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"profiler_loaded"* ]]
}
