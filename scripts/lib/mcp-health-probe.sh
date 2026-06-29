#!/usr/bin/env bash
# mcp-health-probe.sh — MCP Server Health Probe with Auto-Restart + Circuit Breaker
#
# Provides a smart health-check layer that runs alongside agent launches:
#   1. Detects MCP server failures *before* the agent needs them.
#   2. Uses a 2s timeout + per-server retry (exponential backoff) to avoid
#      false positives on slow-starting servers.
#   3. Maintains circuit-breaker state in ~/.ashlr-workbench/mcp-breaker.jsonl
#      so that repeatedly failing servers do not thrash on every launch.
#   4. Provides a pre-launch gate that blocks agent startup if too many servers
#      are open-circuit (default: >3).
#
# Public API (macOS bash 3.2 safe — no GNU-isms, no mapfile):
#
#   mcp_probe_all
#     JSON-RPC ping each of the 10 ashlr-plugin servers with a 2s timeout +
#     retry. Populates MCP_PROBE_RESULTS (space-separated "name:status" pairs)
#     and MCP_PROBE_OPEN_COUNT (number of open-circuit servers).
#     Returns 0 if all servers responded, 1 if any failed.
#
#   mcp_circuit_breaker_status <server_name>
#     Print the circuit state for <server_name>: "closed", "open", or
#     "half-open".  Uses ~/.ashlr-workbench/mcp-breaker.jsonl as backing store.
#     Returns 0 for closed/half-open (allow traffic), 1 for open (block).
#
#   mcp_prelaunch_gate_with_circuit [--max-open <N>]
#     Integrate into start-*.sh scripts. Probes all servers, evaluates circuit
#     state, and returns 1 (abort) if more than --max-open servers (default: 3)
#     are open-circuit. Non-failing servers always allow the agent to proceed.
#
# Environment:
#   ASHLR_PLUGIN_DIR              — path to ashlr-plugin checkout
#                                   (default: ~/Desktop/ashlr-plugin)
#   MCP_HEALTH_PROBE_TIMEOUT      — seconds for each JSON-RPC ping (default: 2)
#   MCP_HEALTH_PROBE_RETRIES      — max probe attempts before circuit-open
#                                   (default: 2)
#   MCP_HEALTH_PROBE_BACKOFF_BASE — exponential backoff base seconds (default: 1)
#   MCP_BREAKER_STORE             — path to the breaker JSONL file
#                                   (default: ~/.ashlr-workbench/mcp-breaker.jsonl)
#   MCP_BREAKER_OPEN_THRESHOLD    — failures before open (default: 3)
#   MCP_BREAKER_HALF_OPEN_AFTER   — seconds before half-open retry (default: 60)
#   MCP_HEALTH_PROBE_VERBOSE      — set non-empty to print probe diagnostics
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_HEALTH_PROBE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_HEALTH_PROBE_SOURCED=1

# ─── Fallback output helpers ──────────────────────────────────────────────────
# Honour any ok/warn/bad/info already defined by the caller (e.g. healthcheck.sh).
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
fi
if ! declare -f warn >/dev/null 2>&1; then
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
fi
if ! declare -f bad >/dev/null 2>&1; then
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
fi
if ! declare -f info >/dev/null 2>&1; then
  info() { printf "  \033[36m•\033[0m %s\n" "$*"; }
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
MCP_HEALTH_PROBE_TIMEOUT="${MCP_HEALTH_PROBE_TIMEOUT:-2}"
MCP_HEALTH_PROBE_RETRIES="${MCP_HEALTH_PROBE_RETRIES:-2}"
MCP_HEALTH_PROBE_BACKOFF_BASE="${MCP_HEALTH_PROBE_BACKOFF_BASE:-1}"
MCP_BREAKER_STORE="${MCP_BREAKER_STORE:-$HOME/.ashlr-workbench/mcp-breaker.jsonl}"
MCP_BREAKER_OPEN_THRESHOLD="${MCP_BREAKER_OPEN_THRESHOLD:-3}"
MCP_BREAKER_HALF_OPEN_AFTER="${MCP_BREAKER_HALF_OPEN_AFTER:-60}"

# Runtime output accumulators (populated by mcp_probe_all).
MCP_PROBE_RESULTS=""     # space-separated "name:status" tokens
MCP_PROBE_OPEN_COUNT=0  # count of servers that are open-circuit after probing

# ─── The 10 ashlr-plugin MCP server short-names ───────────────────────────────
_MCP_HP_SERVERS="efficiency sql bash tree http diff logs genome orient github"

# ─── _mcp_hp_ts ───────────────────────────────────────────────────────────────
# Emit an ISO-8601 UTC timestamp.
_mcp_hp_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ─── _mcp_hp_now_epoch ────────────────────────────────────────────────────────
# Emit the current Unix epoch (seconds).
_mcp_hp_now_epoch() {
  date +%s 2>/dev/null || printf '0'
}

# ─── _mcp_hp_ensure_store ────────────────────────────────────────────────────
# Create the breaker store directory + file if needed.
_mcp_hp_ensure_store() {
  local dir
  dir="$(dirname "$MCP_BREAKER_STORE")"
  mkdir -p "$dir" 2>/dev/null || true
  touch "$MCP_BREAKER_STORE" 2>/dev/null || true
}

# ─── _mcp_hp_find_runtime <entry> ─────────────────────────────────────────────
# Echo the runtime (bun|node) for <entry>, or return 1 if none available.
_mcp_hp_find_runtime() {
  local entry="$1"
  case "$entry" in
    *.ts)
      if command -v bun >/dev/null 2>&1; then printf 'bun'; return 0; fi
      return 1
      ;;
    *.js|*.mjs|*.cjs)
      if command -v node >/dev/null 2>&1; then printf 'node'; return 0; fi
      if command -v bun  >/dev/null 2>&1; then printf 'bun';  return 0; fi
      return 1
      ;;
    *)
      if command -v bun  >/dev/null 2>&1; then printf 'bun';  return 0; fi
      if command -v node >/dev/null 2>&1; then printf 'node'; return 0; fi
      return 1
      ;;
  esac
}

# ─── _mcp_hp_jsonrpc_ping_once <entry> ────────────────────────────────────────
# Fire a minimal JSON-RPC "initialize" frame at the server and wait up to
# MCP_HEALTH_PROBE_TIMEOUT seconds for any line containing "jsonrpc".
#
# Returns:
#   0 — server responded with a jsonrpc line (healthy)
#   1 — timeout (process alive but no response)
#   2 — server crashed (process exited non-zero without response)
#   3 — entry file missing
#   4 — no runtime available
#   5 — malformed response (output present but no "jsonrpc" key)
_mcp_hp_jsonrpc_ping_once() {
  local entry="$1"
  local timeout_s="${MCP_HEALTH_PROBE_TIMEOUT:-2}"

  # ── pre-flight ────────────────────────────────────────────────────────────
  if [ ! -f "$entry" ]; then
    return 3
  fi

  local runtime
  runtime="$(_mcp_hp_find_runtime "$entry")" || return 4

  # ── build a minimal JSON-RPC initialize message (Content-Length framed) ──
  local body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-health-probe","version":"1.0"}}}'
  local len="${#body}"
  local msg
  msg="$(printf 'Content-Length: %d\r\n\r\n%s' "$len" "$body")"

  # ── launch server subprocess ──────────────────────────────────────────────
  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-hp-out-XXXXXX)" || return 2
  tmperr="$(mktemp /tmp/mcp-hp-err-XXXXXX)" || { rm -f "$tmpout"; return 2; }

  local run_dir
  run_dir="$(dirname "$entry")"
  (
    cd "$run_dir" 2>/dev/null || true
    printf '%s' "$msg" | "$runtime" "$entry" >"$tmpout" 2>"$tmperr"
  ) &
  local child_pid=$!

  # ── poll for jsonrpc response ─────────────────────────────────────────────
  local elapsed=0
  local found=0
  local child_alive=1
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      child_alive=0
      break
    fi
    if [ -s "$tmpout" ] && grep -q '"jsonrpc"' "$tmpout" 2>/dev/null; then
      found=1
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # One final check after the loop (process may have just written output).
  if [ "$found" -eq 0 ] && [ -s "$tmpout" ] && grep -q '"jsonrpc"' "$tmpout" 2>/dev/null; then
    found=1
  fi

  # Check if child is still alive BEFORE killing (for timeout classification).
  local still_alive=0
  kill -0 "$child_pid" 2>/dev/null && still_alive=1

  # Capture diagnostics.
  local captured_out captured_err
  captured_out="$(cat "$tmpout" 2>/dev/null)"
  captured_err="$(cat "$tmperr" 2>/dev/null)"
  rm -f "$tmpout" "$tmperr"

  kill "$child_pid" 2>/dev/null
  wait "$child_pid" 2>/dev/null

  if [ "$found" -eq 1 ]; then
    # Validate shape: must have "jsonrpc" AND ("result" or "error").
    if printf '%s' "$captured_out" | grep -qE '"result"|"error"'; then
      return 0
    else
      # Has jsonrpc but no result/error — malformed.
      return 5
    fi
  fi

  # Output present but no jsonrpc key → malformed.
  if [ -n "$captured_out" ]; then
    if [ -n "${MCP_HEALTH_PROBE_VERBOSE:-}" ]; then
      printf '    [probe] malformed: %s\n' "$(printf '%s' "$captured_out" | head -2 | tr '\n' ' ')" >&2
    fi
    return 5
  fi

  # Process still alive after timeout → timeout.
  if [ "$still_alive" -eq 1 ]; then
    return 1
  fi

  # Process exited before timeout with no output → crash.
  if [ -n "${MCP_HEALTH_PROBE_VERBOSE:-}" ] && [ -n "$captured_err" ]; then
    printf '    [probe] crash stderr: %s\n' "$(printf '%s' "$captured_err" | head -2 | tr '\n' ' ')" >&2
  fi
  return 2
}

# ─── _mcp_hp_probe_with_backoff <server_name> <entry> ─────────────────────────
# Probe <entry> up to MCP_HEALTH_PROBE_RETRIES times with exponential backoff.
# Sets _MCP_HP_LAST_RC to the final probe return code.
# Returns 0 if any attempt succeeded, 1 if all attempts failed.
_mcp_hp_probe_with_backoff() {
  local name="$1"
  local entry="$2"
  local max_retries="${MCP_HEALTH_PROBE_RETRIES:-2}"
  local backoff_base="${MCP_HEALTH_PROBE_BACKOFF_BASE:-1}"
  _MCP_HP_LAST_RC=0

  local attempt=0
  local delay=$backoff_base
  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    _mcp_hp_jsonrpc_ping_once "$entry"
    _MCP_HP_LAST_RC=$?

    if [ "$_MCP_HP_LAST_RC" -eq 0 ]; then
      return 0
    fi

    # For missing file or missing runtime, no point retrying.
    if [ "$_MCP_HP_LAST_RC" -eq 3 ] || [ "$_MCP_HP_LAST_RC" -eq 4 ]; then
      return 1
    fi

    # If there are more attempts remaining, wait with exponential backoff.
    if [ "$attempt" -lt "$max_retries" ]; then
      if [ -n "${MCP_HEALTH_PROBE_VERBOSE:-}" ]; then
        printf '    [probe] %s attempt %d/%d failed (rc=%d) — backoff %ds\n' \
          "$name" "$attempt" "$max_retries" "$_MCP_HP_LAST_RC" "$delay" >&2
      fi
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  return 1
}

# ─── _mcp_hp_breaker_read <server_name> ───────────────────────────────────────
# Read the current circuit-breaker record for <server_name> from the store.
# Sets:
#   _MCP_CB_STATE         — "closed" | "open" | "half-open" (default: "closed")
#   _MCP_CB_FAIL_COUNT    — consecutive failure count
#   _MCP_CB_LAST_FAIL_TS  — epoch of the last failure (0 if none)
#   _MCP_CB_LAST_TS       — ISO-8601 timestamp of the last write
_mcp_hp_breaker_read() {
  local name="$1"
  _MCP_CB_STATE="closed"
  _MCP_CB_FAIL_COUNT=0
  _MCP_CB_LAST_FAIL_TS=0
  _MCP_CB_LAST_TS=""

  [ -f "$MCP_BREAKER_STORE" ] || return 0

  # Find the most-recent record for this server (last matching line wins).
  local line
  line="$(grep '"server":"'"$name"'"' "$MCP_BREAKER_STORE" 2>/dev/null | tail -1 || true)"
  [ -z "$line" ] && return 0

  # Extract fields with sed (bash 3.2 safe — no grep -P, no GNU sed).
  local state fail_count last_fail_ts
  state="$(printf '%s' "$line" | sed 's/.*"state":"\([^"]*\)".*/\1/' 2>/dev/null || true)"
  fail_count="$(printf '%s' "$line" | sed 's/.*"fail_count":\([0-9]*\).*/\1/' 2>/dev/null || true)"
  last_fail_ts="$(printf '%s' "$line" | sed 's/.*"last_fail_epoch":\([0-9]*\).*/\1/' 2>/dev/null || true)"
  last_ts="$(printf '%s' "$line" | sed 's/.*"ts":"\([^"]*\)".*/\1/' 2>/dev/null || true)"

  _MCP_CB_STATE="${state:-closed}"
  _MCP_CB_FAIL_COUNT="${fail_count:-0}"
  _MCP_CB_LAST_FAIL_TS="${last_fail_ts:-0}"
  _MCP_CB_LAST_TS="${last_ts:-}"
}

# ─── _mcp_hp_breaker_write <server_name> <state> <fail_count> <last_fail_epoch>
# Append a circuit-breaker record to the store.
_mcp_hp_breaker_write() {
  local name="$1"
  local state="$2"
  local fail_count="$3"
  local last_fail_epoch="$4"

  _mcp_hp_ensure_store

  printf '{"ts":"%s","server":"%s","state":"%s","fail_count":%d,"last_fail_epoch":%d}\n' \
    "$(_mcp_hp_ts)" "$name" "$state" "$fail_count" "$last_fail_epoch" \
    >> "$MCP_BREAKER_STORE" 2>/dev/null || true
}

# ─── _mcp_hp_breaker_evaluate <server_name> <probe_rc> ───────────────────────
# Update the circuit-breaker state for <server_name> based on <probe_rc>.
# probe_rc=0 → success (close/reset circuit).
# probe_rc≠0 → failure (increment counter, potentially open circuit).
# Sets _MCP_CB_NEW_STATE to the resulting state string.
_mcp_hp_breaker_evaluate() {
  local name="$1"
  local probe_rc="$2"
  local open_threshold="${MCP_BREAKER_OPEN_THRESHOLD:-3}"
  local half_open_after="${MCP_BREAKER_HALF_OPEN_AFTER:-60}"
  local now
  now="$(_mcp_hp_now_epoch)"

  _mcp_hp_breaker_read "$name"

  local current_state="$_MCP_CB_STATE"
  local fail_count="$_MCP_CB_FAIL_COUNT"
  local last_fail_ts="$_MCP_CB_LAST_FAIL_TS"

  if [ "$probe_rc" -eq 0 ]; then
    # Success — reset to closed.
    _MCP_CB_NEW_STATE="closed"
    _mcp_hp_breaker_write "$name" "closed" 0 0
    return 0
  fi

  # Failure path.
  fail_count=$((fail_count + 1))
  last_fail_ts="$now"

  if [ "$fail_count" -ge "$open_threshold" ]; then
    _MCP_CB_NEW_STATE="open"
    _mcp_hp_breaker_write "$name" "open" "$fail_count" "$last_fail_ts"
  else
    # Still accumulating failures — remains closed (or half-open moves back).
    _MCP_CB_NEW_STATE="${current_state:-closed}"
    if [ "$_MCP_CB_NEW_STATE" = "open" ]; then
      _MCP_CB_NEW_STATE="open"
    fi
    _mcp_hp_breaker_write "$name" "$_MCP_CB_NEW_STATE" "$fail_count" "$last_fail_ts"
  fi
  return 0
}

# ─── mcp_circuit_breaker_status <server_name> ────────────────────────────────
# Report the circuit state for <server_name>, accounting for the half-open
# window (open circuits become half-open after MCP_BREAKER_HALF_OPEN_AFTER s).
#
# Prints one of: "closed", "open", "half-open"
# Returns:
#   0 — closed or half-open (allow traffic)
#   1 — open (block traffic)
mcp_circuit_breaker_status() {
  local name="$1"
  local half_open_after="${MCP_BREAKER_HALF_OPEN_AFTER:-60}"
  local now
  now="$(_mcp_hp_now_epoch)"

  _mcp_hp_breaker_read "$name"

  local state="$_MCP_CB_STATE"
  local last_fail_ts="$_MCP_CB_LAST_FAIL_TS"

  # An open circuit transitions to half-open once the recovery window passes.
  if [ "$state" = "open" ] && [ "$last_fail_ts" -gt 0 ]; then
    local age=$(( now - last_fail_ts ))
    if [ "$age" -ge "$half_open_after" ]; then
      state="half-open"
    fi
  fi

  printf '%s\n' "$state"

  if [ "$state" = "open" ]; then
    return 1
  fi
  return 0
}

# ─── mcp_probe_all ────────────────────────────────────────────────────────────
# JSON-RPC ping each of the 10 ashlr-plugin MCP servers.
# For each server:
#   1. Check circuit state — if open, skip the live probe.
#   2. Probe with backoff (up to MCP_HEALTH_PROBE_RETRIES attempts).
#   3. Update circuit-breaker state.
#   4. Emit ok/warn/bad output.
#
# Populates:
#   MCP_PROBE_RESULTS    — space-separated "name:status" (healthy|failed|open|skipped)
#   MCP_PROBE_OPEN_COUNT — number of servers in open-circuit state
#
# Returns 0 if all probed servers passed, 1 if any failed.
mcp_probe_all() {
  local plugin_dir="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
  local servers_dir="$plugin_dir/servers"

  MCP_PROBE_RESULTS=""
  MCP_PROBE_OPEN_COUNT=0

  # ── pre-flight ────────────────────────────────────────────────────────────
  if ! command -v bun >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
    warn "mcp-health-probe: no runtime (bun/node) — skipping all probes"
    for name in $_MCP_HP_SERVERS; do
      MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:skipped"
    done
    return 0
  fi

  if [ ! -d "$servers_dir" ]; then
    warn "mcp-health-probe: servers/ not found at $servers_dir — skipping all probes"
    for name in $_MCP_HP_SERVERS; do
      MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:skipped"
    done
    return 0
  fi

  local any_fail=0

  for name in $_MCP_HP_SERVERS; do
    local entry="${servers_dir}/${name}-server.ts"

    # ── check circuit-breaker ───────────────────────────────────────────────
    local cb_state
    cb_state="$(mcp_circuit_breaker_status "$name")"
    if [ "$cb_state" = "open" ]; then
      warn "mcp-health-probe: ashlr-${name}: circuit OPEN — skipping probe"
      MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:open"
      MCP_PROBE_OPEN_COUNT=$((MCP_PROBE_OPEN_COUNT + 1))
      any_fail=1
      continue
    fi

    if [ "$cb_state" = "half-open" ]; then
      info "mcp-health-probe: ashlr-${name}: circuit HALF-OPEN — probing (recovery attempt)"
    fi

    # ── live probe with backoff ─────────────────────────────────────────────
    local probe_rc=0
    _mcp_hp_probe_with_backoff "$name" "$entry"
    probe_rc=$?

    # ── update circuit breaker ──────────────────────────────────────────────
    _mcp_hp_breaker_evaluate "$name" "$probe_rc"
    local new_state="$_MCP_CB_NEW_STATE"

    case "$probe_rc" in
      0)
        ok "mcp-health-probe: ashlr-${name}: healthy"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:healthy"
        if [ "$cb_state" = "half-open" ]; then
          info "mcp-health-probe: ashlr-${name}: circuit closed (recovered)"
        fi
        ;;
      3)
        bad "mcp-health-probe: ashlr-${name}: entry file missing ($entry)"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:failed"
        any_fail=1
        if [ "$new_state" = "open" ]; then
          MCP_PROBE_OPEN_COUNT=$((MCP_PROBE_OPEN_COUNT + 1))
          warn "mcp-health-probe: ashlr-${name}: circuit OPENED after ${MCP_BREAKER_OPEN_THRESHOLD} failures"
        fi
        ;;
      4)
        warn "mcp-health-probe: ashlr-${name}: no runtime (bun/node) — skipped"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:skipped"
        ;;
      1)
        bad "mcp-health-probe: ashlr-${name}: timeout (no jsonrpc response in ${MCP_HEALTH_PROBE_TIMEOUT}s)"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:failed"
        any_fail=1
        if [ "$new_state" = "open" ]; then
          MCP_PROBE_OPEN_COUNT=$((MCP_PROBE_OPEN_COUNT + 1))
          warn "mcp-health-probe: ashlr-${name}: circuit OPENED after ${MCP_BREAKER_OPEN_THRESHOLD} failures"
        fi
        ;;
      2)
        bad "mcp-health-probe: ashlr-${name}: server crashed on startup"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:failed"
        any_fail=1
        if [ "$new_state" = "open" ]; then
          MCP_PROBE_OPEN_COUNT=$((MCP_PROBE_OPEN_COUNT + 1))
          warn "mcp-health-probe: ashlr-${name}: circuit OPENED after ${MCP_BREAKER_OPEN_THRESHOLD} failures"
        fi
        ;;
      5)
        bad "mcp-health-probe: ashlr-${name}: malformed jsonrpc response"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:failed"
        any_fail=1
        if [ "$new_state" = "open" ]; then
          MCP_PROBE_OPEN_COUNT=$((MCP_PROBE_OPEN_COUNT + 1))
          warn "mcp-health-probe: ashlr-${name}: circuit OPENED after ${MCP_BREAKER_OPEN_THRESHOLD} failures"
        fi
        ;;
      *)
        warn "mcp-health-probe: ashlr-${name}: unexpected probe rc=$probe_rc"
        MCP_PROBE_RESULTS="${MCP_PROBE_RESULTS:+$MCP_PROBE_RESULTS }${name}:failed"
        any_fail=1
        ;;
    esac
  done

  return "$any_fail"
}

# ─── mcp_prelaunch_gate_with_circuit [--max-open <N>] ─────────────────────────
# Integration hook for start-*.sh scripts.
#
# Runs mcp_probe_all, then checks MCP_PROBE_OPEN_COUNT against --max-open
# (default: 3). If more than --max-open servers are open-circuit, returns 1
# (indicating the agent should be aborted or degrade gracefully). Otherwise
# returns 0 so the agent starts normally.
#
# The caller decides whether to abort: this function just gates and reports.
#
# Usage in start-*.sh (non-strict, best-effort):
#   mcp_prelaunch_gate_with_circuit || true
#
# Usage in start-*.sh (strict — abort if too many open circuits):
#   mcp_prelaunch_gate_with_circuit --max-open 3 || {
#     echo "Too many MCP servers unavailable — aborting" >&2; exit 1; }
mcp_prelaunch_gate_with_circuit() {
  local max_open=3

  # Parse args.
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-open) shift; max_open="${1:-3}" ;;
      *) ;;
    esac
    shift
  done

  # Run the full probe sweep.
  mcp_probe_all || true  # return value tracked via MCP_PROBE_OPEN_COUNT

  local open_count="$MCP_PROBE_OPEN_COUNT"
  local total=0
  for _t in $_MCP_HP_SERVERS; do total=$((total + 1)); done

  if [ "$open_count" -gt "$max_open" ]; then
    bad "mcp-health-probe: $open_count/$total servers are open-circuit (threshold: $max_open)"
    bad "mcp-health-probe: too many MCP servers unavailable — agent launch blocked"
    return 1
  fi

  if [ "$open_count" -gt 0 ]; then
    warn "mcp-health-probe: $open_count/$total servers open-circuit (below threshold $max_open) — proceeding with degraded capability"
  else
    ok "mcp-health-probe: all $total MCP servers healthy — agent launch permitted"
  fi

  return 0
}

# ─── Standalone execution ──────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail

  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    ok()   { printf "  ✓ %s\n" "$*"; }
    warn() { printf "  ⚠ %s\n" "$*"; }
    bad()  { printf "  ✗ %s\n" "$*"; }
    info() { printf "  • %s\n" "$*"; }
  else
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
    ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
    warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
    bad()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; }
    info() { printf "  %s•%s %s\n" "$C_CYAN"   "$C_RESET" "$*"; }
  fi

  _cmd="${1:-probe}"
  case "$_cmd" in
    probe|probe-all)
      mcp_probe_all
      printf '\nOpen-circuit count: %d\n' "$MCP_PROBE_OPEN_COUNT"
      exit $?
      ;;
    status)
      shift
      _srv="${1:-}"
      if [ -z "$_srv" ]; then
        for _s in $_MCP_HP_SERVERS; do
          _st="$(mcp_circuit_breaker_status "$_s")"
          printf '  %s: %s\n' "$_s" "$_st"
        done
      else
        mcp_circuit_breaker_status "$_srv"
      fi
      exit 0
      ;;
    gate)
      shift
      mcp_prelaunch_gate_with_circuit "$@"
      exit $?
      ;;
    *)
      printf 'Usage: %s [probe-all|status [<server>]|gate [--max-open N]]\n' "$0"
      exit 0
      ;;
  esac
fi
