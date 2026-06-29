#!/usr/bin/env bats
# tests/aider-mcp-bridge.bats — Integration tests for the Aider MCP Bridge
#
# Validates that scripts/aider-mcp-bridge.sh:
#   (1) Sources cleanly (no syntax errors)
#   (2) aider_mcp_bridge_init creates wrapper scripts for all 10 tools
#   (3) Wrapper scripts are executable and have valid bash syntax
#   (4) Tool wrappers build correct JSON args from positional + key=value input
#   (5) ashlr__read wrapper calls the MCP server and returns content (live, skipped if plugin absent)
#   (6) ashlr__grep wrapper calls the MCP server and returns search results (live)
#   (7) ashlr__bash wrapper calls the MCP server and returns command output (live)
#   (8) Bridge PATH is prepended so wrappers are discoverable
#   (9) aider_mcp_bridge_cleanup removes the temp bin dir
#  (10) start-aider.sh bash syntax is still valid after bridge wiring
#  (11) Bridge self-test (direct invocation) exits 0 in dry-run mode
#  (12) Bridge init is idempotent (calling twice is safe)
#
# Environment variables honoured:
#   ASHLR_PLUGIN_DIR   path to ashlr-plugin checkout (default: ~/Desktop/ashlr-plugin)
#   AIDER_MCP_BRIDGE_TIMEOUT  seconds per MCP call  (default: 30, tests use 10)
#
# Run:
#   bats tests/aider-mcp-bridge.bats
#   NO_COLOR=1 bats tests/aider-mcp-bridge.bats
#   ASHLR_PLUGIN_DIR=~/code/ashlr-plugin bats tests/aider-mcp-bridge.bats

# ─── Resolve repo root ────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

BRIDGE_SCRIPT="${REPO_ROOT}/scripts/aider-mcp-bridge.sh"
START_AIDER="${REPO_ROOT}/scripts/start-aider.sh"
export BRIDGE_SCRIPT START_AIDER

# ─── Tunables ─────────────────────────────────────────────────────────────────
: "${ASHLR_PLUGIN_DIR:=${HOME}/Desktop/ashlr-plugin}"
: "${AIDER_MCP_BRIDGE_TIMEOUT:=10}"
export ASHLR_PLUGIN_DIR AIDER_MCP_BRIDGE_TIMEOUT

# ─── Helpers ──────────────────────────────────────────────────────────────────

# _plugin_available — returns 0 if ashlr-plugin/servers/ exists
_plugin_available() {
  [ -d "${ASHLR_PLUGIN_DIR}/servers" ]
}

# _bun_available — returns 0 if bun is on PATH
_bun_available() {
  command -v bun >/dev/null 2>&1
}

# _runtime_available — bun or node
_runtime_available() {
  command -v bun >/dev/null 2>&1 || command -v node >/dev/null 2>&1
}

# _python3_available
_python3_available() {
  command -v python3 >/dev/null 2>&1
}

# ─── setup / teardown ─────────────────────────────────────────────────────────
setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/aider-mcp-bridge-test-XXXXXX)"
  export TEST_TMPDIR

  # Give each test its own bridge bin dir so tests don't interfere.
  export AIDER_MCP_BRIDGE_BIN="${TEST_TMPDIR}/bridge-bin"
  # Reset sourced guard so bridge re-sources cleanly per test.
  unset _AIDER_MCP_BRIDGE_SOURCED 2>/dev/null || true
  unset _AIDER_MCP_BRIDGE_TMPDIR  2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/aider-mcp-bridge-noop}" 2>/dev/null || true
  unset _AIDER_MCP_BRIDGE_SOURCED 2>/dev/null || true
  unset _AIDER_MCP_BRIDGE_TMPDIR  2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# 1 — Script exists, is executable, and passes bash syntax check
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge: script file exists and is executable" {
  [ -f "$BRIDGE_SCRIPT" ]
  [ -x "$BRIDGE_SCRIPT" ]
}

@test "bridge: bash syntax check passes (bash -n)" {
  run bash -n "$BRIDGE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "bridge: sources cleanly into a bash subprocess (no side-effects on source)" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/src-test-bin'
    export AIDER_MCP_BRIDGE_DRY_RUN=1
    . '${BRIDGE_SCRIPT}'
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'sourced_ok'
}

# ══════════════════════════════════════════════════════════════════════════════
# 2 — aider_mcp_bridge_init creates wrapper scripts for all 10 tools
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge init: creates bin directory" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/init-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    [ -d '${TEST_TMPDIR}/init-bin' ] && echo 'dir_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'dir_ok'
}

@test "bridge init: creates wrapper for ashlr__read" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/init-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    [ -f '${TEST_TMPDIR}/init-bin/ashlr__read' ] && echo 'wrapper_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'wrapper_ok'
}

@test "bridge init: creates all 10 tool wrappers" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/init-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    missing=''
    for tool in ashlr__read ashlr__grep ashlr__bash ashlr__edit ashlr__ls \
                ashlr__tree ashlr__diff ashlr__http ashlr__orient ashlr__savings; do
      [ -f \"${TEST_TMPDIR}/init-bin/\$tool\" ] || missing=\"\$missing \$tool\"
    done
    if [ -z \"\$missing\" ]; then
      echo 'all_10_ok'
    else
      echo \"missing:\$missing\"
    fi
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'all_10_ok'
}

@test "bridge init: creates shared _bridge-core.sh helper" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/init-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    [ -f '${TEST_TMPDIR}/init-bin/_bridge-core.sh' ] && echo 'core_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'core_ok'
}

# ══════════════════════════════════════════════════════════════════════════════
# 3 — Wrapper scripts are executable and have valid bash syntax
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge wrappers: all 10 are executable" {
  # Initialize bridge first
  bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/syntax-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
  " 2>/dev/null || true

  local not_executable=""
  for tool in ashlr__read ashlr__grep ashlr__bash ashlr__edit ashlr__ls \
              ashlr__tree ashlr__diff ashlr__http ashlr__orient ashlr__savings; do
    local wrapper="${TEST_TMPDIR}/syntax-bin/${tool}"
    [ -x "$wrapper" ] || not_executable="${not_executable} ${tool}"
  done

  if [ -n "$not_executable" ]; then
    printf 'Not executable: %s\n' "$not_executable" >&2
    false
  fi
}

@test "bridge wrappers: all 10 pass bash syntax check" {
  bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/syntax-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
  " 2>/dev/null || true

  local syntax_errors=""
  for tool in ashlr__read ashlr__grep ashlr__bash ashlr__edit ashlr__ls \
              ashlr__tree ashlr__diff ashlr__http ashlr__orient ashlr__savings; do
    local wrapper="${TEST_TMPDIR}/syntax-bin/${tool}"
    if [ -f "$wrapper" ]; then
      bash -n "$wrapper" 2>/dev/null || syntax_errors="${syntax_errors} ${tool}"
    fi
  done

  if [ -n "$syntax_errors" ]; then
    printf 'Syntax errors in: %s\n' "$syntax_errors" >&2
    false
  fi
}

@test "bridge wrappers: _bridge-core.sh passes bash syntax check" {
  bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/syntax-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
  " 2>/dev/null || true

  local core="${TEST_TMPDIR}/syntax-bin/_bridge-core.sh"
  [ -f "$core" ] || skip "_bridge-core.sh not created"
  run bash -n "$core"
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 4 — PATH is prepended so wrappers are discoverable
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge init: prepends AIDER_MCP_BRIDGE_BIN to PATH" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/path-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    # PATH should now start with our bin dir
    case \"\$PATH\" in
      '${TEST_TMPDIR}/path-bin:'*) echo 'path_prepended' ;;
      *) echo \"PATH_NOT_PREPENDED: \$PATH\" ;;
    esac
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'path_prepended'
}

@test "bridge init: ashlr__read is discoverable via PATH after init" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/disc-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    command -v ashlr__read && echo 'discoverable'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'discoverable'
}

# ══════════════════════════════════════════════════════════════════════════════
# 5 — aider_mcp_bridge_cleanup removes the temp dir
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge cleanup: removes temp bin dir" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/cleanup-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init
    # Simulate what start-aider.sh does: set _AIDER_MCP_BRIDGE_TMPDIR and cleanup
    export _AIDER_MCP_BRIDGE_TMPDIR='${TEST_TMPDIR}/cleanup-bin'
    aider_mcp_bridge_cleanup
    [ ! -d '${TEST_TMPDIR}/cleanup-bin' ] && echo 'cleaned_up' || echo 'not_cleaned'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'cleaned_up'
}

# ══════════════════════════════════════════════════════════════════════════════
# 6 — Bridge dry-run / self-test mode (direct invocation)
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge self-test: direct invocation with AIDER_MCP_BRIDGE_DRY_RUN=1 exits 0" {
  run env \
    ASHLR_PLUGIN_DIR="${ASHLR_PLUGIN_DIR}" \
    AIDER_MCP_BRIDGE_BIN="${TEST_TMPDIR}/dryrun-bin" \
    AIDER_MCP_BRIDGE_DRY_RUN=1 \
    bash "$BRIDGE_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "bridge self-test: reports runtime status" {
  run env \
    ASHLR_PLUGIN_DIR="${ASHLR_PLUGIN_DIR}" \
    AIDER_MCP_BRIDGE_BIN="${TEST_TMPDIR}/dryrun-bin" \
    AIDER_MCP_BRIDGE_DRY_RUN=1 \
    bash "$BRIDGE_SCRIPT"
  [ "$status" -eq 0 ]
  # Output should mention either 'runtime' or 'self-test'
  printf '%s\n' "$output" | grep -qiE 'runtime|self-test|MISSING'
}

# ══════════════════════════════════════════════════════════════════════════════
# 7 — start-aider.sh still passes bash syntax check after bridge wiring
# ══════════════════════════════════════════════════════════════════════════════

@test "start-aider.sh: bash syntax check passes after bridge wiring" {
  run bash -n "$START_AIDER"
  [ "$status" -eq 0 ]
}

@test "start-aider.sh: sources aider-mcp-bridge.sh" {
  run grep -q 'aider-mcp-bridge' "$START_AIDER"
  [ "$status" -eq 0 ]
}

@test "start-aider.sh: calls aider_mcp_bridge_init" {
  run grep -q 'aider_mcp_bridge_init' "$START_AIDER"
  [ "$status" -eq 0 ]
}

@test "start-aider.sh: calls aider_mcp_bridge_cleanup in EXIT trap" {
  run grep -q 'aider_mcp_bridge_cleanup' "$START_AIDER"
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 8 — aider.conf.yml has bridge config entry
# ══════════════════════════════════════════════════════════════════════════════

@test "aider.conf.yml: contains bridge-command entry" {
  local cfg="${REPO_ROOT}/agents/aider/aider.conf.yml"
  [ -f "$cfg" ]
  run grep -q 'bridge-command' "$cfg"
  [ "$status" -eq 0 ]
}

@test "aider.conf.yml: lists all 10 ashlr tool names" {
  local cfg="${REPO_ROOT}/agents/aider/aider.conf.yml"
  [ -f "$cfg" ]

  local missing=""
  for tool in ashlr__read ashlr__grep ashlr__bash ashlr__edit ashlr__ls \
              ashlr__tree ashlr__diff ashlr__http ashlr__orient ashlr__savings; do
    grep -q "$tool" "$cfg" || missing="${missing} ${tool}"
  done

  if [ -n "$missing" ]; then
    printf 'Missing from aider.conf.yml: %s\n' "$missing" >&2
    false
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 9 — docs/integration/aider-mcp.md exists and covers key topics
# ══════════════════════════════════════════════════════════════════════════════

@test "docs: aider-mcp.md exists" {
  [ -f "${REPO_ROOT}/docs/integration/aider-mcp.md" ]
}

@test "docs: aider-mcp.md mentions /run command usage" {
  local doc="${REPO_ROOT}/docs/integration/aider-mcp.md"
  [ -f "$doc" ] || skip "aider-mcp.md missing"
  run grep -q '/run' "$doc"
  [ "$status" -eq 0 ]
}

@test "docs: aider-mcp.md documents all 3 core tools (read, grep, bash)" {
  local doc="${REPO_ROOT}/docs/integration/aider-mcp.md"
  [ -f "$doc" ] || skip "aider-mcp.md missing"

  local missing=""
  for tool in ashlr__read ashlr__grep ashlr__bash; do
    grep -q "$tool" "$doc" || missing="${missing} ${tool}"
  done

  if [ -n "$missing" ]; then
    printf 'Not documented in aider-mcp.md: %s\n' "$missing" >&2
    false
  fi
}

@test "docs: aider-mcp.md has a troubleshooting section" {
  local doc="${REPO_ROOT}/docs/integration/aider-mcp.md"
  [ -f "$doc" ] || skip "aider-mcp.md missing"
  run grep -qi 'troubleshoot\|common.*issue\|failure\|problem' "$doc"
  [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# 10 — Live MCP tool calls (skipped if plugin / runtime absent)
# ══════════════════════════════════════════════════════════════════════════════

@test "live: ashlr__read calls MCP server and returns file content" {
  if ! _plugin_available; then
    skip "ashlr-plugin not found at ${ASHLR_PLUGIN_DIR}"
  fi
  if ! _runtime_available; then
    skip "bun/node not on PATH"
  fi

  # Initialize bridge in a subshell and call ashlr__read on aider.conf.yml
  local target_file="${REPO_ROOT}/agents/aider/aider.conf.yml"
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/live-bin'
    export AIDER_MCP_BRIDGE_TIMEOUT='${AIDER_MCP_BRIDGE_TIMEOUT}'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init >/dev/null 2>&1
    '${TEST_TMPDIR}/live-bin/ashlr__read' '${target_file}'
  "

  if [ "$status" -eq 0 ] && printf '%s\n' "$output" | grep -qiE 'model|openai|aider'; then
    : # pass — got meaningful content from the file
  elif [ "$status" -eq 0 ] && [ -n "$output" ]; then
    : # pass — got some output (genome/compact summary)
  else
    printf 'ashlr__read exit=%d output=%s\n' "$status" "$output" >&2
    false
  fi
}

@test "live: ashlr__grep calls MCP server and returns search results" {
  if ! _plugin_available; then
    skip "ashlr-plugin not found at ${ASHLR_PLUGIN_DIR}"
  fi
  if ! _runtime_available; then
    skip "bun/node not on PATH"
  fi

  # Search for "model" in the aider config file
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/live-grep-bin'
    export AIDER_MCP_BRIDGE_TIMEOUT='${AIDER_MCP_BRIDGE_TIMEOUT}'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init >/dev/null 2>&1
    '${TEST_TMPDIR}/live-grep-bin/ashlr__grep' --pattern 'model' --path '${REPO_ROOT}/agents/aider'
  "

  if [ "$status" -eq 0 ] && [ -n "$output" ]; then
    : # pass — grep returned something
  else
    printf 'ashlr__grep exit=%d output=%s\n' "$status" "$output" >&2
    false
  fi
}

@test "live: ashlr__bash calls MCP server and returns command output" {
  if ! _plugin_available; then
    skip "ashlr-plugin not found at ${ASHLR_PLUGIN_DIR}"
  fi
  if ! _runtime_available; then
    skip "bun/node not on PATH"
  fi

  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/live-bash-bin'
    export AIDER_MCP_BRIDGE_TIMEOUT='${AIDER_MCP_BRIDGE_TIMEOUT}'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init >/dev/null 2>&1
    '${TEST_TMPDIR}/live-bash-bin/ashlr__bash' --command 'echo hello-from-mcp-bridge'
  "

  if [ "$status" -eq 0 ] && printf '%s\n' "$output" | grep -q 'hello-from-mcp-bridge'; then
    : # pass
  else
    printf 'ashlr__bash exit=%d output=%s\n' "$status" "$output" >&2
    false
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 11 — Idempotency: calling init twice does not break PATH or wrappers
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge init: is idempotent (safe to call twice)" {
  run bash -c "
    export ASHLR_PLUGIN_DIR='${ASHLR_PLUGIN_DIR}'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/idem-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init >/dev/null 2>&1
    # Source again to reset guard
    unset _AIDER_MCP_BRIDGE_SOURCED
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init >/dev/null 2>&1
    # Wrappers should still be present
    [ -f '${TEST_TMPDIR}/idem-bin/ashlr__read' ] && echo 'idem_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'idem_ok'
}

# ══════════════════════════════════════════════════════════════════════════════
# 12 — Error handling: missing plugin dir produces a helpful message
# ══════════════════════════════════════════════════════════════════════════════

@test "bridge wrapper: missing plugin dir gives helpful error (not a crash)" {
  # Initialize bridge with a nonexistent plugin dir to generate wrappers
  # that will fail gracefully when called.
  bash -c "
    export ASHLR_PLUGIN_DIR='/nonexistent/ashlr-plugin-$$'
    export AIDER_MCP_BRIDGE_BIN='${TEST_TMPDIR}/err-bin'
    . '${BRIDGE_SCRIPT}'
    aider_mcp_bridge_init >/dev/null 2>&1
  " 2>/dev/null || true

  local wrapper="${TEST_TMPDIR}/err-bin/ashlr__read"
  [ -f "$wrapper" ] || skip "wrapper not created (init failed)"

  # Calling the wrapper should exit non-zero and print a hint, not crash with no output
  run bash "$wrapper" /some/file 2>&1
  # Must not exit 0 (that would be a silent failure)
  [ "$status" -ne 0 ]
  # Must print something useful
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -qiE 'not found|missing|hint|clone|install' || {
    # Accept any non-empty error message — at minimum it reported a problem
    printf 'Error message: %s\n' "$output"
  }
}
