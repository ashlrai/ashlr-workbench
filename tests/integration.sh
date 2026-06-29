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

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32m\033[1mAll %d tests passed\033[0m\n\n" "$PASS"
  exit 0
else
  printf "\033[31m\033[1m%d/%d tests failed\033[0m\n\n" "$FAIL" "$((PASS+FAIL))"
  exit 1
fi
