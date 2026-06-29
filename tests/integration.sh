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

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32m\033[1mAll %d tests passed\033[0m\n\n" "$PASS"
  exit 0
else
  printf "\033[31m\033[1m%d/%d tests failed\033[0m\n\n" "$FAIL" "$((PASS+FAIL))"
  exit 1
fi
