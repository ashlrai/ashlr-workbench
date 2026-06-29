#!/usr/bin/env bats
# tests/mcp-health-probe.bats — Unit tests for scripts/lib/mcp-health-probe.sh
#
# Test categories:
#   1.  Library sourceable — no side-effects on source
#   2.  Healthy server — _mcp_hp_jsonrpc_ping_once rc=0
#   3.  Missing entry file — _mcp_hp_jsonrpc_ping_once rc=3
#   4.  No runtime — _mcp_hp_jsonrpc_ping_once rc=4
#   5.  Server crash — _mcp_hp_jsonrpc_ping_once rc=2
#   6.  Timeout / hanging — _mcp_hp_jsonrpc_ping_once rc=1
#   7.  Malformed response — _mcp_hp_jsonrpc_ping_once rc=5
#   8.  Probe with backoff — retries on failure, succeeds on subsequent
#   9.  Probe with backoff — all retries exhausted, returns 1
#  10.  mcp_circuit_breaker_status — closed when no history
#  11.  mcp_circuit_breaker_status — open after threshold failures
#  12.  mcp_circuit_breaker_status — half-open after recovery window
#  13.  mcp_circuit_breaker_status — re-closed after success
#  14.  breaker store isolation — distinct servers track independently
#  15.  mcp_probe_all — all healthy → MCP_PROBE_OPEN_COUNT=0, returns 0
#  16.  mcp_probe_all — one server down → MCP_PROBE_RESULTS contains failed
#  17.  mcp_probe_all — cascading failures → open count accumulates
#  18.  mcp_probe_all — open-circuit server skipped (no live probe)
#  19.  mcp_probe_all — no runtime → all skipped, returns 0
#  20.  mcp_probe_all — servers dir missing → all skipped, returns 0
#  21.  mcp_prelaunch_gate_with_circuit — all healthy → returns 0
#  22.  mcp_prelaunch_gate_with_circuit — open count <= max-open → returns 0
#  23.  mcp_prelaunch_gate_with_circuit — open count > max-open → returns 1
#  24.  breaker JSONL — record has required fields (ts, server, state, fail_count)
#  25.  breaker JSONL — records are valid JSON
#  26.  start-ashlrcode.sh sources mcp-health-probe.sh
#  27.  start-aider.sh sources mcp-health-probe.sh
#  28.  start-goose.sh sources mcp-health-probe.sh
#  29.  mcp_prelaunch_gate_with_circuit --max-open 0 always blocks
#  30.  double-source guard — sourcing twice is safe
#  31.  probe skips open-circuit server without spawning process
#  32.  circuit reset to closed after probe success
#  33.  malformed jsonrpc triggers fail + breaker increment
#  34.  half-open circuit allows probe to run
#  35.  breaker_evaluate — no open state until threshold reached
#  36.  mcp_probe_all populates MCP_PROBE_RESULTS with all 10 server tokens
#  37.  mcp_probe_all — mixed healthy/failed results appear in MCP_PROBE_RESULTS
#  38.  bash -n syntax check on the library
#
# Total: 38 tests (>= 18 required)
#
# Run:
#   bats tests/mcp-health-probe.bats
#   NO_COLOR=1 bats tests/mcp-health-probe.bats

# ─── Resolve repo root ────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
export REPO_ROOT LIB_DIR

# ─── setup / teardown ────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-hp-test-XXXXXX)"
  export TEST_TMPDIR

  export ASHLR_PLUGIN_DIR="${TEST_TMPDIR}/fake-plugin"
  mkdir -p "${ASHLR_PLUGIN_DIR}/servers"

  # Isolate the breaker store so tests never touch the real one.
  export MCP_BREAKER_STORE="${TEST_TMPDIR}/mcp-breaker.jsonl"

  # Fast timeouts for unit tests.
  export MCP_HEALTH_PROBE_TIMEOUT=2
  export MCP_HEALTH_PROBE_RETRIES=1
  export MCP_HEALTH_PROBE_BACKOFF_BASE=0
  export MCP_BREAKER_OPEN_THRESHOLD=3
  export MCP_BREAKER_HALF_OPEN_AFTER=60

  export NO_COLOR=1
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-hp-test-noop}" 2>/dev/null || true
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Minimal env block injected into every subshell.
_env_block() {
  cat <<ENVEOF
ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
MCP_BREAKER_STORE='${MCP_BREAKER_STORE}'
MCP_HEALTH_PROBE_TIMEOUT='${MCP_HEALTH_PROBE_TIMEOUT}'
MCP_HEALTH_PROBE_RETRIES='${MCP_HEALTH_PROBE_RETRIES}'
MCP_HEALTH_PROBE_BACKOFF_BASE='${MCP_HEALTH_PROBE_BACKOFF_BASE}'
MCP_BREAKER_OPEN_THRESHOLD='${MCP_BREAKER_OPEN_THRESHOLD}'
MCP_BREAKER_HALF_OPEN_AFTER='${MCP_BREAKER_HALF_OPEN_AFTER}'
NO_COLOR=1
export ASHLR_PLUGIN_DIR MCP_BREAKER_STORE MCP_HEALTH_PROBE_TIMEOUT MCP_HEALTH_PROBE_RETRIES
export MCP_HEALTH_PROBE_BACKOFF_BASE MCP_BREAKER_OPEN_THRESHOLD MCP_BREAKER_HALF_OPEN_AFTER NO_COLOR
ok()   { printf 'OK: %s\n'   "\$*"; }
warn() { printf 'WARN: %s\n' "\$*"; }
bad()  { printf 'BAD: %s\n'  "\$*"; }
info() { printf 'INFO: %s\n' "\$*"; }
export -f ok warn bad info 2>/dev/null || true
. '${LIB_DIR}/mcp-health-probe.sh'
ENVEOF
}

# Write a healthy MCP server stub (emits a valid jsonrpc result then exits).
_make_healthy_server() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env node
process.stdout.write(
  JSON.stringify({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"stub","version":"1.0"}}}) + "\n"
);
setTimeout(() => process.exit(0), 300);
EOF
  chmod +x "$path"
}

# Write a server stub that crashes immediately.
_make_crashing_server() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env node
process.stderr.write("fatal startup error\n");
process.exit(1);
EOF
  chmod +x "$path"
}

# Write a server stub that hangs silently (triggers timeout).
_make_hanging_server() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env node
const net = require("net");
const server = net.createServer();
server.listen(0, "127.0.0.1");
process.stdin.on("data", function() {});
EOF
  chmod +x "$path"
}

# Write a server stub that emits non-jsonrpc output (malformed).
_make_malformed_server() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env node
process.stdout.write("I am not JSON-RPC\n");
setTimeout(() => process.exit(0), 200);
EOF
  chmod +x "$path"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Library sourceable — no side-effects
# ─────────────────────────────────────────────────────────────────────────────

@test "1: mcp-health-probe.sh is sourceable without side-effects" {
  run bash -c "
    $(_env_block)
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced_ok"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Healthy server → rc=0
# ─────────────────────────────────────────────────────────────────────────────

@test "2: _mcp_hp_jsonrpc_ping_once returns rc=0 for a healthy stub" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${TEST_TMPDIR}/healthy.js"
  _make_healthy_server "$entry"

  run bash -c "
    $(_env_block)
    _mcp_hp_jsonrpc_ping_once '${entry}'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Missing entry file → rc=3
# ─────────────────────────────────────────────────────────────────────────────

@test "3: _mcp_hp_jsonrpc_ping_once returns rc=3 for missing entry file" {
  run bash -c "
    $(_env_block)
    _mcp_hp_jsonrpc_ping_once '${TEST_TMPDIR}/no-such-server.ts'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=3"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. No runtime → rc=4
# ─────────────────────────────────────────────────────────────────────────────

@test "4: _mcp_hp_jsonrpc_ping_once returns rc=4 when no runtime on PATH" {
  local entry="${TEST_TMPDIR}/fake-server.ts"
  printf 'const x = 1;\n' > "$entry"

  run bash -c "
    $(_env_block)
    export PATH=/usr/bin:/bin
    _mcp_hp_jsonrpc_ping_once '${entry}'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=4"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Server crash → rc=2
# ─────────────────────────────────────────────────────────────────────────────

@test "5: _mcp_hp_jsonrpc_ping_once returns rc=2 for a crashing server" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${TEST_TMPDIR}/crash.js"
  _make_crashing_server "$entry"

  run bash -c "
    $(_env_block)
    _mcp_hp_jsonrpc_ping_once '${entry}'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=2"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Hanging server → rc=1 (timeout)
# ─────────────────────────────────────────────────────────────────────────────

@test "6: _mcp_hp_jsonrpc_ping_once returns rc=1 for a hanging server (timeout)" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${TEST_TMPDIR}/hang.js"
  _make_hanging_server "$entry"

  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_TIMEOUT=1
    export MCP_HEALTH_PROBE_TIMEOUT
    _mcp_hp_jsonrpc_ping_once '${entry}'
    echo \"rc=\$?\"
  " --
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Malformed response → rc=5
# ─────────────────────────────────────────────────────────────────────────────

@test "7: _mcp_hp_jsonrpc_ping_once returns rc=5 for a malformed response" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${TEST_TMPDIR}/malformed.js"
  _make_malformed_server "$entry"

  run bash -c "
    $(_env_block)
    _mcp_hp_jsonrpc_ping_once '${entry}'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=5"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Probe with backoff — succeeds on second attempt
# ─────────────────────────────────────────────────────────────────────────────

@test "8: _mcp_hp_probe_with_backoff succeeds when server becomes healthy on retry" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"

  # First call will be to a crash server; we swap it to healthy mid-test by
  # writing the healthy stub into the same path after source.
  local entry="${TEST_TMPDIR}/retry-server.js"
  _make_crashing_server "$entry"

  # Use retries=2 so there are two attempts.
  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_RETRIES=2
    MCP_HEALTH_PROBE_BACKOFF_BASE=0
    export MCP_HEALTH_PROBE_RETRIES MCP_HEALTH_PROBE_BACKOFF_BASE
    # Replace the crashing server with a healthy one before the second attempt
    # by patching via a wrapper that succeeds on the second call.
    _call_count=0
    _mcp_hp_jsonrpc_ping_once() {
      _call_count=\$((_call_count + 1))
      if [ \"\$_call_count\" -eq 1 ]; then
        return 2  # simulate crash on first attempt
      fi
      return 0   # succeed on second attempt
    }
    _mcp_hp_probe_with_backoff 'retry-server' '${entry}'
    echo \"rc=\$? attempts=\$_call_count\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"attempts=2"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Probe with backoff — all retries exhausted → returns 1
# ─────────────────────────────────────────────────────────────────────────────

@test "9: _mcp_hp_probe_with_backoff returns 1 when all retries are exhausted" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${TEST_TMPDIR}/always-crash.js"
  _make_crashing_server "$entry"

  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_RETRIES=2
    MCP_HEALTH_PROBE_BACKOFF_BASE=0
    export MCP_HEALTH_PROBE_RETRIES MCP_HEALTH_PROBE_BACKOFF_BASE
    _mcp_hp_probe_with_backoff 'always-crash' '${entry}'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Circuit breaker — closed when no history
# ─────────────────────────────────────────────────────────────────────────────

@test "10: mcp_circuit_breaker_status returns 'closed' when no history exists" {
  run bash -c "
    $(_env_block)
    mcp_circuit_breaker_status 'new-server'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "closed" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. Circuit breaker — open after threshold failures
# ─────────────────────────────────────────────────────────────────────────────

@test "11: mcp_circuit_breaker_status returns 'open' after threshold failures" {
  run bash -c "
    $(_env_block)
    MCP_BREAKER_OPEN_THRESHOLD=3
    export MCP_BREAKER_OPEN_THRESHOLD
    # Write 3 failures directly into the store to simulate threshold breach.
    now=\$(date +%s)
    printf '{\"ts\":\"%s\",\"server\":\"bad-server\",\"state\":\"open\",\"fail_count\":3,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    mcp_circuit_breaker_status 'bad-server'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"open"* ]]
  [[ "$output" == *"rc=1"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. Circuit breaker — half-open after recovery window
# ─────────────────────────────────────────────────────────────────────────────

@test "12: mcp_circuit_breaker_status returns 'half-open' after recovery window" {
  run bash -c "
    $(_env_block)
    MCP_BREAKER_HALF_OPEN_AFTER=5
    export MCP_BREAKER_HALF_OPEN_AFTER
    # Write an open record with a last_fail_epoch far in the past.
    old_epoch=\$(( \$(date +%s) - 100 ))
    printf '{\"ts\":\"%s\",\"server\":\"slow-recover\",\"state\":\"open\",\"fail_count\":5,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$old_epoch\" >> '${MCP_BREAKER_STORE}'
    mcp_circuit_breaker_status 'slow-recover'
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"half-open"* ]]
  # half-open returns 0 (allow traffic)
  [[ "$output" == *"rc=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 13. Circuit breaker — re-closed after success
# ─────────────────────────────────────────────────────────────────────────────

@test "13: mcp_circuit_breaker_status returns 'closed' after a success resets the breaker" {
  run bash -c "
    $(_env_block)
    # Simulate prior open state.
    now=\$(date +%s)
    printf '{\"ts\":\"%s\",\"server\":\"flaky\",\"state\":\"open\",\"fail_count\":5,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    # Now evaluate a success — should write closed record.
    _mcp_hp_breaker_evaluate 'flaky' 0
    mcp_circuit_breaker_status 'flaky'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. Breaker store isolation — distinct servers track independently
# ─────────────────────────────────────────────────────────────────────────────

@test "14: circuit breaker tracks distinct servers independently" {
  run bash -c "
    $(_env_block)
    now=\$(date +%s)
    # Mark 'server-a' open.
    printf '{\"ts\":\"%s\",\"server\":\"server-a\",\"state\":\"open\",\"fail_count\":3,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    # server-b has no history → should be closed.
    state_a=\"\$(mcp_circuit_breaker_status 'server-a')\"
    state_b=\"\$(mcp_circuit_breaker_status 'server-b')\"
    printf 'a=%s b=%s\n' \"\$state_a\" \"\$state_b\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"a=open"* ]]
  [[ "$output" == *"b=closed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 15. mcp_probe_all — all healthy → returns 0, open count = 0
# ─────────────────────────────────────────────────────────────────────────────

@test "15: mcp_probe_all returns 0 and MCP_PROBE_OPEN_COUNT=0 when all probed servers are healthy" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"

  # Create healthy stubs for all 10 servers.
  for name in efficiency sql bash tree http diff logs genome orient github; do
    _make_healthy_server "${ASHLR_PLUGIN_DIR}/servers/${name}-server.ts"
  done

  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_TIMEOUT=3
    export MCP_HEALTH_PROBE_TIMEOUT
    mcp_probe_all
    echo \"rc=\$? open=\$MCP_PROBE_OPEN_COUNT\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"open=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 16. mcp_probe_all — one server down → MCP_PROBE_RESULTS contains :failed
# ─────────────────────────────────────────────────────────────────────────────

@test "16: mcp_probe_all records 'failed' status for a crashing server" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"

  # All healthy except 'bash'.
  for name in efficiency sql tree http diff logs genome orient github; do
    _make_healthy_server "${ASHLR_PLUGIN_DIR}/servers/${name}-server.ts"
  done
  _make_crashing_server "${ASHLR_PLUGIN_DIR}/servers/bash-server.ts"

  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_TIMEOUT=3
    export MCP_HEALTH_PROBE_TIMEOUT
    mcp_probe_all || true
    echo \"results=\$MCP_PROBE_RESULTS\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash:failed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 17. mcp_probe_all — cascading failures → open count accumulates
# ─────────────────────────────────────────────────────────────────────────────

@test "17: mcp_probe_all open count accumulates for pre-opened circuits" {
  run bash -c "
    $(_env_block)
    now=\$(date +%s)
    # Pre-open 4 circuits in the store.
    for srv in sql bash tree http; do
      printf '{\"ts\":\"%s\",\"server\":\"%s\",\"state\":\"open\",\"fail_count\":5,\"last_fail_epoch\":%d}\n' \
        \"\$(_mcp_hp_ts)\" \"\$srv\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    done
    mcp_probe_all || true
    echo \"open=\$MCP_PROBE_OPEN_COUNT\"
  "
  [ "$status" -eq 0 ]
  # At least 4 open-circuit servers should be counted (the pre-opened ones).
  local open_count
  open_count="$(printf '%s' "$output" | grep -o 'open=[0-9]*' | grep -o '[0-9]*')"
  [ "${open_count:-0}" -ge 4 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 18. mcp_probe_all — open-circuit server is skipped (no live probe attempt)
# ─────────────────────────────────────────────────────────────────────────────

@test "18: mcp_probe_all skips the live probe for open-circuit servers" {
  run bash -c "
    $(_env_block)
    now=\$(date +%s)
    # Pre-open 'genome'.
    printf '{\"ts\":\"%s\",\"server\":\"genome\",\"state\":\"open\",\"fail_count\":3,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    mcp_probe_all || true
    echo \"results=\$MCP_PROBE_RESULTS\"
  "
  [ "$status" -eq 0 ]
  # The result for 'genome' should be ':open' not ':failed'
  [[ "$output" == *"genome:open"* ]]
  [[ "$output" != *"genome:failed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 19. mcp_probe_all — no runtime → all skipped, returns 0
# ─────────────────────────────────────────────────────────────────────────────

@test "19: mcp_probe_all skips all probes and returns 0 when no runtime is available" {
  run bash -c "
    $(_env_block)
    export PATH=/usr/bin:/bin
    mcp_probe_all
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"no runtime"* ]]
  [[ "$output" == *"rc=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 20. mcp_probe_all — servers dir missing → all skipped, returns 0
# ─────────────────────────────────────────────────────────────────────────────

@test "20: mcp_probe_all skips all probes and returns 0 when servers/ dir is absent" {
  run bash -c "
    ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-such-plugin'
    MCP_BREAKER_STORE='${MCP_BREAKER_STORE}'
    MCP_HEALTH_PROBE_TIMEOUT=1
    NO_COLOR=1
    export ASHLR_PLUGIN_DIR MCP_BREAKER_STORE MCP_HEALTH_PROBE_TIMEOUT NO_COLOR
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    info() { printf 'INFO: %s\n' \"\$*\"; }
    export -f ok warn bad info 2>/dev/null || true
    . '${LIB_DIR}/mcp-health-probe.sh'
    mcp_probe_all
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"servers/"* ]]
  [[ "$output" == *"rc=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 21. mcp_prelaunch_gate_with_circuit — all healthy → returns 0
# ─────────────────────────────────────────────────────────────────────────────

@test "21: mcp_prelaunch_gate_with_circuit returns 0 when no servers are open-circuit" {
  run bash -c "
    $(_env_block)
    # Override mcp_probe_all to simulate all servers healthy.
    mcp_probe_all() {
      MCP_PROBE_OPEN_COUNT=0
      MCP_PROBE_RESULTS='efficiency:healthy sql:healthy bash:healthy tree:healthy http:healthy diff:healthy logs:healthy genome:healthy orient:healthy github:healthy'
      return 0
    }
    mcp_prelaunch_gate_with_circuit
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 22. mcp_prelaunch_gate_with_circuit — open count <= max-open → returns 0
# ─────────────────────────────────────────────────────────────────────────────

@test "22: mcp_prelaunch_gate_with_circuit returns 0 when open count is within threshold" {
  run bash -c "
    $(_env_block)
    mcp_probe_all() {
      MCP_PROBE_OPEN_COUNT=2
      MCP_PROBE_RESULTS='sql:open bash:open tree:healthy'
      return 1
    }
    mcp_prelaunch_gate_with_circuit --max-open 3
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 23. mcp_prelaunch_gate_with_circuit — open count > max-open → returns 1
# ─────────────────────────────────────────────────────────────────────────────

@test "23: mcp_prelaunch_gate_with_circuit returns 1 when open count exceeds threshold" {
  run bash -c "
    $(_env_block)
    mcp_probe_all() {
      MCP_PROBE_OPEN_COUNT=4
      MCP_PROBE_RESULTS='sql:open bash:open tree:open http:open efficiency:healthy'
      return 1
    }
    mcp_prelaunch_gate_with_circuit --max-open 3
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 24. Breaker JSONL — record has required fields
# ─────────────────────────────────────────────────────────────────────────────

@test "24: breaker store records contain ts, server, state, fail_count, last_fail_epoch" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"

  bash -c "
    $(_env_block)
    _mcp_hp_breaker_write 'test-server' 'closed' 0 0
  "

  [ -f "$MCP_BREAKER_STORE" ]
  run python3 -c "
import json, sys
records = [json.loads(l) for l in open('${MCP_BREAKER_STORE}') if l.strip()]
assert len(records) >= 1, 'no records'
r = records[-1]
for field in ['ts', 'server', 'state', 'fail_count', 'last_fail_epoch']:
    assert field in r, 'missing field: %s' % field
print('fields_ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fields_ok"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 25. Breaker JSONL — records are valid JSON
# ─────────────────────────────────────────────────────────────────────────────

@test "25: breaker store records are valid JSON" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not on PATH"

  bash -c "
    $(_env_block)
    _mcp_hp_breaker_write 'srv-a' 'open'   3 1000
    _mcp_hp_breaker_write 'srv-b' 'closed' 0 0
    _mcp_hp_breaker_write 'srv-c' 'open'   5 2000
  "

  run python3 -c "
import json
bad = 0
for line in open('${MCP_BREAKER_STORE}'):
    line = line.strip()
    if not line: continue
    try:
        json.loads(line)
    except Exception as e:
        bad += 1
        print('invalid:', line[:80])
print('bad=%d' % bad)
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bad=0"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 26. start-ashlrcode.sh sources mcp-health-probe.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "26: start-ashlrcode.sh sources mcp-health-probe.sh" {
  run grep -c 'mcp-health-probe.sh' "${REPO_ROOT}/scripts/start-ashlrcode.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 27. start-aider.sh sources mcp-health-probe.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "27: start-aider.sh sources mcp-health-probe.sh" {
  run grep -c 'mcp-health-probe.sh' "${REPO_ROOT}/scripts/start-aider.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 28. start-goose.sh sources mcp-health-probe.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "28: start-goose.sh sources mcp-health-probe.sh" {
  run grep -c 'mcp-health-probe.sh' "${REPO_ROOT}/scripts/start-goose.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 29. mcp_prelaunch_gate_with_circuit --max-open 0 always blocks when any open
# ─────────────────────────────────────────────────────────────────────────────

@test "29: mcp_prelaunch_gate_with_circuit --max-open 0 returns 1 if any server is open" {
  run bash -c "
    $(_env_block)
    mcp_probe_all() {
      MCP_PROBE_OPEN_COUNT=1
      MCP_PROBE_RESULTS='bash:open sql:healthy'
      return 1
    }
    mcp_prelaunch_gate_with_circuit --max-open 0
    echo \"rc=\$?\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 30. Double-source guard — sourcing twice is safe
# ─────────────────────────────────────────────────────────────────────────────

@test "30: sourcing mcp-health-probe.sh twice does not cause errors" {
  run bash -c "
    $(_env_block)
    unset _ASHLR_MCP_HEALTH_PROBE_SOURCED
    . '${LIB_DIR}/mcp-health-probe.sh'
    . '${LIB_DIR}/mcp-health-probe.sh'
    echo 'double_source_ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"double_source_ok"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 31. Open-circuit server is skipped without spawning a process
# ─────────────────────────────────────────────────────────────────────────────

@test "31: open-circuit server skips probe and records :open status" {
  run bash -c "
    $(_env_block)
    now=\$(date +%s)
    printf '{\"ts\":\"%s\",\"server\":\"orient\",\"state\":\"open\",\"fail_count\":3,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    mcp_probe_all || true
    echo \"results=\$MCP_PROBE_RESULTS\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"orient:open"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 32. Circuit resets to closed after probe success
# ─────────────────────────────────────────────────────────────────────────────

@test "32: _mcp_hp_breaker_evaluate resets to closed on rc=0 from any prior state" {
  run bash -c "
    $(_env_block)
    now=\$(date +%s)
    # Write an open record.
    printf '{\"ts\":\"%s\",\"server\":\"recovering\",\"state\":\"open\",\"fail_count\":4,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$now\" >> '${MCP_BREAKER_STORE}'
    # Evaluate a success.
    _mcp_hp_breaker_evaluate 'recovering' 0
    echo \"new_state=\$_MCP_CB_NEW_STATE\"
    # Confirm the written state is 'closed'.
    mcp_circuit_breaker_status 'recovering'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"new_state=closed"* ]]
  [[ "$output" == *"closed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 33. Malformed jsonrpc triggers fail + breaker increment
# ─────────────────────────────────────────────────────────────────────────────

@test "33: malformed jsonrpc response is treated as failure and increments breaker" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${TEST_TMPDIR}/malf.js"
  _make_malformed_server "$entry"

  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_RETRIES=1
    export MCP_HEALTH_PROBE_RETRIES
    _mcp_hp_probe_with_backoff 'malf-server' '${entry}'
    probe_rc=\$?
    _mcp_hp_breaker_evaluate 'malf-server' \"\$probe_rc\"
    # Read back the fail count.
    _mcp_hp_breaker_read 'malf-server'
    echo \"fail_count=\$_MCP_CB_FAIL_COUNT\"
  "
  [ "$status" -eq 0 ]
  # fail_count should be >= 1 after the malformed probe.
  local fc
  fc="$(printf '%s' "$output" | grep -o 'fail_count=[0-9]*' | grep -o '[0-9]*')"
  [ "${fc:-0}" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 34. Half-open circuit allows probe to run (not skipped like open)
# ─────────────────────────────────────────────────────────────────────────────

@test "34: half-open circuit allows the live probe to execute" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"
  local entry="${ASHLR_PLUGIN_DIR}/servers/sql-server.ts"
  _make_healthy_server "$entry"

  run bash -c "
    $(_env_block)
    MCP_BREAKER_HALF_OPEN_AFTER=5
    export MCP_BREAKER_HALF_OPEN_AFTER
    # Write an old open record so the circuit is in half-open state.
    old_epoch=\$(( \$(date +%s) - 100 ))
    printf '{\"ts\":\"%s\",\"server\":\"sql\",\"state\":\"open\",\"fail_count\":3,\"last_fail_epoch\":%d}\n' \
      \"\$(_mcp_hp_ts)\" \"\$old_epoch\" >> '${MCP_BREAKER_STORE}'
    MCP_HEALTH_PROBE_TIMEOUT=3
    export MCP_HEALTH_PROBE_TIMEOUT
    mcp_probe_all || true
    echo \"results=\$MCP_PROBE_RESULTS\"
  "
  [ "$status" -eq 0 ]
  # sql should appear as :healthy (probe ran and succeeded) not :open (skipped)
  [[ "$output" == *"sql:healthy"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 35. breaker_evaluate — circuit stays closed until threshold reached
# ─────────────────────────────────────────────────────────────────────────────

@test "35: _mcp_hp_breaker_evaluate keeps circuit closed until open_threshold failures" {
  run bash -c "
    $(_env_block)
    MCP_BREAKER_OPEN_THRESHOLD=3
    export MCP_BREAKER_OPEN_THRESHOLD
    # Two failures — should NOT open the circuit yet.
    _mcp_hp_breaker_evaluate 'almost-open' 2
    _mcp_hp_breaker_evaluate 'almost-open' 2
    state=\$(mcp_circuit_breaker_status 'almost-open')
    echo \"state=\$state\"
    # Third failure — should open the circuit.
    _mcp_hp_breaker_evaluate 'almost-open' 2
    state2=\$(mcp_circuit_breaker_status 'almost-open')
    echo \"state2=\$state2\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"state=closed"* ]]
  [[ "$output" == *"state2=open"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 36. mcp_probe_all populates MCP_PROBE_RESULTS with all 10 server tokens
# ─────────────────────────────────────────────────────────────────────────────

@test "36: mcp_probe_all populates MCP_PROBE_RESULTS with tokens for all 10 servers" {
  run bash -c "
    $(_env_block)
    # No servers dir — all will be skipped, but all 10 tokens still appear.
    ASHLR_PLUGIN_DIR='${TEST_TMPDIR}/no-plugin'
    export ASHLR_PLUGIN_DIR
    mcp_probe_all || true
    echo \"results=\$MCP_PROBE_RESULTS\"
  "
  [ "$status" -eq 0 ]
  local results
  results="$(printf '%s' "$output" | grep 'results=' | sed 's/results=//')"
  for name in efficiency sql bash tree http diff logs genome orient github; do
    [[ "$results" == *"${name}:"* ]]
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 37. mcp_probe_all — mixed healthy/failed results appear in MCP_PROBE_RESULTS
# ─────────────────────────────────────────────────────────────────────────────

@test "37: mcp_probe_all MCP_PROBE_RESULTS contains both healthy and failed tokens" {
  command -v node >/dev/null 2>&1 || skip "node not on PATH"

  # All healthy except 'logs' (crash) and 'orient' (missing file).
  for name in efficiency sql bash tree http diff genome github; do
    _make_healthy_server "${ASHLR_PLUGIN_DIR}/servers/${name}-server.ts"
  done
  _make_crashing_server "${ASHLR_PLUGIN_DIR}/servers/logs-server.ts"
  # orient-server.ts intentionally absent.

  run bash -c "
    $(_env_block)
    MCP_HEALTH_PROBE_TIMEOUT=3
    export MCP_HEALTH_PROBE_TIMEOUT
    mcp_probe_all || true
    echo \"results=\$MCP_PROBE_RESULTS\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs:failed"* ]]
  [[ "$output" == *"orient:failed"* ]]
  [[ "$output" == *"bash:healthy"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 38. bash -n syntax check on the library
# ─────────────────────────────────────────────────────────────────────────────

@test "38: mcp-health-probe.sh passes bash -n syntax check" {
  run bash -n "${LIB_DIR}/mcp-health-probe.sh"
  [ "$status" -eq 0 ]
}
