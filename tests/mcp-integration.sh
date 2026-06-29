#!/usr/bin/env bash
# tests/mcp-integration.sh — MCP Connection Integration Tests
#
# Verifies that each agent's MCP configuration is structurally sound and that
# the ashlr-plugin MCP servers can perform a real JSON-RPC stdio handshake.
#
# What this tests (that mcp-probe.sh alone cannot):
#   1. Agent config correctly lists MCP server entries (config schema drift)
#   2. MCP server entrypoint scripts exist and are reachable (missing entrypoints)
#   3. Each server performs a full JSON-RPC initialize + tools/list handshake
#   4. Response has the correct JSON-RPC 2.0 shape (env-var injection bugs)
#   5. Server shuts down cleanly within timeout (MCP socket lifecycle issues)
#
# Output:
#   - Human-readable pass/fail matrix table (stdout)
#   - Machine-readable JSONL (MCP_INTEGRATION_JSONL, default: auto temp file)
#
# Usage:
#   bash tests/mcp-integration.sh
#   MCP_CONN_TIMEOUT=3 bash tests/mcp-integration.sh
#   NO_COLOR=1 bash tests/mcp-integration.sh
#
# Environment variables:
#   MCP_CONN_TIMEOUT      — seconds per server probe           (default: 5)
#   MCP_INTEGRATION_JSONL — path for machine-readable output   (default: auto temp)
#   ASHLR_PLUGIN_DIR      — path to ashlr-plugin checkout      (default: ~/Desktop/ashlr-plugin)
#   NO_COLOR              — disable ANSI colour codes
#
# Exit code:
#   0 — all probed servers passed (or only skipped)
#   1 — at least one FAIL

set -uo pipefail

# ─── Resolve repo root ────────────────────────────────────────────────────────
_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$_SCRIPT_PATH" ]; do
  _link="$(readlink "$_SCRIPT_PATH")"
  case "$_link" in
    /*) _SCRIPT_PATH="$_link" ;;
    *)  _SCRIPT_PATH="$(dirname "$_SCRIPT_PATH")/$_link" ;;
  esac
done
TESTS_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Source config for ASHLR_PLUGIN_DIR, WORKBENCH, etc.
# shellcheck source=scripts/lib/config.sh
. "$REPO_ROOT/scripts/lib/config.sh"

# Source the MCP connection helper library.
# shellcheck source=scripts/lib/mcp-connection.sh
. "$REPO_ROOT/scripts/lib/mcp-connection.sh"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

# ─── Counters (in main shell — never update inside a piped subshell) ──────────
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0

# ─── JSONL output file ────────────────────────────────────────────────────────
if [ -z "${MCP_INTEGRATION_JSONL:-}" ]; then
  MCP_INTEGRATION_JSONL="$(mktemp /tmp/mcp-integration-XXXXXX.jsonl)"
  _JSONL_IS_TEMP=1
else
  _JSONL_IS_TEMP=0
fi
export MCP_CONN_JSONL_OUT="$MCP_INTEGRATION_JSONL"

# ─── Timing ───────────────────────────────────────────────────────────────────
SUITE_START="$(date +%s)"

# ─── Helpers ──────────────────────────────────────────────────────────────────
_pass()    { printf "  %sPASS%s %s\n" "$C_GREEN" "$C_RESET" "$*"; TOTAL_PASS=$((TOTAL_PASS+1)); }
_fail()    { printf "  %sFAIL%s %s\n" "$C_RED"   "$C_RESET" "$*"; TOTAL_FAIL=$((TOTAL_FAIL+1)); }
_skip()    { printf "  %sSKIP%s %s\n" "$C_DIM"   "$C_RESET" "$*"; TOTAL_SKIP=$((TOTAL_SKIP+1)); }
_section() { printf "\n%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"; }

# ─── Agent list (static — no piped loops for simple iteration) ────────────────
# 4 agents in ashlr-workbench
AGENTS="aider goose ashlrcode openhands"

_agent_config() {
  # Return config file path for a given agent name
  case "$1" in
    aider)      printf '%s/agents/aider/aider.conf.yml'      "$REPO_ROOT" ;;
    goose)      printf '%s/agents/goose/config.yaml'         "$REPO_ROOT" ;;
    ashlrcode)  printf '%s/agents/ashlrcode/settings.json'   "$REPO_ROOT" ;;
    openhands)  printf '%s/agents/openhands/mcp.json'        "$REPO_ROOT" ;;
  esac
}

# The 10 ashlr-plugin MCP servers (short names, without "ashlr-" prefix)
ASHLR_MCP_SERVERS="efficiency sql bash tree http diff logs genome orient github"

# ─── Pre-flight info ──────────────────────────────────────────────────────────
printf "%sMCP Connection Integration Tests%s\n" "$C_BOLD" "$C_RESET"
PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
SERVERS_DIR="$PLUGIN_DIR/servers"
printf "Plugin dir : %s\n" "$PLUGIN_DIR"
printf "Timeout    : %ss per server\n" "${MCP_CONN_TIMEOUT:-5}"
printf "JSONL out  : %s\n" "$MCP_INTEGRATION_JSONL"

PLUGIN_PRESENT=0
[ -d "$SERVERS_DIR" ] && PLUGIN_PRESENT=1

RUNTIME_AVAILABLE=0
command -v bun  >/dev/null 2>&1 && RUNTIME_AVAILABLE=1
command -v node >/dev/null 2>&1 && RUNTIME_AVAILABLE=1

# ─── Section 1: Agent Config Presence ─────────────────────────────────────────
_section "1. Agent Config Presence"

for _agent in $AGENTS; do
  _cfg="$(_agent_config "$_agent")"
  _rel="${_cfg#$REPO_ROOT/}"
  if [ -f "$_cfg" ]; then
    _pass "$_agent: config file present ($_rel)"
    _mcp_conn_emit_jsonl "$_agent" "config-presence" "pass" "0" "config file present" >/dev/null
  else
    _fail "$_agent: config file MISSING ($_rel)"
    _mcp_conn_emit_jsonl "$_agent" "config-presence" "fail" "0" "config file missing: $_cfg" >/dev/null
  fi
done

# ─── Section 2: Agent Config Lists MCP Servers ────────────────────────────────
_section "2. Agent Config -> MCP Server Entries"

for _agent in $AGENTS; do
  _cfg="$(_agent_config "$_agent")"
  [ -f "$_cfg" ] || continue

  _mcp_count=0
  case "$_cfg" in
    *.json)
      if command -v python3 >/dev/null 2>&1; then
        _mcp_count="$(python3 -c "
import json, sys
try:
    d = json.load(open('$_cfg'))
    if 'mcpServers' in d:
        print(len(d['mcpServers']))
    elif 'stdio_servers' in d:
        print(len(d.get('stdio_servers', [])))
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
      else
        _mcp_count="$(grep -c '"ashlr-' "$_cfg" 2>/dev/null || echo 0)"
      fi
      ;;
    *.yml|*.yaml|*.toml)
      # aider/goose use CLI flags for MCP; count any mcp reference as advisory
      _mcp_count="$(grep -ci 'mcp\|ashlr-' "$_cfg" 2>/dev/null || echo 0)"
      ;;
  esac

  # Ensure clean non-negative integer (strip whitespace, take first run of digits)
  _mcp_count="$(printf '%s' "${_mcp_count:-0}" | tr -d ' \t\n\r' | grep -oE '^[0-9]+' || true)"
  _mcp_count="${_mcp_count:-0}"

  if [ "$_mcp_count" -gt 0 ]; then
    _pass "$_agent: config references $_mcp_count MCP server(s)"
    _mcp_conn_emit_jsonl "$_agent" "config-mcp-count" "pass" "0" "mcp_count=$_mcp_count" >/dev/null
  else
    _skip "$_agent: no MCP server entries detected in config (may use CLI flags)"
    _mcp_conn_emit_jsonl "$_agent" "config-mcp-count" "skip" "0" "no mcpServers key in config" >/dev/null
  fi
done

# ─── Section 3: Plugin + Runtime Pre-flight ───────────────────────────────────
_section "3. Plugin + Runtime Pre-flight"

if [ "$PLUGIN_PRESENT" -eq 1 ]; then
  _pass "ashlr-plugin servers/ directory present ($SERVERS_DIR)"
else
  _skip "ashlr-plugin not found at $PLUGIN_DIR -- handshake probes will be skipped"
  printf "     To run full handshake tests: clone ashlr-plugin to %s\n" "$PLUGIN_DIR"
fi

if [ "$RUNTIME_AVAILABLE" -eq 1 ]; then
  if command -v bun >/dev/null 2>&1; then
    _pass "runtime: bun available ($(bun --version 2>/dev/null || echo '?'))"
  else
    _pass "runtime: node available ($(node --version 2>/dev/null || echo '?'))"
  fi
else
  _skip "runtime: neither bun nor node on PATH -- handshake probes will be skipped"
fi

# ─── Matrix temp file (written by section 4, read by section 5) ───────────────
MATRIX_TMP="$(mktemp /tmp/mcp-matrix-XXXXXX)"
trap 'rm -f "$MATRIX_TMP"' EXIT

# ─── Section 4: Per-Agent x Per-MCP Handshake Probes ─────────────────────────
_section "4. Agent x MCP Handshake Probes"

if [ "$PLUGIN_PRESENT" -eq 1 ] && [ "$RUNTIME_AVAILABLE" -eq 1 ]; then
  for _agent in $AGENTS; do
    printf "  %s%s%s\n" "$C_CYAN" "$_agent" "$C_RESET"

    for _srv_short in $ASHLR_MCP_SERVERS; do
      _srv_full="ashlr-${_srv_short}"
      _ts_path="$SERVERS_DIR/${_srv_short}-server.ts"
      _t0="$(date +%s)"
      _rc=0
      _mcp_conn_probe_server "$_agent" "$_srv_full" "$_ts_path" || _rc=$?
      _t1="$(date +%s)"
      _lat=$(( (_t1 - _t0) * 1000 ))

      case "$_rc" in
        0)
          printf "    %-28s %sPASS%s  %dms\n" "$_srv_full" "$C_GREEN" "$C_RESET" "$_lat"
          printf '%s|%s|pass|%d\n' "$_agent" "$_srv_full" "$_lat" >> "$MATRIX_TMP"
          TOTAL_PASS=$((TOTAL_PASS+1))
          ;;
        3)
          printf "    %-28s %sFAIL%s  entrypoint missing\n" "$_srv_full" "$C_RED" "$C_RESET"
          printf '%s|%s|fail:missing|%d\n' "$_agent" "$_srv_full" "$_lat" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        4)
          printf "    %-28s %sSKIP%s  no runtime\n" "$_srv_full" "$C_DIM" "$C_RESET"
          printf '%s|%s|skip:noruntime|%d\n' "$_agent" "$_srv_full" "$_lat" >> "$MATRIX_TMP"
          TOTAL_SKIP=$((TOTAL_SKIP+1))
          ;;
        2)
          printf "    %-28s %sFAIL%s  timeout (%ds)\n" "$_srv_full" "$C_RED" "$C_RESET" "${MCP_CONN_TIMEOUT:-5}"
          printf '%s|%s|fail:timeout|%d\n' "$_agent" "$_srv_full" "$_lat" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        5)
          printf "    %-28s %sFAIL%s  server crashed\n" "$_srv_full" "$C_RED" "$C_RESET"
          printf '%s|%s|fail:crash|%d\n' "$_agent" "$_srv_full" "$_lat" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        1)
          printf "    %-28s %sFAIL%s  bad response shape\n" "$_srv_full" "$C_RED" "$C_RESET"
          printf '%s|%s|fail:shape|%d\n' "$_agent" "$_srv_full" "$_lat" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        *)
          printf "    %-28s %sFAIL%s  rc=%d\n" "$_srv_full" "$C_RED" "$C_RESET" "$_rc"
          printf '%s|%s|fail:rc%d|%d\n' "$_agent" "$_srv_full" "$_rc" "$_lat" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
      esac
    done
  done
else
  printf "  (skipped -- plugin or runtime unavailable)\n"
  for _agent in $AGENTS; do
    for _srv_short in $ASHLR_MCP_SERVERS; do
      printf '%s|ashlr-%s|skip:prereq|-1\n' "$_agent" "$_srv_short" >> "$MATRIX_TMP"
    done
  done
  # Count all as skipped for summary
  _skip_total=$(( $(printf '%s\n' $AGENTS | wc -l | tr -d ' ') * $(printf '%s\n' $ASHLR_MCP_SERVERS | wc -l | tr -d ' ') ))
  TOTAL_SKIP=$((TOTAL_SKIP + _skip_total))
fi

# ─── Section 5: Matrix Table ──────────────────────────────────────────────────
_section "5. Agent x MCP Result Matrix"

# Build header line in one pass (no pipe — avoids subshell newline issues)
_header="  $(printf '%-28s' 'MCP Server')"
_sep="  $(printf '%-28s' '----------------------------')"
for _agent in $AGENTS; do
  _header="${_header}$(printf '%-12s' "$_agent")"
  _sep="${_sep}$(printf '%-12s' '------------')"
done
printf '%s\n' "$_header"
printf '%s\n' "$_sep"

# One row per MCP server — read matrix file for each cell
for _srv_short in $ASHLR_MCP_SERVERS; do
  _srv_full="ashlr-${_srv_short}"
  _row="  $(printf '%-28s' "$_srv_full")"

  for _agent in $AGENTS; do
    _cell="$(grep "^${_agent}|${_srv_full}|" "$MATRIX_TMP" 2>/dev/null | tail -1 | cut -d'|' -f3 || true)"
    case "${_cell:-}" in
      pass)         _row="${_row}${C_GREEN}$(printf '%-12s' 'pass')${C_RESET}" ;;
      skip*|'')     _row="${_row}${C_DIM}$(printf '%-12s' 'skip')${C_RESET}" ;;
      fail*)        _row="${_row}${C_RED}$(printf '%-12s' 'fail')${C_RESET}" ;;
      *)            _row="${_row}$(printf '%-12s' '-')" ;;
    esac
  done
  printf '%s\n' "$_row"
done

# ─── Section 6: Machine-Readable Output ───────────────────────────────────────
_section "6. Machine-Readable Output"

_jsonl_count=0
[ -f "$MCP_INTEGRATION_JSONL" ] && _jsonl_count="$(wc -l < "$MCP_INTEGRATION_JSONL" | tr -d ' ')"
printf "  JSONL records written : %d\n" "$_jsonl_count"
printf "  JSONL file            : %s\n" "$MCP_INTEGRATION_JSONL"
if [ "${_JSONL_IS_TEMP:-0}" -eq 1 ]; then
  printf "  %s(temp file -- copy before next run to preserve)%s\n" "$C_DIM" "$C_RESET"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
SUITE_END="$(date +%s)"
SUITE_ELAPSED=$(( SUITE_END - SUITE_START ))

printf "\n%sResult:%s %s%d passed%s, %s%d failed%s, %s%d skipped%s  (%ds)\n" \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN" "$TOTAL_PASS" "$C_RESET" \
  "$C_RED"   "$TOTAL_FAIL" "$C_RESET" \
  "$C_DIM"   "$TOTAL_SKIP" "$C_RESET" \
  "$SUITE_ELAPSED"

# Suite-level JSONL summary record
_mcp_conn_emit_jsonl "suite" "summary" \
  "$([ "$TOTAL_FAIL" -eq 0 ] && echo pass || echo fail)" \
  "$((SUITE_ELAPSED * 1000))" \
  "pass=${TOTAL_PASS} fail=${TOTAL_FAIL} skip=${TOTAL_SKIP}" >/dev/null

[ "$TOTAL_FAIL" -eq 0 ]
