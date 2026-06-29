#!/usr/bin/env bash
# agent-monitor.sh — Long-running daemon that supervises workbench agents,
# detects crashes/hangs, and attempts graceful auto-restart with exponential
# backoff.
#
# Usage:
#   scripts/agent-monitor.sh [start|stop|status]
#
# Called by:
#   aw monitor start   — launch the daemon in the background
#   aw monitor stop    — send SIGTERM to the daemon
#   aw monitor status  — print uptime/restart-count/last-check per agent
#
# Behavior:
#   1. Reads agents/monitor.yaml for the supervised-agent list.
#   2. Every CHECK_INTERVAL_SECS (default 10) checks each enabled agent:
#        docker  → docker inspect --format '{{.State.Status}}' <container>
#        pgrep   → pgrep -f <pattern>
#   3. On crash/hang, attempts restart by exec'ing scripts/start-<agent>.sh
#      with MONITOR_RESTART=1 in the environment. Applies exponential backoff
#      (capped at max_backoff_secs) and a max-restarts guard within a rolling
#      backoff window.
#   4. Writes heartbeat + restart events to .ashlr-workbench/monitor.jsonl.
#   5. Writes its own PID to .ashlr-workbench/monitor.pid.
#
# Contract (same as session-log.sh):
#   - Bash 3.2-safe. No mapfile, no sha256sum, no GNU-only date flags.
#   - Never hard-crashes silently — errors are logged to monitor.jsonl.
#   - MONITOR_LOG=0 disables all JSONL writes (useful in tests).

set -uo pipefail

# ─── Resolve workbench root ──────────────────────────────────────────────────
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  _link="$(readlink "$SCRIPT_PATH")"
  case "$_link" in /*) SCRIPT_PATH="$_link" ;; *) SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$_link" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
WORKBENCH="${WORKBENCH:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Paths ───────────────────────────────────────────────────────────────────
MONITOR_CONFIG="${MONITOR_CONFIG:-$WORKBENCH/agents/monitor.yaml}"
MONITOR_DIR="${MONITOR_DIR:-$WORKBENCH/.ashlr-workbench}"
MONITOR_LOG_FILE="${MONITOR_LOG_FILE:-$MONITOR_DIR/monitor.jsonl}"
MONITOR_PID_FILE="${MONITOR_PID_FILE:-$MONITOR_DIR/monitor.pid}"
MONITOR_STATE_FILE="${MONITOR_STATE_FILE:-$MONITOR_DIR/monitor-state.txt}"

# ─── Defaults (can be overridden by env or monitor.yaml defaults block) ───────
CHECK_INTERVAL="${CHECK_INTERVAL_SECS:-10}"

# ─── Colors (NO_COLOR-aware) ─────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

ok()    { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
bad()   { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; }
info()  { printf "  %s•%s %s\n" "$C_CYAN"   "$C_RESET" "$*"; }
title() { printf "%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"; }

# ─── JSONL logger ─────────────────────────────────────────────────────────────
# _monitor_ts — ISO-8601 UTC, millisecond precision where available.
_monitor_ts() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)"
  case "$ts" in *3NZ|"") ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" ;; esac
  printf '%s' "$ts"
}

# _monitor_emit KEY=VALUE... — append one JSONL event to monitor.jsonl
_monitor_emit() {
  [ "${MONITOR_LOG:-1}" = "0" ] && return 0
  mkdir -p "$MONITOR_DIR" 2>/dev/null || return 0
  local pairs="" pair key val
  local ts; ts="$(_monitor_ts)"
  # Always include ts first
  pairs="\"ts\":\"$ts\""
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    # Minimal JSON escaping: backslash then double-quote
    val="$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\031')"
    pairs="${pairs},\"${key}\":\"${val}\""
  done
  printf '{%s}\n' "$pairs" >> "$MONITOR_LOG_FILE" 2>/dev/null || true
}

# ─── YAML config parser ───────────────────────────────────────────────────────
# Minimal line-by-line parser for our known monitor.yaml shape.
# Returns newline-separated KEY=VALUE lines for each agent block.
# Uses python3 if available; otherwise falls back to awk.
_parse_yaml_agents() {
  local config_file="$1"
  if [ ! -f "$config_file" ]; then
    printf '' # no agents
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$config_file" <<'PY'
import sys, re

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Extract defaults block
defaults = {
    'check_interval_secs': '10',
    'max_restarts': '5',
    'backoff_window_secs': '300',
    'initial_backoff_secs': '5',
    'max_backoff_secs': '120',
    'restart_cooldown_secs': '30',
}

in_defaults = False
in_agents = False
in_agent = False
current = {}
agents = []

for line in lines:
    stripped = line.rstrip()
    if re.match(r'^defaults\s*:', stripped):
        in_defaults = True
        in_agents = False
        in_agent = False
        continue
    if re.match(r'^agents\s*:', stripped):
        in_defaults = False
        in_agents = True
        in_agent = False
        continue
    if in_defaults:
        m = re.match(r'^\s{2}(\w+)\s*:\s*(.+)', stripped)
        if m:
            defaults[m.group(1)] = m.group(2).strip()
        elif not stripped.startswith(' '):
            in_defaults = False
    if in_agents:
        # New agent list item
        if re.match(r'^\s{2}-\s+name\s*:', stripped):
            if current:
                agents.append(current)
            current = dict(defaults)
            m = re.match(r'^\s{2}-\s+name\s*:\s*(.+)', stripped)
            if m:
                current['name'] = m.group(1).strip()
        elif in_agent or current:
            m = re.match(r'^\s{4}(\w+)\s*:\s*(.+)', stripped)
            if m:
                current[m.group(1)] = m.group(2).strip()

if current:
    agents.append(current)

for a in agents:
    for k, v in a.items():
        print(f"AGENT_{k.upper()}={v}")
    print("AGENT_END=1")
PY
  else
    # Minimal awk fallback — handles the common case
    awk '
      /^defaults:/ { in_def=1; in_ag=0; next }
      /^agents:/ { in_def=0; in_ag=1; next }
      in_def && /^  [a-z]/ {
        split($0, kv, ":"); gsub(/ /, "", kv[1]); gsub(/^ /, "", kv[2])
        def[kv[1]] = kv[2]
        next
      }
      in_ag && /^  - name:/ {
        if (name != "") {
          for (k in def) if (!(k in cur)) cur[k] = def[k]
          for (k in cur) print "AGENT_" toupper(k) "=" cur[k]
          print "AGENT_END=1"
          delete cur
        }
        split($0, kv, ":"); gsub(/^ - name: /, "", $0); name=$0; cur["name"]=name
        next
      }
      in_ag && /^    [a-z]/ {
        split($0, kv, ":"); key=kv[1]; val=kv[2]
        gsub(/^    /, "", key); gsub(/ /, "", key)
        gsub(/^ /, "", val)
        cur[key] = val
        next
      }
      END {
        if (name != "") {
          for (k in def) if (!(k in cur)) cur[k] = def[k]
          for (k in cur) print "AGENT_" toupper(k) "=" cur[k]
          print "AGENT_END=1"
        }
      }
    ' "$config_file"
  fi
}

# ─── Agent liveness check ─────────────────────────────────────────────────────
# Returns 0 = alive, 1 = dead/missing
_agent_alive() {
  local check_type="$1" check_target="$2"
  case "$check_type" in
    docker)
      if ! command -v docker >/dev/null 2>&1; then return 1; fi
      local state
      state="$(docker inspect --format '{{.State.Status}}' "$check_target" 2>/dev/null || echo missing)"
      [ "$state" = "running" ]
      ;;
    pgrep)
      pgrep -f "$check_target" >/dev/null 2>&1
      ;;
    *)
      # Unknown check type — treat as alive to avoid false restarts
      return 0
      ;;
  esac
}

# ─── State helpers (flat key=value file, Bash 3.2-safe) ───────────────────────
# State keys: <agent>_restart_count, <agent>_last_restart_ts, <agent>_start_ts,
#             <agent>_last_check_ts, <agent>_status, <agent>_backoff_secs

_state_get() {
  local agent="$1" key="$2"
  grep "^${agent}_${key}=" "$MONITOR_STATE_FILE" 2>/dev/null \
    | tail -1 | cut -d= -f2-
}

_state_set() {
  local agent="$1" key="$2" val="$3"
  local tmpf; tmpf="$(mktemp "${MONITOR_STATE_FILE}.XXXXXX")" || return 0
  grep -v "^${agent}_${key}=" "$MONITOR_STATE_FILE" 2>/dev/null > "$tmpf" || true
  printf '%s_%s=%s\n' "$agent" "$key" "$val" >> "$tmpf"
  mv "$tmpf" "$MONITOR_STATE_FILE" 2>/dev/null || true
}

# ─── Restart logic ────────────────────────────────────────────────────────────
_attempt_restart() {
  local agent="$1" start_script="$2"
  local max_restarts="$3" backoff_window="$4"
  local initial_backoff="$5" max_backoff="$6" cooldown="$7"

  local now; now="$(date +%s)"

  # Count restarts within the backoff window
  local restart_count last_restart_ts window_start
  restart_count="$(_state_get "$agent" restart_count)"
  restart_count="${restart_count:-0}"
  last_restart_ts="$(_state_get "$agent" last_restart_ts)"
  last_restart_ts="${last_restart_ts:-0}"
  window_start=$(( now - backoff_window ))

  # Cooldown guard
  if [ "$last_restart_ts" -gt 0 ]; then
    local elapsed=$(( now - last_restart_ts ))
    if [ "$elapsed" -lt "$cooldown" ]; then
      local remaining=$(( cooldown - elapsed ))
      _monitor_emit \
        "event=restart_cooldown" \
        "agent=$agent" \
        "remaining_secs=$remaining"
      return 0
    fi
  fi

  # Rolling window: reset count if last restart was outside the window
  if [ "$last_restart_ts" -lt "$window_start" ]; then
    restart_count=0
  fi

  if [ "$restart_count" -ge "$max_restarts" ]; then
    _monitor_emit \
      "event=restart_limit_reached" \
      "agent=$agent" \
      "restart_count=$restart_count" \
      "max_restarts=$max_restarts"
    warn "monitor: $agent hit restart limit ($restart_count/$max_restarts) — giving up until window resets"
    return 1
  fi

  # Exponential backoff
  local backoff_secs
  backoff_secs="$(_state_get "$agent" backoff_secs)"
  backoff_secs="${backoff_secs:-$initial_backoff}"
  if [ "$restart_count" -gt 0 ]; then
    backoff_secs=$(( backoff_secs * 2 ))
    if [ "$backoff_secs" -gt "$max_backoff" ]; then
      backoff_secs="$max_backoff"
    fi
  fi

  info "monitor: $agent is down — waiting ${backoff_secs}s before restart (attempt $((restart_count+1))/$max_restarts)"
  _monitor_emit \
    "event=restart_scheduled" \
    "agent=$agent" \
    "backoff_secs=$backoff_secs" \
    "attempt=$(( restart_count + 1 ))" \
    "max_restarts=$max_restarts"

  sleep "$backoff_secs"

  # Re-check after the backoff — another process might have restarted it
  local check_type check_target
  check_type="$(_state_get "$agent" check_type)"
  check_target="$(_state_get "$agent" check_target)"
  if [ -n "$check_type" ] && [ -n "$check_target" ]; then
    if _agent_alive "$check_type" "$check_target"; then
      info "monitor: $agent came back on its own during backoff"
      _monitor_emit "event=self_recovered" "agent=$agent"
      _state_set "$agent" backoff_secs "$initial_backoff"
      return 0
    fi
  fi

  local full_script="$WORKBENCH/$start_script"
  if [ ! -x "$full_script" ]; then
    bad "monitor: restart script not found or not executable: $full_script"
    _monitor_emit \
      "event=restart_failed" \
      "agent=$agent" \
      "reason=script_missing" \
      "script=$full_script"
    return 1
  fi

  info "monitor: restarting $agent via $start_script"
  _monitor_emit \
    "event=restart_attempt" \
    "agent=$agent" \
    "attempt=$(( restart_count + 1 ))" \
    "script=$start_script"

  # Run the start script in background so the monitor loop continues
  MONITOR_RESTART=1 "$full_script" >/dev/null 2>&1 &
  local restart_rc=$?

  restart_count=$(( restart_count + 1 ))
  _state_set "$agent" restart_count "$restart_count"
  _state_set "$agent" last_restart_ts "$now"
  _state_set "$agent" backoff_secs "$backoff_secs"
  _state_set "$agent" status "restarting"

  if [ "$restart_rc" -eq 0 ]; then
    _monitor_emit \
      "event=restart_launched" \
      "agent=$agent" \
      "attempt=$restart_count"
    ok "monitor: $agent restart launched (attempt $restart_count/$max_restarts)"
  else
    _monitor_emit \
      "event=restart_failed" \
      "agent=$agent" \
      "exit_code=$restart_rc"
    bad "monitor: $agent restart script exited $restart_rc"
  fi
}

# ─── Daemon loop ──────────────────────────────────────────────────────────────
_run_daemon() {
  mkdir -p "$MONITOR_DIR"
  printf '%d\n' "$$" > "$MONITOR_PID_FILE"

  _monitor_emit "event=monitor_start" "pid=$$" "config=$MONITOR_CONFIG"
  info "monitor daemon started (pid=$$, interval=${CHECK_INTERVAL}s)"
  info "log: $MONITOR_LOG_FILE"

  # Parse config once at startup into an array of agent definition strings.
  # Each "block" is a newline-separated list of AGENT_KEY=VALUE lines.
  local raw_config
  raw_config="$(_parse_yaml_agents "$MONITOR_CONFIG")"

  if [ -z "$raw_config" ]; then
    warn "monitor: no agents found in $MONITOR_CONFIG — nothing to supervise"
    _monitor_emit "event=monitor_no_agents" "config=$MONITOR_CONFIG"
  fi

  # Build per-agent state files from the parsed config
  local agent_names=""  # space-separated list of enabled agents

  # Process each AGENT_END-delimited block
  local block=""
  while IFS= read -r line; do
    if [ "$line" = "AGENT_END=1" ]; then
      # Parse this block
      local name="" enabled="" check_type="" check_target="" start_script=""
      local max_restarts="" backoff_window="" initial_backoff="" max_backoff="" cooldown=""
      while IFS= read -r bline; do
        case "$bline" in
          AGENT_NAME=*)          name="${bline#AGENT_NAME=}" ;;
          AGENT_ENABLED=*)       enabled="${bline#AGENT_ENABLED=}" ;;
          AGENT_CHECK_TYPE=*)    check_type="${bline#AGENT_CHECK_TYPE=}" ;;
          AGENT_CHECK_TARGET=*)  check_target="${bline#AGENT_CHECK_TARGET=}" ;;
          AGENT_START_SCRIPT=*)  start_script="${bline#AGENT_START_SCRIPT=}" ;;
          AGENT_MAX_RESTARTS=*)  max_restarts="${bline#AGENT_MAX_RESTARTS=}" ;;
          AGENT_BACKOFF_WINDOW_SECS=*) backoff_window="${bline#AGENT_BACKOFF_WINDOW_SECS=}" ;;
          AGENT_INITIAL_BACKOFF_SECS=*) initial_backoff="${bline#AGENT_INITIAL_BACKOFF_SECS=}" ;;
          AGENT_MAX_BACKOFF_SECS=*)    max_backoff="${bline#AGENT_MAX_BACKOFF_SECS=}" ;;
          AGENT_RESTART_COOLDOWN_SECS=*) cooldown="${bline#AGENT_RESTART_COOLDOWN_SECS=}" ;;
        esac
      done <<< "$block"

      # Defaults for unset fields
      enabled="${enabled:-true}"
      check_type="${check_type:-docker}"
      max_restarts="${max_restarts:-5}"
      backoff_window="${backoff_window:-300}"
      initial_backoff="${initial_backoff:-5}"
      max_backoff="${max_backoff:-120}"
      cooldown="${cooldown:-30}"

      if [ -n "$name" ] && [ "$enabled" = "true" ]; then
        agent_names="$agent_names $name"
        # Persist config fields in state file so _attempt_restart can read them
        _state_set "$name" check_type "$check_type"
        _state_set "$name" check_target "$check_target"
        _state_set "$name" start_script "$start_script"
        _state_set "$name" max_restarts "$max_restarts"
        _state_set "$name" backoff_window "$backoff_window"
        _state_set "$name" initial_backoff "$initial_backoff"
        _state_set "$name" max_backoff "$max_backoff"
        _state_set "$name" cooldown "$cooldown"
        # Initialise start time
        _state_set "$name" start_ts "$(date +%s)"
        _state_set "$name" status "watching"
        _state_set "$name" restart_count "0"
        _state_set "$name" backoff_secs "$initial_backoff"
      fi
      block=""
    else
      block="${block}${line}
"
    fi
  done <<< "$raw_config"

  # Main check loop
  while true; do
    local now; now="$(date +%s)"

    for agent in $agent_names; do
      local check_type check_target start_script
      local max_restarts backoff_window initial_backoff max_backoff cooldown
      check_type="$(_state_get "$agent" check_type)"
      check_target="$(_state_get "$agent" check_target)"
      start_script="$(_state_get "$agent" start_script)"
      max_restarts="$(_state_get "$agent" max_restarts)"
      backoff_window="$(_state_get "$agent" backoff_window)"
      initial_backoff="$(_state_get "$agent" initial_backoff)"
      max_backoff="$(_state_get "$agent" max_backoff)"
      cooldown="$(_state_get "$agent" cooldown)"

      _state_set "$agent" last_check_ts "$now"

      if _agent_alive "$check_type" "$check_target"; then
        _state_set "$agent" status "running"
        # Emit heartbeat
        _monitor_emit \
          "event=heartbeat" \
          "agent=$agent" \
          "check_type=$check_type" \
          "check_target=$check_target" \
          "status=alive"
      else
        _state_set "$agent" status "down"
        warn "monitor: $agent ($check_target) is down"
        _monitor_emit \
          "event=agent_down" \
          "agent=$agent" \
          "check_type=$check_type" \
          "check_target=$check_target"

        _attempt_restart "$agent" "$start_script" \
          "$max_restarts" "$backoff_window" \
          "$initial_backoff" "$max_backoff" "$cooldown" || true
      fi
    done

    sleep "$CHECK_INTERVAL"
  done
}

# ─── Status subcommand ────────────────────────────────────────────────────────
_cmd_status() {
  title "aw monitor status"

  # Daemon running?
  local daemon_pid=""
  if [ -f "$MONITOR_PID_FILE" ]; then
    daemon_pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)"
  fi
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    ok "daemon running (pid=$daemon_pid)"
  else
    warn "daemon not running  (aw monitor start to launch)"
    daemon_pid=""
  fi
  echo

  if [ ! -f "$MONITOR_STATE_FILE" ]; then
    info "no agent state found (monitor has not been started yet)"
    return 0
  fi

  title "Supervised agents"
  # Extract unique agent names from state file
  local agent_names
  agent_names="$(grep -o '^[a-z][a-zA-Z0-9_]*_' "$MONITOR_STATE_FILE" 2>/dev/null \
    | sort -u | sed 's/_$//' | sort -u)"

  if [ -z "$agent_names" ]; then
    info "no agent state recorded yet"
    return 0
  fi

  local now; now="$(date +%s)"
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    local status restart_count start_ts last_check_ts
    status="$(_state_get "$agent" status)"
    restart_count="$(_state_get "$agent" restart_count)"
    start_ts="$(_state_get "$agent" start_ts)"
    last_check_ts="$(_state_get "$agent" last_check_ts)"

    status="${status:-unknown}"
    restart_count="${restart_count:-0}"

    local uptime_str="unknown"
    if [ -n "$start_ts" ] && [ "$start_ts" != "0" ]; then
      local secs=$(( now - start_ts ))
      local h=$(( secs / 3600 ))
      local m=$(( (secs % 3600) / 60 ))
      local s=$(( secs % 60 ))
      uptime_str=$(printf '%dh%02dm%02ds' "$h" "$m" "$s")
    fi

    local last_check_str="never"
    if [ -n "$last_check_ts" ] && [ "$last_check_ts" != "0" ]; then
      local ago=$(( now - last_check_ts ))
      last_check_str="${ago}s ago"
    fi

    case "$status" in
      running) ok  "$agent  status=$status  uptime=$uptime_str  restarts=$restart_count  last_check=$last_check_str" ;;
      down)    bad "$agent  status=$status  uptime=$uptime_str  restarts=$restart_count  last_check=$last_check_str" ;;
      *)       warn "$agent  status=$status  uptime=$uptime_str  restarts=$restart_count  last_check=$last_check_str" ;;
    esac
  done <<< "$agent_names"

  echo
  if [ -f "$MONITOR_LOG_FILE" ]; then
    local lines; lines="$(wc -l < "$MONITOR_LOG_FILE" 2>/dev/null | tr -d ' ')"
    info "event log: $MONITOR_LOG_FILE ($lines events)"
    info "tail: $(tail -1 "$MONITOR_LOG_FILE" 2>/dev/null || echo '(empty)')"
  else
    info "event log: $MONITOR_LOG_FILE (not created yet)"
  fi
}

# ─── Start subcommand ─────────────────────────────────────────────────────────
_cmd_start() {
  # Check if already running
  if [ -f "$MONITOR_PID_FILE" ]; then
    local existing_pid
    existing_pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      info "monitor daemon already running (pid=$existing_pid)"
      info "Use 'aw monitor status' to check agent health"
      return 0
    fi
  fi

  if [ ! -f "$MONITOR_CONFIG" ]; then
    bad "monitor config not found: $MONITOR_CONFIG"
    info "Expected at: agents/monitor.yaml"
    return 1
  fi

  mkdir -p "$MONITOR_DIR"

  info "Starting monitor daemon in background..."
  info "Config:  $MONITOR_CONFIG"
  info "Log:     $MONITOR_LOG_FILE"
  info "PID:     $MONITOR_PID_FILE"
  echo

  # Detach: redirect stdio and run in background
  nohup "$SCRIPT_PATH" _daemon \
    > "$MONITOR_DIR/monitor.out" 2>&1 &
  local bg_pid=$!
  disown "$bg_pid" 2>/dev/null || true

  # Wait briefly for PID file to appear
  local i=0
  while [ $i -lt 10 ]; do
    if [ -f "$MONITOR_PID_FILE" ]; then
      local written_pid
      written_pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)"
      if [ -n "$written_pid" ] && kill -0 "$written_pid" 2>/dev/null; then
        ok "monitor daemon started (pid=$written_pid)"
        ok "aw monitor status  — check agent health"
        ok "aw monitor stop    — stop the daemon"
        return 0
      fi
    fi
    sleep 1
    i=$(( i + 1 ))
  done

  warn "monitor daemon launched (bg pid=$bg_pid) but PID file not yet written"
  ok "aw monitor status  — check once it initializes"
}

# ─── Stop subcommand ──────────────────────────────────────────────────────────
_cmd_stop() {
  if [ ! -f "$MONITOR_PID_FILE" ]; then
    info "monitor daemon is not running (no PID file found)"
    return 0
  fi

  local pid
  pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    info "monitor PID file is empty — daemon may not be running"
    rm -f "$MONITOR_PID_FILE"
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    info "monitor daemon (pid=$pid) is not running — cleaning up stale PID file"
    rm -f "$MONITOR_PID_FILE"
    return 0
  fi

  info "Stopping monitor daemon (pid=$pid)..."
  _monitor_emit "event=monitor_stop" "pid=$pid" "signal=SIGTERM"
  kill -TERM "$pid" 2>/dev/null || true

  # Wait for it to exit
  local i=0
  while [ $i -lt 10 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$MONITOR_PID_FILE"
      ok "monitor daemon stopped"
      return 0
    fi
    sleep 1
    i=$(( i + 1 ))
  done

  # Force kill if needed
  warn "daemon did not stop gracefully — sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$MONITOR_PID_FILE"
  ok "monitor daemon killed"
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
_subcmd="${1:-status}"

# Clean up PID file on daemon exit
trap '
  rm -f "$MONITOR_PID_FILE" 2>/dev/null || true
  _monitor_emit "event=monitor_exit" "pid=$$"
' EXIT

case "$_subcmd" in
  start)    trap - EXIT; _cmd_start  ;;
  stop)     trap - EXIT; _cmd_stop   ;;
  status)   trap - EXIT; _cmd_status ;;
  _daemon)  _run_daemon ;;  # internal: called by nohup in _cmd_start
  *)
    bad "unknown subcommand: $_subcmd"
    printf "Usage: %s [start|stop|status]\n" "$(basename "$0")"
    exit 2
    ;;
esac
