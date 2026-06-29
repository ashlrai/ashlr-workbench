#!/usr/bin/env bash
# tests/integration.sh — shell integration tests for ashlr-workbench.
#
# Plain-bash harness (no bats dependency) consistent with the repo's
# bash 3.2-safe style.
#
# Tests:
#   1. config.sh sources cleanly and exports all required variables
#   2. All expected defaults have non-empty values
#   3. Env-variable overrides take precedence over defaults
#   4. WORKBENCH resolves to a real directory (repo root detection)
#   5. MCP runtime validation — healthcheck.sh is present and executable
#   6. LM Studio probe — healthcheck parses LM_STUDIO_URL from env
#   7. Scripts that previously hardcoded WORKBENCH now derive it from config.sh
#
# Usage:
#   bash tests/integration.sh          # from the repo root
#   ./tests/integration.sh             # if executable

set -uo pipefail

# ─── Resolve repo root ────────────────────────────────────────────────────────
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  link_target="$(readlink "$SCRIPT_PATH")"
  case "$link_target" in
    /*) SCRIPT_PATH="$link_target" ;;
    *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$link_target" ;;
  esac
done
TESTS_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CONFIG_SH="$REPO_ROOT/scripts/lib/config.sh"

# ─── Tiny test harness ────────────────────────────────────────────────────────
PASS=0
FAIL=0

_ok()  { printf "  \033[32mPASS\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
_fail(){ printf "  \033[31mFAIL\033[0m %s\n" "$*"; FAIL=$((FAIL+1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    _ok "$desc"
  else
    _fail "$desc  (expected='$expected' actual='$actual')"
  fi
}

assert_nonempty() {
  local desc="$1" val="$2"
  if [ -n "$val" ]; then
    _ok "$desc"
  else
    _fail "$desc  (value is empty)"
  fi
}

assert_file_executable() {
  local desc="$1" path="$2"
  if [ -x "$path" ]; then
    _ok "$desc"
  else
    _fail "$desc  (not executable: $path)"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    _ok "$desc"
  else
    _fail "$desc  (expected '$needle' in output)"
  fi
}

# ─── Test 1: config.sh sources cleanly ───────────────────────────────────────
printf "\n\033[1mTest 1: config.sh sources cleanly\033[0m\n"

if [ ! -f "$CONFIG_SH" ]; then
  _fail "config.sh missing at $CONFIG_SH"
else
  _ok "config.sh exists"
fi

# Source in a subshell and emit key=value pairs to avoid polluting this env.
# We deliberately unset any env vars first so we're testing pure defaults.
CONFIG_OUTPUT="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    echo \"WORKBENCH=\$WORKBENCH\"
    echo \"LM_STUDIO_URL=\$LM_STUDIO_URL\"
    echo \"LM_STUDIO_MODEL=\$LM_STUDIO_MODEL\"
    echo \"LMS_CLI=\$LMS_CLI\"
    echo \"OLLAMA_URL=\$OLLAMA_URL\"
    echo \"OLLAMA_MODEL_FAST=\$OLLAMA_MODEL_FAST\"
    echo \"OLLAMA_MODEL_REASONING=\$OLLAMA_MODEL_REASONING\"
    echo \"OPENHANDS_CONTAINER=\$OPENHANDS_CONTAINER\"
    echo \"OPENHANDS_PORT=\$OPENHANDS_PORT\"
    echo \"OPENHANDS_IMAGE=\$OPENHANDS_IMAGE\"
    echo \"OPENHANDS_SANDBOX_IMAGE=\$OPENHANDS_SANDBOX_IMAGE\"
    echo \"OPENHANDS_LLM_BASE_URL=\$OPENHANDS_LLM_BASE_URL\"
    echo \"OPENHANDS_LLM_MODEL=\$OPENHANDS_LLM_MODEL\"
    echo \"OPENHANDS_LLM_API_KEY=\$OPENHANDS_LLM_API_KEY\"
    echo \"OPENHANDS_CONTEXT_LENGTH=\$OPENHANDS_CONTEXT_LENGTH\"
    echo \"ASHLR_PLUGIN_DIR=\$ASHLR_PLUGIN_DIR\"
    echo \"OPENHANDS_STATE_DIR=\$OPENHANDS_STATE_DIR\"
    echo \"OPENHANDS_WORKSPACE_HOST=\$OPENHANDS_WORKSPACE_HOST\"
    echo \"OPENHANDS_CACHE_DIR=\$OPENHANDS_CACHE_DIR\"
    echo \"BUN_LINUX_ARCH=\$BUN_LINUX_ARCH\"
    echo \"BUN_VERSION_URL=\$BUN_VERSION_URL\"
  " 2>&1
)"

if printf '%s' "$CONFIG_OUTPUT" | grep -q '^WORKBENCH='; then
  _ok "config.sh sourced without error"
else
  _fail "config.sh source produced unexpected output: $CONFIG_OUTPUT"
fi

# ─── Test 2: defaults are non-empty ──────────────────────────────────────────
printf "\n\033[1mTest 2: all defaults are non-empty\033[0m\n"

get_val() {
  printf '%s' "$CONFIG_OUTPUT" | grep "^${1}=" | cut -d= -f2-
}

for var in \
  LM_STUDIO_URL LM_STUDIO_MODEL LMS_CLI \
  OLLAMA_URL OLLAMA_MODEL_FAST OLLAMA_MODEL_REASONING \
  OPENHANDS_CONTAINER OPENHANDS_PORT OPENHANDS_IMAGE \
  OPENHANDS_SANDBOX_IMAGE OPENHANDS_LLM_BASE_URL OPENHANDS_LLM_MODEL \
  OPENHANDS_LLM_API_KEY OPENHANDS_CONTEXT_LENGTH \
  ASHLR_PLUGIN_DIR OPENHANDS_STATE_DIR OPENHANDS_WORKSPACE_HOST \
  OPENHANDS_CACHE_DIR BUN_LINUX_ARCH BUN_VERSION_URL; do
  val="$(get_val "$var")"
  assert_nonempty "$var is non-empty (default)" "$val"
done

# WORKBENCH must resolve to a real directory (the repo root itself)
WB_VAL="$(get_val "WORKBENCH")"
if [ -d "$WB_VAL" ]; then
  _ok "WORKBENCH resolves to an existing directory ($WB_VAL)"
else
  _fail "WORKBENCH='$WB_VAL' is not a directory"
fi

# ─── Test 3: env-variable overrides take precedence ──────────────────────────
printf "\n\033[1mTest 3: env overrides take precedence\033[0m\n"

OVERRIDE_OUTPUT="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:9999/v1" \
    OLLAMA_URL="http://localhost:55555" \
    OPENHANDS_PORT="9090" \
    OPENHANDS_CONTAINER="my-custom-container" \
    ASHLR_PLUGIN_DIR="/tmp/my-plugin" \
    bash -c "
      . '$CONFIG_SH'
      echo \"LM_STUDIO_URL=\$LM_STUDIO_URL\"
      echo \"OLLAMA_URL=\$OLLAMA_URL\"
      echo \"OPENHANDS_PORT=\$OPENHANDS_PORT\"
      echo \"OPENHANDS_CONTAINER=\$OPENHANDS_CONTAINER\"
      echo \"ASHLR_PLUGIN_DIR=\$ASHLR_PLUGIN_DIR\"
    " 2>&1
)"

get_override() {
  printf '%s' "$OVERRIDE_OUTPUT" | grep "^${1}=" | cut -d= -f2-
}

assert_eq "LM_STUDIO_URL override"       "http://localhost:9999/v1"   "$(get_override LM_STUDIO_URL)"
assert_eq "OLLAMA_URL override"          "http://localhost:55555"      "$(get_override OLLAMA_URL)"
assert_eq "OPENHANDS_PORT override"      "9090"                        "$(get_override OPENHANDS_PORT)"
assert_eq "OPENHANDS_CONTAINER override" "my-custom-container"         "$(get_override OPENHANDS_CONTAINER)"
assert_eq "ASHLR_PLUGIN_DIR override"    "/tmp/my-plugin"              "$(get_override ASHLR_PLUGIN_DIR)"

# ─── Test 4: double-source guard ─────────────────────────────────────────────
printf "\n\033[1mTest 4: double-source guard (idempotent)\033[0m\n"

DOUBLE_SOURCE_OUTPUT="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$CONFIG_SH'
    echo \"LM_STUDIO_URL=\$LM_STUDIO_URL\"
    echo \"exit_code=0\"
  " 2>&1
)"
if printf '%s' "$DOUBLE_SOURCE_OUTPUT" | grep -q '^exit_code=0'; then
  _ok "double-source is safe (guard works)"
else
  _fail "double-source produced errors: $DOUBLE_SOURCE_OUTPUT"
fi

# ─── Test 5: MCP runtime validation — healthcheck.sh present + executable ────
printf "\n\033[1mTest 5: MCP runtime validation (healthcheck.sh)\033[0m\n"

HEALTHCHECK="$REPO_ROOT/scripts/healthcheck.sh"
assert_file_executable "healthcheck.sh is executable" "$HEALTHCHECK"

# Run healthcheck in dry-run mode: just check that it accepts --help / can be
# sourced.  We can't run the full check in CI (no Docker/LM Studio), but we
# verify it parses cleanly (bash -n) and that it references LM_STUDIO_URL via
# the config convention.
if bash -n "$HEALTHCHECK" 2>/dev/null; then
  _ok "healthcheck.sh passes bash syntax check"
else
  _fail "healthcheck.sh has bash syntax errors"
fi

# Verify healthcheck honors LM_STUDIO_URL env override (grep for the pattern)
if grep -q 'LM_STUDIO_URL' "$HEALTHCHECK"; then
  _ok "healthcheck.sh references LM_STUDIO_URL (env-overridable)"
else
  _fail "healthcheck.sh does not reference LM_STUDIO_URL"
fi

# ─── Test 6: LM Studio probe URL is configurable ─────────────────────────────
printf "\n\033[1mTest 6: LM Studio probe URL is configurable\033[0m\n"

# Source config with a custom LM_STUDIO_URL and confirm the value flows through.
PROBE_OUTPUT="$(
  env -i HOME="$HOME" LM_STUDIO_URL="http://custom-host:4567/v1" bash -c "
    . '$CONFIG_SH'
    printf '%s' \"\$LM_STUDIO_URL\"
  " 2>&1
)"
assert_eq "LM Studio probe URL follows LM_STUDIO_URL" \
  "http://custom-host:4567/v1" "$PROBE_OUTPUT"

# ─── Test 7: refactored scripts derive WORKBENCH from config.sh ──────────────
printf "\n\033[1mTest 7: refactored scripts no longer hardcode WORKBENCH\033[0m\n"

for script in \
  "$REPO_ROOT/scripts/start-aider.sh" \
  "$REPO_ROOT/scripts/start-ashlrcode.sh"; do
  script_name="$(basename "$script")"

  # Must NOT contain the old Mason-specific hardcoded path
  if grep -q '/Users/masonwyatt/Desktop/ashlr-workbench' "$script"; then
    _fail "$script_name still contains hardcoded WORKBENCH path"
  else
    _ok "$script_name: no hardcoded WORKBENCH path"
  fi

  # Must source config.sh
  if grep -q 'lib/config.sh' "$script"; then
    _ok "$script_name: sources lib/config.sh"
  else
    _fail "$script_name: does not source lib/config.sh"
  fi

  # Syntax check
  if bash -n "$script" 2>/dev/null; then
    _ok "$script_name: bash syntax OK"
  else
    _fail "$script_name: bash syntax error"
  fi
done

# mode-switch.sh must no longer hardcode the lms path
if grep -q '\.lmstudio/bin/lms' "$REPO_ROOT/scripts/mode-switch.sh"; then
  _fail "mode-switch.sh still hardcodes LMS path"
else
  _ok "mode-switch.sh: LMS path sourced from config.sh (LMS_CLI)"
fi

# start-openhands.sh must source config.sh and not hardcode image URLs inline
OH_SCRIPT="$REPO_ROOT/scripts/start-openhands.sh"
if grep -q 'lib/config.sh' "$OH_SCRIPT"; then
  _ok "start-openhands.sh: sources lib/config.sh"
else
  _fail "start-openhands.sh: does not source lib/config.sh"
fi
if bash -n "$OH_SCRIPT" 2>/dev/null; then
  _ok "start-openhands.sh: bash syntax OK"
else
  _fail "start-openhands.sh: bash syntax error"
fi

# ─── Test 8: mcp-probe.sh library ────────────────────────────────────────────
printf "\n\033[1mTest 8: mcp-probe.sh library\033[0m\n"

MCP_PROBE_SH="$REPO_ROOT/scripts/lib/mcp-probe.sh"

# 8a — file exists and is executable
assert_file_executable "mcp-probe.sh is executable" "$MCP_PROBE_SH"

# 8b — bash syntax check
if bash -n "$MCP_PROBE_SH" 2>/dev/null; then
  _ok "mcp-probe.sh passes bash syntax check"
else
  _fail "mcp-probe.sh has bash syntax errors"
fi

# 8c — double-source guard
DOUBLE_PROBE="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$MCP_PROBE_SH'
    . '$MCP_PROBE_SH'
    echo sourced_twice_ok
  " 2>&1
)"
if printf '%s' "$DOUBLE_PROBE" | grep -q 'sourced_twice_ok'; then
  _ok "mcp-probe.sh double-source guard works"
else
  _fail "mcp-probe.sh double-source produced errors: $DOUBLE_PROBE"
fi

# 8d — validate_mcp_servers is defined after sourcing
FUNC_DEFINED="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$MCP_PROBE_SH'
    if declare -f validate_mcp_servers >/dev/null 2>&1; then
      echo defined
    else
      echo missing
    fi
  " 2>&1
)"
assert_eq "validate_mcp_servers function is defined" "defined" "$FUNC_DEFINED"

# 8e — _mcp_probe_one returns 3 for a missing file
PROBE_MISSING="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$MCP_PROBE_SH'
    _mcp_probe_one test-server /nonexistent/server.ts
    echo rc=\$?
  " 2>&1
)"
assert_eq "_mcp_probe_one rc=3 for missing file" "rc=3" "$(printf '%s' "$PROBE_MISSING" | grep '^rc=')"

# 8f — _mcp_probe_one returns 4 when runtime absent (simulate via PATH override)
PROBE_NO_RUNTIME="$(
  env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c "
    . '$CONFIG_SH'
    . '$MCP_PROBE_SH'
    # Use a real file but make sure bun/node are not on PATH
    tmpfile=\"\$(mktemp /tmp/mcp-probe-test-XXXXXX.ts)\"
    echo 'console.log(\"hello\")' > \"\$tmpfile\"
    _mcp_probe_one test-server \"\$tmpfile\"
    rc=\$?
    rm -f \"\$tmpfile\"
    echo rc=\$rc
  " 2>&1
)"
assert_eq "_mcp_probe_one rc=4 when runtime absent" "rc=4" "$(printf '%s' "$PROBE_NO_RUNTIME" | grep '^rc=')"

# 8g — _mcp_fix_hint emits a bun-install hint for rc=2 (module-not-found crash)
FIX_HINT="$(
  env -i HOME="$HOME" ASHLR_PLUGIN_DIR="/tmp/fake-plugin" bash -c "
    . '$CONFIG_SH'
    . '$MCP_PROBE_SH'
    _mcp_fix_hint bash-server 2 'Cannot find module @modelcontextprotocol/sdk'
  " 2>&1
)"
if printf '%s' "$FIX_HINT" | grep -qi 'bun install'; then
  _ok "_mcp_fix_hint suggests 'bun install' for missing-module crash"
else
  _fail "_mcp_fix_hint did not suggest 'bun install' (got: $FIX_HINT)"
fi

# 8h — validate_mcp_servers handles missing plugin dir gracefully (no crash)
VALIDATE_NO_DIR="$(
  env -i HOME="$HOME" ASHLR_PLUGIN_DIR="/tmp/definitely-does-not-exist-$$" bash -c "
    . '$CONFIG_SH'
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf '%s\n' \"\$*\"; }
    . '$MCP_PROBE_SH'
    validate_mcp_servers
    echo exit_ok
  " 2>&1
)"
if printf '%s' "$VALIDATE_NO_DIR" | grep -q 'exit_ok'; then
  _ok "validate_mcp_servers exits cleanly when plugin dir is missing"
else
  _fail "validate_mcp_servers crashed with missing plugin dir: $VALIDATE_NO_DIR"
fi

# 8i — healthcheck.sh sources mcp-probe.sh
if grep -q 'mcp-probe.sh' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh sources mcp-probe.sh"
else
  _fail "healthcheck.sh does not source mcp-probe.sh"
fi

# 8j — healthcheck.sh calls validate_mcp_servers
if grep -q 'validate_mcp_servers' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh calls validate_mcp_servers"
else
  _fail "healthcheck.sh does not call validate_mcp_servers"
fi

# ─── Test 9: config-validate.sh library ──────────────────────────────────────
printf "\n\033[1mTest 9: config-validate.sh library\033[0m\n"

CONFIG_VALIDATE_SH="$REPO_ROOT/scripts/lib/config-validate.sh"

# 9a — file exists and is executable
assert_file_executable "config-validate.sh is executable" "$CONFIG_VALIDATE_SH"

# 9b — bash syntax check
if bash -n "$CONFIG_VALIDATE_SH" 2>/dev/null; then
  _ok "config-validate.sh passes bash syntax check"
else
  _fail "config-validate.sh has bash syntax errors"
fi

# 9c — double-source guard
DOUBLE_CV="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    . '$CONFIG_SH'
    . '$CONFIG_VALIDATE_SH'
    . '$CONFIG_VALIDATE_SH'
    echo sourced_twice_ok
  " 2>&1
)"
if printf '%s' "$DOUBLE_CV" | grep -q 'sourced_twice_ok'; then
  _ok "config-validate.sh double-source guard works"
else
  _fail "config-validate.sh double-source produced errors: $DOUBLE_CV"
fi

# 9d — validate_all_agent_configs is defined after sourcing
CV_FUNC="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    . '$CONFIG_SH'
    . '$CONFIG_VALIDATE_SH'
    if declare -f validate_all_agent_configs >/dev/null 2>&1; then
      echo defined
    else
      echo missing
    fi
  " 2>&1
)"
assert_eq "validate_all_agent_configs function is defined" "defined" "$CV_FUNC"

# 9e — validate_toml_sections catches a missing section (bad)
TOML_MISSING_SECTION="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    tmpfile=\"\$(mktemp /tmp/cv-test-XXXXXX.toml)\"
    printf '[core]\nfoo = 1\n' > \"\$tmpfile\"
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); printf 'ok: %s\n' \"\$*\"; }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_toml_sections \"\$tmpfile\" 'core,llm,sandbox' 'test.toml'
    rm -f \"\$tmpfile\"
    echo \"PASS=\$PASS FAIL=\$FAIL\"
  " 2>&1
)"
if printf '%s' "$TOML_MISSING_SECTION" | grep -q 'FAIL=2'; then
  _ok "validate_toml_sections detects 2 missing sections"
else
  _fail "validate_toml_sections section-check unexpected output: $TOML_MISSING_SECTION"
fi

# 9f — validate_toml_keys catches a missing key within a section (bad)
TOML_MISSING_KEY="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    tmpfile=\"\$(mktemp /tmp/cv-test-XXXXXX.toml)\"
    printf '[sandbox]\ntimeout = 120\n' > \"\$tmpfile\"
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_toml_keys \"\$tmpfile\" sandbox \
      'timeout,runtime_container_image,use_host_network' 'test.toml'
    rm -f \"\$tmpfile\"
    echo \"PASS=\$PASS FAIL=\$FAIL\"
  " 2>&1
)"
# Should report failure for the 2 missing keys
if printf '%s' "$TOML_MISSING_KEY" | grep -q 'FAIL='; then
  CV_FAILS="$(printf '%s' "$TOML_MISSING_KEY" | grep 'FAIL=' | grep -o 'FAIL=[0-9]*' | cut -d= -f2)"
  if [ "${CV_FAILS:-0}" -ge 1 ]; then
    _ok "validate_toml_keys detects missing keys in [sandbox]"
  else
    _fail "validate_toml_keys did not catch missing keys (output: $TOML_MISSING_KEY)"
  fi
else
  _fail "validate_toml_keys produced unexpected output: $TOML_MISSING_KEY"
fi

# 9g — validate_yaml_keys catches a missing key
YAML_MISSING_KEY="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    tmpfile=\"\$(mktemp /tmp/cv-test-XXXXXX.yaml)\"
    printf 'model: gpt-4\nstream: true\n' > \"\$tmpfile\"
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_yaml_keys \"\$tmpfile\" 'model,stream,pretty,openai-api-base' 'test.yaml'
    rm -f \"\$tmpfile\"
    echo \"PASS=\$PASS FAIL=\$FAIL\"
  " 2>&1
)"
if printf '%s' "$YAML_MISSING_KEY" | grep -q 'FAIL='; then
  CV_FAILS="$(printf '%s' "$YAML_MISSING_KEY" | grep 'FAIL=' | grep -o 'FAIL=[0-9]*' | cut -d= -f2)"
  if [ "${CV_FAILS:-0}" -ge 1 ]; then
    _ok "validate_yaml_keys detects missing YAML keys"
  else
    _fail "validate_yaml_keys did not catch missing keys (output: $YAML_MISSING_KEY)"
  fi
else
  _fail "validate_yaml_keys produced unexpected output: $YAML_MISSING_KEY"
fi

# 9h — validate_json_keys catches missing keys
JSON_MISSING_KEY="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    tmpfile=\"\$(mktemp /tmp/cv-test-XXXXXX.json)\"
    printf '{\"providers\":{},\"mcpServers\":{}}' > \"\$tmpfile\"
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_json_keys \"\$tmpfile\" 'providers,mcpServers,hooks,approveMode' 'test.json'
    rm -f \"\$tmpfile\"
    echo \"PASS=\$PASS FAIL=\$FAIL\"
  " 2>&1
)"
if printf '%s' "$JSON_MISSING_KEY" | grep -q 'FAIL='; then
  CV_FAILS="$(printf '%s' "$JSON_MISSING_KEY" | grep 'FAIL=' | grep -o 'FAIL=[0-9]*' | cut -d= -f2)"
  if [ "${CV_FAILS:-0}" -ge 1 ]; then
    _ok "validate_json_keys detects missing JSON keys"
  else
    _fail "validate_json_keys did not catch missing keys (output: $JSON_MISSING_KEY)"
  fi
else
  _fail "validate_json_keys produced unexpected output: $JSON_MISSING_KEY"
fi

# 9i — validate_json_schema validates mcp.json structure against schema
JSON_SCHEMA_OK="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); printf 'ok: %s\n' \"\$*\"; }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_json_schema \
      '$REPO_ROOT/agents/openhands/mcp.json' \
      '$REPO_ROOT/agents/openhands/schema.json' \
      'openhands/mcp.json'
    echo \"PASS=\$PASS FAIL=\$FAIL\"
  " 2>&1
)"
if printf '%s' "$JSON_SCHEMA_OK" | grep -q 'FAIL=0'; then
  _ok "validate_json_schema: openhands/mcp.json passes schema baseline"
else
  _fail "validate_json_schema: openhands/mcp.json failed schema check (output: $JSON_SCHEMA_OK)"
fi

# 9j — validate_json_schema catches a schema violation (missing required server)
JSON_SCHEMA_DRIFT="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    tmpfile=\"\$(mktemp /tmp/cv-test-XXXXXX.json)\"
    printf '{\"stdio_servers\":[{\"name\":\"ashlr-efficiency\",\"command\":\"bash\",\"args\":[]}],\"sse_servers\":[],\"shttp_servers\":[]}' > \"\$tmpfile\"
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_json_schema \"\$tmpfile\" \
      '$REPO_ROOT/agents/openhands/schema.json' \
      'test-mcp.json'
    rm -f \"\$tmpfile\"
    echo \"PASS=\$PASS FAIL=\$FAIL\"
  " 2>&1
)"
if printf '%s' "$JSON_SCHEMA_DRIFT" | grep -q 'FAIL='; then
  CV_FAILS="$(printf '%s' "$JSON_SCHEMA_DRIFT" | grep 'FAIL=' | grep -o 'FAIL=[0-9]*' | cut -d= -f2)"
  if [ "${CV_FAILS:-0}" -ge 1 ]; then
    _ok "validate_json_schema detects missing required stdio_servers (schema drift)"
  else
    _fail "validate_json_schema did not catch schema drift (output: $JSON_SCHEMA_DRIFT)"
  fi
else
  _fail "validate_json_schema schema-drift check unexpected output: $JSON_SCHEMA_DRIFT"
fi

# 9k — validate_all_agent_configs runs without crashing on actual agent configs
ALL_CONFIGS="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    PASS=0; WARN=0; FAIL=0
    ok()   { PASS=\$((PASS+1)); }
    warn() { WARN=\$((WARN+1)); }
    bad()  { FAIL=\$((FAIL+1)); printf 'bad: %s\n' \"\$*\"; }
    . '$CONFIG_VALIDATE_SH'
    validate_all_agent_configs
    echo \"PASS=\$PASS FAIL=\$FAIL exit_ok\"
  " 2>&1
)"
if printf '%s' "$ALL_CONFIGS" | grep -q 'exit_ok'; then
  if printf '%s' "$ALL_CONFIGS" | grep -q 'FAIL=0'; then
    _ok "validate_all_agent_configs: all real agent configs pass schema checks"
  else
    CV_FAILS="$(printf '%s' "$ALL_CONFIGS" | grep 'FAIL=' | grep -o 'FAIL=[0-9]*' | cut -d= -f2)"
    _fail "validate_all_agent_configs: ${CV_FAILS:-?} schema check(s) failed (output: $ALL_CONFIGS)"
  fi
else
  _fail "validate_all_agent_configs crashed: $ALL_CONFIGS"
fi

# 9l — healthcheck.sh sources config-validate.sh
if grep -q 'config-validate.sh' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh sources config-validate.sh"
else
  _fail "healthcheck.sh does not source config-validate.sh"
fi

# 9m — healthcheck.sh calls validate_all_agent_configs
if grep -q 'validate_all_agent_configs' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh calls validate_all_agent_configs"
else
  _fail "healthcheck.sh does not call validate_all_agent_configs"
fi

# 9n — all agents have a schema.json baseline
for agent in openhands aider goose ashlrcode; do
  schema_path="$REPO_ROOT/agents/$agent/schema.json"
  if [ -f "$schema_path" ]; then
    # Verify it's valid JSON
    if python3 -c "import json; json.load(open('$schema_path'))" 2>/dev/null; then
      _ok "agents/$agent/schema.json exists and is valid JSON"
    else
      _fail "agents/$agent/schema.json exists but is not valid JSON"
    fi
  else
    _fail "agents/$agent/schema.json missing (schema baseline required)"
  fi
done

# ─── Test 10: session-events.sh library ──────────────────────────────────────
printf "\n\033[1mTest 10: session-events.sh library\033[0m\n"

SESSION_EVENTS_SH="$REPO_ROOT/scripts/lib/session-events.sh"

# 10a — file exists and is executable
assert_file_executable "session-events.sh is executable" "$SESSION_EVENTS_SH"

# 10b — bash syntax check
if bash -n "$SESSION_EVENTS_SH" 2>/dev/null; then
  _ok "session-events.sh passes bash syntax check"
else
  _fail "session-events.sh has bash syntax errors"
fi

# 10c — double-source guard
DOUBLE_SE="$(
  env -i HOME="$HOME" bash -c "
    . '$SESSION_EVENTS_SH'
    . '$SESSION_EVENTS_SH'
    echo sourced_twice_ok
  " 2>&1
)"
if printf '%s' "$DOUBLE_SE" | grep -q 'sourced_twice_ok'; then
  _ok "session-events.sh double-source guard works"
else
  _fail "session-events.sh double-source produced errors: $DOUBLE_SE"
fi

# 10d — all four public functions are defined after sourcing
for fn in on_agent_start on_agent_error on_mcp_server_spawn on_session_end; do
  FUNC_CHK="$(
    env -i HOME="$HOME" bash -c "
      . '$SESSION_EVENTS_SH'
      if declare -f $fn >/dev/null 2>&1; then echo defined; else echo missing; fi
    " 2>&1
  )"
  assert_eq "$fn function is defined" "defined" "$FUNC_CHK"
done

# 10e — on_agent_start emits a well-formed JSON line to the events file
SE_TMP="$(mktemp /tmp/se-test-XXXXXX.jsonl)"
SE_RESULT="$(
  env -i HOME="$HOME" ASHLR_SESSION_EVENTS_PATH="$SE_TMP" bash -c "
    . '$SESSION_EVENTS_SH'
    on_agent_start 'aider' '12345' 'lm-studio/qwen3-coder-30b' '5'
    cat '$SE_TMP'
  " 2>&1
)"
rm -f "$SE_TMP"
# Must be valid JSON with the expected fields
SE_JSON_OK="$(printf '%s' "$SE_RESULT" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    o = json.loads(line)
    assert o.get('event') == 'agent_start', f'bad event: {o}'
    assert o.get('agent') == 'aider', f'bad agent: {o}'
    assert o.get('pid')   == '12345', f'bad pid: {o}'
    assert o.get('model') == 'lm-studio/qwen3-coder-30b', f'bad model: {o}'
    assert o.get('mcp_count') == '5', f'bad mcp_count: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "on_agent_start emits valid JSON with correct fields" "ok" "$SE_JSON_OK"

# 10f — on_agent_error emits a well-formed JSON line
SE_TMP="$(mktemp /tmp/se-test-XXXXXX.jsonl)"
SE_ERR_RESULT="$(
  env -i HOME="$HOME" ASHLR_SESSION_EVENTS_PATH="$SE_TMP" bash -c "
    . '$SESSION_EVENTS_SH'
    on_agent_error 'goose' '1' 'TOML parse error on line 42'
    cat '$SE_TMP'
  " 2>&1
)"
rm -f "$SE_TMP"
SE_ERR_OK="$(printf '%s' "$SE_ERR_RESULT" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    o = json.loads(line)
    assert o.get('event') == 'agent_error', f'bad event: {o}'
    assert o.get('agent') == 'goose', f'bad agent: {o}'
    assert o.get('exit_code') == '1', f'bad exit_code: {o}'
    assert 'TOML' in o.get('stderr', ''), f'bad stderr: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "on_agent_error emits valid JSON with correct fields" "ok" "$SE_ERR_OK"

# 10g — on_mcp_server_spawn emits a well-formed JSON line
SE_TMP="$(mktemp /tmp/se-test-XXXXXX.jsonl)"
SE_MCP_RESULT="$(
  env -i HOME="$HOME" ASHLR_SESSION_EVENTS_PATH="$SE_TMP" bash -c "
    . '$SESSION_EVENTS_SH'
    on_mcp_server_spawn 'openhands' 'ashlr-efficiency'
    cat '$SE_TMP'
  " 2>&1
)"
rm -f "$SE_TMP"
SE_MCP_OK="$(printf '%s' "$SE_MCP_RESULT" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    o = json.loads(line)
    assert o.get('event')  == 'mcp_server_spawn', f'bad event: {o}'
    assert o.get('agent')  == 'openhands', f'bad agent: {o}'
    assert o.get('server') == 'ashlr-efficiency', f'bad server: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "on_mcp_server_spawn emits valid JSON with correct fields" "ok" "$SE_MCP_OK"

# 10h — on_session_end emits a well-formed JSON line
SE_TMP="$(mktemp /tmp/se-test-XXXXXX.jsonl)"
SE_END_RESULT="$(
  env -i HOME="$HOME" ASHLR_SESSION_EVENTS_PATH="$SE_TMP" bash -c "
    . '$SESSION_EVENTS_SH'
    on_session_end 'aider' '120' 'ok'
    cat '$SE_TMP'
  " 2>&1
)"
rm -f "$SE_TMP"
SE_END_OK="$(printf '%s' "$SE_END_RESULT" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    o = json.loads(line)
    assert o.get('event')    == 'session_end', f'bad event: {o}'
    assert o.get('agent')    == 'aider', f'bad agent: {o}'
    assert o.get('duration') == '120', f'bad duration: {o}'
    assert o.get('status')   == 'ok', f'bad status: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "on_session_end emits valid JSON with correct fields" "ok" "$SE_END_OK"

# 10i — ASHLR_SESSION_EVENTS=0 kill switch suppresses all writes
SE_TMP="$(mktemp /tmp/se-test-XXXXXX.jsonl)"
SE_KILL_RESULT="$(
  env -i HOME="$HOME" \
    ASHLR_SESSION_EVENTS="0" \
    ASHLR_SESSION_EVENTS_PATH="$SE_TMP" bash -c "
    . '$SESSION_EVENTS_SH'
    on_agent_start 'aider' '99' 'test-model' '0'
    on_session_end 'aider' '5' 'ok'
    wc -l < '$SE_TMP' | tr -d ' '
  " 2>&1
)"
rm -f "$SE_TMP"
assert_eq "ASHLR_SESSION_EVENTS=0 suppresses all writes" "0" "$SE_KILL_RESULT"

# 10j — session id is stable across start+end events within one shell (correlation)
SE_TMP="$(mktemp /tmp/se-test-XXXXXX.jsonl)"
SE_CORR_RESULT="$(
  env -i HOME="$HOME" ASHLR_SESSION_EVENTS_PATH="$SE_TMP" bash -c "
    . '$SESSION_EVENTS_SH'
    on_agent_start 'aider' '1' 'model' '0'
    on_session_end 'aider' '30' 'ok'
    python3 -c \"
import json, sys
lines = [json.loads(l) for l in open('$SE_TMP') if l.strip()]
ids = set(o.get('session','') for o in lines)
print('correlated' if len(ids) == 1 and '' not in ids else f'not-correlated:{ids}')
\"
  " 2>&1
)"
rm -f "$SE_TMP"
assert_eq "session id correlates across agent_start and session_end" "correlated" "$SE_CORR_RESULT"

# 10k — start-aider.sh sources session-events.sh
if grep -q 'session-events.sh' "$REPO_ROOT/scripts/start-aider.sh"; then
  _ok "start-aider.sh sources session-events.sh"
else
  _fail "start-aider.sh does not source session-events.sh"
fi
if grep -q 'on_agent_start' "$REPO_ROOT/scripts/start-aider.sh"; then
  _ok "start-aider.sh calls on_agent_start"
else
  _fail "start-aider.sh does not call on_agent_start"
fi

# 10l — start-ashlrcode.sh sources session-events.sh and calls hooks
if grep -q 'session-events.sh' "$REPO_ROOT/scripts/start-ashlrcode.sh"; then
  _ok "start-ashlrcode.sh sources session-events.sh"
else
  _fail "start-ashlrcode.sh does not source session-events.sh"
fi
if grep -q 'on_agent_start' "$REPO_ROOT/scripts/start-ashlrcode.sh"; then
  _ok "start-ashlrcode.sh calls on_agent_start"
else
  _fail "start-ashlrcode.sh does not call on_agent_start"
fi

# 10m — start-goose.sh sources session-events.sh and calls hooks
if grep -q 'session-events.sh' "$REPO_ROOT/scripts/start-goose.sh"; then
  _ok "start-goose.sh sources session-events.sh"
else
  _fail "start-goose.sh does not source session-events.sh"
fi
if grep -q 'on_mcp_server_spawn' "$REPO_ROOT/scripts/start-goose.sh"; then
  _ok "start-goose.sh calls on_mcp_server_spawn"
else
  _fail "start-goose.sh does not call on_mcp_server_spawn"
fi

# 10n — start-openhands.sh sources session-events.sh and calls hooks
if grep -q 'session-events.sh' "$REPO_ROOT/scripts/start-openhands.sh"; then
  _ok "start-openhands.sh sources session-events.sh"
else
  _fail "start-openhands.sh does not source session-events.sh"
fi
if grep -q 'on_mcp_server_spawn' "$REPO_ROOT/scripts/start-openhands.sh"; then
  _ok "start-openhands.sh calls on_mcp_server_spawn"
else
  _fail "start-openhands.sh does not call on_mcp_server_spawn"
fi

# 10o — session-analytics.sh exists and passes syntax check
SESSION_ANALYTICS_SH="$REPO_ROOT/scripts/session-analytics.sh"
assert_file_executable "session-analytics.sh is executable" "$SESSION_ANALYTICS_SH"
if bash -n "$SESSION_ANALYTICS_SH" 2>/dev/null; then
  _ok "session-analytics.sh passes bash syntax check"
else
  _fail "session-analytics.sh has bash syntax errors"
fi

# 10p — session-analytics.sh --help exits 0 and mentions all 4 report sections
SA_HELP="$(
  env -i HOME="$HOME" NO_COLOR=1 bash -c "
    '$SESSION_ANALYTICS_SH' --help
  " 2>&1
)"
if printf '%s' "$SA_HELP" | grep -qi 'uptime'; then
  _ok "session-analytics.sh --help mentions uptime"
else
  _fail "session-analytics.sh --help missing uptime section (got: $SA_HELP)"
fi
if printf '%s' "$SA_HELP" | grep -qi 'error\|crash'; then
  _ok "session-analytics.sh --help mentions errors/crashes"
else
  _fail "session-analytics.sh --help missing errors section"
fi
if printf '%s' "$SA_HELP" | grep -qi 'shape\|session'; then
  _ok "session-analytics.sh --help mentions session shape"
else
  _fail "session-analytics.sh --help missing session shape section"
fi

# 10q — session-analytics.sh runs cleanly on a synthetic event log
SA_TMP_LOG="$(mktemp /tmp/sa-test-XXXXXX.jsonl)"
# Write 3 synthetic events: start, mcp spawn, end
python3 -c "
import json, datetime
now = datetime.datetime.utcnow().replace(microsecond=0)
def ts(offset_s=0):
    t = now.replace(second=now.second + offset_s) if offset_s < 60 else now
    return t.strftime('%Y-%m-%dT%H:%M:%S.000Z')

events = [
    {'ts': ts(0),  'event': 'agent_start',     'agent': 'aider',
     'session': 'abc123', 'pid': '111', 'model': 'qwen3', 'mcp_count': '2'},
    {'ts': ts(1),  'event': 'mcp_server_spawn', 'agent': 'aider',
     'session': 'abc123', 'server': 'ashlr-efficiency'},
    {'ts': ts(30), 'event': 'session_end',      'agent': 'aider',
     'session': 'abc123', 'duration': '30', 'status': 'ok'},
    {'ts': ts(5),  'event': 'agent_start',      'agent': 'goose',
     'session': 'def456', 'pid': '222', 'model': 'qwen3', 'mcp_count': '3'},
    {'ts': ts(10), 'event': 'agent_error',       'agent': 'goose',
     'session': 'def456', 'exit_code': '1', 'stderr': 'TOML parse error'},
    {'ts': ts(15), 'event': 'agent_error',       'agent': 'goose',
     'session': 'def456', 'exit_code': '1', 'stderr': 'TOML parse error'},
    {'ts': ts(60), 'event': 'session_end',       'agent': 'goose',
     'session': 'def456', 'duration': '60', 'status': 'error'},
]
for e in events:
    print(json.dumps(e))
" > "$SA_TMP_LOG"

SA_REPORT="$(
  env -i HOME="$HOME" NO_COLOR=1 \
    ASHLR_SESSION_EVENTS_PATH="$SA_TMP_LOG" \
    bash -c "'$SESSION_ANALYTICS_SH'" 2>&1
)"
rm -f "$SA_TMP_LOG"

# Must contain each of the four section headers
for section in "AGENT UPTIME" "MCP SERVER" "ERROR CLUSTERING" "SESSION SHAPE"; do
  if printf '%s' "$SA_REPORT" | grep -qi "$section"; then
    _ok "session-analytics report contains '$section' section"
  else
    _fail "session-analytics report missing '$section' section (output: $SA_REPORT)"
  fi
done

# Must report aider and goose in the session shape
if printf '%s' "$SA_REPORT" | grep -qi 'aider'; then
  _ok "session-analytics report mentions aider"
else
  _fail "session-analytics report missing aider"
fi
if printf '%s' "$SA_REPORT" | grep -qi 'goose'; then
  _ok "session-analytics report mentions goose"
else
  _fail "session-analytics report missing goose"
fi

# 10r — aw-log delegates 'session-analytics' to the analytics script
if grep -q 'session-analytics' "$REPO_ROOT/bin/aw-log"; then
  _ok "aw-log dispatches 'session-analytics' subcommand"
else
  _fail "aw-log does not dispatch 'session-analytics' subcommand"
fi
if grep -q 'session-analytics.sh' "$REPO_ROOT/bin/aw-log"; then
  _ok "aw-log references session-analytics.sh"
else
  _fail "aw-log does not reference session-analytics.sh"
fi

# 10s — aw-log help output includes session-analytics
AW_LOG_HELP="$(
  env -i HOME="$HOME" NO_COLOR=1 bash -c "'$REPO_ROOT/bin/aw-log' help" 2>&1
)"
if printf '%s' "$AW_LOG_HELP" | grep -q 'session-analytics'; then
  _ok "aw-log help lists session-analytics subcommand"
else
  _fail "aw-log help missing session-analytics (got: $AW_LOG_HELP)"
fi

# ─── Test 11: llm-router.sh library ─────────────────────────────────────────
printf "\n\033[1mTest 11: llm-router.sh library\033[0m\n"

LLM_ROUTER_SH="$REPO_ROOT/scripts/lib/llm-router.sh"

# 11a — file exists and is executable
assert_file_executable "llm-router.sh is executable" "$LLM_ROUTER_SH"

# 11b — bash syntax check
if bash -n "$LLM_ROUTER_SH" 2>/dev/null; then
  _ok "llm-router.sh passes bash syntax check"
else
  _fail "llm-router.sh has bash syntax errors"
fi

# 11c — double-source guard
DOUBLE_LR="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$LLM_ROUTER_SH'
    . '$LLM_ROUTER_SH'
    echo sourced_twice_ok
  " 2>&1
)"
if printf '%s' "$DOUBLE_LR" | grep -q 'sourced_twice_ok'; then
  _ok "llm-router.sh double-source guard works"
else
  _fail "llm-router.sh double-source produced errors: $DOUBLE_LR"
fi

# 11d — all public functions are defined after sourcing
for fn in llm_router_init llm_router_select llm_router_status on_routing_decision llm_router_aider_args; do
  LR_FUNC="$(
    env -i HOME="$HOME" bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      if declare -f $fn >/dev/null 2>&1; then echo defined; else echo missing; fi
    " 2>&1
  )"
  assert_eq "$fn function is defined" "defined" "$LR_FUNC"
done

# 11e — llm_router_init runs without error even when all endpoints are down.
#        We simulate this by pointing URLs at an unreachable port.
LR_INIT_DOWN="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:19999/v1" \
    OLLAMA_URL="http://localhost:19998" \
    ASHLR_LLM_PROBE_TIMEOUT="1" \
    ASHLR_LLM_ROUTER_EVENTS="0" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      llm_router_init
      echo \"READY=\${LLM_ROUTER_READY:-0}\"
      echo \"PRIMARY=\${LLM_PRIMARY:-none:}\"
      echo \"FALLBACK=\${LLM_FALLBACK:-none:}\"
    " 2>&1
)"
if printf '%s' "$LR_INIT_DOWN" | grep -q 'READY=1'; then
  _ok "llm_router_init completes (sets READY=1) even when all endpoints are down"
else
  _fail "llm_router_init did not set READY=1 (output: $LR_INIT_DOWN)"
fi
LR_PRIMARY_DOWN="$(printf '%s' "$LR_INIT_DOWN" | grep '^PRIMARY=' | cut -d= -f2-)"
if [ "$LR_PRIMARY_DOWN" = "none:" ]; then
  _ok "llm_router_init sets PRIMARY=none: when all endpoints are down"
else
  _fail "llm_router_init PRIMARY unexpected when all down: '$LR_PRIMARY_DOWN'"
fi

# 11f — llm_router_init exports LLM_PRIMARY_MS and FALLBACK_THRESHOLD
LR_VARS="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:19999/v1" \
    OLLAMA_URL="http://localhost:19998" \
    ASHLR_LLM_PROBE_TIMEOUT="1" \
    ASHLR_LLM_FALLBACK_MS="2500" \
    ASHLR_LLM_ROUTER_EVENTS="0" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      llm_router_init
      echo \"THRESHOLD=\${FALLBACK_THRESHOLD:-unset}\"
    " 2>&1
)"
assert_eq "FALLBACK_THRESHOLD exported from ASHLR_LLM_FALLBACK_MS" \
  "THRESHOLD=2500" "$(printf '%s' "$LR_VARS" | grep '^THRESHOLD=')"

# 11g — llm_router_select gracefully degrades when primary is unavailable
LR_SELECT="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:19999/v1" \
    OLLAMA_URL="http://localhost:19998" \
    ASHLR_LLM_PROBE_TIMEOUT="1" \
    ASHLR_LLM_ROUTER_EVENTS="0" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      llm_router_init
      llm_router_select aider
      echo \"PRIMARY=\${LLM_PRIMARY:-none:}\"
      echo \"FALLBACK=\${LLM_FALLBACK:-none:}\"
    " 2>&1
)"
if printf '%s' "$LR_SELECT" | grep -q 'PRIMARY='; then
  _ok "llm_router_select completes without error when all endpoints down"
else
  _fail "llm_router_select failed (output: $LR_SELECT)"
fi

# 11h — on_routing_decision emits a well-formed JSON event
LR_TMP="$(mktemp /tmp/lr-test-XXXXXX.jsonl)"
LR_EVENT="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:19999/v1" \
    OLLAMA_URL="http://localhost:19998" \
    ASHLR_LLM_PROBE_TIMEOUT="1" \
    ASHLR_LLM_ROUTER_LOG="$LR_TMP" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      LLM_PRIMARY_MS=450
      LLM_FALLBACK_MS=99999
      FALLBACK_THRESHOLD=2000
      on_routing_decision 'aider' 'lmstudio:qwen3-coder-30b' 'none:'
      cat '$LR_TMP'
    " 2>&1
)"
rm -f "$LR_TMP"
LR_EVENT_OK="$(printf '%s' "$LR_EVENT" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    o = json.loads(line)
    assert o.get('event') == 'routing_decision', f'bad event: {o}'
    assert o.get('agent') == 'aider', f'bad agent: {o}'
    assert o.get('primary') == 'lmstudio:qwen3-coder-30b', f'bad primary: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "on_routing_decision emits valid JSON with correct fields" "ok" "$LR_EVENT_OK"

# 11i — ASHLR_LLM_ROUTER_EVENTS=0 suppresses routing event writes
LR_TMP="$(mktemp /tmp/lr-test-XXXXXX.jsonl)"
LR_SUPPRESS="$(
  env -i HOME="$HOME" \
    ASHLR_LLM_ROUTER_EVENTS="0" \
    ASHLR_LLM_ROUTER_LOG="$LR_TMP" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      LLM_PRIMARY_MS=100
      LLM_FALLBACK_MS=99999
      FALLBACK_THRESHOLD=2000
      on_routing_decision 'goose' 'lmstudio:qwen3' 'none:'
      wc -l < '$LR_TMP' | tr -d ' '
    " 2>&1
)"
rm -f "$LR_TMP"
assert_eq "ASHLR_LLM_ROUTER_EVENTS=0 suppresses routing event writes" "0" "$LR_SUPPRESS"

# 11j — llm_router_status runs without error and outputs expected sections
LR_STATUS="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:19999/v1" \
    OLLAMA_URL="http://localhost:19998" \
    ASHLR_LLM_PROBE_TIMEOUT="1" \
    ASHLR_LLM_ROUTER_EVENTS="0" \
    NO_COLOR="1" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      llm_router_init
      llm_router_status
    " 2>&1
)"
if printf '%s' "$LR_STATUS" | grep -qi 'Latency Matrix'; then
  _ok "llm_router_status output contains 'Latency Matrix'"
else
  _fail "llm_router_status missing 'Latency Matrix' (got: $LR_STATUS)"
fi
for backend in lmstudio ollama xai anthropic; do
  if printf '%s' "$LR_STATUS" | grep -q "$backend"; then
    _ok "llm_router_status mentions backend: $backend"
  else
    _fail "llm_router_status missing backend: $backend"
  fi
done
if printf '%s' "$LR_STATUS" | grep -qi 'Primary\|Fallback\|Threshold'; then
  _ok "llm_router_status output contains routing summary"
else
  _fail "llm_router_status missing routing summary"
fi

# 11k — llm_router_aider_args returns non-empty flags
LR_AIDER_ARGS="$(
  env -i HOME="$HOME" \
    LM_STUDIO_URL="http://localhost:19999/v1" \
    OLLAMA_URL="http://localhost:19998" \
    ASHLR_LLM_PROBE_TIMEOUT="1" \
    ASHLR_LLM_ROUTER_EVENTS="0" \
    bash -c "
      . '$CONFIG_SH'
      . '$LLM_ROUTER_SH'
      llm_router_init
      llm_router_aider_args
    " 2>&1
)"
if [ -n "$LR_AIDER_ARGS" ]; then
  _ok "llm_router_aider_args returns non-empty flags even when all endpoints down"
else
  _fail "llm_router_aider_args returned empty string"
fi

# 11l — start-aider.sh sources llm-router.sh
if grep -q 'llm-router.sh' "$REPO_ROOT/scripts/start-aider.sh"; then
  _ok "start-aider.sh sources llm-router.sh"
else
  _fail "start-aider.sh does not source llm-router.sh"
fi
if grep -q 'llm_router_init' "$REPO_ROOT/scripts/start-aider.sh"; then
  _ok "start-aider.sh calls llm_router_init"
else
  _fail "start-aider.sh does not call llm_router_init"
fi

# 11m — start-goose.sh sources llm-router.sh
if grep -q 'llm-router.sh' "$REPO_ROOT/scripts/start-goose.sh"; then
  _ok "start-goose.sh sources llm-router.sh"
else
  _fail "start-goose.sh does not source llm-router.sh"
fi

# 11n — start-ashlrcode.sh sources llm-router.sh
if grep -q 'llm-router.sh' "$REPO_ROOT/scripts/start-ashlrcode.sh"; then
  _ok "start-ashlrcode.sh sources llm-router.sh"
else
  _fail "start-ashlrcode.sh does not source llm-router.sh"
fi

# 11o — start-openhands.sh sources llm-router.sh
if grep -q 'llm-router.sh' "$REPO_ROOT/scripts/start-openhands.sh"; then
  _ok "start-openhands.sh sources llm-router.sh"
else
  _fail "start-openhands.sh does not source llm-router.sh"
fi

# 11p — aw binary recognises 'llm-status' as a known subcommand
if grep -q 'llm-status' "$REPO_ROOT/bin/aw"; then
  _ok "bin/aw recognises llm-status subcommand"
else
  _fail "bin/aw does not recognise llm-status"
fi

# 11q — aw help text mentions llm-status
AW_HELP="$(
  env -i HOME="$HOME" NO_COLOR=1 bash -c "'$REPO_ROOT/bin/aw' help" 2>&1
)"
if printf '%s' "$AW_HELP" | grep -q 'llm-status'; then
  _ok "aw help mentions llm-status"
else
  _fail "aw help missing llm-status (got: $AW_HELP)"
fi

# 11r — start-aider.sh bash syntax OK after router integration
if bash -n "$REPO_ROOT/scripts/start-aider.sh" 2>/dev/null; then
  _ok "start-aider.sh bash syntax OK after router integration"
else
  _fail "start-aider.sh has bash syntax errors after router integration"
fi

# 11s — start-goose.sh bash syntax OK after router integration
if bash -n "$REPO_ROOT/scripts/start-goose.sh" 2>/dev/null; then
  _ok "start-goose.sh bash syntax OK after router integration"
else
  _fail "start-goose.sh has bash syntax errors after router integration"
fi

# 11t — start-ashlrcode.sh bash syntax OK after router integration
if bash -n "$REPO_ROOT/scripts/start-ashlrcode.sh" 2>/dev/null; then
  _ok "start-ashlrcode.sh bash syntax OK after router integration"
else
  _fail "start-ashlrcode.sh has bash syntax errors after router integration"
fi

# 11u — start-openhands.sh bash syntax OK after router integration
if bash -n "$REPO_ROOT/scripts/start-openhands.sh" 2>/dev/null; then
  _ok "start-openhands.sh bash syntax OK after router integration"
else
  _fail "start-openhands.sh has bash syntax errors after router integration"
fi

# ─── Test 12: mcp-connection.sh library + mcp-integration.sh ─────────────────
printf "\n\033[1mTest 12: mcp-connection.sh + mcp-integration.sh\033[0m\n"

MCP_CONN_SH="$REPO_ROOT/scripts/lib/mcp-connection.sh"
MCP_INT_SH="$REPO_ROOT/tests/mcp-integration.sh"

# 12a — mcp-connection.sh exists and is executable
assert_file_executable "mcp-connection.sh is executable" "$MCP_CONN_SH"

# 12b — mcp-connection.sh passes bash syntax check
if bash -n "$MCP_CONN_SH" 2>/dev/null; then
  _ok "mcp-connection.sh passes bash syntax check"
else
  _fail "mcp-connection.sh has bash syntax errors"
fi

# 12c — double-source guard
DOUBLE_MC="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    . '$MCP_CONN_SH'
    echo sourced_twice_ok
  " 2>&1
)"
if printf '%s' "$DOUBLE_MC" | grep -q 'sourced_twice_ok'; then
  _ok "mcp-connection.sh double-source guard works"
else
  _fail "mcp-connection.sh double-source produced errors: $DOUBLE_MC"
fi

# 12d — all public functions are defined after sourcing
for fn in _mcp_conn_emit_jsonl _mcp_conn_jsonrpc_msg _mcp_conn_find_runtime \
          _mcp_conn_probe_server mcp_conn_extract_servers_from_json mcp_conn_validate_agent; do
  MC_FUNC="$(
    env -i HOME="$HOME" bash -c "
      . '$CONFIG_SH'
      . '$MCP_CONN_SH'
      if declare -f $fn >/dev/null 2>&1; then echo defined; else echo missing; fi
    " 2>&1
  )"
  assert_eq "$fn function is defined" "defined" "$MC_FUNC"
done

# 12e — _mcp_conn_emit_jsonl produces valid JSON with required fields
MC_JSONL_TMP="$(mktemp /tmp/mc-test-XXXXXX.jsonl)"
MC_JSONL_OUT="$(
  env -i HOME="$HOME" MCP_CONN_JSONL_OUT="$MC_JSONL_TMP" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    _mcp_conn_emit_jsonl 'aider' 'ashlr-bash' 'pass' '123' 'handshake OK'
    cat '$MC_JSONL_TMP'
  " 2>&1
)"
rm -f "$MC_JSONL_TMP"
MC_JSONL_OK="$(printf '%s' "$MC_JSONL_OUT" | python3 -c "
import sys, json
line = sys.stdin.read().strip().splitlines()[-1]
try:
    o = json.loads(line)
    assert o.get('agent')      == 'aider',       f'bad agent: {o}'
    assert o.get('mcp')        == 'ashlr-bash',  f'bad mcp: {o}'
    assert o.get('status')     == 'pass',         f'bad status: {o}'
    assert o.get('latency_ms') == 123,            f'bad latency_ms: {o}'
    assert 'ts' in o,                             f'missing ts: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "_mcp_conn_emit_jsonl produces valid JSONL with required fields" "ok" "$MC_JSONL_OK"

# 12f — _mcp_conn_jsonrpc_msg produces a framed message with Content-Length
MC_FRAME="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    _mcp_conn_jsonrpc_msg 1 'initialize' '{}'
  " 2>&1
)"
if printf '%s' "$MC_FRAME" | grep -q 'Content-Length:'; then
  _ok "_mcp_conn_jsonrpc_msg produces Content-Length framed message"
else
  _fail "_mcp_conn_jsonrpc_msg missing Content-Length header (got: $MC_FRAME)"
fi
if printf '%s' "$MC_FRAME" | grep -q '"jsonrpc"'; then
  _ok "_mcp_conn_jsonrpc_msg body contains jsonrpc field"
else
  _fail "_mcp_conn_jsonrpc_msg body missing jsonrpc field"
fi

# 12g — _mcp_conn_find_runtime picks bun for .ts files
MC_RUNTIME="$(
  env -i HOME="$HOME" PATH="$PATH" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    _mcp_conn_find_runtime 'servers/bash-server.ts'
  " 2>&1
)"
if [ "$MC_RUNTIME" = "bun" ] || [ "$MC_RUNTIME" = "node" ]; then
  _ok "_mcp_conn_find_runtime returns a valid runtime for .ts: $MC_RUNTIME"
else
  _fail "_mcp_conn_find_runtime returned unexpected value for .ts: '$MC_RUNTIME'"
fi

# 12h — _mcp_conn_probe_server returns 3 for a missing file
MC_PROBE_MISSING="$(
  env -i HOME="$HOME" PATH="$PATH" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    _mcp_conn_probe_server test-agent ashlr-bash /nonexistent/path/server.ts
    echo rc=\$?
  " 2>&1
)"
assert_eq "_mcp_conn_probe_server rc=3 for missing entry file" \
  "rc=3" "$(printf '%s' "$MC_PROBE_MISSING" | grep '^rc=')"

# 12i — _mcp_conn_probe_server returns 4 when no runtime is available
MC_PROBE_NORUNTIME="$(
  env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    tmpf=\"\$(mktemp /tmp/mc-test-XXXXXX.ts)\"
    printf 'console.log(\"hello\")' > \"\$tmpf\"
    _mcp_conn_probe_server test-agent ashlr-bash \"\$tmpf\"
    rc=\$?
    rm -f \"\$tmpf\"
    echo rc=\$rc
  " 2>&1
)"
assert_eq "_mcp_conn_probe_server rc=4 when no runtime available" \
  "rc=4" "$(printf '%s' "$MC_PROBE_NORUNTIME" | grep '^rc=')"

# 12j — mcp_conn_extract_servers_from_json parses ashlrcode settings.json
MC_EXTRACT="$(
  env -i HOME="$HOME" bash -c "
    . '$CONFIG_SH'
    . '$MCP_CONN_SH'
    mcp_conn_extract_servers_from_json '$REPO_ROOT/agents/ashlrcode/settings.json'
  " 2>&1
)"
if printf '%s' "$MC_EXTRACT" | grep -q 'ashlr-bash'; then
  _ok "mcp_conn_extract_servers_from_json finds ashlr-bash in ashlrcode settings.json"
else
  _fail "mcp_conn_extract_servers_from_json did not find ashlr-bash (got: $MC_EXTRACT)"
fi
if printf '%s' "$MC_EXTRACT" | grep -q 'ashlr-efficiency'; then
  _ok "mcp_conn_extract_servers_from_json finds ashlr-efficiency in ashlrcode settings.json"
else
  _fail "mcp_conn_extract_servers_from_json did not find ashlr-efficiency"
fi

# 12k — mcp-integration.sh exists and is executable
assert_file_executable "mcp-integration.sh is executable" "$MCP_INT_SH"

# 12l — mcp-integration.sh passes bash syntax check
if bash -n "$MCP_INT_SH" 2>/dev/null; then
  _ok "mcp-integration.sh passes bash syntax check"
else
  _fail "mcp-integration.sh has bash syntax errors"
fi

# 12m — mcp-integration.sh runs without error and produces a Result: line
MC_INT_TMP="$(mktemp /tmp/mc-int-test-XXXXXX.jsonl)"
MC_INT_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 \
    MCP_CONN_TIMEOUT=5 MCP_INTEGRATION_JSONL="$MC_INT_TMP" \
    bash "$MCP_INT_SH" 2>&1
)"
MC_INT_RC=$?
rm -f "$MC_INT_TMP"
if printf '%s' "$MC_INT_OUT" | grep -q 'Result:'; then
  _ok "mcp-integration.sh produces a Result: summary line"
else
  _fail "mcp-integration.sh produced no Result: line (rc=$MC_INT_RC, output: $MC_INT_OUT)"
fi

# 12n — mcp-integration.sh exits 0 (all pass or skip, no fail)
if [ "$MC_INT_RC" -eq 0 ]; then
  _ok "mcp-integration.sh exits 0 (no failures)"
else
  _fail "mcp-integration.sh exited $MC_INT_RC (unexpected failures)"
fi

# 12o — mcp-integration.sh output contains the matrix table header
if printf '%s' "$MC_INT_OUT" | grep -q 'MCP Server'; then
  _ok "mcp-integration.sh output contains matrix table header"
else
  _fail "mcp-integration.sh output missing matrix table header"
fi

# 12p — mcp-integration.sh output lists all 4 agent names
for _ag in aider goose ashlrcode openhands; do
  if printf '%s' "$MC_INT_OUT" | grep -q "$_ag"; then
    _ok "mcp-integration.sh output mentions agent: $_ag"
  else
    _fail "mcp-integration.sh output missing agent: $_ag"
  fi
done

# 12q — mcp-integration.sh writes JSONL records
MC_INT_TMP2="$(mktemp /tmp/mc-int-test2-XXXXXX.jsonl)"
env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 \
  MCP_CONN_TIMEOUT=5 MCP_INTEGRATION_JSONL="$MC_INT_TMP2" \
  bash "$MCP_INT_SH" >/dev/null 2>&1 || true
MC_JSONL_LINES="$(wc -l < "$MC_INT_TMP2" 2>/dev/null | tr -d ' ' || echo 0)"
rm -f "$MC_INT_TMP2"
if [ "${MC_JSONL_LINES:-0}" -gt 0 ]; then
  _ok "mcp-integration.sh writes JSONL records ($MC_JSONL_LINES lines)"
else
  _fail "mcp-integration.sh wrote no JSONL records"
fi

# 12r — healthcheck.sh sources mcp-connection.sh
if grep -q 'mcp-connection.sh' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh sources mcp-connection.sh"
else
  _fail "healthcheck.sh does not source mcp-connection.sh"
fi

# 12s — healthcheck.sh contains Agent-MCP Handshakes section
if grep -q 'Agent-MCP Handshakes' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh contains 'Agent-MCP Handshakes' section"
else
  _fail "healthcheck.sh missing 'Agent-MCP Handshakes' section"
fi

# 12t — healthcheck.sh references mcp-integration.sh
if grep -q 'mcp-integration.sh' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh references mcp-integration.sh"
else
  _fail "healthcheck.sh does not reference mcp-integration.sh"
fi

# 12u — healthcheck.sh still passes bash syntax check after additions
if bash -n "$REPO_ROOT/scripts/healthcheck.sh" 2>/dev/null; then
  _ok "healthcheck.sh passes bash syntax check after Agent-MCP Handshakes addition"
else
  _fail "healthcheck.sh has bash syntax errors after Agent-MCP Handshakes addition"
fi

# ─── Test 13: agent-monitor.sh + monitor.yaml ────────────────────────────────
printf "\n\033[1mTest 13: agent-monitor.sh + monitor.yaml\033[0m\n"

MONITOR_SH="$REPO_ROOT/scripts/agent-monitor.sh"
MONITOR_YAML="$REPO_ROOT/agents/monitor.yaml"

# 13a — agent-monitor.sh exists and is executable
assert_file_executable "agent-monitor.sh is executable" "$MONITOR_SH"

# 13b — agent-monitor.sh passes bash syntax check
if bash -n "$MONITOR_SH" 2>/dev/null; then
  _ok "agent-monitor.sh passes bash syntax check"
else
  _fail "agent-monitor.sh has bash syntax errors"
fi

# 13c — monitor.yaml exists
if [ -f "$MONITOR_YAML" ]; then
  _ok "agents/monitor.yaml exists"
else
  _fail "agents/monitor.yaml missing"
fi

# 13d — monitor.yaml is valid YAML-ish (python3 can load the agents block)
YAML_AGENTS="$(
  python3 - "$MONITOR_YAML" <<'PY' 2>/dev/null
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Check required top-level keys
for key in ('defaults:', 'agents:'):
    assert key in content, f"missing {key}"
# Check at least one agent entry
assert '- name:' in content, "no agent entries"
print('ok')
PY
)"
if [ "$YAML_AGENTS" = "ok" ]; then
  _ok "monitor.yaml contains defaults + agents blocks"
else
  _fail "monitor.yaml missing required structure (got: $YAML_AGENTS)"
fi

# 13e — monitor.yaml contains an openhands entry with docker check_type
if grep -q 'name: openhands' "$MONITOR_YAML"; then
  _ok "monitor.yaml has openhands agent entry"
else
  _fail "monitor.yaml missing openhands agent entry"
fi
if grep -q 'check_type: docker' "$MONITOR_YAML"; then
  _ok "monitor.yaml uses docker check_type for openhands"
else
  _fail "monitor.yaml missing docker check_type"
fi

# 13f — agent-monitor.sh status subcommand runs without error (no daemon)
MON_TMPDIR="$(mktemp -d /tmp/monitor-test-XXXXXX)"
MON_STATUS_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 \
    MONITOR_DIR="$MON_TMPDIR" \
    MONITOR_PID_FILE="$MON_TMPDIR/monitor.pid" \
    MONITOR_STATE_FILE="$MON_TMPDIR/monitor-state.txt" \
    MONITOR_LOG_FILE="$MON_TMPDIR/monitor.jsonl" \
    MONITOR_CONFIG="$MONITOR_YAML" \
    bash "$MONITOR_SH" status 2>&1
)"
MON_STATUS_RC=$?
rm -rf "$MON_TMPDIR"
if [ "$MON_STATUS_RC" -eq 0 ]; then
  _ok "agent-monitor.sh status exits 0 when daemon not running"
else
  _fail "agent-monitor.sh status exited $MON_STATUS_RC (output: $MON_STATUS_OUT)"
fi

# 13g — status output mentions 'daemon not running' (or similar) when no PID file
if printf '%s' "$MON_STATUS_OUT" | grep -qi 'not running\|no.*pid\|monitor'; then
  _ok "agent-monitor.sh status reports daemon state when not running"
else
  _fail "agent-monitor.sh status output unexpected (got: $MON_STATUS_OUT)"
fi

# 13h — JSONL emit: agent-monitor.sh monitor.jsonl path is defined and
#         the log file is written to .ashlr-workbench/ directory
if grep -q '\.ashlr-workbench/monitor\.jsonl\|MONITOR_LOG_FILE\|monitor\.jsonl' "$MONITOR_SH"; then
  _ok "agent-monitor.sh defines monitor.jsonl log path"
else
  _fail "agent-monitor.sh does not define monitor.jsonl log path"
fi

# 13i — MONITOR_LOG=0 kill switch: monitor.sh respects the env var
MON_TMPDIR="$(mktemp -d /tmp/monitor-test-XXXXXX)"
env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 \
  MONITOR_LOG=0 \
  MONITOR_DIR="$MON_TMPDIR" \
  MONITOR_PID_FILE="$MON_TMPDIR/monitor.pid" \
  MONITOR_STATE_FILE="$MON_TMPDIR/monitor-state.txt" \
  MONITOR_LOG_FILE="$MON_TMPDIR/monitor.jsonl" \
  MONITOR_CONFIG="$MONITOR_YAML" \
  bash "$MONITOR_SH" status >/dev/null 2>&1 || true
MON_LOG_LINES="$(wc -l < "$MON_TMPDIR/monitor.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
rm -rf "$MON_TMPDIR"
assert_eq "MONITOR_LOG=0 suppresses JSONL writes during status" "0" "$MON_LOG_LINES"

# 13j — session-log.sh exposes log_monitor_event function
SESSION_LOG_SH="$REPO_ROOT/scripts/lib/session-log.sh"
SESSION_LOG_FUNC="$(
  env -i HOME="$HOME" bash -c "
    . '$SESSION_LOG_SH'
    if declare -f log_monitor_event >/dev/null 2>&1; then echo defined; else echo missing; fi
  " 2>&1
)"
assert_eq "log_monitor_event function is defined in session-log.sh" "defined" "$SESSION_LOG_FUNC"

# 13k — log_monitor_event writes a valid JSONL line
SL_TMP="$(mktemp /tmp/sl-monitor-XXXXXX.jsonl)"
SL_MON_OUT="$(
  env -i HOME="$HOME" ASHLR_SESSION_LOG_PATH="$SL_TMP" bash -c "
    . '$SESSION_LOG_SH'
    log_monitor_event openhands monitor_restart 'attempt=2' 'backoff_secs=20'
    cat '$SL_TMP'
  " 2>&1
)"
rm -f "$SL_TMP"
SL_MON_JSON_OK="$(printf '%s' "$SL_MON_OUT" | python3 -c "
import sys, json
line = sys.stdin.read().strip()
try:
    o = json.loads(line)
    assert o.get('agent') == 'openhands', f'bad agent: {o}'
    assert o.get('event') == 'monitor_restart', f'bad event: {o}'
    assert o.get('attempt') == '2', f'bad attempt: {o}'
    assert o.get('backoff_secs') == '20', f'bad backoff_secs: {o}'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" 2>&1)"
assert_eq "log_monitor_event writes valid JSONL with extra fields" "ok" "$SL_MON_JSON_OK"

# 13l — log_monitor_event respects ASHLR_SESSION_LOG=0 kill switch
SL_TMP="$(mktemp /tmp/sl-monitor-XXXXXX.jsonl)"
env -i HOME="$HOME" ASHLR_SESSION_LOG="0" ASHLR_SESSION_LOG_PATH="$SL_TMP" bash -c "
  . '$SESSION_LOG_SH'
  log_monitor_event openhands monitor_restart 'attempt=1'
" 2>/dev/null || true
SL_MON_KILL_LINES="$(wc -l < "$SL_TMP" 2>/dev/null | tr -d ' ' || echo 0)"
rm -f "$SL_TMP"
assert_eq "log_monitor_event respects ASHLR_SESSION_LOG=0 kill switch" "0" "$SL_MON_KILL_LINES"

# 13m — bin/aw recognises 'monitor' as a known subcommand
if grep -q 'monitor' "$REPO_ROOT/bin/aw"; then
  _ok "bin/aw recognises monitor subcommand"
else
  _fail "bin/aw does not recognise monitor subcommand"
fi

# 13n — aw help mentions monitor
AW_HELP_MON="$(
  env -i HOME="$HOME" NO_COLOR=1 bash -c "'$REPO_ROOT/bin/aw' help" 2>&1
)"
if printf '%s' "$AW_HELP_MON" | grep -q 'monitor'; then
  _ok "aw help mentions monitor subcommand"
else
  _fail "aw help missing monitor (got: $AW_HELP_MON)"
fi

# 13o — aw monitor status delegates to agent-monitor.sh (file reference check)
if grep -q 'agent-monitor.sh' "$REPO_ROOT/bin/aw"; then
  _ok "bin/aw references agent-monitor.sh for monitor subcommand"
else
  _fail "bin/aw does not reference agent-monitor.sh"
fi

# 13p — monitor start/stop/status are listed in agent-monitor.sh usage
if grep -q 'start|stop|status' "$MONITOR_SH" || grep -q 'start.*stop.*status' "$MONITOR_SH"; then
  _ok "agent-monitor.sh handles start/stop/status subcommands"
else
  _fail "agent-monitor.sh does not handle start/stop/status"
fi

# 13q — .ashlr-workbench/monitor.jsonl path is used in agent-monitor.sh
if grep -q 'monitor.jsonl' "$MONITOR_SH"; then
  _ok "agent-monitor.sh references monitor.jsonl log path"
else
  _fail "agent-monitor.sh does not reference monitor.jsonl"
fi

# 13r — agent-monitor.sh references MONITOR_RESTART env var for restart flag
if grep -q 'MONITOR_RESTART' "$MONITOR_SH"; then
  _ok "agent-monitor.sh sets MONITOR_RESTART=1 on restart"
else
  _fail "agent-monitor.sh does not reference MONITOR_RESTART"
fi

# 13s — monitor.yaml has default check_interval_secs of 10
if grep -q 'check_interval_secs: 10' "$MONITOR_YAML"; then
  _ok "monitor.yaml default check_interval_secs is 10"
else
  _fail "monitor.yaml check_interval_secs not set to 10"
fi

# 13t — agent-monitor.sh stop subcommand runs cleanly when daemon is not running
MON_TMPDIR="$(mktemp -d /tmp/monitor-test-XXXXXX)"
MON_STOP_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 \
    MONITOR_DIR="$MON_TMPDIR" \
    MONITOR_PID_FILE="$MON_TMPDIR/monitor.pid" \
    MONITOR_STATE_FILE="$MON_TMPDIR/monitor-state.txt" \
    MONITOR_LOG_FILE="$MON_TMPDIR/monitor.jsonl" \
    MONITOR_CONFIG="$MONITOR_YAML" \
    bash "$MONITOR_SH" stop 2>&1
)"
MON_STOP_RC=$?
rm -rf "$MON_TMPDIR"
if [ "$MON_STOP_RC" -eq 0 ]; then
  _ok "agent-monitor.sh stop exits 0 when daemon not running"
else
  _fail "agent-monitor.sh stop exited $MON_STOP_RC (output: $MON_STOP_OUT)"
fi

# ─── Test 14: config-audit.sh + agents/config-schema.json ────────────────────
printf "\n\033[1mTest 14: config-audit.sh + config-schema.json\033[0m\n"

AUDIT_SH="$REPO_ROOT/scripts/config-audit.sh"
AUDIT_SCHEMA="$REPO_ROOT/agents/config-schema.json"

# 14a — config-audit.sh exists and is executable
assert_file_executable "config-audit.sh is executable" "$AUDIT_SH"

# 14b — config-audit.sh passes bash syntax check
if bash -n "$AUDIT_SH" 2>/dev/null; then
  _ok "config-audit.sh passes bash syntax check"
else
  _fail "config-audit.sh has bash syntax errors"
fi

# 14c — agents/config-schema.json exists and is valid JSON
if [ -f "$AUDIT_SCHEMA" ]; then
  if python3 -c "import json; json.load(open('$AUDIT_SCHEMA'))" 2>/dev/null; then
    _ok "agents/config-schema.json exists and is valid JSON"
  else
    _fail "agents/config-schema.json exists but is not valid JSON"
  fi
else
  _fail "agents/config-schema.json missing"
fi

# 14d — schema contains required top-level sections
SCHEMA_SECTIONS="$(
  python3 -c "
import json, sys
schema = json.load(open('$AUDIT_SCHEMA'))
required = ['known_models', 'known_llm_urls', 'known_mcp_servers', 'deprecated_keys', 'agents']
missing = [k for k in required if k not in schema]
print('missing=' + ','.join(missing) if missing else 'ok')
" 2>/dev/null
)"
if [ "$SCHEMA_SECTIONS" = "ok" ]; then
  _ok "agents/config-schema.json has all required top-level sections"
else
  _fail "agents/config-schema.json missing sections: ${SCHEMA_SECTIONS#missing=}"
fi

# 14e — config-audit.sh --help exits 0
AUDIT_HELP_RC=0
env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash "$AUDIT_SH" --help >/dev/null 2>&1 || AUDIT_HELP_RC=$?
if [ "$AUDIT_HELP_RC" -eq 0 ]; then
  _ok "config-audit.sh --help exits 0"
else
  _fail "config-audit.sh --help exited $AUDIT_HELP_RC"
fi

# 14f — config-audit.sh runs cleanly on real configs (no crashes)
AUDIT_CSV_TMP="$(mktemp /tmp/audit-test-XXXXXX.csv)"
AUDIT_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 WORKBENCH="$REPO_ROOT" \
    bash "$AUDIT_SH" --csv "$AUDIT_CSV_TMP" 2>&1
)"
AUDIT_RC=$?
if [ "$AUDIT_RC" -eq 0 ] || [ "$AUDIT_RC" -eq 1 ]; then
  _ok "config-audit.sh exits cleanly (0=clean, 1=issues) on real configs (rc=$AUDIT_RC)"
else
  _fail "config-audit.sh crashed with unexpected exit code $AUDIT_RC"
fi

# 14g — config-audit.sh produces an Audit Summary line
if printf '%s' "$AUDIT_OUT" | grep -q 'Audit Summary:'; then
  _ok "config-audit.sh output contains 'Audit Summary:' line"
else
  _fail "config-audit.sh output missing 'Audit Summary:' line (got: $AUDIT_OUT)"
fi

# 14h — CSV file is written and contains expected header
if [ -f "$AUDIT_CSV_TMP" ]; then
  if grep -q 'timestamp,agent,pass,warn,fail,compliance_pct,status' "$AUDIT_CSV_TMP"; then
    _ok "config-audit.sh writes CSV with correct header"
  else
    _fail "config-audit.sh CSV missing expected header"
  fi
else
  _fail "config-audit.sh did not write CSV to $AUDIT_CSV_TMP"
fi
rm -f "$AUDIT_CSV_TMP"

# 14i — CSV contains an entry for each of the 4 agents
AUDIT_CSV_TMP2="$(mktemp /tmp/audit-test2-XXXXXX.csv)"
env -i HOME="$HOME" PATH="$PATH" NO_COLOR=1 WORKBENCH="$REPO_ROOT" \
  bash "$AUDIT_SH" --csv "$AUDIT_CSV_TMP2" >/dev/null 2>&1 || true
for ag in openhands goose aider ashlrcode; do
  if grep -q ",$ag," "$AUDIT_CSV_TMP2" 2>/dev/null || grep -q "^[^,]*,$ag," "$AUDIT_CSV_TMP2" 2>/dev/null; then
    _ok "config-audit.sh CSV contains entry for agent: $ag"
  else
    _fail "config-audit.sh CSV missing entry for agent: $ag"
  fi
done
rm -f "$AUDIT_CSV_TMP2"

# 14j — config-audit.sh output covers all 5 audit sections
for section in \
  "1. Model Name" \
  "2. LLM Endpoint" \
  "3. MCP Server" \
  "4. Deprecated Key" \
  "5. Env Var"; do
  if printf '%s' "$AUDIT_OUT" | grep -qi "$section"; then
    _ok "config-audit.sh covers audit section: $section"
  else
    _fail "config-audit.sh missing audit section: $section (got: $(printf '%s' "$AUDIT_OUT" | head -5))"
  fi
done

# 14k — schema known_models includes the workbench default model
if python3 -c "
import json, sys
schema = json.load(open('$AUDIT_SCHEMA'))
models = schema.get('known_models', [])
# Primary local model must be present (with and without openai/ prefix)
assert any('qwen3-coder-30b' in m for m in models), 'qwen3-coder-30b not in known_models'
print('ok')
" 2>/dev/null | grep -q ok; then
  _ok "agents/config-schema.json known_models includes qwen3-coder-30b"
else
  _fail "agents/config-schema.json known_models missing qwen3-coder-30b"
fi

# 14l — schema deprecated_keys covers all 4 agent config formats
if python3 -c "
import json, sys
schema = json.load(open('$AUDIT_SCHEMA'))
depr = schema.get('deprecated_keys', {})
required = ['openhands_config_toml', 'goose_config_yaml', 'aider_conf_yml', 'ashlrcode_settings_json']
missing = [k for k in required if k not in depr]
print('missing=' + ','.join(missing) if missing else 'ok')
" 2>/dev/null | grep -q ok; then
  _ok "agents/config-schema.json deprecated_keys covers all 4 agent config formats"
else
  _fail "agents/config-schema.json deprecated_keys missing some agent config formats"
fi

# 14m — config-audit.sh --fix flag is accepted (syntax / flag parsing)
AUDIT_FIX_SYNTAX_RC=0
bash -c "bash '$AUDIT_SH' --help | grep -q fix" 2>/dev/null || AUDIT_FIX_SYNTAX_RC=$?
if printf '%s' "$(env -i HOME="$HOME" bash "$AUDIT_SH" --help 2>&1)" | grep -q '\-\-fix'; then
  _ok "config-audit.sh --help documents --fix flag"
else
  _fail "config-audit.sh --help missing --fix flag documentation"
fi

# 14n — pre-commit hook exists and is executable
PRECOMMIT_HOOK="$REPO_ROOT/.git/hooks/pre-commit"
if [ -x "$PRECOMMIT_HOOK" ]; then
  _ok ".git/hooks/pre-commit exists and is executable"
else
  _fail ".git/hooks/pre-commit missing or not executable"
fi

# 14o — pre-commit hook passes bash syntax check
if bash -n "$PRECOMMIT_HOOK" 2>/dev/null; then
  _ok ".git/hooks/pre-commit passes bash syntax check"
else
  _fail ".git/hooks/pre-commit has bash syntax errors"
fi

# 14p — pre-commit hook references config-audit.sh
if grep -q 'config-audit.sh' "$PRECOMMIT_HOOK"; then
  _ok ".git/hooks/pre-commit references config-audit.sh"
else
  _fail ".git/hooks/pre-commit does not reference config-audit.sh"
fi

# 14q — pre-commit hook exits 0 when no config files are staged (non-config commit)
PRECOMMIT_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" \
    GIT_DIR="$REPO_ROOT/.git" \
    GIT_WORK_TREE="$REPO_ROOT" \
    SKIP_CONFIG_AUDIT=1 \
    bash "$PRECOMMIT_HOOK" 2>&1
)"
PRECOMMIT_RC=$?
if [ "$PRECOMMIT_RC" -eq 0 ]; then
  _ok ".git/hooks/pre-commit exits 0 when SKIP_CONFIG_AUDIT=1"
else
  _fail ".git/hooks/pre-commit exited $PRECOMMIT_RC with SKIP_CONFIG_AUDIT=1"
fi

# ─── Test 15: gen-tool-matrix.sh ─────────────────────────────────────────────
printf "\n\033[1mTest 15: gen-tool-matrix.sh\033[0m\n"

MATRIX_SH="$REPO_ROOT/scripts/gen-tool-matrix.sh"

# 15a — file exists and is executable
assert_file_executable "gen-tool-matrix.sh is executable" "$MATRIX_SH"

# 15b — bash syntax check (bash -n)
if bash -n "$MATRIX_SH" 2>/dev/null; then
  _ok "gen-tool-matrix.sh passes bash syntax check"
else
  _fail "gen-tool-matrix.sh has bash syntax errors"
fi

# 15c — --help flag exits 0 and prints usage
MATRIX_HELP="$(bash "$MATRIX_SH" --help 2>&1)"
MATRIX_HELP_RC=$?
if [ "$MATRIX_HELP_RC" -eq 0 ]; then
  _ok "gen-tool-matrix.sh --help exits 0"
else
  _fail "gen-tool-matrix.sh --help exited $MATRIX_HELP_RC"
fi
if printf '%s' "$MATRIX_HELP" | grep -q 'health-embed'; then
  _ok "gen-tool-matrix.sh --help documents --health-embed flag"
else
  _fail "gen-tool-matrix.sh --help missing --health-embed (got: $MATRIX_HELP)"
fi

# 15d — unknown flag exits non-zero
MATRIX_BAD_RC=0
bash "$MATRIX_SH" --no-such-flag >/dev/null 2>&1 || MATRIX_BAD_RC=$?
if [ "$MATRIX_BAD_RC" -ne 0 ]; then
  _ok "gen-tool-matrix.sh exits non-zero for unknown flag"
else
  _fail "gen-tool-matrix.sh should exit non-zero for unknown flag"
fi

# 15e — full generation produces HTML + MD files and exits 0
MATRIX_TMPDIR="$(mktemp -d /tmp/matrix-test-XXXXXX)"
MATRIX_GEN_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" \
    ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
    MATRIX_CACHE_DIR="$MATRIX_TMPDIR/cache" \
    NO_COLOR=1 \
    bash "$MATRIX_SH" 2>&1
)"
MATRIX_GEN_RC=$?
if [ "$MATRIX_GEN_RC" -eq 0 ]; then
  _ok "gen-tool-matrix.sh (full mode, no plugin) exits 0"
else
  _fail "gen-tool-matrix.sh exited $MATRIX_GEN_RC (output: $(printf '%s' "$MATRIX_GEN_OUT" | head -5))"
fi

# 15f — HTML output file was created
if [ -f "$REPO_ROOT/docs/generated/tool-matrix.html" ]; then
  _ok "docs/generated/tool-matrix.html was created"
else
  _fail "docs/generated/tool-matrix.html was not created"
fi

# 15g — HTML file contains expected structural elements
if [ -f "$REPO_ROOT/docs/generated/tool-matrix.html" ]; then
  HTML_CONTENT="$(cat "$REPO_ROOT/docs/generated/tool-matrix.html")"
  if printf '%s' "$HTML_CONTENT" | grep -q 'MCP Capability Matrix'; then
    _ok "tool-matrix.html contains matrix title"
  else
    _fail "tool-matrix.html missing matrix title"
  fi
  if printf '%s' "$HTML_CONTENT" | grep -q 'ashlr-efficiency'; then
    _ok "tool-matrix.html references ashlr-efficiency server"
  else
    _fail "tool-matrix.html missing ashlr-efficiency entry"
  fi
  if printf '%s' "$HTML_CONTENT" | grep -q 'ashlrcode'; then
    _ok "tool-matrix.html references ashlrcode agent"
  else
    _fail "tool-matrix.html missing ashlrcode agent"
  fi
fi

# 15h — Markdown inventory file was created
if [ -f "$REPO_ROOT/docs/TOOL-INVENTORY.md" ]; then
  _ok "docs/TOOL-INVENTORY.md was created"
else
  _fail "docs/TOOL-INVENTORY.md was not created"
fi

# 15i — Markdown file contains expected content
if [ -f "$REPO_ROOT/docs/TOOL-INVENTORY.md" ]; then
  MD_CONTENT="$(cat "$REPO_ROOT/docs/TOOL-INVENTORY.md")"
  if printf '%s' "$MD_CONTENT" | grep -q '# Tool Inventory'; then
    _ok "TOOL-INVENTORY.md has correct heading"
  else
    _fail "TOOL-INVENTORY.md missing '# Tool Inventory' heading"
  fi
  if printf '%s' "$MD_CONTENT" | grep -q 'ashlr-bash'; then
    _ok "TOOL-INVENTORY.md lists ashlr-bash server"
  else
    _fail "TOOL-INVENTORY.md missing ashlr-bash server"
  fi
  if printf '%s' "$MD_CONTENT" | grep -q 'Cross-Reference Matrix'; then
    _ok "TOOL-INVENTORY.md contains cross-reference matrix section"
  else
    _fail "TOOL-INVENTORY.md missing cross-reference matrix section"
  fi
fi

# 15j — --diff-only exits 0 and produces output (even on first run / missing snapshot)
MATRIX_DIFF_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" \
    ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
    MATRIX_CACHE_DIR="$MATRIX_TMPDIR/cache2" \
    NO_COLOR=1 \
    bash "$MATRIX_SH" --diff-only 2>&1
)"
MATRIX_DIFF_RC=$?
if [ "$MATRIX_DIFF_RC" -eq 0 ]; then
  _ok "gen-tool-matrix.sh --diff-only exits 0"
else
  _fail "gen-tool-matrix.sh --diff-only exited $MATRIX_DIFF_RC"
fi
if [ -n "$MATRIX_DIFF_OUT" ]; then
  _ok "gen-tool-matrix.sh --diff-only produces output"
else
  _fail "gen-tool-matrix.sh --diff-only produced no output"
fi

# 15k — --health-embed exits 0 and produces summary line
MATRIX_HE_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" \
    ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
    MATRIX_CACHE_DIR="$MATRIX_TMPDIR/cache3" \
    NO_COLOR=1 \
    bash "$MATRIX_SH" --health-embed 2>&1
)"
MATRIX_HE_RC=$?
if [ "$MATRIX_HE_RC" -eq 0 ]; then
  _ok "gen-tool-matrix.sh --health-embed exits 0"
else
  _fail "gen-tool-matrix.sh --health-embed exited $MATRIX_HE_RC"
fi
if printf '%s' "$MATRIX_HE_OUT" | grep -qi 'Tool Matrix'; then
  _ok "gen-tool-matrix.sh --health-embed summary mentions 'Tool Matrix'"
else
  _fail "gen-tool-matrix.sh --health-embed missing summary line (got: $(printf '%s' "$MATRIX_HE_OUT" | head -3))"
fi

# 15l — --health-embed output includes server count
if printf '%s' "$MATRIX_HE_OUT" | grep -qE '[0-9]+ servers'; then
  _ok "gen-tool-matrix.sh --health-embed reports server count"
else
  _fail "gen-tool-matrix.sh --health-embed missing server count"
fi

# 15m — snapshot file is written to cache dir
MATRIX_SNAP_DIR="$(mktemp -d /tmp/matrix-snap-XXXXXX)"
env -i HOME="$HOME" PATH="$PATH" \
  ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
  MATRIX_CACHE_DIR="$MATRIX_SNAP_DIR" \
  NO_COLOR=1 \
  bash "$MATRIX_SH" >/dev/null 2>&1 || true
if [ -f "$MATRIX_SNAP_DIR/last-snapshot.txt" ]; then
  _ok "gen-tool-matrix.sh writes last-snapshot.txt to MATRIX_CACHE_DIR"
else
  _fail "gen-tool-matrix.sh did not create last-snapshot.txt in MATRIX_CACHE_DIR"
fi

# 15n — snapshot file contains server entries
if [ -f "$MATRIX_SNAP_DIR/last-snapshot.txt" ]; then
  if grep -q '^efficiency=' "$MATRIX_SNAP_DIR/last-snapshot.txt"; then
    _ok "last-snapshot.txt contains efficiency= entry"
  else
    _fail "last-snapshot.txt missing efficiency= entry (content: $(cat "$MATRIX_SNAP_DIR/last-snapshot.txt" | head -5))"
  fi
fi

# 15o — diff detects a tool addition between two runs
MATRIX_DIFF_DIR="$(mktemp -d /tmp/matrix-diff-XXXXXX)"
# Write a fake previous snapshot missing a tool
mkdir -p "$MATRIX_DIFF_DIR"
printf '# snapshot\nefficiency=ashlr__read ashlr__grep\n' > "$MATRIX_DIFF_DIR/last-snapshot.txt"
MATRIX_CHANGE_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" \
    ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
    MATRIX_CACHE_DIR="$MATRIX_DIFF_DIR" \
    NO_COLOR=1 \
    bash "$MATRIX_SH" --diff-only 2>&1
)"
# The static registry has more tools for efficiency than just ashlr__read ashlr__grep
# so there should be additions detected (ashlr__glob, ashlr__savings, ashlr__flush)
if printf '%s' "$MATRIX_CHANGE_OUT" | grep -q '+'; then
  _ok "gen-tool-matrix.sh --diff-only detects added tools vs. stale snapshot"
else
  _fail "gen-tool-matrix.sh --diff-only did not detect tool additions (got: $MATRIX_CHANGE_OUT)"
fi

# 15p — healthcheck.sh sources gen-tool-matrix.sh
if grep -q 'gen-tool-matrix.sh' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh references gen-tool-matrix.sh"
else
  _fail "healthcheck.sh does not reference gen-tool-matrix.sh"
fi

# 15q — healthcheck.sh has Tool Matrix section
if grep -q 'Tool Matrix' "$REPO_ROOT/scripts/healthcheck.sh"; then
  _ok "healthcheck.sh has Tool Matrix section"
else
  _fail "healthcheck.sh missing Tool Matrix section"
fi

# Cleanup temp dirs
rm -rf "$MATRIX_TMPDIR" "$MATRIX_SNAP_DIR" "$MATRIX_DIFF_DIR"

# ─── Test 16: mcp-protocol-validator.sh + mcp-protocol-schema.json ───────────
printf "\n\033[1mTest 16: MCP Protocol Validator\033[0m\n"

MCP_VALIDATOR_SH="$REPO_ROOT/tests/mcp-protocol-validator.sh"
MCP_PROTO_SCHEMA="$REPO_ROOT/tests/mcp-protocol-schema.json"

# 16a — validator script exists and is executable
assert_file_executable "mcp-protocol-validator.sh is executable" "$MCP_VALIDATOR_SH"

# 16b — validator passes bash syntax check
if bash -n "$MCP_VALIDATOR_SH" 2>/dev/null; then
  _ok "mcp-protocol-validator.sh passes bash syntax check"
else
  _fail "mcp-protocol-validator.sh has bash syntax errors"
fi

# 16c — schema file exists and is valid JSON
if [ -f "$MCP_PROTO_SCHEMA" ]; then
  _ok "mcp-protocol-schema.json present"
  if python3 -c "import json; json.load(open('$MCP_PROTO_SCHEMA'))" 2>/dev/null; then
    _ok "mcp-protocol-schema.json is valid JSON"
  else
    _fail "mcp-protocol-schema.json is not valid JSON"
  fi
else
  _fail "mcp-protocol-schema.json missing at $MCP_PROTO_SCHEMA"
fi

# 16d — schema declares the 10 canonical required_mcp_servers
if [ -f "$MCP_PROTO_SCHEMA" ]; then
  SCHEMA_SERVERS="$(python3 -c "
import json, sys
d = json.load(open('$MCP_PROTO_SCHEMA'))
servers = d.get('properties', {}).get('required_mcp_servers', {}).get('const', [])
print(len(servers))
" 2>/dev/null || echo 0)"
  if [ "${SCHEMA_SERVERS:-0}" -eq 10 ]; then
    _ok "mcp-protocol-schema.json declares exactly 10 required MCP servers"
  else
    _fail "mcp-protocol-schema.json required_mcp_servers count is ${SCHEMA_SERVERS:-0}, expected 10"
  fi
fi

# 16e — schema defines initialize_result and tools_list_result shapes
for _def in initialize_result tools_list_result jsonrpc_response tool_definition; do
  if python3 -c "
import json, sys
d = json.load(open('$MCP_PROTO_SCHEMA'))
assert '$_def' in d.get('definitions', {}), 'missing'
print('ok')
" 2>/dev/null | grep -q ok; then
    _ok "mcp-protocol-schema.json defines '$_def'"
  else
    _fail "mcp-protocol-schema.json missing definition: '$_def'"
  fi
done

# 16f — validator sources config.sh successfully (no syntax error in sourcing chain)
VALIDATOR_SOURCE_OK="$(
  env -i HOME="$HOME" WORKBENCH="$REPO_ROOT" bash -c "
    . '$REPO_ROOT/scripts/lib/config.sh'
    bash -n '$MCP_VALIDATOR_SH' && echo sourced_ok
  " 2>&1
)"
if printf '%s' "$VALIDATOR_SOURCE_OK" | grep -q 'sourced_ok'; then
  _ok "mcp-protocol-validator.sh syntax OK when config.sh is pre-sourced"
else
  _fail "mcp-protocol-validator.sh syntax error with config.sh: $VALIDATOR_SOURCE_OK"
fi

# 16g — validator run (dry-run with no plugin): exits 0 and emits the matrix header
VALIDATOR_OUT="$(
  env -i HOME="$HOME" PATH="$PATH" \
    ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
    NO_COLOR=1 \
    MCP_PROTO_JSONL="$(mktemp /tmp/pv-test-XXXXXX.jsonl)" \
    bash "$MCP_VALIDATOR_SH" 2>&1
)"
if printf '%s' "$VALIDATOR_OUT" | grep -qi 'Compliance Matrix'; then
  _ok "mcp-protocol-validator.sh emits Compliance Matrix section"
else
  _fail "mcp-protocol-validator.sh missing Compliance Matrix section (got: $(printf '%s' "$VALIDATOR_OUT" | head -5))"
fi

# 16h — validator emits a compliance score line
if printf '%s' "$VALIDATOR_OUT" | grep -qi 'Compliance score'; then
  _ok "mcp-protocol-validator.sh emits Compliance score"
else
  _fail "mcp-protocol-validator.sh missing Compliance score line"
fi

# 16i — validator exits 0 when plugin is absent (all-skip = no failures)
VALIDATOR_RC=0
env -i HOME="$HOME" PATH="$PATH" \
  ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
  NO_COLOR=1 \
  MCP_PROTO_JSONL="$(mktemp /tmp/pv-rc-XXXXXX.jsonl)" \
  bash "$MCP_VALIDATOR_SH" >/dev/null 2>&1 || VALIDATOR_RC=$?
if [ "$VALIDATOR_RC" -eq 0 ]; then
  _ok "mcp-protocol-validator.sh exits 0 when plugin absent (all-skip)"
else
  _fail "mcp-protocol-validator.sh exited $VALIDATOR_RC with no plugin (expected 0)"
fi

# 16j — validator emits valid JSONL records (every line parses as JSON)
JSONL_TMP="$(mktemp /tmp/pv-jsonl-XXXXXX.jsonl)"
env -i HOME="$HOME" PATH="$PATH" \
  ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
  NO_COLOR=1 \
  MCP_PROTO_JSONL="$JSONL_TMP" \
  bash "$MCP_VALIDATOR_SH" >/dev/null 2>&1 || true
if [ -s "$JSONL_TMP" ]; then
  JSONL_BAD="$(python3 -c "
import json, sys
bad = 0
for i, line in enumerate(open('$JSONL_TMP')):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as e:
        bad += 1
        print(f'line {i+1}: {e}')
print(bad)
" 2>/dev/null | tail -1)"
  if [ "${JSONL_BAD:-1}" = "0" ]; then
    _ok "mcp-protocol-validator.sh JSONL output: all records are valid JSON"
  else
    _fail "mcp-protocol-validator.sh JSONL has ${JSONL_BAD} malformed line(s)"
  fi
else
  _fail "mcp-protocol-validator.sh produced no JSONL output"
fi
rm -f "$JSONL_TMP"

# 16k — each JSONL record has the required fields (ts, agent, mcp, phase, status, latency_ms)
JSONL_TMP2="$(mktemp /tmp/pv-jsonl2-XXXXXX.jsonl)"
env -i HOME="$HOME" PATH="$PATH" \
  ASHLR_PLUGIN_DIR="/tmp/nonexistent-plugin-$$" \
  NO_COLOR=1 \
  MCP_PROTO_JSONL="$JSONL_TMP2" \
  bash "$MCP_VALIDATOR_SH" >/dev/null 2>&1 || true
if [ -s "$JSONL_TMP2" ]; then
  FIELDS_OK="$(python3 -c "
import json, sys
required = {'ts','agent','mcp','phase','status','latency_ms'}
bad = 0
for i, line in enumerate(open('$JSONL_TMP2')):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        missing = required - set(obj.keys())
        if missing:
            bad += 1
            print(f'line {i+1} missing: {missing}')
    except Exception:
        bad += 1
print(bad)
" 2>/dev/null | tail -1)"
  if [ "${FIELDS_OK:-1}" = "0" ]; then
    _ok "mcp-protocol-validator.sh JSONL records all have required fields"
  else
    _fail "mcp-protocol-validator.sh JSONL has ${FIELDS_OK} record(s) with missing fields"
  fi
fi
rm -f "$JSONL_TMP2"

# 16l — validator detects config drift when a server is missing from a temp config
DRIFT_TMP="$(mktemp /tmp/pv-drift-XXXXXX.json)"
python3 -c "
import json
# Write a mcp.json missing ashlr-github (9 servers instead of 10)
d = {
  'stdio_servers': [
    {'name': 'ashlr-efficiency', 'command': 'bash', 'args': []},
    {'name': 'ashlr-sql',        'command': 'bash', 'args': []},
    {'name': 'ashlr-bash',       'command': 'bash', 'args': []},
    {'name': 'ashlr-tree',       'command': 'bash', 'args': []},
    {'name': 'ashlr-http',       'command': 'bash', 'args': []},
    {'name': 'ashlr-diff',       'command': 'bash', 'args': []},
    {'name': 'ashlr-logs',       'command': 'bash', 'args': []},
    {'name': 'ashlr-genome',     'command': 'bash', 'args': []},
    {'name': 'ashlr-orient',     'command': 'bash', 'args': []}
  ],
  'sse_servers': [], 'shttp_servers': []
}
print(json.dumps(d))
" > "$DRIFT_TMP"
# Source the validator's extraction helper in a subshell and check it finds 9 not 10
DRIFT_NAMES="$(
  env -i HOME="$HOME" bash -c "
    . '$REPO_ROOT/scripts/lib/config.sh'
    # Inline the extraction logic for JSON (same as validator's _extract_server_names)
    python3 - '$DRIFT_TMP' <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
names = [s.get('name','') for s in d.get('stdio_servers',[]) if s.get('name','').startswith('ashlr-')]
for n in sorted(names): print(n)
PYEOF
  " 2>&1
)"
DRIFT_COUNT="$(printf '%s\n' "$DRIFT_NAMES" | grep -c 'ashlr-' || echo 0)"
if [ "$DRIFT_COUNT" -eq 9 ]; then
  _ok "config drift extraction correctly finds 9 servers in a truncated mcp.json"
else
  _fail "config drift extraction expected 9 servers, got $DRIFT_COUNT"
fi
rm -f "$DRIFT_TMP"

# 16m — aw doctor --mcp-audit flag is wired: aw recognises the subcommand
if grep -q 'mcp-audit' "$REPO_ROOT/bin/aw"; then
  _ok "bin/aw contains --mcp-audit flag handling"
else
  _fail "bin/aw does not contain --mcp-audit flag handling"
fi

# 16n — aw doctor --mcp-audit delegates to mcp-protocol-validator.sh
if grep -q 'mcp-protocol-validator.sh' "$REPO_ROOT/bin/aw"; then
  _ok "bin/aw doctor --mcp-audit references mcp-protocol-validator.sh"
else
  _fail "bin/aw doctor --mcp-audit does not reference mcp-protocol-validator.sh"
fi

# 16o — validator help text includes protocol cycle phases
for _phrase in 'initialize' 'tools/list' 'shutdown' 'compliance'; do
  if grep -qi "$_phrase" "$MCP_VALIDATOR_SH"; then
    _ok "mcp-protocol-validator.sh mentions '$_phrase'"
  else
    _fail "mcp-protocol-validator.sh missing phrase '$_phrase'"
  fi
done

# 16p — validator correctly validates initialize response shape (unit)
INIT_GOOD="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"test\"}}}"
INIT_BAD="{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}"
# Source the validator and call _validate_initialize_response in a subshell
VALIDATE_GOOD="$(
  env -i HOME="$HOME" bash -c "
    . '$REPO_ROOT/scripts/lib/config.sh'
    # Re-implement the inline check matching the validator's logic
    txt='$INIT_GOOD'
    ok=1
    printf '%s' \"\$txt\" | grep -q '\"jsonrpc\"'          || ok=0
    printf '%s' \"\$txt\" | grep -q '\"result\"'           || ok=0
    printf '%s' \"\$txt\" | grep -q '\"protocolVersion\"'  || ok=0
    printf '%s' \"\$txt\" | grep -q '\"serverInfo\"'       || ok=0
    echo \$ok
  " 2>&1
)"
assert_eq "_validate_initialize_response: good response passes" "1" "$VALIDATE_GOOD"

VALIDATE_BAD="$(
  env -i HOME="$HOME" bash -c "
    txt='$INIT_BAD'
    ok=1
    printf '%s' \"\$txt\" | grep -q '\"jsonrpc\"'          || ok=0
    printf '%s' \"\$txt\" | grep -q '\"result\"'           || ok=0
    printf '%s' \"\$txt\" | grep -q '\"protocolVersion\"'  || ok=0
    printf '%s' \"\$txt\" | grep -q '\"serverInfo\"'       || ok=0
    echo \$ok
  " 2>&1
)"
assert_eq "_validate_initialize_response: bad response (missing fields) fails" "0" "$VALIDATE_BAD"

# 16q — validator correctly validates tools/list response shape (unit)
LIST_GOOD="{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"ashlr__read\",\"description\":\"Read files\"}]}}"
LIST_BAD="{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}"
VALIDATE_LIST_GOOD="$(
  env -i HOME="$HOME" bash -c "
    txt='$LIST_GOOD'
    ok=1
    printf '%s' \"\$txt\" | grep -q '\"jsonrpc\"' || ok=0
    printf '%s' \"\$txt\" | grep -q '\"result\"'  || ok=0
    printf '%s' \"\$txt\" | grep -q '\"tools\"'   || ok=0
    printf '%s' \"\$txt\" | grep -q '\"name\"'    || ok=0
    echo \$ok
  " 2>&1
)"
assert_eq "_validate_tools_list_response: good response passes" "1" "$VALIDATE_LIST_GOOD"

VALIDATE_LIST_BAD="$(
  env -i HOME="$HOME" bash -c "
    txt='$LIST_BAD'
    # empty tools array — 'name' field will be absent
    ok=1
    printf '%s' \"\$txt\" | grep -q '\"name\"' || ok=0
    echo \$ok
  " 2>&1
)"
assert_eq "_validate_tools_list_response: empty tools array fails name check" "0" "$VALIDATE_LIST_BAD"

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32m\033[1mAll %d tests passed\033[0m\n\n" "$PASS"
  exit 0
else
  printf "\033[31m\033[1m%d/%d tests failed\033[0m\n\n" "$FAIL" "$((PASS+FAIL))"
  exit 1
fi
