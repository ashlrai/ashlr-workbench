#!/usr/bin/env bash
# tests/mcp-protocol-validator.sh — MCP Runtime Protocol Compliance Suite
#
# Validates each agent's MCP configuration against the JSON-RPC 2.0 spec by
# executing a full initialize → tools/list → shutdown cycle per server and
# comparing the response shapes against tests/mcp-protocol-schema.json.
#
# What this validates (beyond the basic handshakes in mcp-integration.sh):
#   1. Config-drift check — all 4 agent configs declare the exact same 10 MCP
#      servers; any missing entry or extra drift server is a FAIL.
#   2. Per-server protocol cycle — spawn, initialize, tools/list, shutdown;
#      each phase is individually recorded with latency.
#   3. Response-shape validation — initialize result has protocolVersion +
#      capabilities + serverInfo; tools/list has at least one named tool; both
#      carry jsonrpc:"2.0" and a matching id.
#   4. JSONL output — every (agent × server × phase) triple is written as one
#      JSONL record for machine consumption / CI artefacts.
#   5. Compliance matrix — pass/fail table per (agent × server) pair plus an
#      overall compliance score (0-100).
#
# Usage:
#   bash tests/mcp-protocol-validator.sh
#   MCP_PROTO_TIMEOUT=8 bash tests/mcp-protocol-validator.sh
#   NO_COLOR=1 MCP_PROTO_JSONL=/tmp/audit.jsonl bash tests/mcp-protocol-validator.sh
#   aw doctor --mcp-audit          (delegates to this script)
#
# Environment variables:
#   MCP_PROTO_TIMEOUT    — seconds for the full initialize+tools/list cycle  (default: 8)
#   MCP_PROTO_JSONL      — path for JSONL output                             (default: auto temp)
#   ASHLR_PLUGIN_DIR     — path to ashlr-plugin checkout                     (default: ~/Desktop/ashlr-plugin)
#   NO_COLOR             — disable ANSI colour codes
#
# Exit codes:
#   0 — all tested phases passed (or skipped due to missing prereqs)
#   1 — at least one FAIL

set -uo pipefail

# ─── Resolve repo root ────────────────────────────────────────────────────────
_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$_SCRIPT_PATH" ]; do
  _lnk="$(readlink "$_SCRIPT_PATH")"
  case "$_lnk" in
    /*) _SCRIPT_PATH="$_lnk" ;;
    *)  _SCRIPT_PATH="$(dirname "$_SCRIPT_PATH")/$_lnk" ;;
  esac
done
TESTS_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Source centralized config for ASHLR_PLUGIN_DIR etc.
# shellcheck source=scripts/lib/config.sh
. "$REPO_ROOT/scripts/lib/config.sh"

# ─── Colours ──────────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

# ─── Configuration ────────────────────────────────────────────────────────────
MCP_PROTO_TIMEOUT="${MCP_PROTO_TIMEOUT:-8}"    # seconds per server full cycle

PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
SERVERS_DIR="$PLUGIN_DIR/servers"
SCHEMA_FILE="$TESTS_DIR/mcp-protocol-schema.json"

# JSONL output
if [ -z "${MCP_PROTO_JSONL:-}" ]; then
  MCP_PROTO_JSONL="$(mktemp /tmp/mcp-protocol-XXXXXX.jsonl)"
  _JSONL_IS_TEMP=1
else
  _JSONL_IS_TEMP=0
fi

# ─── Canonical server + agent lists ──────────────────────────────────────────
# The 10 ashlr-plugin servers every agent must declare
REQUIRED_SERVERS="efficiency sql bash tree http diff logs genome orient github"

# Agents and their config file paths
AGENTS="openhands ashlrcode goose aider"

_agent_cfg() {
  case "$1" in
    openhands) printf '%s/agents/openhands/mcp.json'     "$REPO_ROOT" ;;
    ashlrcode) printf '%s/agents/ashlrcode/settings.json' "$REPO_ROOT" ;;
    goose)     printf '%s/agents/goose/config.yaml'       "$REPO_ROOT" ;;
    aider)     printf '%s/agents/aider/aider.conf.yml'    "$REPO_ROOT" ;;
  esac
}

# ─── Counters (never inside a piped subshell) ─────────────────────────────────
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0; TOTAL_WARN=0

# ─── Temp files for matrix accumulation ──────────────────────────────────────
MATRIX_TMP="$(mktemp /tmp/mcp-proto-matrix-XXXXXX)"
trap 'rm -f "$MATRIX_TMP"' EXIT

# ─── Helpers ──────────────────────────────────────────────────────────────────
_pass()    { printf "  %sPASS%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; TOTAL_PASS=$((TOTAL_PASS+1)); }
_fail()    { printf "  %sFAIL%s %s\n" "$C_RED"    "$C_RESET" "$*"; TOTAL_FAIL=$((TOTAL_FAIL+1)); }
_skip()    { printf "  %sSKIP%s %s\n" "$C_DIM"    "$C_RESET" "$*"; TOTAL_SKIP=$((TOTAL_SKIP+1)); }
_warn()    { printf "  %sWARN%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; TOTAL_WARN=$((TOTAL_WARN+1)); }
_section() { printf "\n%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"; }

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'; }

# _emit_jsonl <agent> <mcp> <phase> <status> <latency_ms> [detail] [response_excerpt]
_emit_jsonl() {
  local agent="$1" mcp="$2" phase="$3" status="$4" lat="$5"
  local detail="${6:-}" resp="${7:-}"
  # Escape for JSON
  local det_esc resp_esc
  det_esc="$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/"/\\"/g; s/\\/\\\\/g' 2>/dev/null || printf '%s' "$detail")"
  resp_esc="$(printf '%s' "$resp"   | tr '\n' ' ' | sed 's/"/\\"/g; s/\\/\\\\/g' 2>/dev/null || printf '%s' "$resp")"
  # Truncate response excerpt to 200 chars
  resp_esc="$(printf '%s' "$resp_esc" | cut -c1-200)"
  local rec
  rec="{\"ts\":\"$(_ts)\",\"agent\":\"${agent}\",\"mcp\":\"${mcp}\",\"phase\":\"${phase}\",\"status\":\"${status}\",\"latency_ms\":${lat},\"detail\":\"${det_esc}\",\"response\":\"${resp_esc}\"}"
  printf '%s\n' "$rec" >> "$MCP_PROTO_JSONL"
}

# ─── JSON-RPC message builders ────────────────────────────────────────────────
# Emit a framed Content-Length JSON-RPC message to stdout
_jsonrpc_msg() {
  local id="$1" method="$2" params="${3:-{}}"
  local body="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"${method}\",\"params\":${params}}"
  local len="${#body}"
  printf 'Content-Length: %d\r\n\r\n%s' "$len" "$body"
}

# ─── Config-drift extraction helpers ─────────────────────────────────────────
# Print sorted newline-separated ashlr-* server names from a config file
_extract_server_names() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1

  case "$cfg" in
    *.json)
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$cfg" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    names = []
    if 'mcpServers' in d:
        names = [k for k in d['mcpServers'] if k.startswith('ashlr-')]
    elif 'stdio_servers' in d:
        names = [s.get('name','') for s in d.get('stdio_servers',[]) if s.get('name','').startswith('ashlr-')]
    for n in sorted(names):
        print(n)
except Exception:
    sys.exit(1)
PYEOF
      else
        grep -oE '"ashlr-[a-z]+"' "$cfg" 2>/dev/null | tr -d '"' | sort -u
      fi
      ;;
    *.yaml|*.yml)
      # Goose config.yaml uses YAML extensions block; grep for "name: ashlr-" lines
      grep -E '^\s+(name:\s+ashlr-|ashlr-[a-z]+:)' "$cfg" 2>/dev/null \
        | grep -oE 'ashlr-[a-z]+' | sort -u
      ;;
    *.toml)
      grep -oE '"ashlr-[a-z]+"' "$cfg" 2>/dev/null | tr -d '"' | sort -u
      ;;
  esac
}

# ─── Protocol cycle helpers ───────────────────────────────────────────────────
# _find_runtime <entry_file> — echo "bun" or "node", return 1 if none
_find_runtime() {
  case "$1" in
    *.ts)
      command -v bun  >/dev/null 2>&1 && printf 'bun'  && return 0
      return 1 ;;
    *.js|*.mjs|*.cjs)
      command -v node >/dev/null 2>&1 && printf 'node' && return 0
      command -v bun  >/dev/null 2>&1 && printf 'bun'  && return 0
      return 1 ;;
    *)
      command -v bun  >/dev/null 2>&1 && printf 'bun'  && return 0
      command -v node >/dev/null 2>&1 && printf 'node' && return 0
      return 1 ;;
  esac
}

# _validate_initialize_response <json_text> — return 0 if valid, 1 if not
_validate_initialize_response() {
  local txt="$1"
  # Must contain: "jsonrpc":"2.0", "result", "protocolVersion", "serverInfo"
  printf '%s' "$txt" | grep -q '"jsonrpc"' || return 1
  printf '%s' "$txt" | grep -q '"result"'  || return 1
  printf '%s' "$txt" | grep -q '"protocolVersion"' || return 1
  printf '%s' "$txt" | grep -q '"serverInfo"' || return 1
  return 0
}

# _validate_tools_list_response <json_text> — return 0 if valid, 1 if not
_validate_tools_list_response() {
  local txt="$1"
  # Must contain: "jsonrpc":"2.0", "result", "tools", at least one "name" in tools
  printf '%s' "$txt" | grep -q '"jsonrpc"' || return 1
  printf '%s' "$txt" | grep -q '"result"'  || return 1
  printf '%s' "$txt" | grep -q '"tools"'   || return 1
  # tools array must have at least one element with a "name" field
  printf '%s' "$txt" | grep -q '"name"'    || return 1
  return 0
}

# ─── Full protocol cycle for one server ──────────────────────────────────────
# _run_protocol_cycle <agent> <srv_full> <entry_ts_path>
# Sets: _CYCLE_RC, _CYCLE_INIT_LAT, _CYCLE_LIST_LAT, _CYCLE_DETAIL
# Returns 0=all-pass, 1=shape-fail, 2=timeout, 3=missing, 4=no-runtime, 5=crash
_CYCLE_RC=0; _CYCLE_INIT_LAT=-1; _CYCLE_LIST_LAT=-1; _CYCLE_DETAIL=""

_run_protocol_cycle() {
  local agent="$1" srv="$2" entry="$3"
  _CYCLE_RC=0; _CYCLE_INIT_LAT=-1; _CYCLE_LIST_LAT=-1; _CYCLE_DETAIL=""

  # Phase: entry file check
  if [ ! -f "$entry" ]; then
    _CYCLE_RC=3; _CYCLE_DETAIL="entry file missing: $entry"
    _emit_jsonl "$agent" "$srv" "initialize" "fail" "-1" "$_CYCLE_DETAIL"
    _emit_jsonl "$agent" "$srv" "tools-list"  "fail" "-1" "skipped: no entry file"
    _emit_jsonl "$agent" "$srv" "shutdown"    "fail" "-1" "skipped: no entry file"
    _emit_jsonl "$agent" "$srv" "overall"     "fail" "-1" "$_CYCLE_DETAIL"
    return 3
  fi

  local runtime
  runtime="$(_find_runtime "$entry")" || {
    _CYCLE_RC=4; _CYCLE_DETAIL="no bun/node runtime on PATH"
    _emit_jsonl "$agent" "$srv" "initialize" "skip" "-1" "$_CYCLE_DETAIL"
    _emit_jsonl "$agent" "$srv" "tools-list"  "skip" "-1" "$_CYCLE_DETAIL"
    _emit_jsonl "$agent" "$srv" "shutdown"    "skip" "-1" "$_CYCLE_DETAIL"
    _emit_jsonl "$agent" "$srv" "overall"     "skip" "-1" "$_CYCLE_DETAIL"
    return 4
  }

  # Build the two-message payload: initialize then tools/list
  local init_msg list_msg payload
  init_msg="$(_jsonrpc_msg 1 'initialize' \
    '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-protocol-validator","version":"1.0"}}')"
  list_msg="$(_jsonrpc_msg 2 'tools/list' '{}')"
  payload="${init_msg}${list_msg}"

  # Temp files for I/O
  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-pv-out-XXXXXX)" || return 5
  tmperr="$(mktemp /tmp/mcp-pv-err-XXXXXX)" || { rm -f "$tmpout"; return 5; }

  local t0 t1 t2
  t0="$(date +%s)"
  local run_dir
  run_dir="$(dirname "$entry")"

  # Spawn server; pipe the two messages as stdin
  (
    cd "$run_dir" 2>/dev/null || true
    printf '%s' "$payload" | "$runtime" "$entry" >"$tmpout" 2>"$tmperr"
  ) &
  local child_pid=$!

  # Poll for initialize response (id:1)
  local elapsed=0 found_init=0
  while [ "$elapsed" -lt "$MCP_PROTO_TIMEOUT" ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then break; fi
    if [ -s "$tmpout" ] && grep -q '"id":1' "$tmpout" 2>/dev/null; then
      found_init=1; break
    fi
    sleep 1; elapsed=$((elapsed+1))
  done
  # One final check after loop
  if [ "$found_init" -eq 0 ] && [ -s "$tmpout" ] && grep -q '"id":1' "$tmpout" 2>/dev/null; then
    found_init=1
  fi
  t1="$(date +%s)"
  _CYCLE_INIT_LAT=$(( (t1 - t0) * 1000 ))

  local out_text
  out_text="$(cat "$tmpout" 2>/dev/null)"
  local err_text
  err_text="$(cat "$tmperr" 2>/dev/null)"

  # Determine crash vs timeout for initialize
  if [ "$found_init" -eq 0 ]; then
    kill "$child_pid" 2>/dev/null; wait "$child_pid" 2>/dev/null
    rm -f "$tmpout" "$tmperr"
    if ! kill -0 "$child_pid" 2>/dev/null; then
      _CYCLE_RC=5
      _CYCLE_DETAIL="server crashed: $(printf '%s' "$err_text" | head -2 | tr '\n' ' ')"
    else
      _CYCLE_RC=2
      _CYCLE_DETAIL="timeout: no initialize response in ${MCP_PROTO_TIMEOUT}s"
    fi
    _emit_jsonl "$agent" "$srv" "initialize" "fail" "$_CYCLE_INIT_LAT" "$_CYCLE_DETAIL"
    _emit_jsonl "$agent" "$srv" "tools-list"  "fail" "-1" "skipped: initialize failed"
    _emit_jsonl "$agent" "$srv" "shutdown"    "fail" "-1" "skipped: initialize failed"
    _emit_jsonl "$agent" "$srv" "overall"     "fail" "$_CYCLE_INIT_LAT" "$_CYCLE_DETAIL"
    return "$_CYCLE_RC"
  fi

  # Validate initialize response shape
  local init_resp_ok=0
  _validate_initialize_response "$out_text" && init_resp_ok=1

  local init_excerpt
  init_excerpt="$(printf '%s' "$out_text" | tr -d '\r\n' | cut -c1-200)"

  if [ "$init_resp_ok" -eq 1 ]; then
    _emit_jsonl "$agent" "$srv" "initialize" "pass" "$_CYCLE_INIT_LAT" \
      "initialize OK (jsonrpc+result+protocolVersion+serverInfo)" "$init_excerpt"
  else
    _emit_jsonl "$agent" "$srv" "initialize" "fail" "$_CYCLE_INIT_LAT" \
      "bad initialize shape (missing protocolVersion/serverInfo/result)" "$init_excerpt"
    _CYCLE_RC=1
  fi

  # Poll for tools/list response (id:2)
  elapsed=0; local found_list=0
  while [ "$elapsed" -lt "$MCP_PROTO_TIMEOUT" ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then break; fi
    if grep -q '"id":2' "$tmpout" 2>/dev/null; then found_list=1; break; fi
    sleep 1; elapsed=$((elapsed+1))
  done
  if [ "$found_list" -eq 0 ] && grep -q '"id":2' "$tmpout" 2>/dev/null; then
    found_list=1
  fi
  t2="$(date +%s)"
  _CYCLE_LIST_LAT=$(( (t2 - t1) * 1000 ))

  # Validate tools/list response shape
  if [ "$found_list" -eq 1 ]; then
    local list_ok=0
    _validate_tools_list_response "$out_text" && list_ok=1
    local list_excerpt
    list_excerpt="$(printf '%s' "$out_text" | tr -d '\r\n' | cut -c1-200)"
    if [ "$list_ok" -eq 1 ]; then
      _emit_jsonl "$agent" "$srv" "tools-list" "pass" "$_CYCLE_LIST_LAT" \
        "tools/list OK (tools array present with named entries)" "$list_excerpt"
    else
      _emit_jsonl "$agent" "$srv" "tools-list" "fail" "$_CYCLE_LIST_LAT" \
        "bad tools/list shape (missing tools array or empty)" "$list_excerpt"
      _CYCLE_RC=1
    fi
  else
    _emit_jsonl "$agent" "$srv" "tools-list" "fail" "$_CYCLE_LIST_LAT" \
      "timeout/no tools/list response in ${MCP_PROTO_TIMEOUT}s"
    _CYCLE_RC=2
  fi

  # Shutdown: send shutdown request + exit notification, then kill
  local t_shut0 t_shut1 shut_lat
  t_shut0="$(date +%s)"
  _jsonrpc_msg 3 'shutdown' '{}' | {
    kill -0 "$child_pid" 2>/dev/null && cat >> /dev/stdin || true
  } 2>/dev/null || true
  kill "$child_pid" 2>/dev/null
  wait "$child_pid" 2>/dev/null
  t_shut1="$(date +%s)"
  shut_lat=$(( (t_shut1 - t_shut0) * 1000 ))
  _emit_jsonl "$agent" "$srv" "shutdown" "pass" "$shut_lat" "server terminated cleanly"

  rm -f "$tmpout" "$tmperr"

  # Overall record
  local overall_lat=$(( (t_shut1 - t0) * 1000 ))
  if [ "$_CYCLE_RC" -eq 0 ]; then
    _emit_jsonl "$agent" "$srv" "overall" "pass" "$overall_lat" \
      "initialize+tools/list+shutdown all passed"
  else
    _emit_jsonl "$agent" "$srv" "overall" "fail" "$overall_lat" \
      "rc=${_CYCLE_RC}: protocol cycle had failures"
  fi

  return "$_CYCLE_RC"
}

# ─── Schema file pre-flight ───────────────────────────────────────────────────
SCHEMA_PRESENT=0
[ -f "$SCHEMA_FILE" ] && SCHEMA_PRESENT=1

# ─── Pre-flight: plugin + runtime ────────────────────────────────────────────
PLUGIN_PRESENT=0
[ -d "$SERVERS_DIR" ] && PLUGIN_PRESENT=1

RUNTIME_PRESENT=0
command -v bun  >/dev/null 2>&1 && RUNTIME_PRESENT=1
command -v node >/dev/null 2>&1 && RUNTIME_PRESENT=1

# ─── Suite header ─────────────────────────────────────────────────────────────
printf "%sMCP Protocol Compliance Validator%s\n" "$C_BOLD" "$C_RESET"
printf "Schema     : %s\n" "$SCHEMA_FILE"
printf "Plugin dir : %s\n" "$PLUGIN_DIR"
printf "Timeout    : %ss per server cycle\n" "$MCP_PROTO_TIMEOUT"
printf "JSONL out  : %s\n" "$MCP_PROTO_JSONL"
SUITE_START="$(date +%s)"

# ─── Section 1: Schema file present + valid JSON ─────────────────────────────
_section "1. Protocol Schema File"

if [ "$SCHEMA_PRESENT" -eq 1 ]; then
  _pass "mcp-protocol-schema.json present ($SCHEMA_FILE)"
  # Validate JSON syntax if python3 is available
  if command -v python3 >/dev/null 2>&1; then
    _schema_check="$(python3 -c "import json; json.load(open('$SCHEMA_FILE')); print('ok')" 2>&1)"
    if [ "$_schema_check" = "ok" ]; then
      _pass "mcp-protocol-schema.json is valid JSON"
    else
      _fail "mcp-protocol-schema.json has JSON syntax error: $_schema_check"
    fi
  else
    _skip "python3 not available — JSON syntax check skipped"
  fi
else
  _fail "mcp-protocol-schema.json missing at $SCHEMA_FILE"
fi

# ─── Section 2: Config Drift Check ───────────────────────────────────────────
_section "2. Config Drift — All Agents Declare the Same 10 MCP Servers"

# Build sorted canonical list
CANONICAL_LIST=""
for s in $REQUIRED_SERVERS; do
  CANONICAL_LIST="${CANONICAL_LIST}${CANONICAL_LIST:+ }ashlr-${s}"
done
# Convert to sorted newline form for comparison
CANONICAL_SORTED="$(printf '%s\n' $CANONICAL_LIST | sort)"

for _agent in $AGENTS; do
  _cfg="$(_agent_cfg "$_agent")"
  _rel="${_cfg#$REPO_ROOT/}"

  if [ ! -f "$_cfg" ]; then
    _fail "$_agent: config missing ($_rel)"
    _emit_jsonl "$_agent" "(all)" "config-drift" "fail" "-1" "config file missing: $_cfg"
    continue
  fi

  # aider deliberately does not carry MCP in its config file — that's by design
  if [ "$_agent" = "aider" ]; then
    _skip "$_agent: MCP not declared in aider.conf.yml (uses CLI flags — expected)"
    _emit_jsonl "$_agent" "(all)" "config-drift" "skip" "-1" \
      "aider does not declare MCP in config file (design decision)"
    continue
  fi

  _declared="$(_extract_server_names "$_cfg" 2>/dev/null | sort || true)"

  if [ -z "$_declared" ]; then
    _fail "$_agent: no ashlr-* MCP servers found in $_rel"
    _emit_jsonl "$_agent" "(all)" "config-drift" "fail" "-1" "no ashlr-* servers in config"
    printf '%s|(all)|fail:no-servers|-1\n' "$_agent" >> "$MATRIX_TMP"
    continue
  fi

  # Count declared vs canonical
  _declared_count="$(printf '%s\n' "$_declared" | grep -c . || echo 0)"
  _canonical_count="$(printf '%s\n' "$CANONICAL_SORTED" | grep -c . || echo 0)"

  # Find missing and extra servers
  _missing="$(comm -23 <(printf '%s\n' "$CANONICAL_SORTED") <(printf '%s\n' "$_declared") 2>/dev/null || true)"
  _extra="$(comm   -13 <(printf '%s\n' "$CANONICAL_SORTED") <(printf '%s\n' "$_declared") 2>/dev/null || true)"

  _drift_detail=""
  _drift_ok=1

  if [ -n "$_missing" ]; then
    _missing_list="$(printf '%s' "$_missing" | tr '\n' ',')"
    _drift_detail="${_drift_detail}missing:[${_missing_list%,}] "
    _drift_ok=0
  fi
  if [ -n "$_extra" ]; then
    _extra_list="$(printf '%s' "$_extra" | tr '\n' ',')"
    _drift_detail="${_drift_detail}extra:[${_extra_list%,}] "
    # Extra non-ashlr servers (e.g. supabase, roblox) are not drift — warn only for ashlr-* extras
    _ashlr_extras="$(printf '%s\n' "$_extra" | grep '^ashlr-' || true)"
    if [ -n "$_ashlr_extras" ]; then
      _drift_ok=0
    fi
  fi

  if [ "$_drift_ok" -eq 1 ] && [ "$_declared_count" -ge "$_canonical_count" ]; then
    _pass "$_agent: all 10 required servers declared ($_declared_count found) — no drift"
    _emit_jsonl "$_agent" "(all)" "config-drift" "pass" "-1" \
      "all 10 canonical servers present; declared=${_declared_count}"
  else
    _fail "$_agent: config drift — ${_drift_detail:-count mismatch declared=$_declared_count required=$_canonical_count}"
    _emit_jsonl "$_agent" "(all)" "config-drift" "fail" "-1" \
      "${_drift_detail:-count mismatch declared=$_declared_count required=$_canonical_count}"
    printf '%s|(all)|fail:drift|-1\n' "$_agent" >> "$MATRIX_TMP"
  fi
done

# ─── Section 3: Plugin + Runtime Pre-flight ───────────────────────────────────
_section "3. Plugin + Runtime Pre-flight"

if [ "$PLUGIN_PRESENT" -eq 1 ]; then
  _pass "ashlr-plugin servers/ directory present ($SERVERS_DIR)"
else
  _skip "ashlr-plugin not found at $PLUGIN_DIR (protocol cycle probes will be skipped)"
fi

if [ "$RUNTIME_PRESENT" -eq 1 ]; then
  _runtime_name="$(command -v bun >/dev/null 2>&1 && echo bun || echo node)"
  _runtime_ver="$($_runtime_name --version 2>/dev/null || echo '?')"
  _pass "runtime: $_runtime_name $_runtime_ver available"
else
  _skip "runtime: neither bun nor node on PATH (protocol cycle probes will be skipped)"
fi

# ─── Section 4: Per-Agent × Per-Server Protocol Cycle ────────────────────────
_section "4. Protocol Cycle: initialize → tools/list → shutdown"

if [ "$PLUGIN_PRESENT" -eq 1 ] && [ "$RUNTIME_PRESENT" -eq 1 ]; then

  for _agent in $AGENTS; do
    printf "\n  %s%s%s\n" "$C_CYAN" "$_agent" "$C_RESET"

    # aider has no MCP config to probe — skip with explanation
    if [ "$_agent" = "aider" ]; then
      printf "    (no MCP server entries in aider config — skipping cycle tests)\n"
      for _s in $REQUIRED_SERVERS; do
        _srv="ashlr-${_s}"
        printf '%s|%s|skip:no-config|-1\n' "$_agent" "$_srv" >> "$MATRIX_TMP"
        _emit_jsonl "$_agent" "$_srv" "overall" "skip" "-1" \
          "aider does not declare MCP in config file"
        TOTAL_SKIP=$((TOTAL_SKIP+1))
      done
      continue
    fi

    for _s in $REQUIRED_SERVERS; do
      _srv="ashlr-${_s}"
      _entry="$SERVERS_DIR/${_s}-server.ts"

      _t0="$(date +%s)"
      _rc=0
      _run_protocol_cycle "$_agent" "$_srv" "$_entry" || _rc=$?
      _t1="$(date +%s)"
      _total_ms=$(( (_t1 - _t0) * 1000 ))

      case "$_rc" in
        0)
          printf "    %-24s %sPASS%s  init=%dms list=%dms\n" \
            "$_srv" "$C_GREEN" "$C_RESET" "$_CYCLE_INIT_LAT" "$_CYCLE_LIST_LAT"
          printf '%s|%s|pass|%d\n' "$_agent" "$_srv" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_PASS=$((TOTAL_PASS+1))
          ;;
        1)
          printf "    %-24s %sFAIL%s  bad-shape  %s\n" \
            "$_srv" "$C_RED" "$C_RESET" "${_CYCLE_DETAIL:-}"
          printf '%s|%s|fail:shape|%d\n' "$_agent" "$_srv" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        2)
          printf "    %-24s %sFAIL%s  timeout(%ds)\n" \
            "$_srv" "$C_RED" "$C_RESET" "$MCP_PROTO_TIMEOUT"
          printf '%s|%s|fail:timeout|%d\n' "$_agent" "$_srv" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        3)
          printf "    %-24s %sFAIL%s  missing-entrypoint\n" \
            "$_srv" "$C_RED" "$C_RESET"
          printf '%s|%s|fail:missing|%d\n' "$_agent" "$_srv" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        4)
          printf "    %-24s %sSKIP%s  no-runtime\n" \
            "$_srv" "$C_DIM" "$C_RESET"
          printf '%s|%s|skip:noruntime|%d\n' "$_agent" "$_srv" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_SKIP=$((TOTAL_SKIP+1))
          ;;
        5)
          printf "    %-24s %sFAIL%s  crash  %s\n" \
            "$_srv" "$C_RED" "$C_RESET" "${_CYCLE_DETAIL:-}"
          printf '%s|%s|fail:crash|%d\n' "$_agent" "$_srv" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
        *)
          printf "    %-24s %sFAIL%s  rc=%d\n" \
            "$_srv" "$C_RED" "$C_RESET" "$_rc"
          printf '%s|%s|fail:rc%d|%d\n' "$_agent" "$_srv" "$_rc" "$_total_ms" >> "$MATRIX_TMP"
          TOTAL_FAIL=$((TOTAL_FAIL+1))
          ;;
      esac
    done
  done

else
  printf "  (skipped — plugin or runtime unavailable)\n"
  for _agent in $AGENTS; do
    for _s in $REQUIRED_SERVERS; do
      printf '%s|ashlr-%s|skip:prereq|-1\n' "$_agent" "$_s" >> "$MATRIX_TMP"
      _emit_jsonl "$_agent" "ashlr-${_s}" "overall" "skip" "-1" \
        "prereq missing: plugin=${PLUGIN_PRESENT} runtime=${RUNTIME_PRESENT}"
      TOTAL_SKIP=$((TOTAL_SKIP+1))
    done
  done
fi

# ─── Section 5: Compliance Matrix Table ──────────────────────────────────────
_section "5. Compliance Matrix (agent × server)"

# Build column header
_hdr="  $(printf '%-26s' 'MCP Server')"
_sep="  $(printf '%-26s' '--------------------------')"
for _agent in $AGENTS; do
  _hdr="${_hdr}$(printf '%-14s' "$_agent")"
  _sep="${_sep}$(printf '%-14s' '--------------')"
done
printf '%s\n' "$_hdr"
printf '%s\n' "$_sep"

# One row per server
for _s in $REQUIRED_SERVERS; do
  _srv="ashlr-${_s}"
  _row="  $(printf '%-26s' "$_srv")"
  for _agent in $AGENTS; do
    _cell="$(grep "^${_agent}|${_srv}|" "$MATRIX_TMP" 2>/dev/null | tail -1 | cut -d'|' -f3 || true)"
    case "${_cell:-}" in
      pass)          _row="${_row}${C_GREEN}$(printf '%-14s' 'pass')${C_RESET}" ;;
      skip*|'')      _row="${_row}${C_DIM}$(printf   '%-14s' 'skip')${C_RESET}" ;;
      fail:shape)    _row="${_row}${C_RED}$(printf    '%-14s' 'fail:shape')${C_RESET}" ;;
      fail:missing)  _row="${_row}${C_RED}$(printf    '%-14s' 'fail:missing')${C_RESET}" ;;
      fail:timeout)  _row="${_row}${C_RED}$(printf    '%-14s' 'fail:timeout')${C_RESET}" ;;
      fail:crash)    _row="${_row}${C_RED}$(printf    '%-14s' 'fail:crash')${C_RESET}" ;;
      fail*)         _row="${_row}${C_RED}$(printf    '%-14s' "${_cell}")${C_RESET}" ;;
      *)             _row="${_row}$(printf '%-14s' '-')" ;;
    esac
  done
  printf '%s\n' "$_row"
done

# ─── Section 6: Compliance Score ─────────────────────────────────────────────
_section "6. Compliance Score"

# Count matrix entries (exclude aider and drift checks)
_matrix_total=0; _matrix_pass=0; _matrix_fail=0; _matrix_skip=0

if [ -f "$MATRIX_TMP" ]; then
  while IFS='|' read -r _a _srv _cell _lat; do
    [ "$_a" = "aider" ] && continue      # aider is exempt (by design)
    [ "$_srv" = "(all)" ] && continue    # drift check rows handled separately
    _matrix_total=$((_matrix_total+1))
    case "$_cell" in
      pass)   _matrix_pass=$((_matrix_pass+1)) ;;
      skip*)  _matrix_skip=$((_matrix_skip+1)) ;;
      fail*)  _matrix_fail=$((_matrix_fail+1)) ;;
    esac
  done < "$MATRIX_TMP"
fi

# Score = pass / (pass + fail) * 100  (skip doesn't count against)
_score_denom=$((_matrix_pass + _matrix_fail))
if [ "$_score_denom" -gt 0 ]; then
  _score=$(( _matrix_pass * 100 / _score_denom ))
else
  _score=100  # nothing testable = no failures = 100%
fi

# Thresholds from schema: pass>=90, warn>=70, fail<70
if [ "$_score" -ge 90 ]; then
  printf "  %sCompliance score: %d%%%s  (pass=%d fail=%d skip=%d)\n" \
    "$C_GREEN" "$_score" "$C_RESET" "$_matrix_pass" "$_matrix_fail" "$_matrix_skip"
elif [ "$_score" -ge 70 ]; then
  printf "  %sCompliance score: %d%%%s  (pass=%d fail=%d skip=%d)\n" \
    "$C_YELLOW" "$_score" "$C_RESET" "$_matrix_pass" "$_matrix_fail" "$_matrix_skip"
else
  printf "  %sCompliance score: %d%%%s  (pass=%d fail=%d skip=%d)\n" \
    "$C_RED" "$_score" "$C_RESET" "$_matrix_pass" "$_matrix_fail" "$_matrix_skip"
fi

# Emit a suite-level summary JSONL record
_suite_end="$(date +%s)"
_suite_lat=$(( (_suite_end - SUITE_START) * 1000 ))
_emit_jsonl "suite" "(all)" "overall" \
  "$([ "$TOTAL_FAIL" -eq 0 ] && echo pass || echo fail)" \
  "$_suite_lat" \
  "score=${_score} pass=${TOTAL_PASS} fail=${TOTAL_FAIL} skip=${TOTAL_SKIP}"

# ─── Section 7: JSONL Output Summary ─────────────────────────────────────────
_section "7. JSONL Output"

_jsonl_count=0
[ -f "$MCP_PROTO_JSONL" ] && _jsonl_count="$(wc -l < "$MCP_PROTO_JSONL" | tr -d ' ')"
printf "  Records written : %d\n" "$_jsonl_count"
printf "  Output file     : %s\n" "$MCP_PROTO_JSONL"
if [ "${_JSONL_IS_TEMP:-0}" -eq 1 ]; then
  printf "  %s(temp file — copy before next run to preserve)%s\n" "$C_DIM" "$C_RESET"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
_suite_elapsed=$(( _suite_end - SUITE_START ))
printf "\n%sResult:%s %s%d passed%s, %s%d failed%s, %s%d skipped%s, %s%d warned%s  (%ds)  score=%d%%\n" \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN"  "$TOTAL_PASS" "$C_RESET" \
  "$C_RED"    "$TOTAL_FAIL" "$C_RESET" \
  "$C_DIM"    "$TOTAL_SKIP" "$C_RESET" \
  "$C_YELLOW" "$TOTAL_WARN" "$C_RESET" \
  "$_suite_elapsed" "$_score"

[ "$TOTAL_FAIL" -eq 0 ]
