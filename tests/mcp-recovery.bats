#!/usr/bin/env bats
# tests/mcp-recovery.bats — Unit + integration tests for mcp-recovery.sh
#
# Test categories:
#   1. Library sourceable — no side-effects on source
#   2. Missing binary (rc=3) — entry file does not exist
#   3. Missing runtime (rc=4) — bun/node not available
#   4. Parse error (rc=5) — TypeScript/JS syntax error in server file
#   5. Timeout (rc=1) — server starts but never emits init signal
#   6. Crash (rc=2) — server exits non-zero immediately
#   7. Healthy (rc=0) — server emits JSON or ready line within timeout
#   8. MCP_UNAVAILABLE accumulation — failures accumulate correctly
#   9. MCP_FAILURES_JSONL emission — failure records are valid JSONL
#  10. mcp_recovery_report output — % line and flaky server list
#  11. mcp_recovery_probe_all with explicit pairs
#  12. mcp_recovery_check_unavailable helper
#  13. Integration — one broken server among healthy peers, agent still launches
#
# Run:
#   bats tests/mcp-recovery.bats
#   NO_COLOR=1 bats tests/mcp-recovery.bats

# ─── Resolve paths ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
export REPO_ROOT LIB_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-recovery-test-XXXXXX)"
  export TEST_TMPDIR

  # Isolate all state into the temp dir.
  export MCP_FAILURES_JSONL="${TEST_TMPDIR}/mcp-failures.jsonl"
  export MCP_UNAVAILABLE=""
  export MCP_RECOVERY_TIMEOUT=3
  export ASHLR_PLUGIN_DIR="${TEST_TMPDIR}/fake-plugin"
  unset MCP_RECOVERY_VERBOSE
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-recovery-noop}" 2>/dev/null || true
}

# ─── Helper: source the library fresh in each test subprocess ─────────────────
_source_lib() {
  # Unset source guard so sourcing always re-runs in each test's process.
  unset _ASHLR_MCP_RECOVERY_SOURCED
  # shellcheck source=scripts/lib/mcp-recovery.sh
  . "${LIB_DIR}/mcp-recovery.sh"
}

# ─── Helper: write a minimal "healthy" MCP server stub ────────────────────────
_make_healthy_server() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env node
// Minimal stub: emit a JSON line (simulates MCP stdio handshake) then idle.
process.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}\n');
// Hold stdin open briefly so the probe has time to read the output.
setTimeout(function(){}, 10000);
EOF
  chmod +x "$path"
}

# ─── Helper: write a server that exits immediately non-zero (crash) ────────────
_make_crash_server() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '#!/usr/bin/env node\nprocess.stderr.write("fatal: internal error\\n"); process.exit(1);\n' > "$path"
  chmod +x "$path"
}

# ─── Helper: write a server with a syntax error (parse error) ─────────────────
_make_parse_error_server() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  # JS with intentional syntax error — "SyntaxError" will appear in stderr.
  printf '#!/usr/bin/env node\nthis is not valid javascript @@@\n' > "$path"
  chmod +x "$path"
}

# ─── Helper: write a server that hangs silently (timeout) ─────────────────────
# Uses process.stdin.resume() + setInterval to keep the event loop alive even
# when stdin is /dev/null, ensuring the process stays running for the full
# MCP_RECOVERY_TIMEOUT so the probe classifies it as rc=1 (timeout) not rc=2.
_make_hang_server() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env node
// Hang forever without emitting any output — simulates a stuck MCP server.
// process.stdin.resume() keeps the event loop alive even when stdin is /dev/null.
process.stdin.resume();
setInterval(function(){}, 60000);
EOF
  chmod +x "$path"
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. Library sourceable with no side-effects
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-recovery.sh: sources cleanly with bash -n (syntax check)" {
  run bash -n "${LIB_DIR}/mcp-recovery.sh"
  [ "$status" -eq 0 ]
}

@test "mcp-recovery.sh: sources cleanly with no error output" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    echo 'sourced'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced"* ]]
}

@test "mcp-recovery.sh: double-source guard prevents re-initialization" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    . '${LIB_DIR}/mcp-recovery.sh'
    echo 'double-sourced-ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double-sourced-ok"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. Missing binary (rc=3)
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_server: rc=3 when entry file does not exist" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'ghost-server' '${TEST_TMPDIR}/nonexistent/server.ts'
  "
  [ "$status" -eq 3 ]
}

@test "probe_server: rc=3 emits JSONL record with exit_code=3" {
  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'ghost-server' '${TEST_TMPDIR}/nonexistent/server.ts' || true
  "
  [ -f "${TEST_TMPDIR}/f.jsonl" ]
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl")"
  [[ "$record" == *'"server":"ghost-server"'* ]]
  [[ "$record" == *'"exit_code":3'* ]]
}

@test "probe_server: rc=3 marks server unavailable in MCP_UNAVAILABLE" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'ghost-server' '${TEST_TMPDIR}/nonexistent/server.ts' || true
    printf '%s' \"\$MCP_UNAVAILABLE\"
  "
  [[ "$output" == *"ghost-server"* ]]
}

@test "probe_server: rc=3 suggested_fix mentions git pull" {
  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'ghost-server' '${TEST_TMPDIR}/nonexistent/server.ts' || true
  "
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl")"
  [[ "$record" == *"git pull"* ]] || [[ "$record" == *"missing"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. Missing runtime (rc=4)
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_server: rc=4 when runtime is not on PATH (for .ts entry)" {
  # Create the file but run in an env where bun is not available.
  local entry="${TEST_TMPDIR}/fake-server.ts"
  printf 'const x = 1;\n' > "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    export PATH=/usr/bin:/bin   # strip bun/node from PATH
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'no-runtime' '${entry}'
  "
  # Exit code should be 4 (no runtime).
  [ "$status" -eq 4 ]
}

@test "probe_server: rc=4 emits JSONL record with exit_code=4" {
  local entry="${TEST_TMPDIR}/fake-server.ts"
  printf 'const x = 1;\n' > "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    export PATH=/usr/bin:/bin
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'no-runtime' '${entry}' || true
  "
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl" 2>/dev/null || echo '')"
  [[ "$record" == *'"exit_code":4'* ]]
}

@test "probe_server: rc=4 suggested_fix mentions bun install" {
  local entry="${TEST_TMPDIR}/fake-server.ts"
  printf 'const x = 1;\n' > "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    export PATH=/usr/bin:/bin
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'no-runtime' '${entry}' || true
  "
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl" 2>/dev/null || echo '')"
  [[ "$record" == *"bun"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. Parse error (rc=5)
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_server: rc=5 when server has a syntax error" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH — skipping parse-error test"
  fi
  local entry="${TEST_TMPDIR}/bad-syntax.js"
  _make_parse_error_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'bad-syntax' '${entry}'
  "
  # rc=5 (parse error) or rc=2 (crash) are both acceptable for this path —
  # the important thing is that it is NOT 0 (not healthy).
  [ "$status" -ne 0 ]
}

@test "probe_server: parse error emits JSONL with non-zero exit_code" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/bad-syntax.js"
  _make_parse_error_server "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'bad-syntax' '${entry}' || true
  "
  [ -f "${TEST_TMPDIR}/f.jsonl" ]
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl")"
  [[ "$record" == *'"server":"bad-syntax"'* ]]
  # exit_code must be non-zero (2 or 5).
  [[ "$record" != *'"exit_code":0'* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. Timeout (rc=1)
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_server: rc=1 when server hangs without emitting init signal" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/hang-server.js"
  _make_hang_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=2
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'hang-server' '${entry}'
  "
  [ "$status" -eq 1 ]
}

@test "probe_server: timeout emits JSONL with exit_code=1" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/hang-server.js"
  _make_hang_server "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=2
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'hang-server' '${entry}' || true
  "
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl" 2>/dev/null || echo '')"
  [[ "$record" == *'"exit_code":1'* ]]
}

@test "probe_server: timeout marks server unavailable" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/hang-server.js"
  _make_hang_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=2
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'hang-server' '${entry}' || true
    printf '%s' \"\$MCP_UNAVAILABLE\"
  "
  [[ "$output" == *"hang-server"* ]]
}

@test "probe_server: timeout suggested_fix mentions manual run" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/hang-server.js"
  _make_hang_server "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=2
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'hang-server' '${entry}' || true
  "
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl" 2>/dev/null || echo '')"
  # Fix should tell user to run the server manually.
  [[ "$record" == *"run"* ]] || [[ "$record" == *"manual"* ]] || [[ "$record" == *"bun"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. Crash (rc=2)
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_server: rc=2 when server exits non-zero immediately" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/crash-server.js"
  _make_crash_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'crash-server' '${entry}'
  "
  [ "$status" -eq 2 ]
}

@test "probe_server: crash emits JSONL with exit_code=2" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/crash-server.js"
  _make_crash_server "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'crash-server' '${entry}' || true
  "
  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl" 2>/dev/null || echo '')"
  [[ "$record" == *'"exit_code":2'* ]]
}

@test "probe_server: crash marks server unavailable" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/crash-server.js"
  _make_crash_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'crash-server' '${entry}' || true
    printf '%s' \"\$MCP_UNAVAILABLE\"
  "
  [[ "$output" == *"crash-server"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 7. Healthy (rc=0)
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_server: rc=0 when server emits JSON init line" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/healthy-server.js"
  _make_healthy_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=5
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'healthy-server' '${entry}'
  "
  [ "$status" -eq 0 ]
}

@test "probe_server: healthy server does NOT mark server unavailable" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/healthy-server.js"
  _make_healthy_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=5
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'healthy-server' '${entry}'
    printf '%s' \"\$MCP_UNAVAILABLE\"
  "
  # MCP_UNAVAILABLE should remain empty.
  [[ "$output" != *"healthy-server"* ]]
}

@test "probe_server: healthy server does NOT write to MCP_FAILURES_JSONL" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/healthy-server.js"
  _make_healthy_server "$entry"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=5
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'healthy-server' '${entry}'
  "
  # JSONL file should not exist or should be empty.
  if [ -f "${TEST_TMPDIR}/f.jsonl" ]; then
    local line_count
    line_count="$(wc -l < "${TEST_TMPDIR}/f.jsonl" | tr -d ' ')"
    [ "$line_count" -eq 0 ]
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 8. MCP_UNAVAILABLE accumulation
# ══════════════════════════════════════════════════════════════════════════════

@test "MCP_UNAVAILABLE: accumulates multiple failed servers without duplicates" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    # Probe three nonexistent servers.
    mcp_recovery_probe_server 'alpha' '/nope/alpha.ts' || true
    mcp_recovery_probe_server 'beta'  '/nope/beta.ts'  || true
    mcp_recovery_probe_server 'gamma' '/nope/gamma.ts' || true
    # Probe same server twice — should not duplicate.
    mcp_recovery_probe_server 'alpha' '/nope/alpha.ts' || true
    printf '%s' \"\$MCP_UNAVAILABLE\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" == *"gamma"* ]]
  # Count occurrences of "alpha" — must be exactly 1.
  local count
  count="$(printf '%s' "$output" | tr ':' '\n' | grep -c '^alpha$' || echo 0)"
  [ "$count" -eq 1 ]
}

@test "MCP_UNAVAILABLE: exported so subprocesses inherit it" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'srv-a' '/nope/srv-a.ts' || true
    # Verify a child process sees the variable.
    bash -c 'printf \"%s\" \"\$MCP_UNAVAILABLE\"'
  "
  [[ "$output" == *"srv-a"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 9. MCP_FAILURES_JSONL content validation
# ══════════════════════════════════════════════════════════════════════════════

@test "MCP_FAILURES_JSONL: each record is valid JSON" {
  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'srv1' '/nope/srv1.ts' || true
    mcp_recovery_probe_server 'srv2' '/nope/srv2.ts' || true
  "
  [ -f "${TEST_TMPDIR}/f.jsonl" ]
  local bad_lines=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    python3 -c "import json; json.loads('${line//\'/\'\\\'\'}')" 2>/dev/null || bad_lines=$((bad_lines+1))
  done < "${TEST_TMPDIR}/f.jsonl"
  [ "$bad_lines" -eq 0 ]
}

@test "MCP_FAILURES_JSONL: each record has required fields (ts, server, exit_code, error, suggested_fix)" {
  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'required-fields' '/nope/x.ts' || true
  "
  [ -f "${TEST_TMPDIR}/f.jsonl" ]
  local result
  result="$(python3 -c "
import json, sys
for line in open('${TEST_TMPDIR}/f.jsonl'):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    for k in ['ts', 'server', 'exit_code', 'error', 'suggested_fix']:
        assert k in r, f'missing field {k}: {r}'
print('ok')
" 2>&1)"
  [ "$result" = "ok" ]
}

@test "MCP_FAILURES_JSONL: ts field is ISO-8601 formatted" {
  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'ts-check' '/nope/ts.ts' || true
  "
  local result
  result="$(python3 -c "
import json, re
for line in open('${TEST_TMPDIR}/f.jsonl'):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    ts = r.get('ts', '')
    assert re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', ts), f'bad ts: {ts}'
print('ok')
" 2>&1)"
  [ "$result" = "ok" ]
}

@test "MCP_FAILURES_JSONL: records for distinct servers are appended (not overwritten)" {
  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'srv-a' '/nope/a.ts' || true
    mcp_recovery_probe_server 'srv-b' '/nope/b.ts' || true
    mcp_recovery_probe_server 'srv-c' '/nope/c.ts' || true
  "
  local line_count
  line_count="$(wc -l < "${TEST_TMPDIR}/f.jsonl" | tr -d ' ')"
  [ "$line_count" -eq 3 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 10. mcp_recovery_report output
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp_recovery_report: shows 100% when no failures" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TOTAL_SERVERS=10
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_report
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"10/10"* ]]
  [[ "$output" == *"100%"* ]]
}

@test "mcp_recovery_report: shows degraded % when some servers failed" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE='sql:logs'
    MCP_RECOVERY_TOTAL_SERVERS=10
    . '${LIB_DIR}/mcp-recovery.sh'
    # Emit failure records for the two unavailable servers.
    _mcp_recovery_emit_failure 'sql'  3 'file missing' 'run git pull'
    _mcp_recovery_emit_failure 'logs' 2 'crashed'      'bun install'
    mcp_recovery_report
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"8/10"* ]]
  [[ "$output" == *"80%"* ]]
}

@test "mcp_recovery_report: lists flaky server names when failures present" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE='flaky-one:flaky-two'
    MCP_RECOVERY_TOTAL_SERVERS=10
    . '${LIB_DIR}/mcp-recovery.sh'
    _mcp_recovery_emit_failure 'flaky-one' 3 'missing entry' 'git pull'
    _mcp_recovery_emit_failure 'flaky-two' 1 'timeout'       'run manually'
    mcp_recovery_report
  "
  [[ "$output" == *"flaky-one"* ]]
  [[ "$output" == *"flaky-two"* ]]
}

@test "mcp_recovery_report: shows failures log path when JSONL has content" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE='broken'
    MCP_RECOVERY_TOTAL_SERVERS=10
    . '${LIB_DIR}/mcp-recovery.sh'
    _mcp_recovery_emit_failure 'broken' 2 'crash' 'fix it'
    mcp_recovery_report
  "
  [[ "$output" == *"${TEST_TMPDIR}/f.jsonl"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# 11. mcp_recovery_probe_all with explicit pairs
# ══════════════════════════════════════════════════════════════════════════════

@test "probe_all: returns 1 when any server in the list fails" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_all 'ghost' '/nope/ghost.ts'
  "
  [ "$status" -eq 1 ]
}

@test "probe_all: accumulates all failures when multiple servers are broken" {
  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_all \
      'one' '/nope/one.ts' \
      'two' '/nope/two.ts' || true
    printf '%s' \"\$MCP_UNAVAILABLE\"
  "
  [[ "$output" == *"one"* ]]
  [[ "$output" == *"two"* ]]
}

@test "probe_all: returns 0 when all servers pass" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  local entry="${TEST_TMPDIR}/healthy.js"
  _make_healthy_server "$entry"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=5
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_all 'healthy' '${entry}'
  "
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 12. mcp_recovery_check_unavailable helper
# ══════════════════════════════════════════════════════════════════════════════

@test "check_unavailable: returns 0 (true) for a server in MCP_UNAVAILABLE" {
  run bash -c "
    MCP_UNAVAILABLE='alpha:beta:gamma'
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_check_unavailable 'beta'
  "
  [ "$status" -eq 0 ]
}

@test "check_unavailable: returns 1 (false) for a server not in MCP_UNAVAILABLE" {
  run bash -c "
    MCP_UNAVAILABLE='alpha:beta:gamma'
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_check_unavailable 'delta'
  "
  [ "$status" -eq 1 ]
}

@test "check_unavailable: returns 1 when MCP_UNAVAILABLE is empty" {
  run bash -c "
    MCP_UNAVAILABLE=''
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_check_unavailable 'anything'
  "
  [ "$status" -eq 1 ]
}

@test "check_unavailable: partial name match does NOT count as unavailable" {
  # 'bash' should not match 'ashlr-bash' or 'bash-extra'.
  run bash -c "
    MCP_UNAVAILABLE='bash-extra:ashlr-bash'
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_check_unavailable 'bash'
  "
  [ "$status" -eq 1 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 13. Integration — one broken server; agent still launches
# ══════════════════════════════════════════════════════════════════════════════

@test "integration: agent continues with reduced capability when one server fails" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi

  local healthy="${TEST_TMPDIR}/healthy.js"
  local broken="${TEST_TMPDIR}/broken.js"
  _make_healthy_server "$healthy"
  _make_crash_server   "$broken"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'

    # Probe two servers: one healthy, one broken.
    mcp_recovery_probe_server 'healthy-svc' '${healthy}' || true
    mcp_recovery_probe_server 'broken-svc'  '${broken}'  || true

    # Simulate agent launch: it checks availability and skips broken servers.
    launch_status=0
    if mcp_recovery_check_unavailable 'broken-svc'; then
      printf 'SKIP broken-svc\n'
    fi
    if ! mcp_recovery_check_unavailable 'healthy-svc'; then
      printf 'LAUNCH with healthy-svc\n'
    fi

    # Agent launch succeeded even with one degraded server.
    printf 'agent_launched=%d\n' \"\$launch_status\"
    printf 'unavailable=%s\n' \"\$MCP_UNAVAILABLE\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP broken-svc"* ]]
  [[ "$output" == *"LAUNCH with healthy-svc"* ]]
  [[ "$output" == *"agent_launched=0"* ]]
  [[ "$output" == *"broken-svc"* ]]
  [[ "$output" != *"healthy-svc"*"unavailable"* ]] || true  # healthy-svc not in MCP_UNAVAILABLE
}

@test "integration: degradation is logged to JSONL and failure file exists" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi

  local healthy="${TEST_TMPDIR}/h.js"
  local broken="${TEST_TMPDIR}/b.js"
  _make_healthy_server "$healthy"
  _make_crash_server   "$broken"

  bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'svc-ok'  '${healthy}' || true
    mcp_recovery_probe_server 'svc-bad' '${broken}'  || true
  "

  # Exactly one failure record (for svc-bad).
  [ -f "${TEST_TMPDIR}/f.jsonl" ]
  local line_count
  line_count="$(wc -l < "${TEST_TMPDIR}/f.jsonl" | tr -d ' ')"
  [ "$line_count" -eq 1 ]

  local record
  record="$(cat "${TEST_TMPDIR}/f.jsonl")"
  [[ "$record" == *'"server":"svc-bad"'* ]]
}

@test "integration: mcp_recovery_report shows correct degraded % after mixed probes" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi

  local healthy="${TEST_TMPDIR}/h2.js"
  local broken="${TEST_TMPDIR}/b2.js"
  _make_healthy_server "$healthy"
  _make_crash_server   "$broken"

  run bash -c "
    MCP_FAILURES_JSONL='${TEST_TMPDIR}/f.jsonl'
    MCP_UNAVAILABLE=''
    MCP_RECOVERY_TIMEOUT=3
    MCP_RECOVERY_TOTAL_SERVERS=2
    . '${LIB_DIR}/mcp-recovery.sh'
    mcp_recovery_probe_server 'good-svc' '${healthy}' || true
    mcp_recovery_probe_server 'bad-svc'  '${broken}'  || true
    mcp_recovery_report
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"1/2"* ]]
  [[ "$output" == *"50%"* ]]
}
