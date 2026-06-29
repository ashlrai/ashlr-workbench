#!/usr/bin/env bash
# mcp-lifecycle.sh — Stateful MCP server lifecycle manager.
#
# Tracks per-agent MCP server process state, performs health probes every 30s,
# auto-recovers failed servers, and surfaces 'recoverable' vs 'fatal' failures.
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.
#
# Public API:
#   mcp_lc_register      <agent> <server> <entry>
#       Register an MCP server for lifecycle tracking.
#
#   mcp_lc_start         <agent> <server>
#       Start a registered MCP server and track its PID + startup timestamp.
#       Returns 0 on success, non-zero on failure.
#
#   mcp_lc_probe         <agent> <server>
#       Health probe one server (JSON-RPC tools/list heartbeat + timeout check).
#       Returns 0 = healthy, 1 = unhealthy (triggers auto-recovery).
#
#   mcp_lc_probe_agent   <agent>
#       Probe all registered servers for one agent.
#       Returns 0 = all healthy, 1 = at least one unhealthy.
#
#   mcp_lc_heal          <agent>
#       Force immediate probe + recovery cycle for all servers in one agent.
#
#   mcp_lc_status        [agent]
#       Print a human-readable status table for all (or one agent's) servers.
#       Shows: agent, server, pid, uptime, health score, last probe ts.
#
#   mcp_lc_watch         [--verbose]
#       Live dashboard — probe loop, refresh every MCP_LC_PROBE_INTERVAL seconds.
#       --verbose prints full log tail for each probe.  Ctrl-C to stop.
#
#   mcp_lc_shutdown      <agent> [<server>]
#       Gracefully shut down one server (or all servers for an agent).
#       Sets graceful-shutdown flag so auto-recovery does not restart it.
#
#   mcp_lc_shutdown_all
#       Gracefully shut down every tracked server across all agents.
#
# Environment variables (read):
#   MCP_LC_PROBE_INTERVAL   seconds between health probes      (default: 30)
#   MCP_LC_PROBE_TIMEOUT    seconds per heartbeat probe        (default: 5)
#   MCP_LC_MAX_RESTARTS     max restarts before fatal          (default: 3)
#   MCP_LC_STATE_DIR        dir for per-process state files    (default: ~/.ashlr-workbench/mcp-lifecycle)
#   MCP_LC_LIFECYCLE_JSONL  lifecycle event log                (default: ~/.ashlr-workbench/mcp-lifecycle.jsonl)
#   ASHLR_SESSION_EVENTS_PATH  session-events.jsonl path (inherited from session-events.sh)
#   MCP_LC_VERBOSE          non-empty → verbose output
#
# Failure classification:
#   fatal      — plugin dir missing, entry file absent, no runtime → do NOT restart
#   recoverable — network timeout, crash, transient exit → restart up to MCP_LC_MAX_RESTARTS

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_LC_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_LC_SOURCED=1

# ─── Load crash analyzer (optional — degrades gracefully if absent) ───────────
_MCP_LC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -f "${_MCP_LC_LIB_DIR}/mcp-crash-analyzer.sh" ] && \
   [ -z "${_ASHLR_MCP_CRASH_ANALYZER_SOURCED:-}" ]; then
  # shellcheck source=scripts/lib/mcp-crash-analyzer.sh
  . "${_MCP_LC_LIB_DIR}/mcp-crash-analyzer.sh" 2>/dev/null || true
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
: "${MCP_LC_PROBE_INTERVAL:=30}"
: "${MCP_LC_PROBE_TIMEOUT:=5}"
: "${MCP_LC_MAX_RESTARTS:=3}"
: "${MCP_LC_STATE_DIR:=$HOME/.ashlr-workbench/mcp-lifecycle}"
: "${MCP_LC_LIFECYCLE_JSONL:=$HOME/.ashlr-workbench/mcp-lifecycle.jsonl}"

# Session events integration — emit into the same file used by session-events.sh
: "${ASHLR_SESSION_EVENTS_PATH:=$HOME/.ashlr-workbench/session-events.jsonl}"

# ─── Output helpers (fallbacks if not already defined by healthcheck) ─────────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
  info() { printf "  \033[36m•\033[0m %s\n" "$*"; }
fi

# ─── Internal: timestamp helpers ──────────────────────────────────────────────
_mcp_lc_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

_mcp_lc_epoch() {
  date +%s 2>/dev/null || echo 0
}

# ─── Internal: JSON escape ────────────────────────────────────────────────────
_mcp_lc_json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g'   \
    | tr '\n' ' '       \
    | tr '\r' ' '       \
    | tr '\t' ' '
}

# ─── Internal: ensure state directory exists ──────────────────────────────────
_mcp_lc_ensure_dirs() {
  mkdir -p "$MCP_LC_STATE_DIR" 2>/dev/null || true
  local jsonl_dir
  jsonl_dir="$(dirname "$MCP_LC_LIFECYCLE_JSONL")"
  mkdir -p "$jsonl_dir" 2>/dev/null || true
  local se_dir
  se_dir="$(dirname "$ASHLR_SESSION_EVENTS_PATH")"
  mkdir -p "$se_dir" 2>/dev/null || true
}

# ─── Internal: state file path for agent+server ───────────────────────────────
# State file format (one field per line, key=value):
#   entry=<path>
#   pid=<pid>
#   start_ts=<iso8601>
#   start_epoch=<unix>
#   graceful_shutdown=0|1
#   restart_count=<n>
#   last_probe_ts=<iso8601>
#   last_health=ok|fail|unknown
#   failure_class=recoverable|fatal|unknown
_mcp_lc_state_file() {
  local agent="$1"
  local server="$2"
  printf '%s/%s__%s.state' "$MCP_LC_STATE_DIR" "$agent" "$server"
}

# ─── Internal: read one field from a state file ───────────────────────────────
_mcp_lc_state_get() {
  local agent="$1"
  local server="$2"
  local key="$3"
  local sf
  sf="$(_mcp_lc_state_file "$agent" "$server")"
  [ -f "$sf" ] || { printf ''; return 1; }
  grep "^${key}=" "$sf" 2>/dev/null | head -1 | cut -d= -f2-
}

# ─── Internal: write/update one field in a state file ─────────────────────────
_mcp_lc_state_set() {
  local agent="$1"
  local server="$2"
  local key="$3"
  local val="$4"
  local sf
  sf="$(_mcp_lc_state_file "$agent" "$server")"
  _mcp_lc_ensure_dirs
  # Remove existing key line then append updated value.
  if [ -f "$sf" ]; then
    local tmp
    tmp="$(mktemp /tmp/mcp-lc-state-XXXXXX)" || return 1
    grep -v "^${key}=" "$sf" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$sf"
  else
    printf '%s=%s\n' "$key" "$val" > "$sf"
  fi
}

# ─── Internal: initialize a state file from scratch ──────────────────────────
_mcp_lc_state_init() {
  local agent="$1"
  local server="$2"
  local entry="$3"
  local sf
  sf="$(_mcp_lc_state_file "$agent" "$server")"
  _mcp_lc_ensure_dirs
  cat > "$sf" <<EOF
entry=${entry}
pid=0
start_ts=
start_epoch=0
graceful_shutdown=0
restart_count=0
last_probe_ts=
last_health=unknown
failure_class=unknown
EOF
}

# ─── Internal: emit a structured lifecycle event ──────────────────────────────
# Also mirrors into ASHLR_SESSION_EVENTS_PATH so session-events.sh consumers
# (session-analytics.sh) see MCP lifecycle events.
_mcp_lc_emit_event() {
  local event="$1"   # mcp_server_start | mcp_server_probe | mcp_server_recover | mcp_server_fatal | mcp_server_stop
  local agent="$2"
  local server="$3"
  local extra="$4"   # optional extra key=value pairs as JSON fragment

  local ts
  ts="$(_mcp_lc_ts)"
  local esc_agent esc_server esc_extra
  esc_agent="$(_mcp_lc_json_escape "$agent")"
  esc_server="$(_mcp_lc_json_escape "$server")"
  esc_extra="$(_mcp_lc_json_escape "${extra:-}")"

  local record
  if [ -n "${extra:-}" ]; then
    record="{\"ts\":\"${ts}\",\"event\":\"${event}\",\"agent\":\"${esc_agent}\",\"server\":\"${esc_server}\",${extra}}"
  else
    record="{\"ts\":\"${ts}\",\"event\":\"${event}\",\"agent\":\"${esc_agent}\",\"server\":\"${esc_server}\"}"
  fi

  _mcp_lc_ensure_dirs
  printf '%s\n' "$record" >> "$MCP_LC_LIFECYCLE_JSONL" 2>/dev/null || true
  # Mirror into session-events.jsonl (best-effort).
  printf '%s\n' "$record" >> "$ASHLR_SESSION_EVENTS_PATH" 2>/dev/null || true
}

# ─── Internal: classify a failure as recoverable or fatal ─────────────────────
# Fatal: missing entry file, missing plugin dir, missing runtime, parse error
# Recoverable: crash (transient), timeout (network/slow), unknown
_mcp_lc_classify_failure() {
  local agent="$1"
  local server="$2"
  local exit_code="${3:-0}"
  local stderr_snippet="${4:-}"

  # Entry file missing → fatal
  local entry
  entry="$(_mcp_lc_state_get "$agent" "$server" "entry")"
  if [ -n "$entry" ] && [ ! -f "$entry" ]; then
    printf 'fatal'
    return
  fi

  # Plugin dir missing → fatal (entry under ASHLR_PLUGIN_DIR)
  local plugin_dir="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
  if [ ! -d "$plugin_dir" ]; then
    printf 'fatal'
    return
  fi

  # Runtime missing → fatal
  case "${entry:-}" in
    *.ts)
      if ! command -v bun >/dev/null 2>&1; then
        printf 'fatal'; return
      fi ;;
    *.js|*.mjs|*.cjs)
      if ! command -v node >/dev/null 2>&1 && ! command -v bun >/dev/null 2>&1; then
        printf 'fatal'; return
      fi ;;
  esac

  # Parse / syntax error → fatal
  if printf '%s' "$stderr_snippet" | grep -qiE 'SyntaxError|syntax error|unexpected token|parse error'; then
    printf 'fatal'
    return
  fi

  # exit_code=3 (missing file) or =4 (no runtime) → fatal
  if [ "$exit_code" -eq 3 ] || [ "$exit_code" -eq 4 ] || [ "$exit_code" -eq 5 ]; then
    printf 'fatal'
    return
  fi

  # Otherwise: crash (rc=2) or timeout (rc=1) → recoverable
  printf 'recoverable'
}

# ─── Internal: find runtime for an entry file ─────────────────────────────────
_mcp_lc_find_runtime() {
  local entry="$1"
  case "$entry" in
    *.ts)
      command -v bun >/dev/null 2>&1 && { printf 'bun'; return 0; }
      return 1 ;;
    *.js|*.mjs|*.cjs)
      command -v node >/dev/null 2>&1 && { printf 'node'; return 0; }
      command -v bun  >/dev/null 2>&1 && { printf 'bun';  return 0; }
      return 1 ;;
    *)
      command -v bun  >/dev/null 2>&1 && { printf 'bun';  return 0; }
      command -v node >/dev/null 2>&1 && { printf 'node'; return 0; }
      return 1 ;;
  esac
}

# ─── Internal: start the server process (shared by mcp_lc_start + recovery) ──
# Returns 0 if process launched and appears healthy within MCP_LC_PROBE_TIMEOUT.
# Updates state file with new pid + timestamps.
_mcp_lc_launch() {
  local agent="$1"
  local server="$2"

  local entry runtime
  entry="$(_mcp_lc_state_get "$agent" "$server" "entry")"

  # Pre-flight: entry file must exist.
  if [ -z "$entry" ] || [ ! -f "$entry" ]; then
    _mcp_lc_emit_event "mcp_server_fatal" "$agent" "$server" \
      "\"reason\":\"entry_missing\",\"entry\":\"$(_mcp_lc_json_escape "${entry:-}")\""
    _mcp_lc_state_set "$agent" "$server" "last_health" "fail"
    _mcp_lc_state_set "$agent" "$server" "failure_class" "fatal"
    return 3
  fi

  # Pre-flight: runtime.
  runtime="$(_mcp_lc_find_runtime "$entry")" || {
    _mcp_lc_emit_event "mcp_server_fatal" "$agent" "$server" \
      "\"reason\":\"no_runtime\",\"entry\":\"$(_mcp_lc_json_escape "$entry")\""
    _mcp_lc_state_set "$agent" "$server" "last_health" "fail"
    _mcp_lc_state_set "$agent" "$server" "failure_class" "fatal"
    return 4
  }

  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-lc-out-XXXXXX)" || return 2
  tmperr="$(mktemp /tmp/mcp-lc-err-XXXXXX)" || { rm -f "$tmpout"; return 2; }

  local run_dir
  run_dir="$(dirname "$entry")"

  (
    cd "$run_dir" 2>/dev/null || true
    "$runtime" "$entry" </dev/null >"$tmpout" 2>"$tmperr"
  ) &
  local child_pid=$!

  # Poll for healthy init signal.
  local elapsed=0
  local found=0
  local timeout="${MCP_LC_PROBE_TIMEOUT:-5}"
  while [ "$elapsed" -lt "$timeout" ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then break; fi
    if [ -s "$tmpout" ] && grep -q '^{' "$tmpout" 2>/dev/null; then
      found=1; break
    fi
    if [ -s "$tmperr" ] && grep -qiE '(listen|start|ready|running|server)' "$tmperr" 2>/dev/null; then
      found=1; break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # One final check.
  if [ "$found" -eq 0 ] && [ -s "$tmpout" ] && grep -q '^{' "$tmpout" 2>/dev/null; then
    found=1
  fi

  local captured_err
  captured_err="$(cat "$tmperr" 2>/dev/null | head -5 | tr '\n' ' ')"
  rm -f "$tmpout" "$tmperr"

  if [ "$found" -eq 0 ]; then
    # Kill the child and classify the failure.
    kill "$child_pid" 2>/dev/null
    wait "$child_pid" 2>/dev/null
    local cls
    cls="$(_mcp_lc_classify_failure "$agent" "$server" 2 "$captured_err")"
    _mcp_lc_state_set "$agent" "$server" "last_health" "fail"
    _mcp_lc_state_set "$agent" "$server" "failure_class" "$cls"
    _mcp_lc_emit_event "mcp_server_fatal" "$agent" "$server" \
      "\"reason\":\"launch_failed\",\"failure_class\":\"${cls}\",\"stderr\":\"$(_mcp_lc_json_escape "$captured_err")\""
    return 2
  fi

  # Healthy — record state.
  local now_ts now_epoch
  now_ts="$(_mcp_lc_ts)"
  now_epoch="$(_mcp_lc_epoch)"
  _mcp_lc_state_set "$agent" "$server" "pid"         "$child_pid"
  _mcp_lc_state_set "$agent" "$server" "start_ts"    "$now_ts"
  _mcp_lc_state_set "$agent" "$server" "start_epoch" "$now_epoch"
  _mcp_lc_state_set "$agent" "$server" "last_health" "ok"
  _mcp_lc_state_set "$agent" "$server" "failure_class" "unknown"
  _mcp_lc_state_set "$agent" "$server" "last_probe_ts" "$now_ts"

  _mcp_lc_emit_event "mcp_server_start" "$agent" "$server" \
    "\"pid\":${child_pid},\"runtime\":\"${runtime}\""

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════════════

# ─── mcp_lc_register <agent> <server> <entry> ─────────────────────────────────
# Register an MCP server for lifecycle tracking without starting it.
# Idempotent — calling again with the same agent+server resets the state.
mcp_lc_register() {
  local agent="$1"
  local server="$2"
  local entry="$3"
  _mcp_lc_ensure_dirs
  _mcp_lc_state_init "$agent" "$server" "$entry"
}

# ─── mcp_lc_start <agent> <server> ───────────────────────────────────────────
# Start a previously-registered server. Clears graceful-shutdown flag.
# Returns 0 on healthy startup, non-zero on failure.
mcp_lc_start() {
  local agent="$1"
  local server="$2"

  local sf
  sf="$(_mcp_lc_state_file "$agent" "$server")"
  if [ ! -f "$sf" ]; then
    bad "mcp-lifecycle: $agent/$server not registered — call mcp_lc_register first"
    return 1
  fi

  # Clear graceful shutdown flag so recovery works.
  _mcp_lc_state_set "$agent" "$server" "graceful_shutdown" "0"

  _mcp_lc_launch "$agent" "$server"
}

# ─── mcp_lc_probe <agent> <server> ───────────────────────────────────────────
# Health probe one server:
#   1. Check the pid is still alive (kill -0).
#   2. Send a JSON-RPC tools/list request on a short timeout.
#   3. If unhealthy and failure is recoverable: kill → relaunch (auto-recovery).
# Returns 0 = healthy after probe (possibly post-recovery), 1 = still unhealthy.
mcp_lc_probe() {
  local agent="$1"
  local server="$2"

  local sf
  sf="$(_mcp_lc_state_file "$agent" "$server")"
  if [ ! -f "$sf" ]; then
    warn "mcp-lifecycle: $agent/$server not registered — skipping probe"
    return 1
  fi

  # Skip if graceful shutdown requested.
  local gs
  gs="$(_mcp_lc_state_get "$agent" "$server" "graceful_shutdown")"
  if [ "${gs:-0}" = "1" ]; then
    return 0
  fi

  local now_ts
  now_ts="$(_mcp_lc_ts)"
  _mcp_lc_state_set "$agent" "$server" "last_probe_ts" "$now_ts"

  local pid
  pid="$(_mcp_lc_state_get "$agent" "$server" "pid")"

  local process_alive=0
  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    kill -0 "$pid" 2>/dev/null && process_alive=1
  fi

  # If process is alive, attempt a JSON-RPC tools/list heartbeat.
  local heartbeat_ok=0
  if [ "$process_alive" -eq 1 ]; then
    # We send a tools/list request on a temp FIFO and read back any JSON response.
    local hb_tmpout
    hb_tmpout="$(mktemp /tmp/mcp-lc-hb-XXXXXX)" || hb_tmpout=""
    if [ -n "$hb_tmpout" ]; then
      local hb_timeout="${MCP_LC_PROBE_TIMEOUT:-5}"
      local hb_payload
      hb_payload='{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
      # Try to probe: pipe one request to the process's stdin via /proc/PID/fd/0
      # on Linux, or fall back to a no-op pass when stdin can't be injected
      # (macOS doesn't expose /proc). We accept process-alive as sufficient health
      # signal when the stdio pipe isn't accessible — real probing requires the
      # process to have been started with an injectable stdin.
      if [ -e "/proc/${pid}/fd/0" ]; then
        (
          printf '%s\n' "$hb_payload" > "/proc/${pid}/fd/0" 2>/dev/null
        ) &
        local hb_pid=$!
        local hb_elapsed=0
        while [ "$hb_elapsed" -lt "$hb_timeout" ]; do
          if [ -s "$hb_tmpout" ] && grep -q '"result"' "$hb_tmpout" 2>/dev/null; then
            heartbeat_ok=1; break
          fi
          sleep 1
          hb_elapsed=$((hb_elapsed + 1))
        done
        kill "$hb_pid" 2>/dev/null
        wait "$hb_pid" 2>/dev/null
      else
        # macOS: process-alive signal is the heartbeat.
        heartbeat_ok=1
      fi
      rm -f "$hb_tmpout"
    else
      # mktemp failed — treat alive as ok.
      heartbeat_ok="$process_alive"
    fi
  fi

  # Determine overall health.
  local is_healthy=0
  if [ "$process_alive" -eq 1 ] && [ "$heartbeat_ok" -eq 1 ]; then
    is_healthy=1
  fi

  if [ "$is_healthy" -eq 1 ]; then
    _mcp_lc_state_set "$agent" "$server" "last_health" "ok"
    _mcp_lc_emit_event "mcp_server_probe" "$agent" "$server" \
      "\"result\":\"ok\",\"pid\":${pid}"
    return 0
  fi

  # ── Unhealthy path ─────────────────────────────────────────────────────────
  local exit_code=2
  [ "$process_alive" -eq 0 ] && exit_code=2
  [ "$process_alive" -eq 1 ] && exit_code=1  # alive but heartbeat timed out

  # Tail the log if the process has a known log file.
  local log_snippet=""
  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    # Best-effort log tail (stderr redirect captured by start script if present).
    local log_file="${MCP_LC_STATE_DIR}/${agent}__${server}.log"
    if [ -f "$log_file" ]; then
      log_snippet="$(tail -5 "$log_file" 2>/dev/null | tr '\n' ' ')"
    fi
  fi

  local cls
  cls="$(_mcp_lc_classify_failure "$agent" "$server" "$exit_code" "$log_snippet")"
  _mcp_lc_state_set "$agent" "$server" "last_health" "fail"
  _mcp_lc_state_set "$agent" "$server" "failure_class" "$cls"

  _mcp_lc_emit_event "mcp_server_probe" "$agent" "$server" \
    "\"result\":\"fail\",\"pid\":${pid:-0},\"exit_code\":${exit_code},\"failure_class\":\"${cls}\""

  # ── Deep crash analysis via mcp-crash-analyzer ────────────────────────────
  # Emit a richer crash classification record to the lifecycle JSONL.
  if declare -f analyze_mcp_crash >/dev/null 2>&1; then
    local _crash_json
    _crash_json="$(analyze_mcp_crash "$agent" "$server" "$exit_code" "$log_snippet" "" 2>/dev/null)"
    if [ -n "$_crash_json" ]; then
      _mcp_lc_ensure_dirs
      printf '%s\n' "$_crash_json" >> "$MCP_LC_LIFECYCLE_JSONL" 2>/dev/null || true
      printf '%s\n' "$_crash_json" >> "$ASHLR_SESSION_EVENTS_PATH" 2>/dev/null || true
      # Promote the crash_class to failure_class when it gives better signal.
      local _deep_class
      _deep_class="$(printf '%s' "$_crash_json" | grep -o '"crash_class":"[^"]*"' | cut -d'"' -f4)"
      case "${_deep_class:-}" in
        oom|segfault|model_token_overflow|dependency)
          # These are more specific; upgrade to fatal so lifecycle doesn't loop.
          _mcp_lc_state_set "$agent" "$server" "failure_class" "fatal"
          cls="fatal"
          ;;
      esac
    fi
  fi

  # Kill stale process.
  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
  fi
  _mcp_lc_state_set "$agent" "$server" "pid" "0"

  # ── Auto-recovery for recoverable failures ─────────────────────────────────
  if [ "$cls" = "fatal" ]; then
    _mcp_lc_emit_event "mcp_server_fatal" "$agent" "$server" \
      "\"reason\":\"probe_fatal\",\"failure_class\":\"fatal\""
    warn "mcp-lifecycle: $agent/$server — fatal failure, not restarting"
    return 1
  fi

  local restart_count
  restart_count="$(_mcp_lc_state_get "$agent" "$server" "restart_count")"
  restart_count="${restart_count:-0}"
  local max_restarts="${MCP_LC_MAX_RESTARTS:-3}"

  if [ "$restart_count" -ge "$max_restarts" ]; then
    _mcp_lc_emit_event "mcp_server_fatal" "$agent" "$server" \
      "\"reason\":\"max_restarts_exceeded\",\"restart_count\":${restart_count},\"max\":${max_restarts}"
    bad "mcp-lifecycle: $agent/$server — max restarts (${max_restarts}) exceeded, marking fatal"
    _mcp_lc_state_set "$agent" "$server" "failure_class" "fatal"
    return 1
  fi

  restart_count=$((restart_count + 1))
  _mcp_lc_state_set "$agent" "$server" "restart_count" "$restart_count"

  _mcp_lc_emit_event "mcp_server_recover" "$agent" "$server" \
    "\"attempt\":${restart_count},\"max\":${max_restarts}"
  warn "mcp-lifecycle: $agent/$server — recoverable failure, restarting (attempt ${restart_count}/${max_restarts})"

  if _mcp_lc_launch "$agent" "$server"; then
    ok "mcp-lifecycle: $agent/$server — recovered successfully"
    return 0
  else
    bad "mcp-lifecycle: $agent/$server — recovery failed on attempt ${restart_count}"
    return 1
  fi
}

# ─── mcp_lc_probe_agent <agent> ───────────────────────────────────────────────
# Probe all registered servers for one agent. Returns 0 if all healthy.
mcp_lc_probe_agent() {
  local agent="$1"
  local any_fail=0

  _mcp_lc_ensure_dirs
  local sf
  for sf in "$MCP_LC_STATE_DIR"/${agent}__*.state; do
    [ -f "$sf" ] || continue
    local base
    base="$(basename "$sf" .state)"
    local server="${base#${agent}__}"
    mcp_lc_probe "$agent" "$server" || any_fail=1
  done
  return "$any_fail"
}

# ─── mcp_lc_heal <agent> ──────────────────────────────────────────────────────
# Force immediate probe + recovery cycle for all servers in one agent.
mcp_lc_heal() {
  local agent="$1"
  info "mcp-lifecycle: healing agent $agent"
  mcp_lc_probe_agent "$agent"
}

# ─── mcp_lc_status [agent] ────────────────────────────────────────────────────
# Print a human-readable status table.
mcp_lc_status() {
  local filter_agent="${1:-}"
  _mcp_lc_ensure_dirs

  local now_epoch
  now_epoch="$(_mcp_lc_epoch)"

  # Header
  printf "\n%s%-14s %-22s %-8s %-10s %-12s %-20s%s\n" \
    "$(printf '\033[1m')" \
    "AGENT" "SERVER" "PID" "UPTIME" "HEALTH" "LAST PROBE" \
    "$(printf '\033[0m')"
  printf '%s\n' "─────────────────────────────────────────────────────────────────────────────────"

  local found=0
  local sf
  for sf in "$MCP_LC_STATE_DIR"/__*.state "$MCP_LC_STATE_DIR"/*__*.state; do
    [ -f "$sf" ] || continue
    local base
    base="$(basename "$sf" .state)"
    # Parse agent and server from filename: agent__server
    local agent server
    case "$base" in
      *__*)
        agent="${base%%__*}"
        server="${base#*__}"
        ;;
      *)
        continue
        ;;
    esac

    # Filter by agent if specified.
    [ -n "$filter_agent" ] && [ "$agent" != "$filter_agent" ] && continue

    local pid start_epoch last_health last_probe_ts failure_class graceful restart_count
    pid="$(_mcp_lc_state_get "$agent" "$server" "pid")"
    start_epoch="$(_mcp_lc_state_get "$agent" "$server" "start_epoch")"
    last_health="$(_mcp_lc_state_get "$agent" "$server" "last_health")"
    last_probe_ts="$(_mcp_lc_state_get "$agent" "$server" "last_probe_ts")"
    failure_class="$(_mcp_lc_state_get "$agent" "$server" "failure_class")"
    graceful="$(_mcp_lc_state_get "$agent" "$server" "graceful_shutdown")"
    restart_count="$(_mcp_lc_state_get "$agent" "$server" "restart_count")"

    pid="${pid:-0}"
    start_epoch="${start_epoch:-0}"
    last_health="${last_health:-unknown}"
    last_probe_ts="${last_probe_ts:--}"
    failure_class="${failure_class:-unknown}"
    graceful="${graceful:-0}"
    restart_count="${restart_count:-0}"

    # Compute uptime.
    local uptime_str="-"
    if [ "$start_epoch" != "0" ] && [ "$start_epoch" != "" ]; then
      local uptime_secs=$(( now_epoch - start_epoch ))
      if [ "$uptime_secs" -lt 60 ]; then
        uptime_str="${uptime_secs}s"
      elif [ "$uptime_secs" -lt 3600 ]; then
        uptime_str="$(( uptime_secs / 60 ))m$(( uptime_secs % 60 ))s"
      else
        uptime_str="$(( uptime_secs / 3600 ))h$(( (uptime_secs % 3600) / 60 ))m"
      fi
    fi

    # Health score / display.
    local health_display
    if [ "${graceful}" = "1" ]; then
      health_display="stopped"
    elif [ "$last_health" = "ok" ]; then
      health_display="ok(restarts:${restart_count})"
    elif [ "$failure_class" = "fatal" ]; then
      health_display="FATAL"
    else
      health_display="fail(${failure_class})"
    fi

    # Truncate last_probe_ts for display.
    local probe_display="${last_probe_ts}"
    probe_display="${probe_display:-"-"}"
    # Keep just time portion if ISO timestamp.
    case "$probe_display" in
      *T*Z) probe_display="$(printf '%s' "$probe_display" | cut -dT -f2 | cut -dZ -f1)" ;;
    esac

    printf "%-14s %-22s %-8s %-10s %-12s %-20s\n" \
      "$agent" "$server" "$pid" "$uptime_str" "$health_display" "$probe_display"
    found=1
  done

  if [ "$found" -eq 0 ]; then
    if [ -n "$filter_agent" ]; then
      info "No MCP servers registered for agent: $filter_agent"
    else
      info "No MCP servers currently registered in $MCP_LC_STATE_DIR"
    fi
  fi
  echo
}

# ─── mcp_lc_watch [--verbose] ─────────────────────────────────────────────────
# Live dashboard — probes all agents in a loop. Ctrl-C to stop.
mcp_lc_watch() {
  local verbose=0
  [ "${1:-}" = "--verbose" ] && verbose=1

  local interval="${MCP_LC_PROBE_INTERVAL:-30}"
  local agent

  trap 'printf "\nmcp-lifecycle: watch stopped.\n"; exit 0' INT TERM

  while true; do
    # Clear screen and show header.
    if [ -t 1 ]; then
      printf '\033[2J\033[H'
    fi
    printf '%s MCP Lifecycle Dashboard — every %ss (Ctrl-C to stop)\n\n' \
      "$(_mcp_lc_ts)" "$interval"

    # Probe all agents.
    _mcp_lc_ensure_dirs
    local sf
    local agents_seen=""
    for sf in "$MCP_LC_STATE_DIR"/*__*.state; do
      [ -f "$sf" ] || continue
      local base
      base="$(basename "$sf" .state)"
      case "$base" in
        *__*)
          agent="${base%%__*}"
          ;;
        *)
          continue
          ;;
      esac
      # Track unique agents.
      case " $agents_seen " in
        *" $agent "*) : ;;
        *) agents_seen="${agents_seen} ${agent}" ;;
      esac
    done

    for agent in $agents_seen; do
      printf 'Probing agent: %s\n' "$agent"
      mcp_lc_probe_agent "$agent"
      if [ "$verbose" -eq 1 ]; then
        # Show recent lifecycle log entries for this agent.
        if [ -f "$MCP_LC_LIFECYCLE_JSONL" ]; then
          printf '  Recent events:\n'
          grep "\"agent\":\"${agent}\"" "$MCP_LC_LIFECYCLE_JSONL" 2>/dev/null \
            | tail -5 \
            | while IFS= read -r line; do
                printf '    %s\n' "$line"
              done
        fi
      fi
    done

    mcp_lc_status

    sleep "$interval"
  done
}

# ─── mcp_lc_shutdown <agent> [<server>] ───────────────────────────────────────
# Gracefully shut down one server (or all servers for an agent).
# Sets graceful-shutdown flag so probe loop does not restart it.
mcp_lc_shutdown() {
  local agent="$1"
  local server="${2:-}"

  _mcp_lc_ensure_dirs

  _do_shutdown_one() {
    local _agent="$1"
    local _server="$2"
    local _sf
    _sf="$(_mcp_lc_state_file "$_agent" "$_server")"
    [ -f "$_sf" ] || return 0

    # Set graceful shutdown flag BEFORE killing.
    _mcp_lc_state_set "$_agent" "$_server" "graceful_shutdown" "1"

    local _pid
    _pid="$(_mcp_lc_state_get "$_agent" "$_server" "pid")"
    if [ -n "$_pid" ] && [ "$_pid" != "0" ]; then
      kill -0 "$_pid" 2>/dev/null && {
        kill -TERM "$_pid" 2>/dev/null
        # Give it 3s to exit gracefully before SIGKILL.
        local _wait=0
        while [ "$_wait" -lt 3 ]; do
          kill -0 "$_pid" 2>/dev/null || break
          sleep 1
          _wait=$(( _wait + 1 ))
        done
        kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
        wait "$_pid" 2>/dev/null || true
      }
    fi
    _mcp_lc_state_set "$_agent" "$_server" "pid" "0"
    _mcp_lc_state_set "$_agent" "$_server" "last_health" "ok"
    _mcp_lc_emit_event "mcp_server_stop" "$_agent" "$_server" \
      "\"graceful\":true,\"pid\":${_pid:-0}"
    ok "mcp-lifecycle: stopped $_{agent}/$_server (graceful)"
  }

  if [ -n "$server" ]; then
    _do_shutdown_one "$agent" "$server"
  else
    # Shut down all servers for this agent.
    local sf
    for sf in "$MCP_LC_STATE_DIR"/${agent}__*.state; do
      [ -f "$sf" ] || continue
      local base
      base="$(basename "$sf" .state)"
      local _srv="${base#${agent}__}"
      _do_shutdown_one "$agent" "$_srv"
    done
  fi
}

# ─── mcp_lc_shutdown_all ──────────────────────────────────────────────────────
# Gracefully shut down every tracked server across all agents.
mcp_lc_shutdown_all() {
  _mcp_lc_ensure_dirs
  local sf
  for sf in "$MCP_LC_STATE_DIR"/*__*.state; do
    [ -f "$sf" ] || continue
    local base
    base="$(basename "$sf" .state)"
    case "$base" in
      *__*)
        local _agent="${base%%__*}"
        local _server="${base#*__}"
        mcp_lc_shutdown "$_agent" "$_server"
        ;;
    esac
  done
}
