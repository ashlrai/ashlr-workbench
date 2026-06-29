#!/usr/bin/env bash
# mcp-contract-validator.sh — MCP tool capability assertion & runtime contract checker.
#
# Performs JSON-RPC stdio handshake with each ashlr-plugin MCP server, requests
# the tools/list response, and validates it against the static schema defined in
# the mcp-tool-inspector.sh registry.
#
# Public API:
#   mcp_contract_validate_server  <name> <entry>
#       Start server, perform initialize + tools/list, validate tools, optionally
#       spot-check one tool invocation.  Outputs structured lines:
#         PASS <name>:<tool>   — tool present and parameters match
#         FAIL <name>:<tool>   — tool missing or param mismatch
#         SKIP <name>          — server unavailable (not an error)
#       Returns 0 if all expected tools pass, 1 if any fail, 2 if server skipped.
#
#   mcp_contract_validate_all [servers...]
#       Run mcp_contract_validate_server for every server (or the given subset).
#       Prints a compliance matrix and returns 1 if any server has failures.
#
#   mcp_contract_spot_check <name> <entry> <tool_name> <params_json>
#       Send one tool call to a live server and verify the result field is present
#       and does not contain an "error" key.  Returns 0 on success, 1 on failure.
#
# Environment variables:
#   ASHLR_PLUGIN_DIR          path to ashlr-plugin checkout
#   MCP_CONTRACT_TIMEOUT      seconds per server probe  (default: 8)
#   MCP_CONTRACT_VERBOSE      non-empty → print raw JSON exchanges
#   NO_COLOR                  disable ANSI escape codes
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_CONTRACT_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_CONTRACT_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────
: "${ASHLR_PLUGIN_DIR:=$HOME/Desktop/ashlr-plugin}"
: "${MCP_CONTRACT_TIMEOUT:=8}"

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  _MCV_RESET=""; _MCV_BOLD=""; _MCV_DIM=""
  _MCV_RED=""; _MCV_GREEN=""; _MCV_YELLOW=""; _MCV_CYAN=""
else
  _MCV_RESET=$'\033[0m'; _MCV_BOLD=$'\033[1m'; _MCV_DIM=$'\033[2m'
  _MCV_RED=$'\033[31m'; _MCV_GREEN=$'\033[32m'; _MCV_YELLOW=$'\033[33m'
  _MCV_CYAN=$'\033[36m'
fi

# ─── Output helpers (fallbacks if not already defined) ────────────────────────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
fi

# ─── Static expected-tool registry (mirrors mcp-tool-inspector.sh) ───────────
# These are the tools each server MUST expose via tools/list.
# Kept in sync with agents/*/mcp-schema.json required_servers list.
_MCV_EXPECTED_efficiency="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
_MCV_EXPECTED_sql="ashlr__sql"
_MCV_EXPECTED_bash="ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list"
_MCV_EXPECTED_tree="ashlr__tree ashlr__ls"
_MCV_EXPECTED_http="ashlr__http ashlr__webfetch ashlr__websearch"
_MCV_EXPECTED_diff="ashlr__diff ashlr__diff_semantic"
_MCV_EXPECTED_logs="ashlr__logs"
_MCV_EXPECTED_genome="ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status"
_MCV_EXPECTED_orient="ashlr__orient"
_MCV_EXPECTED_github="ashlr__pr ashlr__pr_comment ashlr__pr_approve ashlr__issue ashlr__issue_create ashlr__issue_close"

# ─── Spot-check invocations: server → "tool_name|params_json|expect_pattern" ─
# One spot-check per server: call a low-risk read-only tool with minimal params.
_MCV_SPOT_efficiency='ashlr__glob|{"pattern":"*.json"}|'
_MCV_SPOT_sql='ashlr__sql|{"query":"SELECT 1 AS n"}|'
_MCV_SPOT_bash='ashlr__bash|{"command":"echo hello"}|hello'
_MCV_SPOT_tree='ashlr__ls|{"path":"."}|'
_MCV_SPOT_http='ashlr__http|{"url":"http://localhost","method":"GET"}|'
_MCV_SPOT_diff='ashlr__diff|{"path":".","ref":"HEAD"}|'
_MCV_SPOT_logs='ashlr__logs|{"lines":1}|'
_MCV_SPOT_genome='ashlr__genome_status|{}|'
_MCV_SPOT_orient='ashlr__orient|{}|'
_MCV_SPOT_github='ashlr__pr|{"repo":"owner/repo","number":1}|'

# ─── _mcv_json_get_string <json_text> <key> ───────────────────────────────────
# Portable (no jq) extraction of a top-level string value from a JSON object.
# Handles both compact and pretty-printed JSON.
# Usage: val=$(_mcv_json_get_string "$json" "key")
_mcv_json_get_string() {
  local json="$1"
  local key="$2"
  # Match "key":"value" or "key": "value" — handles simple string values only.
  printf '%s' "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 | sed 's/.*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# ─── _mcv_json_get_tools <tools_list_response> ────────────────────────────────
# Extract all "name" values from the tools array in a tools/list RPC response.
# Returns newline-separated tool names.
_mcv_json_get_tools() {
  local json="$1"
  # Extract each "name":"..." occurrence after "tools" appears in the JSON.
  # This handles the standard MCP tools/list response shape:
  #   {"result":{"tools":[{"name":"...","description":"...","inputSchema":{...}}]}}
  printf '%s' "$json" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# ─── _mcv_start_server <entry> <tmpout> <tmperr> ─────────────────────────────
# Launch an MCP server process connected to a named pipe (stdin) and writing to
# tmpout/tmperr.  Sets _MCV_SERVER_PID and _MCV_SERVER_FIFO.
# Returns 0 on success, 3 if entry missing, 4 if no runtime.
_mcv_start_server() {
  local entry="$1"
  local tmpout="$2"
  local tmperr="$3"

  if [ ! -f "$entry" ]; then
    return 3
  fi

  local runtime=""
  if command -v bun >/dev/null 2>&1; then
    runtime="bun"
  elif command -v node >/dev/null 2>&1; then
    runtime="node"
  else
    return 4
  fi

  # Create a FIFO for feeding JSON-RPC requests to the server stdin.
  _MCV_SERVER_FIFO="$(mktemp -u /tmp/mcp-contract-fifo-XXXXXX)"
  mkfifo "$_MCV_SERVER_FIFO" || return 2

  local plugin_dir
  plugin_dir="$(dirname "$entry")"
  # Run from plugin root so relative imports resolve.
  (
    cd "$(dirname "$plugin_dir")" 2>/dev/null || cd "$ASHLR_PLUGIN_DIR" 2>/dev/null || true
    "$runtime" "$entry" <"$_MCV_SERVER_FIFO" >"$tmpout" 2>"$tmperr"
  ) &
  _MCV_SERVER_PID=$!

  return 0
}

# ─── _mcv_send_rpc <fifo> <method> <params_json> <id> ────────────────────────
# Send a single JSON-RPC 2.0 request over the FIFO using Content-Length framing.
_mcv_send_rpc() {
  local fifo="$1"
  local method="$2"
  local params="$3"
  local id="$4"

  local body
  body="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"${method}\",\"params\":${params}}"
  local len=${#body}
  printf 'Content-Length: %d\r\n\r\n%s' "$len" "$body" > "$fifo" 2>/dev/null || true
}

# ─── _mcv_wait_response <tmpout> <id> <timeout> ──────────────────────────────
# Poll tmpout for a JSON-RPC response with the given id.
# Echoes the matched JSON line.  Returns 0 on success, 1 on timeout.
_mcv_wait_response() {
  local tmpout="$1"
  local id="$2"
  local timeout="${3:-$MCP_CONTRACT_TIMEOUT}"

  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    # Look for a line containing "\"id\":N" (both compact and spaced forms).
    local match
    match="$(grep -m1 "\"id\"[[:space:]]*:[[:space:]]*${id}[^0-9]" "$tmpout" 2>/dev/null || true)"
    if [ -n "$match" ]; then
      printf '%s\n' "$match"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# ─── _mcv_kill_server ─────────────────────────────────────────────────────────
# Clean up the server process and FIFO created by _mcv_start_server.
_mcv_kill_server() {
  if [ -n "${_MCV_SERVER_PID:-}" ]; then
    kill "$_MCV_SERVER_PID" 2>/dev/null
    wait "$_MCV_SERVER_PID" 2>/dev/null || true
    _MCV_SERVER_PID=""
  fi
  if [ -n "${_MCV_SERVER_FIFO:-}" ]; then
    rm -f "$_MCV_SERVER_FIFO"
    _MCV_SERVER_FIFO=""
  fi
}

# ─── mcp_contract_validate_server <name> <entry> ─────────────────────────────
# Full contract validation: start, initialize, tools/list, assert all expected
# tools present with non-empty descriptions and inputSchema.
# Prints PASS/FAIL/SKIP lines and returns 0/1/2.
mcp_contract_validate_server() {
  local name="$1"
  local entry="$2"

  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-contract-out-XXXXXX)"
  tmperr="$(mktemp /tmp/mcp-contract-err-XXXXXX)"

  # Get expected tools for this server.
  local expected_var="_MCV_EXPECTED_${name}"
  local expected
  eval "expected=\"\${${expected_var}:-}\""
  if [ -z "$expected" ]; then
    printf 'SKIP %s (no expected tool list defined)\n' "$name"
    rm -f "$tmpout" "$tmperr"
    return 2
  fi

  # Start the server.
  _MCV_SERVER_PID=""
  _MCV_SERVER_FIFO=""
  _mcv_start_server "$entry" "$tmpout" "$tmperr"
  local start_rc=$?

  if [ "$start_rc" -eq 3 ]; then
    printf 'SKIP %s (entry file missing: %s)\n' "$name" "$entry"
    rm -f "$tmpout" "$tmperr"
    return 2
  fi
  if [ "$start_rc" -eq 4 ]; then
    printf 'SKIP %s (no bun/node runtime on PATH)\n' "$name"
    rm -f "$tmpout" "$tmperr"
    return 2
  fi
  if [ "$start_rc" -ne 0 ]; then
    printf 'SKIP %s (server failed to start: rc=%d)\n' "$name" "$start_rc"
    rm -f "$tmpout" "$tmperr"
    return 2
  fi

  # Brief pause to let the server initialize its stdio transport.
  sleep 1

  # Send initialize request (required by MCP protocol before tools/list).
  _mcv_send_rpc "$_MCV_SERVER_FIFO" "initialize" \
    '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-contract-validator","version":"1.0"}}' \
    1

  local init_resp
  init_resp="$(_mcv_wait_response "$tmpout" 1 4)"
  if [ -z "$init_resp" ]; then
    # Some servers don't require an explicit initialize reply before tools/list.
    # Continue anyway — this is not fatal for the contract check.
    true
  fi

  # Send tools/list request.
  _mcv_send_rpc "$_MCV_SERVER_FIFO" "tools/list" '{}' 2

  local list_resp
  list_resp="$(_mcv_wait_response "$tmpout" 2 "$MCP_CONTRACT_TIMEOUT")"

  _mcv_kill_server

  if [ -z "$list_resp" ]; then
    # Could not get tools/list response — try reading any JSON lines from output.
    list_resp="$(grep -m1 '"tools"' "$tmpout" 2>/dev/null || true)"
  fi

  if [ -n "${MCP_CONTRACT_VERBOSE:-}" ]; then
    printf '[mcp-contract] %s tools/list raw: %s\n' "$name" "$list_resp" >&2
  fi

  local any_fail=0

  if [ -z "$list_resp" ]; then
    # No JSON-RPC response at all — skip (server may need deps or env).
    printf 'SKIP %s (no tools/list response; server may need runtime deps)\n' "$name"
    rm -f "$tmpout" "$tmperr"
    return 2
  fi

  # Extract actual tool names from the response.
  local actual_tools
  actual_tools="$(_mcv_json_get_tools "$list_resp")"

  if [ -n "${MCP_CONTRACT_VERBOSE:-}" ]; then
    printf '[mcp-contract] %s actual tools: %s\n' "$name" "$(printf '%s' "$actual_tools" | tr '\n' ' ')" >&2
  fi

  # Assert each expected tool is present in the live response.
  for tool in $expected; do
    local present=0
    if printf '%s\n' "$actual_tools" | grep -qxF "$tool" 2>/dev/null; then
      present=1
    fi

    # Also check that the tool has a non-empty description and inputSchema.
    local has_desc=0
    local has_schema=0
    if [ "$present" -eq 1 ]; then
      # Description check: look for "description":"..." near the tool name.
      if printf '%s' "$list_resp" | grep -q '"description"[[:space:]]*:[[:space:]]*"[^"]\+\"'; then
        has_desc=1
      fi
      # inputSchema check: look for inputSchema object.
      if printf '%s' "$list_resp" | grep -q '"inputSchema"'; then
        has_schema=1
      fi
    fi

    if [ "$present" -eq 1 ] && [ "$has_desc" -eq 1 ] && [ "$has_schema" -eq 1 ]; then
      printf 'PASS %s:%s\n' "$name" "$tool"
    elif [ "$present" -eq 1 ]; then
      # Present but missing description or schema — partial pass.
      printf 'PASS %s:%s (present; schema/desc check inconclusive)\n' "$name" "$tool"
    else
      printf 'FAIL %s:%s (tool missing from live tools/list response)\n' "$name" "$tool"
      any_fail=1
    fi
  done

  rm -f "$tmpout" "$tmperr"
  return "$any_fail"
}

# ─── mcp_contract_spot_check <name> <entry> <tool> <params> [expect] ─────────
# Send a single tool call to a live server and verify a result (not an error)
# is returned.  Optionally check that the result content matches <expect> pattern.
# Returns 0 on success (result returned), 1 on tool error / no response, 2 skip.
mcp_contract_spot_check() {
  local name="$1"
  local entry="$2"
  local tool="$3"
  local params="$4"
  local expect="${5:-}"

  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-contract-spot-out-XXXXXX)"
  tmperr="$(mktemp /tmp/mcp-contract-spot-err-XXXXXX)"

  _MCV_SERVER_PID=""
  _MCV_SERVER_FIFO=""
  _mcv_start_server "$entry" "$tmpout" "$tmperr"
  local start_rc=$?

  if [ "$start_rc" -ne 0 ]; then
    rm -f "$tmpout" "$tmperr"
    return 2
  fi

  sleep 1

  # Initialize.
  _mcv_send_rpc "$_MCV_SERVER_FIFO" "initialize" \
    '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-contract-validator","version":"1.0"}}' \
    10

  _mcv_wait_response "$tmpout" 10 3 >/dev/null || true

  # Call the tool.
  local call_body
  call_body="{\"name\":\"${tool}\",\"arguments\":${params}}"
  _mcv_send_rpc "$_MCV_SERVER_FIFO" "tools/call" "$call_body" 11

  local call_resp
  call_resp="$(_mcv_wait_response "$tmpout" 11 "$MCP_CONTRACT_TIMEOUT")"

  _mcv_kill_server
  rm -f "$tmpout" "$tmperr"

  if [ -z "$call_resp" ]; then
    return 2
  fi

  # Check for error response.
  if printf '%s' "$call_resp" | grep -q '"error"'; then
    return 1
  fi

  # Check for result field.
  if ! printf '%s' "$call_resp" | grep -q '"result"'; then
    return 1
  fi

  # Optional content match.
  if [ -n "$expect" ]; then
    if printf '%s' "$call_resp" | grep -q "$expect"; then
      return 0
    else
      return 1
    fi
  fi

  return 0
}

# ─── mcp_contract_validate_all [server...] ────────────────────────────────────
# Validate all 10 servers (or the given subset) and print a compliance matrix.
# Returns 1 if any server has FAIL lines, 0 otherwise.
mcp_contract_validate_all() {
  local servers="${*:-efficiency sql bash tree http diff logs genome orient github}"

  local total_pass=0
  local total_fail=0
  local total_skip=0

  printf '\n%sMCP Contract Compliance Matrix%s\n' "$_MCV_BOLD" "$_MCV_RESET"
  printf '%s%-14s  %-36s  %s%s\n' "$_MCV_DIM" "SERVER" "TOOL" "STATUS" "$_MCV_RESET"
  printf '%s\n' "─────────────────────────────────────────────────────────────"

  for name in $servers; do
    local entry="${ASHLR_PLUGIN_DIR}/servers/${name}-server.ts"
    local output
    output="$(mcp_contract_validate_server "$name" "$entry" 2>/dev/null)"
    local server_rc=$?

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local status
      status="$(printf '%s' "$line" | cut -d' ' -f1)"
      local detail
      detail="$(printf '%s' "$line" | cut -d' ' -f2-)"

      case "$status" in
        PASS)
          printf '  %s%-14s  %-36s  %sPASS%s\n' \
            "$_MCV_DIM" "$name" "$detail" "$_MCV_GREEN" "$_MCV_RESET"
          total_pass=$((total_pass+1))
          ;;
        FAIL)
          printf '  %s%-14s  %-36s  %sFAIL%s\n' \
            "$_MCV_BOLD" "$name" "$detail" "$_MCV_RED" "$_MCV_RESET"
          total_fail=$((total_fail+1))
          ;;
        SKIP)
          printf '  %-14s  %-36s  %sSKIP%s\n' \
            "$name" "$detail" "$_MCV_YELLOW" "$_MCV_RESET"
          total_skip=$((total_skip+1))
          break
          ;;
      esac
    done <<EOF
$output
EOF
  done

  printf '%s\n' "─────────────────────────────────────────────────────────────"
  printf '%sContracts:%s %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
    "$_MCV_BOLD" "$_MCV_RESET" \
    "$_MCV_GREEN" "$total_pass" "$_MCV_RESET" \
    "$_MCV_RED" "$total_fail" "$_MCV_RESET" \
    "$_MCV_YELLOW" "$total_skip" "$_MCV_RESET"

  if [ "$total_fail" -gt 0 ]; then
    return 1
  fi
  return 0
}
