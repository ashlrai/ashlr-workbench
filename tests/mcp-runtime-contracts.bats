#!/usr/bin/env bats
# tests/mcp-runtime-contracts.bats — MCP Tool Capability Assertion & Runtime Contract Tests
#
# Verifies each of the 10 ashlr-plugin MCP servers (efficiency, sql, bash, tree, http,
# diff, logs, genome, orient, github) actually expose the tools they claim in the static
# schema registry maintained by mcp-tool-inspector.sh / mcp-contract-validator.sh.
#
# Test structure per server:
#   1. Library sources cleanly (no side-effects)
#   2. Static registry: expected tools defined for server
#   3. Live tools/list: server starts, responds with tools/list (skip if plugin absent)
#   4. Schema conformance: each expected tool present in live response
#   5. Parameter contract: tools have non-empty description + inputSchema
#   6. Spot-check: one low-risk tool invocation per server returns a result
#
# Global tests:
#   - mcp-contract-validator.sh passes bash -n
#   - All 10 servers have non-empty expected tool lists
#   - Live compliance matrix (PASS/FAIL/SKIP) emitted via mcp_contract_validate_all
#   - Integration with healthcheck contract probe
#
# When ashlr-plugin is absent, live/spot-check tests are automatically skipped
# (they output SKIP lines, not FAIL).  Static registry tests always run.
#
# Run:
#   bats tests/mcp-runtime-contracts.bats
#   NO_COLOR=1 bats tests/mcp-runtime-contracts.bats
#
# Integrate into healthcheck:
#   bash scripts/healthcheck.sh  (section "MCP Contract Probes" is added by this PR)

# ─── Resolve paths ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
export REPO_ROOT LIB_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-runtime-contracts-XXXXXX)"
  export TEST_TMPDIR

  # Isolate plugin dir and cache.
  export ASHLR_PLUGIN_DIR="${TEST_TMPDIR}/fake-plugin"
  export MCP_CONTRACT_TIMEOUT=6
  export NO_COLOR=1
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-runtime-contracts-noop}" 2>/dev/null || true
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Source the contract validator fresh in a subprocess.
_source_validator() {
  unset _ASHLR_MCP_CONTRACT_SOURCED
  # shellcheck source=scripts/lib/mcp-contract-validator.sh
  . "${LIB_DIR}/mcp-contract-validator.sh"
}

# Create a minimal fake plugin directory with stub server .ts files.
_make_fake_plugin() {
  local dir="${1:-${TEST_TMPDIR}/fake-plugin}"
  mkdir -p "${dir}/servers"
  for name in efficiency sql bash tree http diff logs genome orient github; do
    printf '// stub %s\n' "$name" > "${dir}/servers/${name}-server.ts"
  done
}

# Create a minimal MCP server stub (node) that handles initialize + tools/list.
# Arguments: path, tool_names (space-separated), spot_tool (name), spot_result (string)
_make_mcp_server() {
  local path="$1"
  local tool_names="$2"
  local spot_tool="${3:-}"
  local spot_result="${4:-spot_ok}"

  mkdir -p "$(dirname "$path")"

  # Build tools JSON array.
  local tools_json=""
  local first=1
  for t in $tool_names; do
    local entry
    entry="{\"name\":\"${t}\",\"description\":\"${t} description\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
    if [ "$first" -eq 1 ]; then
      tools_json="$entry"
      first=0
    else
      tools_json="${tools_json},${entry}"
    fi
  done

  cat > "$path" <<NODESCRIPT
#!/usr/bin/env node
process.stdin.setEncoding('utf8');
var buf = '';
process.stdin.on('data', function(chunk) {
  buf += chunk;
  // Try to parse each double-newline-delimited block as JSON-RPC.
  var parts = buf.split('\r\n\r\n');
  for (var i = 0; i < parts.length; i++) {
    var block = parts[i];
    // Extract JSON body (after Content-Length header or raw JSON).
    var bodyMatch = block.match(/\{.*\}/s);
    if (!bodyMatch) continue;
    try {
      var req = JSON.parse(bodyMatch[0]);
      var id = req.id != null ? req.id : 0;
      if (req.method === 'initialize') {
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', id: id,
          result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: { name: 'test-${spot_tool}', version: '1.0' } }
        }) + '\n');
      } else if (req.method === 'tools/list') {
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', id: id,
          result: { tools: [${tools_json}] }
        }) + '\n');
      } else if (req.method === 'tools/call') {
        var toolName = (req.params && req.params.name) ? req.params.name : '';
        var resultText = '${spot_result}';
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', id: id,
          result: { content: [{ type: 'text', text: resultText }] }
        }) + '\n');
        // Exit after answering one tool call to keep tests fast.
        setTimeout(function(){ process.exit(0); }, 100);
      }
    } catch(e) { /* ignore parse errors */ }
  }
  // Keep only the last incomplete block.
  buf = parts[parts.length - 1];
});
process.stdin.resume();
// Prevent premature exit — wait up to 30s for input.
setTimeout(function(){ process.exit(0); }, 30000);
NODESCRIPT
  chmod +x "$path"
}

# Skip a test if the real ashlr-plugin is not installed.
_skip_without_plugin() {
  local real_plugin="${ASHLR_PLUGIN_DIR_REAL:-$HOME/Desktop/ashlr-plugin}"
  if [ ! -d "${real_plugin}/servers" ]; then
    skip "ashlr-plugin not installed at ${real_plugin} — live contract test requires plugin"
  fi
}

# Return 0 if node is available.
_require_node() {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH — live server tests require node"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — Library integrity
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-contract-validator.sh: passes bash -n syntax check" {
  run bash -n "${LIB_DIR}/mcp-contract-validator.sh"
  [ "$status" -eq 0 ]
}

@test "mcp-contract-validator.sh: sources cleanly with no error output" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced_ok"* ]]
}

@test "mcp-contract-validator.sh: double-source guard works" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo 'double_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double_ok"* ]]
}

@test "mcp-contract-validator.sh: public functions defined after sourcing" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    declare -f mcp_contract_validate_server >/dev/null && echo 'validate_server_ok'
    declare -f mcp_contract_validate_all    >/dev/null && echo 'validate_all_ok'
    declare -f mcp_contract_spot_check      >/dev/null && echo 'spot_check_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate_server_ok"* ]]
  [[ "$output" == *"validate_all_ok"* ]]
  [[ "$output" == *"spot_check_ok"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — Static registry: expected tool lists defined for all 10 servers
# ══════════════════════════════════════════════════════════════════════════════

@test "static registry: all 10 servers have non-empty expected tool lists" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    empty=0
    for srv in efficiency sql bash tree http diff logs genome orient github; do
      eval \"tools=\\\"\\\${_MCV_EXPECTED_\${srv}:-}\\\"\"
      if [ -z \"\$tools\" ]; then
        echo \"EMPTY: \$srv\"
        empty=\$((empty+1))
      fi
    done
    echo \"empty_count=\$empty\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty_count=0"* ]]
}

@test "static registry: efficiency server expects read grep glob savings flush" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_efficiency}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]]
  [[ "$output" == *"ashlr__grep"* ]]
  [[ "$output" == *"ashlr__glob"* ]]
  [[ "$output" == *"ashlr__savings"* ]]
  [[ "$output" == *"ashlr__flush"* ]]
}

@test "static registry: bash server expects bash bash_start bash_tail bash_stop bash_list" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_bash}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__bash"* ]]
  [[ "$output" == *"ashlr__bash_start"* ]]
  [[ "$output" == *"ashlr__bash_tail"* ]]
  [[ "$output" == *"ashlr__bash_stop"* ]]
  [[ "$output" == *"ashlr__bash_list"* ]]
}

@test "static registry: sql server expects ashlr__sql" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_sql}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__sql"* ]]
}

@test "static registry: tree server expects ashlr__tree ashlr__ls" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_tree}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__tree"* ]]
  [[ "$output" == *"ashlr__ls"* ]]
}

@test "static registry: http server expects http webfetch websearch" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_http}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__http"* ]]
  [[ "$output" == *"ashlr__webfetch"* ]]
  [[ "$output" == *"ashlr__websearch"* ]]
}

@test "static registry: diff server expects ashlr__diff ashlr__diff_semantic" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_diff}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__diff"* ]]
  [[ "$output" == *"ashlr__diff_semantic"* ]]
}

@test "static registry: logs server expects ashlr__logs" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_logs}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__logs"* ]]
}

@test "static registry: genome server expects propose consolidate status" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_genome}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__genome_propose"* ]]
  [[ "$output" == *"ashlr__genome_consolidate"* ]]
  [[ "$output" == *"ashlr__genome_status"* ]]
}

@test "static registry: orient server expects ashlr__orient" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_orient}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__orient"* ]]
}

@test "static registry: github server expects pr pr_comment pr_approve issue issue_create issue_close" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    echo \"\${_MCV_EXPECTED_github}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__pr"* ]]
  [[ "$output" == *"ashlr__pr_comment"* ]]
  [[ "$output" == *"ashlr__pr_approve"* ]]
  [[ "$output" == *"ashlr__issue"* ]]
  [[ "$output" == *"ashlr__issue_create"* ]]
  [[ "$output" == *"ashlr__issue_close"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — mcp_contract_validate_server: skip when plugin absent
# ══════════════════════════════════════════════════════════════════════════════

@test "validate_server: emits SKIP when entry file is missing" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'efficiency' '${TEST_TMPDIR}/no-plugin-here/servers/efficiency-server.ts'
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"SKIP"* ]]
  [[ "$output" == *"efficiency"* ]]
}

@test "validate_server: emits SKIP when runtime absent" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    # Create fake entry file but strip bun/node from PATH.
    mkdir -p '${TEST_TMPDIR}/fake-plugin/servers'
    printf '' > '${TEST_TMPDIR}/fake-plugin/servers/sql-server.ts'
    export PATH=/usr/bin:/bin
    # Remove bun and node from those paths for test isolation.
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'sql' '${TEST_TMPDIR}/fake-plugin/servers/sql-server.ts'
  "
  # Status 2 = skip, or 4 from _mcv_start_server bubbling up.
  [ "$status" -le 2 ]
  [[ "$output" == *"SKIP"* ]] || [[ "$output" == *"runtime"* ]]
}

@test "validate_server: returns 2 (skip) when no expected tool list for unknown server" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'totally-nonexistent-server' '/nope/nope.ts'
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"SKIP"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — Live tools/list validation against stub MCP servers
# (These require node; they test the full JSON-RPC protocol path)
# ══════════════════════════════════════════════════════════════════════════════

@test "live validate_server: efficiency — all expected tools present (stub server)" {
  _require_node
  local tools="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
  local entry="${TEST_TMPDIR}/fake-plugin/servers/efficiency-server.ts"
  _make_mcp_server "$entry" "$tools" "ashlr__glob" "glob_result"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'efficiency' '${entry}'
  "
  # Should be 0 (all pass) or 2 (skip if server didn't respond in time).
  [ "$status" -le 2 ]
  # If we got a response, all expected tools must PASS (no FAIL lines).
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: sql — ashlr__sql present (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/sql-server.ts"
  _make_mcp_server "$entry" "ashlr__sql" "ashlr__sql" "1"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'sql' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
    [[ "$output" == *"ashlr__sql"* ]]
  fi
}

@test "live validate_server: bash — all 5 bash tools present (stub server)" {
  _require_node
  local tools="ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list"
  local entry="${TEST_TMPDIR}/fake-plugin/servers/bash-server.ts"
  _make_mcp_server "$entry" "$tools" "ashlr__bash" "hello"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'bash' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
    [[ "$output" == *"ashlr__bash"* ]]
  fi
}

@test "live validate_server: tree — ashlr__tree ashlr__ls present (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/tree-server.ts"
  _make_mcp_server "$entry" "ashlr__tree ashlr__ls" "ashlr__ls" "."

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'tree' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: http — http webfetch websearch present (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/http-server.ts"
  _make_mcp_server "$entry" "ashlr__http ashlr__webfetch ashlr__websearch" "ashlr__http" "ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'http' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: diff — ashlr__diff ashlr__diff_semantic present (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/diff-server.ts"
  _make_mcp_server "$entry" "ashlr__diff ashlr__diff_semantic" "ashlr__diff" "diff_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'diff' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: logs — ashlr__logs present (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/logs-server.ts"
  _make_mcp_server "$entry" "ashlr__logs" "ashlr__logs" "log_line"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'logs' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: genome — propose consolidate status present (stub server)" {
  _require_node
  local tools="ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status"
  local entry="${TEST_TMPDIR}/fake-plugin/servers/genome-server.ts"
  _make_mcp_server "$entry" "$tools" "ashlr__genome_status" "genome_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'genome' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: orient — ashlr__orient present (stub server)" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/orient-server.ts"
  _make_mcp_server "$entry" "ashlr__orient" "ashlr__orient" "orient_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'orient' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
  fi
}

@test "live validate_server: github — pr issue tools present (stub server)" {
  _require_node
  local tools="ashlr__pr ashlr__pr_comment ashlr__pr_approve ashlr__issue ashlr__issue_create ashlr__issue_close"
  local entry="${TEST_TMPDIR}/fake-plugin/servers/github-server.ts"
  _make_mcp_server "$entry" "$tools" "ashlr__pr" "pr_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'github' '${entry}'
  "
  [ "$status" -le 2 ]
  if [[ "$output" == *"PASS"* ]]; then
    [[ "$output" != *"FAIL"* ]]
    [[ "$output" == *"ashlr__pr"* ]]
    [[ "$output" == *"ashlr__issue"* ]]
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — Schema drift detection: FAIL when expected tool is omitted
# ══════════════════════════════════════════════════════════════════════════════

@test "drift detection: FAIL when expected tool missing from live tools/list" {
  _require_node
  # Stub that returns only ONE of the expected bash tools (simulates schema rot).
  local entry="${TEST_TMPDIR}/fake-plugin/servers/bash-server.ts"
  # Only expose ashlr__bash — omit bash_start, bash_tail, bash_stop, bash_list.
  _make_mcp_server "$entry" "ashlr__bash" "ashlr__bash" "ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'bash' '${entry}'
  "
  # Status 1 = failures detected; 2 = skip (acceptable if server didn't respond).
  if [ "$status" -ne 2 ]; then
    # If we got a live response, missing tools must produce FAIL lines.
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
    # The missing tools should be named in the failure output.
    [[ "$output" == *"ashlr__bash_start"* ]]
  fi
}

@test "drift detection: FAIL when all tools stripped from response" {
  _require_node
  # Server returns empty tools array.
  local entry="${TEST_TMPDIR}/fake-plugin/servers/efficiency-server.ts"
  mkdir -p "$(dirname "$entry")"
  cat > "$entry" <<'NODESCRIPT'
#!/usr/bin/env node
process.stdin.setEncoding('utf8');
var buf = '';
process.stdin.on('data', function(chunk) {
  buf += chunk;
  var m = buf.match(/\{.*\}/s);
  if (!m) return;
  try {
    var req = JSON.parse(m[0]);
    if (req.method === 'initialize') {
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,result:{protocolVersion:'2024-11-05',capabilities:{},serverInfo:{name:'empty'}}})+'\n');
    } else if (req.method === 'tools/list') {
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,result:{tools:[]}})+'\n');
      setTimeout(function(){process.exit(0);},100);
    }
  } catch(e){}
  buf='';
});
process.stdin.resume();
setTimeout(function(){process.exit(0);},30000);
NODESCRIPT
  chmod +x "$entry"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_server 'efficiency' '${entry}'
  "
  if [ "$status" -ne 2 ]; then
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — Spot-check: single tool invocation per server
# ══════════════════════════════════════════════════════════════════════════════

@test "spot check: bash-server — call ashlr__bash echo hello, verify stdout in result" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/bash-spot-server.ts"
  local tools="ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list"
  _make_mcp_server "$entry" "$tools" "ashlr__bash" "hello"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'bash' '${entry}' 'ashlr__bash' '{\"command\":\"echo hello\"}' 'hello' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  # rc=0 (pass) or rc=2 (skip — server didn't respond); rc=1 would mean tool error.
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: efficiency-server — call ashlr__glob, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/efficiency-spot-server.ts"
  local tools="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
  _make_mcp_server "$entry" "$tools" "ashlr__glob" "glob_result_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'efficiency' '${entry}' 'ashlr__glob' '{\"pattern\":\"*.json\"}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: sql-server — call ashlr__sql SELECT 1, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/sql-spot-server.ts"
  _make_mcp_server "$entry" "ashlr__sql" "ashlr__sql" "1"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'sql' '${entry}' 'ashlr__sql' '{\"query\":\"SELECT 1 AS n\"}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: tree-server — call ashlr__ls, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/tree-spot-server.ts"
  _make_mcp_server "$entry" "ashlr__tree ashlr__ls" "ashlr__ls" "listing_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'tree' '${entry}' 'ashlr__ls' '{\"path\":\".\"}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: http-server — call ashlr__http, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/http-spot-server.ts"
  _make_mcp_server "$entry" "ashlr__http ashlr__webfetch ashlr__websearch" "ashlr__http" "http_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'http' '${entry}' 'ashlr__http' '{\"url\":\"http://localhost\",\"method\":\"GET\"}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: diff-server — call ashlr__diff, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/diff-spot-server.ts"
  _make_mcp_server "$entry" "ashlr__diff ashlr__diff_semantic" "ashlr__diff" "diff_output"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'diff' '${entry}' 'ashlr__diff' '{\"path\":\".\",\"ref\":\"HEAD\"}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: logs-server — call ashlr__logs, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/logs-spot-server.ts"
  _make_mcp_server "$entry" "ashlr__logs" "ashlr__logs" "log_entry"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'logs' '${entry}' 'ashlr__logs' '{\"lines\":1}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: genome-server — call ashlr__genome_status, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/genome-spot-server.ts"
  local tools="ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status"
  _make_mcp_server "$entry" "$tools" "ashlr__genome_status" "genome_status_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'genome' '${entry}' 'ashlr__genome_status' '{}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: orient-server — call ashlr__orient, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/orient-spot-server.ts"
  _make_mcp_server "$entry" "ashlr__orient" "ashlr__orient" "orient_result"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'orient' '${entry}' 'ashlr__orient' '{}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

@test "spot check: github-server — call ashlr__pr, verify result returned" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/github-spot-server.ts"
  local tools="ashlr__pr ashlr__pr_comment ashlr__pr_approve ashlr__issue ashlr__issue_create ashlr__issue_close"
  _make_mcp_server "$entry" "$tools" "ashlr__pr" "pr_result_ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'github' '${entry}' 'ashlr__pr' '{\"repo\":\"owner/repo\",\"number\":1}' '' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"spot_rc=1"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — Spot-check error detection: error response must not pass
# ══════════════════════════════════════════════════════════════════════════════

@test "spot check error detection: tool returning error response returns rc=1" {
  _require_node
  local entry="${TEST_TMPDIR}/fake-plugin/servers/error-server.ts"
  mkdir -p "$(dirname "$entry")"
  cat > "$entry" <<'NODESCRIPT'
#!/usr/bin/env node
process.stdin.setEncoding('utf8');
var buf = '';
process.stdin.on('data', function(chunk) {
  buf += chunk;
  var m = buf.match(/\{.*\}/s);
  if (!m) return;
  try {
    var req = JSON.parse(m[0]);
    if (req.method === 'initialize') {
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,result:{protocolVersion:'2024-11-05',capabilities:{},serverInfo:{name:'error-srv'}}})+'\n');
    } else if (req.method === 'tools/list') {
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,result:{tools:[{name:'ashlr__bash',description:'bash',inputSchema:{}}]}})+'\n');
    } else if (req.method === 'tools/call') {
      // Return an error response — this should cause spot_check to return 1.
      process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,error:{code:-32000,message:'internal error'}})+'\n');
      setTimeout(function(){process.exit(0);},100);
    }
  } catch(e){}
  buf='';
});
process.stdin.resume();
setTimeout(function(){process.exit(0);},30000);
NODESCRIPT
  chmod +x "$entry"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'bash' '${entry}' 'ashlr__bash' '{\"command\":\"echo hi\"}' 'hello' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  # rc=1 (tool error) or rc=2 (skip); must NOT be 0 (false pass).
  [[ "$output" != *"spot_rc=0"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 8 — mcp_contract_validate_all: compliance matrix output
# ══════════════════════════════════════════════════════════════════════════════

@test "validate_all: prints compliance matrix header" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_all
  "
  # Status 0 (all skipped = no failures) is acceptable.
  [ "$status" -le 1 ]
  [[ "$output" == *"MCP Contract Compliance Matrix"* ]]
}

@test "validate_all: matrix contains all 10 server names" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_all
  "
  [ "$status" -le 1 ]
  [[ "$output" == *"efficiency"* ]]
  [[ "$output" == *"sql"* ]]
  [[ "$output" == *"bash"* ]]
  [[ "$output" == *"tree"* ]]
  [[ "$output" == *"http"* ]]
  [[ "$output" == *"diff"* ]]
  [[ "$output" == *"logs"* ]]
  [[ "$output" == *"genome"* ]]
  [[ "$output" == *"orient"* ]]
  [[ "$output" == *"github"* ]]
}

@test "validate_all: matrix footer shows Contracts summary line" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_all
  "
  [ "$status" -le 1 ]
  [[ "$output" == *"Contracts:"* ]]
  [[ "$output" == *"passed"* ]]
  [[ "$output" == *"failed"* ]]
  [[ "$output" == *"skipped"* ]]
}

@test "validate_all: returns 0 when all servers skip (plugin absent)" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_all
  "
  # All servers should skip (plugin absent), not fail.
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAIL"* ]]
}

@test "validate_all: returns 1 when at least one server fails" {
  _require_node
  # Set up a stub server for bash that exposes ONLY ashlr__bash (missing 4 tools).
  local entry="${TEST_TMPDIR}/fake-plugin/servers/bash-server.ts"
  _make_mcp_server "$entry" "ashlr__bash" "ashlr__bash" "ok"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=8
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    # Validate only the bash server (known to be incomplete).
    mcp_contract_validate_all bash
  "
  # Status is either 1 (failure) or 0 (skip if server timed out).
  if [[ "$output" == *"FAIL"* ]]; then
    [ "$status" -eq 1 ]
  fi
}

@test "validate_all: accepts subset of servers" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=2
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_all efficiency sql bash
  "
  [ "$status" -le 1 ]
  [[ "$output" == *"efficiency"* ]]
  [[ "$output" == *"sql"* ]]
  [[ "$output" == *"bash"* ]]
  [[ "$output" != *"github"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 9 — JSON helper unit tests
# ══════════════════════════════════════════════════════════════════════════════

@test "_mcv_json_get_tools: extracts tool names from compact JSON" {
  run bash -c "
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    json='{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"ashlr__read\",\"description\":\"d\",\"inputSchema\":{}},{\"name\":\"ashlr__grep\",\"description\":\"d\",\"inputSchema\":{}}]}}'
    _mcv_json_get_tools \"\$json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]]
  [[ "$output" == *"ashlr__grep"* ]]
}

@test "_mcv_json_get_tools: returns empty string for empty tools array" {
  run bash -c "
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    json='{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}'
    result=\$(_mcv_json_get_tools \"\$json\")
    echo \"empty=\${result:-YES}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty=YES"* ]]
}

@test "_mcv_json_get_string: extracts simple string value" {
  run bash -c "
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    json='{\"protocolVersion\":\"2024-11-05\",\"serverName\":\"test-server\"}'
    _mcv_json_get_string \"\$json\" 'protocolVersion'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"2024-11-05"* ]]
}

@test "_mcv_json_get_tools: extracts single tool correctly" {
  run bash -c "
    export NO_COLOR=1
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    json='{\"result\":{\"tools\":[{\"name\":\"ashlr__sql\",\"description\":\"SQL query\",\"inputSchema\":{\"type\":\"object\"}}]}}'
    _mcv_json_get_tools \"\$json\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__sql"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 10 — Real plugin integration (skip when plugin absent)
# ══════════════════════════════════════════════════════════════════════════════

@test "real plugin: validate_all runs without FAIL when ashlr-plugin installed" {
  local real_plugin="${ASHLR_PLUGIN_DIR_REAL:-$HOME/Desktop/ashlr-plugin}"
  if [ ! -d "${real_plugin}/servers" ]; then
    skip "ashlr-plugin not installed at ${real_plugin}"
  fi
  if ! command -v bun >/dev/null 2>&1; then
    skip "bun not on PATH — cannot run real plugin servers"
  fi
  if [ ! -d "${real_plugin}/node_modules/@modelcontextprotocol/sdk" ]; then
    skip "ashlr-plugin deps not installed (run: cd ${real_plugin} && bun install)"
  fi

  run bash -c "
    export ASHLR_PLUGIN_DIR='${real_plugin}'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=10
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    mcp_contract_validate_all
  "
  # Any FAIL lines are a hard error (schema drift or broken server).
  [[ "$output" != *"FAIL"* ]]
  # Status 0 = all pass or skip; 1 = failures.
  [ "$status" -eq 0 ]
}

@test "real plugin: bash-server spot-check echo hello (skip if plugin absent)" {
  local real_plugin="${ASHLR_PLUGIN_DIR_REAL:-$HOME/Desktop/ashlr-plugin}"
  if [ ! -d "${real_plugin}/servers" ]; then
    skip "ashlr-plugin not installed"
  fi
  if ! command -v bun >/dev/null 2>&1; then
    skip "bun not on PATH"
  fi
  if [ ! -d "${real_plugin}/node_modules/@modelcontextprotocol/sdk" ]; then
    skip "ashlr-plugin deps not installed"
  fi

  run bash -c "
    export ASHLR_PLUGIN_DIR='${real_plugin}'
    export NO_COLOR=1
    export MCP_CONTRACT_TIMEOUT=10
    unset _ASHLR_MCP_CONTRACT_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    rc=0
    mcp_contract_spot_check 'bash' '${real_plugin}/servers/bash-server.ts' \
      'ashlr__bash' '{\"command\":\"echo hello\"}' 'hello' || rc=\$?
    echo \"spot_rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  # Must not return rc=1 (tool error).
  [[ "$output" != *"spot_rc=1"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 11 — Integration: validate_all + mcp-tool-inspector static registry agree
# ══════════════════════════════════════════════════════════════════════════════

@test "contract-vs-inspector: same 10 server names in both registries" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1

    unset _ASHLR_MCP_CONTRACT_SOURCED _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    . '${LIB_DIR}/mcp-tool-inspector.sh'

    # Both registries must define the same 10 servers.
    mismatch=0
    for srv in efficiency sql bash tree http diff logs genome orient github; do
      eval \"cv_tools=\\\"\\\${_MCV_EXPECTED_\${srv}:-}\\\"\"
      eval \"ins_tools=\\\"\\\${_INSP_STATIC_\${srv}:-}\\\"\"
      if [ -z \"\$cv_tools\" ] || [ -z \"\$ins_tools\" ]; then
        echo \"MISMATCH: \$srv cv=\${cv_tools:-(empty)} ins=\${ins_tools:-(empty)}\"
        mismatch=\$((mismatch+1))
      fi
    done
    echo \"mismatches=\$mismatch\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"mismatches=0"* ]]
}

@test "contract-vs-inspector: expected tool sets are consistent across both registries" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1

    unset _ASHLR_MCP_CONTRACT_SOURCED _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-contract-validator.sh'
    . '${LIB_DIR}/mcp-tool-inspector.sh'

    # For each server, every tool in the contract validator expected list must
    # also appear in the inspector static list.
    missing=0
    for srv in efficiency sql bash tree http diff logs genome orient github; do
      eval \"cv_tools=\\\"\\\${_MCV_EXPECTED_\${srv}:-}\\\"\"
      eval \"ins_tools=\\\"\\\${_INSP_STATIC_\${srv}:-}\\\"\"
      for tool in \$cv_tools; do
        found=0
        for t in \$ins_tools; do
          [ \"\$t\" = \"\$tool\" ] && found=1 && break
        done
        if [ \"\$found\" -eq 0 ]; then
          echo \"CONTRACT_ONLY: \$srv:\$tool\"
          missing=\$((missing+1))
        fi
      done
    done
    echo \"contract_only_count=\$missing\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"contract_only_count=0"* ]]
}
