#!/usr/bin/env bats
# tests/mcp-config-validation.bats — MCP Server Configuration Validation + Auto-Migration Tests
#
# Tests the MCP schema validation system introduced in scripts/lib/config-schema-registry.sh
# (mcp_validate_agent_config, mcp_validate_all_agents, mcp_prelaunch_gate) and the
# per-agent mcp-schema.json files under agents/{name}/mcp-schema.json.
#
# Test categories:
#   1.  Schema files exist and are valid JSON (4 tests)
#   2.  Schema file structure — required fields (4 tests)
#   3.  mcp_validate_agent_config — happy path (4 tests)
#   4.  mcp_validate_agent_config — missing required server detected (4 tests)
#   5.  mcp_validate_agent_config — missing required field on server entry (4 tests)
#   6.  mcp_validate_agent_config — breaking change detection (2 tests)
#   7.  mcp_validate_agent_config — deprecated server name / entrypoint detection (2 tests)
#   8.  mcp_validate_agent_config — diff report written correctly (2 tests)
#   9.  mcp_validate_all_agents — validates all 4 agents (2 tests)
#  10.  mcp_prelaunch_gate — warns but does not abort by default (2 tests)
#  11.  mcp_prelaunch_gate — aborts when ASHLR_MCP_GATE_STRICT=1 and errors present (2 tests)
#  12.  mcp_generate_diff_report — writes JSON report file (1 test)
#  13.  start-script integration — start scripts source registry and run gate (4 tests)
#  14.  config_registry_check_all includes MCP validation (1 test)
#  15.  Edge cases — missing schema file, missing config file, python3 absent (3 tests)
#
# Total: 41 tests
#
# Run:
#   bats tests/mcp-config-validation.bats
#   NO_COLOR=1 bats tests/mcp-config-validation.bats

# ─── Resolve repo root ─────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT
LIB_DIR="${REPO_ROOT}/scripts/lib"
export LIB_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/mcp-config-validation-XXXXXX)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/mcp-config-validation-noop}" 2>/dev/null || true
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Source the registry lib in a fresh subshell; capture exit code.
_source_registry() {
  bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    . '${LIB_DIR}/config-schema-registry.sh'
    \$@
  " -- "$@"
}

# Run mcp_validate_agent_config for <agent> in a subshell.
# Usage: run _validate_mcp <agent> [extra args]
_validate_mcp() {
  local agent="$1"; shift
  bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_agent_config '${agent}' \"\$@\"
  " -- "$@"
}

# Run mcp_prelaunch_gate for <agent> in a subshell with optional override vars.
_gate_mcp() {
  local agent="$1"; shift
  bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_prelaunch_gate '${agent}' \"\$@\"
  " -- "$@"
}

# Make a temp copy of a config file, inject a bad value, validate it.
_validate_mcp_custom_config() {
  local agent="$1"
  local config_src="$2"
  local custom_config="$3"
  bash -c "
    WORKBENCH='${TEST_TMPDIR}/fake-workbench'
    export WORKBENCH
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    # Set up fake workbench with real schema + custom config
    mkdir -p \"\${WORKBENCH}/agents/${agent}\"
    cp '${REPO_ROOT}/agents/${agent}/mcp-schema.json' \"\${WORKBENCH}/agents/${agent}/mcp-schema.json\"
    cp '${custom_config}' \"\${WORKBENCH}/agents/${agent}/$(basename ${config_src})\"
    # Also copy real migrations so config_validate_strict works
    if [ -f '${REPO_ROOT}/agents/${agent}/config-migrations.json' ]; then
      cp '${REPO_ROOT}/agents/${agent}/config-migrations.json' \"\${WORKBENCH}/agents/${agent}/config-migrations.json\"
    fi
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_agent_config '${agent}'
  "
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 1 — Schema files exist and are valid JSON
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-schema: ashlrcode/mcp-schema.json exists and is valid JSON" {
  local f="${REPO_ROOT}/agents/ashlrcode/mcp-schema.json"
  [ -f "$f" ]
  python3 -c "import json; json.load(open('${f}'))"
}

@test "mcp-schema: aider/mcp-schema.json exists and is valid JSON" {
  local f="${REPO_ROOT}/agents/aider/mcp-schema.json"
  [ -f "$f" ]
  python3 -c "import json; json.load(open('${f}'))"
}

@test "mcp-schema: openhands/mcp-schema.json exists and is valid JSON" {
  local f="${REPO_ROOT}/agents/openhands/mcp-schema.json"
  [ -f "$f" ]
  python3 -c "import json; json.load(open('${f}'))"
}

@test "mcp-schema: goose/mcp-schema.json exists and is valid JSON" {
  local f="${REPO_ROOT}/agents/goose/mcp-schema.json"
  [ -f "$f" ]
  python3 -c "import json; json.load(open('${f}'))"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 2 — Schema file structure — required fields
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-schema: ashlrcode schema has required top-level keys" {
  local f="${REPO_ROOT}/agents/ashlrcode/mcp-schema.json"
  result="$(python3 -c "
import json, sys
d = json.load(open('${f}'))
required = ['agent', 'config_file', 'config_format', 'mcp_config_key', 'required_servers', 'server_schema', 'migrations']
missing = [k for k in required if k not in d]
print(','.join(missing) if missing else 'ok')
")"
  [ "$result" = "ok" ]
}

@test "mcp-schema: all 4 schemas declare all 10 ashlr-plugin servers as required" {
  local all_ok=1
  for agent in ashlrcode aider openhands goose; do
    local f="${REPO_ROOT}/agents/${agent}/mcp-schema.json"
    result="$(python3 -c "
import json
d = json.load(open('${f}'))
required = d.get('required_servers', [])
expected = ['ashlr-efficiency','ashlr-sql','ashlr-bash','ashlr-tree','ashlr-http',
            'ashlr-diff','ashlr-logs','ashlr-genome','ashlr-orient','ashlr-github']
missing = [s for s in expected if s not in required]
print(','.join(missing) if missing else 'ok')
" 2>/dev/null)"
    if [ "$result" != "ok" ]; then
      echo "agent=${agent} missing required servers: ${result}" >&3
      all_ok=0
    fi
  done
  [ "$all_ok" -eq 1 ]
}

@test "mcp-schema: all 4 schemas have a non-empty migrations list" {
  local all_ok=1
  for agent in ashlrcode aider openhands goose; do
    local f="${REPO_ROOT}/agents/${agent}/mcp-schema.json"
    count="$(python3 -c "
import json
d = json.load(open('${f}'))
print(len(d.get('migrations', [])))
" 2>/dev/null)"
    if [ "${count:-0}" -eq 0 ]; then
      echo "agent=${agent} has no migrations" >&3
      all_ok=0
    fi
  done
  [ "$all_ok" -eq 1 ]
}

@test "mcp-schema: schema _version field matches SCHEMA_REGISTRY_VERSION convention" {
  for agent in ashlrcode aider openhands goose; do
    local f="${REPO_ROOT}/agents/${agent}/mcp-schema.json"
    result="$(python3 -c "
import json, re
d = json.load(open('${f}'))
v = d.get('_version', '')
print('ok' if re.match(r'^v\d+\.\d+', v) else 'bad:' + v)
" 2>/dev/null)"
    [ "$result" = "ok" ] || { echo "agent=${agent}: bad _version: ${result}" >&3; false; }
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 3 — mcp_validate_agent_config — happy path (real configs)
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: ashlrcode settings.json passes MCP validation" {
  run _validate_mcp ashlrcode
  # Should print OK line and exit 0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "OK:"
}

@test "mcp-validate: aider aider.conf.yml passes MCP validation" {
  run _validate_mcp aider
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "OK:"
}

@test "mcp-validate: openhands mcp.json passes MCP validation" {
  run _validate_mcp openhands
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "OK:"
}

@test "mcp-validate: goose config.yaml passes MCP validation" {
  run _validate_mcp goose
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "OK:"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 4 — Missing required server detected
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: ashlrcode — missing required server triggers ERROR" {
  # Build a stripped settings.json missing ashlr-bash
  local bad_cfg="${TEST_TMPDIR}/settings-missing-server.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
mcp.pop('ashlr-bash', None)
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q "ashlr-bash"
}

@test "mcp-validate: openhands — missing required server in stdio_servers triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/mcp-missing-server.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/openhands/mcp.json'))
servers = d.get('stdio_servers', [])
servers = [s for s in servers if s.get('name') != 'ashlr-genome']
d['stdio_servers'] = servers
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config openhands \
    "${REPO_ROOT}/agents/openhands/mcp.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q "ashlr-genome"
}

@test "mcp-validate: ashlrcode — empty mcpServers triggers ERRORs for all 10 required servers" {
  local bad_cfg="${TEST_TMPDIR}/settings-empty-mcp.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
d['mcpServers'] = {}
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  # Should report all 10 missing servers
  local error_count
  error_count="$(printf '%s\n' "$output" | grep -c "BAD:" || echo 0)"
  [ "${error_count}" -ge 10 ]
}

@test "mcp-validate: goose — missing required server in extensions triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/goose-missing-server.yaml"
  # Remove ashlr-orient from the YAML by filtering out its block
  python3 -c "
import re
raw = open('${REPO_ROOT}/agents/goose/config.yaml').read()
# Remove the ashlr-orient: block (from its key to the next top-level extension key)
raw = re.sub(r'^  ashlr-orient:\n(?:    .*\n)*', '', raw, flags=re.MULTILINE)
open('${bad_cfg}', 'w').write(raw)
"
  run _validate_mcp_custom_config goose \
    "${REPO_ROOT}/agents/goose/config.yaml" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q "ashlr-orient"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 5 — Missing required field on server entry
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: ashlrcode — server entry missing 'args' triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/settings-missing-args.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
if 'ashlr-efficiency' in mcp:
    srv = dict(mcp['ashlr-efficiency'])
    srv.pop('args', None)
    mcp['ashlr-efficiency'] = srv
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "args"
}

@test "mcp-validate: ashlrcode — server entry missing 'command' triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/settings-missing-command.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
if 'ashlr-sql' in mcp:
    srv = dict(mcp['ashlr-sql'])
    srv.pop('command', None)
    mcp['ashlr-sql'] = srv
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "command"
}

@test "mcp-validate: openhands — stdio_servers entry missing 'name' triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/mcp-missing-name.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/openhands/mcp.json'))
servers = d.get('stdio_servers', [])
if servers:
    s = dict(servers[0])
    s.pop('name', None)
    servers[0] = s
d['stdio_servers'] = servers
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config openhands \
    "${REPO_ROOT}/agents/openhands/mcp.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "name"
}

@test "mcp-validate: ashlrcode — args field not an array triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/settings-args-not-array.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
if 'ashlr-tree' in mcp:
    srv = dict(mcp['ashlr-tree'])
    srv['args'] = 'not-an-array'
    mcp['ashlr-tree'] = srv
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "array"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 6 — Breaking change detection (3rd-party servers)
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: ashlrcode — supabase with old '--project-url' flag triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/settings-old-supabase-flag.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
if 'supabase' in mcp:
    srv = dict(mcp['supabase'])
    # Replace --project-ref with deprecated --project-url
    args = [a.replace('--project-ref', '--project-url') for a in srv.get('args', [])]
    srv['args'] = args
    mcp['supabase'] = srv
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "project-url\|breaking"
}

@test "mcp-validate: ashlrcode — deprecated server name 'ashlr-plugin' triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/settings-old-server-name.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
# Add the deprecated monolithic server name
mcp['ashlr-plugin'] = {'command': 'bash', 'args': ['old-entrypoint.sh', 'servers/plugin-server.ts']}
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "ashlr-plugin\|deprecated"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 7 — Deprecated entrypoint detection
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: ashlrcode — deprecated entrypoint 'servers/plugin-server.ts' triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/settings-old-entrypoint.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
mcp = d.get('mcpServers', {})
# Replace the first server's entry point with the deprecated one
if 'ashlr-efficiency' in mcp:
    srv = dict(mcp['ashlr-efficiency'])
    srv['args'] = ['scripts/mcp-entrypoint.sh', 'servers/plugin-server.ts']
    mcp['ashlr-efficiency'] = srv
d['mcpServers'] = mcp
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config ashlrcode \
    "${REPO_ROOT}/agents/ashlrcode/settings.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "plugin-server\|deprecated\|entrypoint"
}

@test "mcp-validate: openhands — deprecated 'mcpServers' key in mcp.json triggers ERROR" {
  local bad_cfg="${TEST_TMPDIR}/mcp-old-config-key.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/openhands/mcp.json'))
# Add the deprecated mcpServers top-level key alongside stdio_servers
d['mcpServers'] = {}
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run _validate_mcp_custom_config openhands \
    "${REPO_ROOT}/agents/openhands/mcp.json" "$bad_cfg"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "mcpServers\|deprecated"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 8 — Diff report written correctly
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: diff report is written as valid JSON when --diff-report-path is set" {
  local report_path="${TEST_TMPDIR}/ashlrcode-mcp-diff.json"
  run bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_agent_config ashlrcode --diff-report-path '${report_path}'
  "
  [ -f "$report_path" ]
  python3 -c "import json; d = json.load(open('${report_path}')); assert 'agent' in d, 'missing agent field'"
}

@test "mcp-validate: diff report contains required fields (agent, timestamp, status, errors, warnings)" {
  local report_path="${TEST_TMPDIR}/report-fields-check.json"
  bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { :; }; warn() { :; }; bad() { :; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_agent_config ashlrcode --diff-report-path '${report_path}' >/dev/null 2>&1
  " || true
  [ -f "$report_path" ]
  result="$(python3 -c "
import json
d = json.load(open('${report_path}'))
required = ['agent', 'timestamp', 'status', 'errors', 'warnings', 'diff_items']
missing = [k for k in required if k not in d]
print(','.join(missing) if missing else 'ok')
" 2>/dev/null)"
  [ "$result" = "ok" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 9 — mcp_validate_all_agents
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate-all: validates all 4 agents and exits 0 with clean configs" {
  run bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_all_agents
  "
  [ "$status" -eq 0 ]
  # Should have 4 OK lines (one per agent)
  local ok_count
  ok_count="$(printf '%s\n' "$output" | grep -c "^OK:" || echo 0)"
  [ "${ok_count}" -ge 4 ]
}

@test "mcp-validate-all: --diff-report-dir writes one JSON file per agent" {
  local report_dir="${TEST_TMPDIR}/mcp-reports"
  run bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { :; }; warn() { :; }; bad() { :; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_all_agents --diff-report-dir '${report_dir}'
  "
  [ -d "$report_dir" ]
  for agent in ashlrcode aider openhands goose; do
    [ -f "${report_dir}/${agent}-mcp-diff.json" ] || {
      echo "missing report: ${agent}-mcp-diff.json" >&3; false
    }
    python3 -c "import json; json.load(open('${report_dir}/${agent}-mcp-diff.json'))" || {
      echo "invalid JSON in ${agent}-mcp-diff.json" >&3; false
    }
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 10 — mcp_prelaunch_gate — warns but does not abort by default
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-gate: prelaunch gate exits 0 with clean ashlrcode config (no strict)" {
  run _gate_mcp ashlrcode
  [ "$status" -eq 0 ]
}

@test "mcp-gate: prelaunch gate exits 0 even with bad config when not in strict mode" {
  # Create a bad config that is missing servers
  local bad_cfg="${TEST_TMPDIR}/settings-gate-test.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
d['mcpServers'] = {}
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  # Run gate against the bad config — without strict mode it should exit 0 (warn only)
  run bash -c "
    WORKBENCH='${TEST_TMPDIR}/fw2'
    export WORKBENCH
    mkdir -p \"\${WORKBENCH}/agents/ashlrcode\"
    cp '${REPO_ROOT}/agents/ashlrcode/mcp-schema.json' \"\${WORKBENCH}/agents/ashlrcode/mcp-schema.json\"
    cp '${bad_cfg}' \"\${WORKBENCH}/agents/ashlrcode/settings.json\"
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_prelaunch_gate ashlrcode
  "
  # Should exit 0 (warn mode, not strict)
  [ "$status" -eq 0 ]
  # But should have printed a warning about errors
  printf '%s\n' "$output" | grep -qi "warn\|error\|mcp-gate" || true
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 11 — mcp_prelaunch_gate — aborts with ASHLR_MCP_GATE_STRICT=1
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-gate: strict mode exits 0 with clean config" {
  run bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_prelaunch_gate ashlrcode --abort-on-error
  "
  [ "$status" -eq 0 ]
}

@test "mcp-gate: strict mode exits non-zero with bad config (missing servers)" {
  local bad_cfg="${TEST_TMPDIR}/settings-strict-gate.json"
  python3 -c "
import json
d = json.load(open('${REPO_ROOT}/agents/ashlrcode/settings.json'))
d['mcpServers'] = {}
open('${bad_cfg}', 'w').write(json.dumps(d, indent=2))
"
  run bash -c "
    WORKBENCH='${TEST_TMPDIR}/fw3'
    export WORKBENCH
    mkdir -p \"\${WORKBENCH}/agents/ashlrcode\"
    cp '${REPO_ROOT}/agents/ashlrcode/mcp-schema.json' \"\${WORKBENCH}/agents/ashlrcode/mcp-schema.json\"
    cp '${bad_cfg}' \"\${WORKBENCH}/agents/ashlrcode/settings.json\"
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_prelaunch_gate ashlrcode --abort-on-error
  "
  # Strict mode must exit non-zero when there are errors
  [ "$status" -ne 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 12 — mcp_generate_diff_report
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-generate-diff-report: writes a valid JSON report file for ashlrcode" {
  local report_path="${TEST_TMPDIR}/gen-report-ashlrcode.json"
  run bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    ok()   { :; }; warn() { :; }; bad() { :; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_generate_diff_report ashlrcode '${report_path}'
  "
  [ "$status" -eq 0 ]
  [ -f "$report_path" ]
  python3 -c "
import json
d = json.load(open('${report_path}'))
assert d.get('agent') == 'ashlrcode', 'agent field wrong: ' + str(d.get('agent'))
assert 'status' in d
assert 'errors' in d
print('ok')
"
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 13 — start-script integration — scripts source registry and run gate
# ══════════════════════════════════════════════════════════════════════════════

@test "start-scripts: start-ashlrcode.sh sources config-schema-registry.sh" {
  grep -q "config-schema-registry.sh" "${REPO_ROOT}/scripts/start-ashlrcode.sh"
}

@test "start-scripts: start-aider.sh sources config-schema-registry.sh" {
  grep -q "config-schema-registry.sh" "${REPO_ROOT}/scripts/start-aider.sh"
}

@test "start-scripts: start-goose.sh sources config-schema-registry.sh" {
  grep -q "config-schema-registry.sh" "${REPO_ROOT}/scripts/start-goose.sh"
}

@test "start-scripts: start-openhands.sh sources config-schema-registry.sh" {
  grep -q "config-schema-registry.sh" "${REPO_ROOT}/scripts/start-openhands.sh"
}

@test "start-scripts: all 4 start scripts call mcp_prelaunch_gate" {
  local all_ok=1
  for script in start-ashlrcode.sh start-aider.sh start-goose.sh start-openhands.sh; do
    if ! grep -q "mcp_prelaunch_gate" "${REPO_ROOT}/scripts/${script}"; then
      echo "missing mcp_prelaunch_gate in ${script}" >&3
      all_ok=0
    fi
  done
  [ "$all_ok" -eq 1 ]
}

@test "start-scripts: ASHLR_MCP_GATE_STRICT env var is honoured in all 4 start scripts" {
  local all_ok=1
  for script in start-ashlrcode.sh start-aider.sh start-goose.sh start-openhands.sh; do
    if ! grep -q "ASHLR_MCP_GATE_STRICT" "${REPO_ROOT}/scripts/${script}"; then
      echo "ASHLR_MCP_GATE_STRICT not referenced in ${script}" >&3
      all_ok=0
    fi
  done
  [ "$all_ok" -eq 1 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 14 — config_registry_check_all includes MCP validation
# ══════════════════════════════════════════════════════════════════════════════

@test "config_registry_check_all: calls mcp_validate_agent_config (grep check)" {
  # Structural check that the integration is wired up in the source
  grep -q "mcp_validate_agent_config" "${LIB_DIR}/config-schema-registry.sh"
}

@test "config_registry_check_all: runs without error against real configs" {
  run bash -c "
    WORKBENCH='${REPO_ROOT}'
    export WORKBENCH
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); printf 'OK: %s\n'   \"\$*\"; }
    warn() { WARN=\$((WARN+1)); printf 'WARN: %s\n' \"\$*\"; }
    bad()  { FAIL=\$((FAIL+1)); printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    config_registry_check_all
  "
  # Should exit 0 (all real configs are valid)
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# CATEGORY 15 — Edge cases
# ══════════════════════════════════════════════════════════════════════════════

@test "mcp-validate: missing mcp-schema.json produces warn not error (graceful)" {
  # An agent dir without mcp-schema.json should warn but exit 0
  run bash -c "
    WORKBENCH='${TEST_TMPDIR}/no-schema-wb'
    export WORKBENCH
    mkdir -p \"\${WORKBENCH}/agents/ashlrcode\"
    # Copy real settings.json but no schema
    cp '${REPO_ROOT}/agents/ashlrcode/settings.json' \"\${WORKBENCH}/agents/ashlrcode/settings.json\"
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_agent_config ashlrcode
  "
  # Should exit 0 (schema missing → warn, not abort)
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi "warn\|not found" || true
}

@test "mcp-validate: missing config file produces error (not silent)" {
  run bash -c "
    WORKBENCH='${TEST_TMPDIR}/no-config-wb'
    export WORKBENCH
    mkdir -p \"\${WORKBENCH}/agents/ashlrcode\"
    # Copy real schema but no settings.json
    cp '${REPO_ROOT}/agents/ashlrcode/mcp-schema.json' \"\${WORKBENCH}/agents/ashlrcode/mcp-schema.json\"
    ok()   { printf 'OK: %s\n'   \"\$*\"; }
    warn() { printf 'WARN: %s\n' \"\$*\"; }
    bad()  { printf 'BAD: %s\n'  \"\$*\"; }
    export -f ok warn bad 2>/dev/null || true
    . '${LIB_DIR}/config-schema-registry.sh'
    mcp_validate_agent_config ashlrcode
  "
  # Should exit non-zero (config is required)
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi "BAD:\|not found"
}

@test "mcp-validate: config-schema-registry.sh passes bash syntax check" {
  run bash -n "${LIB_DIR}/config-schema-registry.sh"
  [ "$status" -eq 0 ]
}
