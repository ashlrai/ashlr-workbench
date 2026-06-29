#!/usr/bin/env bash
# mcp-perf-profiler.sh — MCP Tool Latency Profiler
#
# Wraps MCP tool invocations with wall-clock timing and emits JSONL records
# to ~/.ashlr-workbench/mcp-perf.jsonl for later dashboard analysis.
#
# Public API:
#   mcp_perf_record <agent> <server> <tool> <args_hash> <latency_ms> <result_size> [status]
#       Append one JSONL record to the perf log.
#
#   mcp_perf_probe_tool <agent> <server> <tool> <entry> [params_json]
#       Start the server, send initialize + tools/call, measure wall-clock
#       latency, emit the JSONL record.  Returns 0 on success, non-zero on error.
#
#   mcp_perf_probe_server <agent> <server> <entry>
#       Probe all known tools on a server (calls mcp_perf_probe_tool for each).
#
#   mcp_perf_baseline_all [timeout_seconds]
#       Run a baseline profile across all 10 servers × all 4 agents.
#       Completes in ≤ timeout_seconds (default 60).
#
# Output schema (each line in mcp-perf.jsonl):
#   {
#     "ts":          "<ISO-8601 UTC>",
#     "agent":       "<openhands|goose|aider|ashlrcode>",
#     "server":      "<efficiency|sql|bash|…>",
#     "tool":        "<ashlr__read|…>",
#     "args_hash":   "<8-char hex MD5 of params JSON>",
#     "latency_ms":  <integer>,
#     "result_size": <integer bytes>,
#     "status":      "<ok|error|timeout|skip>"
#   }
#
# Environment variables:
#   ASHLR_PLUGIN_DIR              path to ashlr-plugin checkout (default ~/Desktop/ashlr-plugin)
#   MCP_PERF_LOG                  override log file path
#   MCP_PERF_TOOL_TIMEOUT         seconds per tool call (default 10)
#   MCP_PERF_BASELINE_TIMEOUT     seconds for entire baseline sweep (default 60)
#   NO_COLOR                      disable ANSI escape codes
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_PERF_PROFILER_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_PERF_PROFILER_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────
: "${ASHLR_PLUGIN_DIR:=$HOME/Desktop/ashlr-plugin}"
: "${MCP_PERF_LOG:=$HOME/.ashlr-workbench/mcp-perf.jsonl}"
: "${MCP_PERF_TOOL_TIMEOUT:=10}"
: "${MCP_PERF_BASELINE_TIMEOUT:=60}"

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  _MPP_RESET=""; _MPP_GREEN=""; _MPP_YELLOW=""; _MPP_RED=""; _MPP_DIM=""
else
  _MPP_RESET=$'\033[0m'; _MPP_GREEN=$'\033[32m'
  _MPP_YELLOW=$'\033[33m'; _MPP_RED=$'\033[31m'; _MPP_DIM=$'\033[2m'
fi

# ─── Output helpers (safe fallbacks) ──────────────────────────────────────────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  %s✓%s %s\n" "$_MPP_GREEN"  "$_MPP_RESET" "$*"; }
  warn() { printf "  %s⚠%s %s\n" "$_MPP_YELLOW" "$_MPP_RESET" "$*"; }
  bad()  { printf "  %s✗%s %s\n" "$_MPP_RED"    "$_MPP_RESET" "$*"; }
fi

# ─── Tool registry per server (mirrors mcp-contract-validator.sh) ─────────────
# Used by mcp_perf_probe_server to know which tools to probe.
_MPP_TOOLS_efficiency="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
_MPP_TOOLS_sql="ashlr__sql"
_MPP_TOOLS_bash="ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list"
_MPP_TOOLS_tree="ashlr__tree ashlr__ls"
_MPP_TOOLS_http="ashlr__http ashlr__webfetch ashlr__websearch"
_MPP_TOOLS_diff="ashlr__diff ashlr__diff_semantic"
_MPP_TOOLS_logs="ashlr__logs"
_MPP_TOOLS_genome="ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status"
_MPP_TOOLS_orient="ashlr__orient"
_MPP_TOOLS_github="ashlr__pr ashlr__pr_comment ashlr__pr_approve ashlr__issue ashlr__issue_create ashlr__issue_close"

# Minimal safe params per tool (won't mutate state, won't require credentials).
_MPP_PARAMS_ashlr__read='{"path":"."}'
_MPP_PARAMS_ashlr__grep='{"pattern":"nonexistent_______","path":"."}'
_MPP_PARAMS_ashlr__glob='{"pattern":"*.json"}'
_MPP_PARAMS_ashlr__savings='{}'
_MPP_PARAMS_ashlr__flush='{}'
_MPP_PARAMS_ashlr__sql='{"query":"SELECT 1 AS n"}'
_MPP_PARAMS_ashlr__bash='{"command":"echo perf_probe"}'
_MPP_PARAMS_ashlr__bash_start='{"command":"echo perf_probe_start","id":"perf_probe"}'
_MPP_PARAMS_ashlr__bash_tail='{"id":"perf_probe"}'
_MPP_PARAMS_ashlr__bash_stop='{"id":"perf_probe"}'
_MPP_PARAMS_ashlr__bash_list='{}'
_MPP_PARAMS_ashlr__tree='{"path":"."}'
_MPP_PARAMS_ashlr__ls='{"path":"."}'
_MPP_PARAMS_ashlr__http='{"url":"http://localhost","method":"GET"}'
_MPP_PARAMS_ashlr__webfetch='{"url":"http://localhost"}'
_MPP_PARAMS_ashlr__websearch='{"query":"test"}'
_MPP_PARAMS_ashlr__diff='{"path":".","ref":"HEAD"}'
_MPP_PARAMS_ashlr__diff_semantic='{"path":".","ref":"HEAD"}'
_MPP_PARAMS_ashlr__logs='{"lines":1}'
_MPP_PARAMS_ashlr__genome_propose='{}'
_MPP_PARAMS_ashlr__genome_consolidate='{}'
_MPP_PARAMS_ashlr__genome_status='{}'
_MPP_PARAMS_ashlr__orient='{}'
_MPP_PARAMS_ashlr__pr='{"repo":"owner/repo","number":1}'
_MPP_PARAMS_ashlr__pr_comment='{"repo":"owner/repo","number":1,"body":"probe"}'
_MPP_PARAMS_ashlr__pr_approve='{"repo":"owner/repo","number":1}'
_MPP_PARAMS_ashlr__issue='{"repo":"owner/repo","number":1}'
_MPP_PARAMS_ashlr__issue_create='{"repo":"owner/repo","title":"probe","body":"probe"}'
_MPP_PARAMS_ashlr__issue_close='{"repo":"owner/repo","number":1}'

# ─── _mpp_now_ms ──────────────────────────────────────────────────────────────
# Return current time in milliseconds since epoch.
# Uses python3 (always available on macOS) for sub-second precision.
_mpp_now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

# ─── _mpp_iso_ts ──────────────────────────────────────────────────────────────
# Return current UTC time as ISO-8601 string.
_mpp_iso_ts() {
  python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z")'
}

# ─── _mpp_args_hash <params_json> ─────────────────────────────────────────────
# Return 8-char hex hash of params_json for correlation/grouping.
_mpp_args_hash() {
  local params="$1"
  printf '%s' "$params" | md5 2>/dev/null \
    || printf '%s' "$params" | md5sum 2>/dev/null | cut -c1-8 \
    || printf '%s' "00000000"
}

# ─── mcp_perf_record <agent> <server> <tool> <args_hash> <latency_ms> <result_size> [status] ──
# Append one JSONL performance record to the perf log.
mcp_perf_record() {
  local agent="$1"
  local server="$2"
  local tool="$3"
  local args_hash="$4"
  local latency_ms="$5"
  local result_size="$6"
  local status="${7:-ok}"

  # Ensure log directory exists.
  mkdir -p "$(dirname "$MCP_PERF_LOG")"

  local ts
  ts="$(_mpp_iso_ts)"

  # Emit compact JSONL — no external deps (pure printf).
  printf '{"ts":"%s","agent":"%s","server":"%s","tool":"%s","args_hash":"%s","latency_ms":%s,"result_size":%s,"status":"%s"}\n' \
    "$ts" "$agent" "$server" "$tool" "$args_hash" "$latency_ms" "$result_size" "$status" \
    >> "$MCP_PERF_LOG"
}

# ─── _mpp_send_rpc <fifo> <method> <params_json> <id> ────────────────────────
# Send a single JSON-RPC 2.0 request with Content-Length framing over a FIFO.
_mpp_send_rpc() {
  local fifo="$1"
  local method="$2"
  local params="$3"
  local id="$4"
  local body
  body="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"${method}\",\"params\":${params}}"
  local len=${#body}
  printf 'Content-Length: %d\r\n\r\n%s' "$len" "$body" > "$fifo" 2>/dev/null || true
}

# ─── _mpp_wait_response <tmpout> <id> <timeout> ──────────────────────────────
# Poll tmpout for a JSON-RPC response with the given id.
# Echoes the raw JSON line.  Returns 0 on match, 1 on timeout.
_mpp_wait_response() {
  local tmpout="$1"
  local id="$2"
  local timeout="${3:-$MCP_PERF_TOOL_TIMEOUT}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
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

# ─── _mpp_start_server <entry> <tmpout> <tmperr> ─────────────────────────────
# Launch a bun/node MCP server via FIFO.
# Sets _MPP_SERVER_PID and _MPP_SERVER_FIFO.
# Returns 0 ok, 3 missing entry, 4 no runtime.
_mpp_start_server() {
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

  _MPP_SERVER_FIFO="$(mktemp -u /tmp/mcp-perf-fifo-XXXXXX)"
  mkfifo "$_MPP_SERVER_FIFO" || return 2

  (
    cd "$(dirname "$(dirname "$entry")")" 2>/dev/null \
      || cd "$ASHLR_PLUGIN_DIR" 2>/dev/null \
      || true
    "$runtime" "$entry" <"$_MPP_SERVER_FIFO" >"$tmpout" 2>"$tmperr"
  ) &
  _MPP_SERVER_PID=$!
  return 0
}

# ─── _mpp_kill_server ─────────────────────────────────────────────────────────
_mpp_kill_server() {
  if [ -n "${_MPP_SERVER_PID:-}" ]; then
    kill "$_MPP_SERVER_PID" 2>/dev/null || true
    wait "$_MPP_SERVER_PID" 2>/dev/null || true
    _MPP_SERVER_PID=""
  fi
  if [ -n "${_MPP_SERVER_FIFO:-}" ]; then
    rm -f "$_MPP_SERVER_FIFO"
    _MPP_SERVER_FIFO=""
  fi
}

# ─── mcp_perf_probe_tool <agent> <server> <tool> <entry> [params_json] ────────
# Start the server, initialize, call the tool, measure latency, record JSONL.
# Returns 0 ok, 1 tool error, 2 skip, 3 timeout.
mcp_perf_probe_tool() {
  local agent="$1"
  local server="$2"
  local tool="$3"
  local entry="$4"
  local params="${5:-}"

  # If no params supplied, look up default safe params.
  if [ -z "$params" ]; then
    local params_var="_MPP_PARAMS_${tool}"
    eval "params=\"\${${params_var}:-{}}\""
  fi

  local args_hash
  args_hash="$(_mpp_args_hash "$params")"

  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-perf-out-XXXXXX)"
  tmperr="$(mktemp /tmp/mcp-perf-err-XXXXXX)"

  _MPP_SERVER_PID=""
  _MPP_SERVER_FIFO=""

  _mpp_start_server "$entry" "$tmpout" "$tmperr"
  local start_rc=$?

  if [ "$start_rc" -eq 3 ]; then
    rm -f "$tmpout" "$tmperr"
    mcp_perf_record "$agent" "$server" "$tool" "$args_hash" 0 0 "skip"
    return 2
  fi
  if [ "$start_rc" -eq 4 ]; then
    rm -f "$tmpout" "$tmperr"
    mcp_perf_record "$agent" "$server" "$tool" "$args_hash" 0 0 "skip"
    return 2
  fi
  if [ "$start_rc" -ne 0 ]; then
    rm -f "$tmpout" "$tmperr"
    mcp_perf_record "$agent" "$server" "$tool" "$args_hash" 0 0 "skip"
    return 2
  fi

  # Brief pause for server stdio transport to initialize.
  sleep 1

  # Send initialize.
  _mpp_send_rpc "$_MPP_SERVER_FIFO" "initialize" \
    '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-perf-profiler","version":"1.0"}}' \
    1

  _mpp_wait_response "$tmpout" 1 4 >/dev/null || true

  # Record wall-clock start before the tool call.
  local t_start t_end latency_ms
  t_start="$(_mpp_now_ms)"

  # Build tools/call request.
  local call_params
  call_params="{\"name\":\"${tool}\",\"arguments\":${params}}"
  _mpp_send_rpc "$_MPP_SERVER_FIFO" "tools/call" "$call_params" 2

  # Wait for response and measure elapsed time.
  local resp
  if resp="$(_mpp_wait_response "$tmpout" 2 "$MCP_PERF_TOOL_TIMEOUT")"; then
    t_end="$(_mpp_now_ms)"
    latency_ms=$((t_end - t_start))
    _mpp_kill_server
    rm -f "$tmpout" "$tmperr"

    # Determine status.
    local call_status="ok"
    if printf '%s' "$resp" | grep -q '"error"'; then
      call_status="error"
    fi

    # Measure result payload size.
    local result_size=${#resp}

    mcp_perf_record "$agent" "$server" "$tool" "$args_hash" \
      "$latency_ms" "$result_size" "$call_status"

    if [ "$call_status" = "ok" ]; then
      return 0
    else
      return 1
    fi
  else
    # Timeout.
    t_end="$(_mpp_now_ms)"
    latency_ms=$((t_end - t_start))
    _mpp_kill_server
    rm -f "$tmpout" "$tmperr"
    mcp_perf_record "$agent" "$server" "$tool" "$args_hash" \
      "$latency_ms" 0 "timeout"
    return 3
  fi
}

# ─── mcp_perf_probe_server <agent> <server> <entry> ──────────────────────────
# Probe all known tools for a server, one per invocation.
# Returns count of errors (0 = all ok/skipped).
mcp_perf_probe_server() {
  local agent="$1"
  local server="$2"
  local entry="$3"

  local tools_var="_MPP_TOOLS_${server}"
  local tools
  eval "tools=\"\${${tools_var}:-}\""

  if [ -z "$tools" ]; then
    warn "mcp-perf: no tool list for server '${server}'"
    return 0
  fi

  local errors=0
  for tool in $tools; do
    mcp_perf_probe_tool "$agent" "$server" "$tool" "$entry" || {
      local rc=$?
      [ "$rc" -ne 2 ] && errors=$((errors + 1))
    }
  done
  return "$errors"
}

# ─── mcp_perf_baseline_all [timeout_seconds] ─────────────────────────────────
# Run a baseline profile sweep: all 10 servers × all 4 agents.
# Uses a shared server start per agent×server pair for efficiency.
# Respects MCP_PERF_BASELINE_TIMEOUT.
mcp_perf_baseline_all() {
  local timeout="${1:-$MCP_PERF_BASELINE_TIMEOUT}"
  local deadline
  deadline=$(( $(_mpp_now_ms) + timeout * 1000 ))

  local servers="efficiency sql bash tree http diff logs genome orient github"
  local agents="openhands goose aider ashlrcode"

  printf '\n%smcp-perf baseline%s  (timeout=%ds, log=%s)\n' \
    "${_MPP_DIM}" "${_MPP_RESET}" "$timeout" "$MCP_PERF_LOG"

  local total=0 ok_count=0 skip_count=0 err_count=0

  for server in $servers; do
    local entry="${ASHLR_PLUGIN_DIR}/servers/${server}-server.ts"
    for agent in $agents; do
      # Honour deadline.
      if [ "$(_mpp_now_ms)" -gt "$deadline" ]; then
        warn "mcp-perf: baseline timeout reached (${timeout}s) — stopping early"
        break 2
      fi

      local tools_var="_MPP_TOOLS_${server}"
      local tools
      eval "tools=\"\${${tools_var}:-}\""

      for tool in $tools; do
        total=$((total + 1))
        local rc=0
        mcp_perf_probe_tool "$agent" "$server" "$tool" "$entry" || rc=$?
        case "$rc" in
          0) ok_count=$((ok_count + 1)) ;;
          2) skip_count=$((skip_count + 1)) ;;
          *) err_count=$((err_count + 1)) ;;
        esac
      done
    done
  done

  printf '%smcp-perf baseline complete:%s %d probes — %s%d ok%s, %s%d skip%s, %s%d error%s\n' \
    "${_MPP_DIM}" "${_MPP_RESET}" \
    "$total" \
    "${_MPP_GREEN}" "$ok_count" "${_MPP_RESET}" \
    "${_MPP_YELLOW}" "$skip_count" "${_MPP_RESET}" \
    "${_MPP_RED}" "$err_count" "${_MPP_RESET}"
  printf '%slog: %s%s\n' "${_MPP_DIM}" "$MCP_PERF_LOG" "${_MPP_RESET}"
}
