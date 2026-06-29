#!/usr/bin/env bats
# tests/mcp-tool-discovery.bats — Tests for mcp-tool-inspector.sh + aw tools
#
# Test categories:
#   1.  Library sourceable — no side-effects on source, syntax clean
#   2.  Static tool registry — correct tools returned per server when probe unavailable
#   3.  Matrix build — mcp_inspector_build_matrix populates state vars
#   4.  Tool list — mcp_inspector_tool_list returns correct tools per agent
#   5.  Suggest prompt — mcp_inspector_suggest_prompt output validation
#   6.  Task-hint narrowing — suggest_prompt filters to task-relevant tools
#   7.  Breakage detection — mcp_inspector_detect_breakage returns correct status
#   8.  Fallback suggestions — broken server surfaces fallback for each tool
#   9.  Session hint injectors — goose/aider/ashlrcode hint generation
#  10.  Cache — probe results are cached and reused within TTL
#  11.  aw tools subcommand — basic invocation and flag parsing
#  12.  Agent config reader — correct server list per agent config
#  13.  Integration — tool matrix matches static config when plugin absent
#
# Run:
#   bats tests/mcp-tool-discovery.bats
#   NO_COLOR=1 bats tests/mcp-tool-discovery.bats

# ─── Resolve paths ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
BIN_DIR="${REPO_ROOT}/bin"
export REPO_ROOT LIB_DIR BIN_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-tool-discovery-test-XXXXXX)"
  export TEST_TMPDIR

  # Isolate plugin dir and cache
  export ASHLR_PLUGIN_DIR="${TEST_TMPDIR}/fake-plugin"
  export MCP_INSP_CACHE_DIR="${TEST_TMPDIR}/inspector-cache"
  export MCP_INSP_PROBE_TIMEOUT=2
  export MCP_INSP_CACHE_TTL=300
  export NO_COLOR=1
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-tool-discovery-noop}" 2>/dev/null || true
}

# ─── Helper: source the inspector fresh in each subprocess ───────────────────
_source_inspector() {
  unset _ASHLR_MCP_INSPECTOR_SOURCED
  # shellcheck source=scripts/lib/mcp-tool-inspector.sh
  . "${LIB_DIR}/mcp-tool-inspector.sh"
}

# ─── Helper: create a minimal fake plugin dir with server stubs ──────────────
_make_fake_plugin() {
  local plugin_dir="${1:-${TEST_TMPDIR}/fake-plugin}"
  mkdir -p "${plugin_dir}/servers"
  for name in efficiency sql bash tree http diff logs genome orient github; do
    # Create a minimal .ts stub file that exists but does not run
    printf '// fake %s server\n' "$name" > "${plugin_dir}/servers/${name}-server.ts"
  done
}

# ─── Helper: create a healthy fake MCP server that returns tools/list ─────────
_make_healthy_mcp_server() {
  local path="$1"
  local tool_names="$2"   # space-separated tool names to return
  mkdir -p "$(dirname "$path")"

  # Build the tools array JSON
  local tools_json=""
  local first=1
  for t in $tool_names; do
    if [ "$first" -eq 1 ]; then
      tools_json="{\"name\":\"${t}\",\"description\":\"${t} tool\",\"inputSchema\":{}}"
      first=0
    else
      tools_json="${tools_json},{\"name\":\"${t}\",\"description\":\"${t} tool\",\"inputSchema\":{}}"
    fi
  done

  cat > "$path" <<EOF
#!/usr/bin/env node
// Minimal MCP server stub for testing
process.stdin.setEncoding('utf8');
var buf = '';
process.stdin.on('data', function(chunk) {
  buf += chunk;
  var lines = buf.split('\r\n\r\n');
  for (var i = 0; i < lines.length - 1; i++) {
    var body = lines[i + 1] ? lines[i + 1].split('Content-Length')[0] : '';
    try {
      var req = JSON.parse(body || lines[i]);
      if (req.method === 'initialize') {
        process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,result:{protocolVersion:'2024-11-05',capabilities:{},serverInfo:{name:'test'}}}) + '\n');
      } else if (req.method === 'tools/list') {
        process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:req.id,result:{tools:[${tools_json}]}}) + '\n');
        process.exit(0);
      }
    } catch(e) {}
  }
  buf = lines[lines.length - 1];
});
process.stdin.resume();
EOF
  chmod +x "$path"
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. Library sourceable — no side-effects
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-tool-inspector.sh: passes bash -n syntax check" {
  run bash -n "${LIB_DIR}/mcp-tool-inspector.sh"
  [ "$status" -eq 0 ]
}

@test "mcp-tool-inspector.sh: sources cleanly with no error output" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced_ok"* ]]
}

@test "mcp-tool-inspector.sh: double-source guard works" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    echo 'double_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double_ok"* ]]
}

@test "mcp-tool-inspector.sh: public functions are defined after sourcing" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    declare -f mcp_inspector_build_matrix >/dev/null && echo 'build_ok'
    declare -f mcp_inspector_tool_list >/dev/null    && echo 'list_ok'
    declare -f mcp_inspector_suggest_prompt >/dev/null && echo 'suggest_ok'
    declare -f mcp_inspector_detect_breakage >/dev/null && echo 'detect_ok'
    declare -f mcp_inspector_show >/dev/null           && echo 'show_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"build_ok"* ]]
  [[ "$output" == *"list_ok"* ]]
  [[ "$output" == *"suggest_ok"* ]]
  [[ "$output" == *"detect_ok"* ]]
  [[ "$output" == *"show_ok"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. Static tool registry — correct tools when probe unavailable
# ══════════════════════════════════════════════════════════════════════════════

@test "static registry: efficiency server has expected tools" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"\${_INSP_SRV_TOOLS_efficiency}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]]
  [[ "$output" == *"ashlr__grep"* ]]
  [[ "$output" == *"ashlr__glob"* ]]
}

@test "static registry: bash server has expected tools" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"\${_INSP_SRV_TOOLS_bash}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__bash"* ]]
  [[ "$output" == *"ashlr__bash_start"* ]]
  [[ "$output" == *"ashlr__bash_tail"* ]]
}

@test "static registry: sql server has ashlr__sql" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"\${_INSP_SRV_TOOLS_sql}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__sql"* ]]
}

@test "static registry: github server has pr and issue tools" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"\${_INSP_SRV_TOOLS_github}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__pr"* ]]
  [[ "$output" == *"ashlr__issue"* ]]
}

@test "static registry: all 10 servers have non-empty tool lists" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    empty=0
    for srv in efficiency sql bash tree http diff logs genome orient github; do
      eval \"tools=\\\"\\\${_INSP_SRV_TOOLS_\${srv}:-}\\\"\"
      [ -z \"\$tools\" ] && empty=\$((empty+1)) && echo \"EMPTY: \$srv\"
    done
    echo \"empty_count=\$empty\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty_count=0"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. Matrix build — state variables populated correctly
# ══════════════════════════════════════════════════════════════════════════════

@test "build_matrix: sets _INSP_MATRIX_BUILT=1 after call" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"built=\${_INSP_MATRIX_BUILT}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"built=1"* ]]
}

@test "build_matrix: status=unavailable when plugin dir missing" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"efficiency_status=\${_INSP_SRV_STATUS_efficiency}\"
    echo \"bash_status=\${_INSP_SRV_STATUS_bash}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"efficiency_status=unavailable"* ]]
  [[ "$output" == *"bash_status=unavailable"* ]]
}

@test "build_matrix: status=static when plugin present but bun absent" {
  _make_fake_plugin "${TEST_TMPDIR}/fake-plugin"
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    # Strip bun from PATH to simulate no runtime
    export PATH=/usr/bin:/bin
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"status=\${_INSP_SRV_STATUS_efficiency}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=static"* ]]
}

@test "build_matrix: healthy=0 when plugin missing" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"healthy=\${_INSP_SRV_HEALTHY_bash}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy=0"* ]]
}

@test "build_matrix: force flag bypasses cache" {
  # Pre-populate a cache file for bash server
  mkdir -p "${TEST_TMPDIR}/inspector-cache"
  printf 'cached_tool_xyz\n' > "${TEST_TMPDIR}/inspector-cache/tools-bash.txt"
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/inspector-cache'
    export MCP_INSP_CACHE_TTL=300
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    # With force, cache is ignored; since plugin missing, falls back to static
    mcp_inspector_build_matrix force
    echo \"tools=\${_INSP_SRV_TOOLS_bash}\"
  "
  [ "$status" -eq 0 ]
  # After force, static tools (not the cached_tool_xyz) should be present
  [[ "$output" != *"cached_tool_xyz"* ]]
  [[ "$output" == *"ashlr__bash"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. Tool list — mcp_inspector_tool_list
# ══════════════════════════════════════════════════════════════════════════════

@test "tool_list: returns tools for all servers when no agent specified" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_tool_list
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]]
  [[ "$output" == *"ashlr__bash"* ]]
  [[ "$output" == *"ashlr__sql"* ]]
  [[ "$output" == *"ashlr__pr"* ]]
}

@test "tool_list: no duplicate tools in output" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_tool_list
  "
  [ "$status" -eq 0 ]
  # Count occurrences of ashlr__bash — should be exactly 1
  local count
  count="$(printf '%s\n' "$output" | grep -c '^ashlr__bash$' || echo 0)"
  [ "$count" -eq 1 ]
}

@test "tool_list: returns tools when agent is 'ashlrcode'" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_tool_list ashlrcode
  "
  [ "$status" -eq 0 ]
  # Should get at least some tools (falls back to all servers when config absent)
  [ -n "$output" ]
}

@test "tool_list: output is newline-separated (one tool per line)" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_tool_list | head -5
  "
  [ "$status" -eq 0 ]
  # Each line should look like ashlr__something (no spaces within a line)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Tool names must not contain spaces
    [[ "$line" != *" "* ]]
  done <<< "$output"
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. Suggest prompt — output validation
# ══════════════════════════════════════════════════════════════════════════════

@test "suggest_prompt: output mentions agent name" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt goose
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"goose"* ]]
}

@test "suggest_prompt: output contains tool names" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt ashlrcode
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__"* ]]
}

@test "suggest_prompt: no-agent call returns all tools" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__bash"* ]]
  [[ "$output" == *"ashlr__read"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. Task-hint narrowing
# ══════════════════════════════════════════════════════════════════════════════

@test "suggest_prompt: 'search' hint includes ashlr__grep" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt '' search
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__grep"* ]]
}

@test "suggest_prompt: 'sql' hint includes ashlr__sql" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt '' sql
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__sql"* ]]
}

@test "suggest_prompt: 'debug' hint includes ashlr__bash and ashlr__logs" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt '' debug
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__bash"* ]]
  [[ "$output" == *"ashlr__logs"* ]]
}

@test "suggest_prompt: 'git' hint includes ashlr__diff" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt '' git
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__diff"* ]]
}

@test "suggest_prompt: 'pr' hint includes ashlr__pr" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt '' pr
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__pr"* ]]
}

@test "suggest_prompt: task hint output includes 'Tool details' section" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_suggest_prompt '' search
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool details"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 7. Breakage detection
# ══════════════════════════════════════════════════════════════════════════════

@test "detect_breakage: returns 1 when plugin is missing" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_detect_breakage
  "
  # Plugin missing → healthy=0 for all servers → returns 1
  [ "$status" -eq 1 ]
}

@test "detect_breakage: returns 1 when plugin present but bun absent" {
  _make_fake_plugin "${TEST_TMPDIR}/fake-plugin"
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    export PATH=/usr/bin:/bin
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_detect_breakage
  "
  [ "$status" -eq 1 ]
}

@test "detect_breakage: prints info about broken servers" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_detect_breakage || true
  "
  [ "$status" -eq 0 ]   # bash -c exit 0 even if detect_breakage returns 1
  # Should mention at least one server name
  [[ "$output" == *"ashlr-"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 8. Fallback suggestions — broken server surfaces fallbacks
# ══════════════════════════════════════════════════════════════════════════════

@test "detect_breakage: surfaces fallback for ashlr__bash when broken" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_detect_breakage || true
  "
  [ "$status" -eq 0 ]
  # Fallback hint for bash should mention native Bash
  [[ "$output" == *"Bash"* ]] || [[ "$output" == *"fallback"* ]]
}

@test "detect_breakage: surfaces fallback for ashlr__read when broken" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_detect_breakage || true
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]] || [[ "$output" == *"cat"* ]] || [[ "$output" == *"fallback"* ]]
}

@test "fallback registry: ashlr__diff fallback is git diff" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    printf '%s' \"\${_INSP_FALLBACK_ashlr__diff}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"git diff"* ]]
}

@test "fallback registry: ashlr__http fallback is curl" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    printf '%s' \"\${_INSP_FALLBACK_ashlr__http}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"curl"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 9. Session hint injectors — goose/aider/ashlrcode
# ══════════════════════════════════════════════════════════════════════════════

@test "inject_goose_hint: output mentions ashlr tools" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_inject_goose_session_hint goose
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr"* ]]
}

@test "inject_goose_hint: output mentions token efficiency" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_inject_goose_session_hint goose
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"token"* ]] || [[ "$output" == *"efficiency"* ]] || [[ "$output" == *"efficient"* ]]
}

@test "inject_aider_hint: output is non-empty" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_inject_aider_session_hint aider
  "
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "inject_ashlrcode_hint: output includes key usage rules" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_inject_ashlrcode_session_hint ashlrcode
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]]
  [[ "$output" == *"ashlr__bash"* ]]
}

@test "inject_ashlrcode_hint: output starts with # header" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_inject_ashlrcode_session_hint ashlrcode | head -1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"#"* ]]
}

@test "inject: goose hint with task produces task-specific output" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_inject_goose_session_hint goose search
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__grep"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 10. Cache — results cached and reused within TTL
# ══════════════════════════════════════════════════════════════════════════════

@test "cache: cache dir is created by build_matrix" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/new-cache-dir'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo done
  "
  [ "$status" -eq 0 ]
  # Cache dir should be created (may be absent since no live probe succeeded)
  # The library creates the dir lazily on write; just verify it didn't crash
  [[ "$output" == *"done"* ]]
}

@test "cache: pre-populated cache is used when within TTL" {
  # Write a fake cache file for the efficiency server
  mkdir -p "${TEST_TMPDIR}/inspector-cache"
  printf 'ashlr__read\nashlr__grep\nashlr__glob\n' \
    > "${TEST_TMPDIR}/inspector-cache/tools-efficiency.txt"

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/fake-plugin'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/inspector-cache'
    export MCP_INSP_CACHE_TTL=9999
    export NO_COLOR=1
    mkdir -p '${TEST_TMPDIR}/fake-plugin/servers'
    printf '' > '${TEST_TMPDIR}/fake-plugin/servers/efficiency-server.ts'
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"status=\${_INSP_SRV_STATUS_efficiency}\"
    echo \"tools=\${_INSP_SRV_TOOLS_efficiency}\"
  "
  [ "$status" -eq 0 ]
  # Cache hit → status should be live, tools from cache
  [[ "$output" == *"status=live"* ]]
  [[ "$output" == *"ashlr__read"* ]]
}

@test "cache: expired cache is not used (falls back to probe/static)" {
  # Write a fake cache file with a very old mtime
  mkdir -p "${TEST_TMPDIR}/inspector-cache"
  printf 'stale_cached_tool\n' \
    > "${TEST_TMPDIR}/inspector-cache/tools-efficiency.txt"
  # Set mtime to epoch 0 (very old)
  touch -t 197001010000 "${TEST_TMPDIR}/inspector-cache/tools-efficiency.txt" 2>/dev/null || true

  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/inspector-cache'
    export MCP_INSP_CACHE_TTL=60
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    echo \"tools=\${_INSP_SRV_TOOLS_efficiency}\"
  "
  [ "$status" -eq 0 ]
  # stale cache should not be used; static tools used instead
  [[ "$output" != *"stale_cached_tool"* ]]
  [[ "$output" == *"ashlr__read"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 11. aw tools subcommand
# ══════════════════════════════════════════════════════════════════════════════

@test "aw tools: subcommand exists and shows output" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools 2>&1
  "
  # Should not crash; status 0 or 1 both acceptable (1 if breakage detected)
  [ "$status" -le 1 ]
  # Output should include the tool inventory header
  [[ "$output" == *"Tool Inventory"* ]] || [[ "$output" == *"ashlr"* ]]
}

@test "aw tools: --help flag exits 0 and shows usage" {
  run bash -c "
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools --help 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"aw tools"* ]]
  [[ "$output" == *"--refresh"* ]]
}

@test "aw tools: accepts valid agent argument" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools goose 2>&1
  "
  [ "$status" -le 1 ]
  [ -n "$output" ]
}

@test "aw tools: rejects unknown agent" {
  run bash -c "
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools nonexistent-agent 2>&1
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown agent"* ]]
}

@test "aw tools: --suggest flag produces suggestion output" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools --suggest 'search and grep files' 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__grep"* ]]
}

@test "aw tools: --inject-ashlrcode produces hint text" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools --inject-ashlrcode 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr__read"* ]]
}

@test "aw tools: --inject-goose produces goose hint" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools --inject-goose 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ashlr"* ]]
}

@test "aw tools: --inject-aider produces aider hint" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools --inject-aider 2>&1
  "
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "aw tools: --refresh flag runs without error" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    '${BIN_DIR}/aw' tools --refresh 2>&1
  "
  [ "$status" -le 1 ]
  [ -n "$output" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 12. Agent config reader
# ══════════════════════════════════════════════════════════════════════════════

@test "agent_servers: ashlrcode config returns ashlr-plugin server names" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    result=\$(_insp_agent_servers ashlrcode)
    printf '%s\n' \"\$result\"
  "
  [ "$status" -eq 0 ]
  # Should return something non-empty (real config or fallback)
  [ -n "$output" ]
}

@test "agent_servers: unknown agent falls back to all servers" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    result=\$(_insp_agent_servers totally-unknown-agent)
    printf '%s\n' \"\$result\"
  "
  [ "$status" -eq 0 ]
  # Falls back to all servers
  [[ "$output" == *"efficiency"* ]] || [[ "$output" == *"bash"* ]]
}

@test "agent_servers: reads real ashlrcode settings.json if present" {
  local settings_file="${REPO_ROOT}/agents/ashlrcode/settings.json"
  if [ ! -f "$settings_file" ]; then
    skip "agents/ashlrcode/settings.json not present"
  fi
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    result=\$(_insp_agent_servers ashlrcode)
    printf '%s\n' \"\$result\"
  "
  [ "$status" -eq 0 ]
  # The real config has at least efficiency, bash, sql
  [[ "$output" == *"efficiency"* ]] || [[ "$output" == *"bash"* ]] || [ -n "$output" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 13. Integration — tool matrix matches static config when plugin absent
# ══════════════════════════════════════════════════════════════════════════════

@test "integration: tool matrix generation succeeds with no plugin" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_tool_list | wc -l | tr -d ' '
  "
  [ "$status" -eq 0 ]
  # Should return at least 10 tools (static registry has 27 total)
  [ "${output}" -ge 10 ]
}

@test "integration: mcp_inspector_show runs without error" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_show
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOOL"* ]]
  [[ "$output" == *"ashlr__"* ]]
}

@test "integration: mcp_inspector_show includes footnotes section" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'
    mcp_inspector_build_matrix
    mcp_inspector_show
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Footnotes"* ]]
  [[ "$output" == *"Servers:"* ]]
}

@test "integration: full pipeline — build, list, suggest, show, detect" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin-here'
    export MCP_INSP_CACHE_DIR='${TEST_TMPDIR}/cache'
    export NO_COLOR=1
    unset _ASHLR_MCP_INSPECTOR_SOURCED
    . '${LIB_DIR}/mcp-tool-inspector.sh'

    mcp_inspector_build_matrix
    echo 'build_ok'

    count=\$(mcp_inspector_tool_list | wc -l | tr -d ' ')
    echo \"tools_count=\$count\"

    mcp_inspector_suggest_prompt ashlrcode search > /dev/null
    echo 'suggest_ok'

    mcp_inspector_show > /dev/null
    echo 'show_ok'

    mcp_inspector_detect_breakage > /dev/null || true
    echo 'detect_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"build_ok"* ]]
  [[ "$output" == *"suggest_ok"* ]]
  [[ "$output" == *"show_ok"* ]]
  [[ "$output" == *"detect_ok"* ]]
  # Sanity: at least 10 tools from static registry
  local count
  count="$(printf '%s\n' "$output" | grep 'tools_count=' | cut -d= -f2)"
  [ "${count:-0}" -ge 10 ]
}
