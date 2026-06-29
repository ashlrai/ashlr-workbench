#!/usr/bin/env bash
# session-events.sh — Structured lifecycle event emitter for workbench sessions.
#
# Sourced by each start-<agent>.sh to emit typed JSON events to a per-machine
# event log. Complements session-log.sh (which writes the existing
# ~/.ashlr/session-log.jsonl trace) with richer structured data used by
# session-analytics.sh.
#
# Exported functions:
#   on_agent_start   agent pid model mcp_count
#   on_agent_error   agent exit_code stderr_snippet
#   on_mcp_server_spawn  agent server_name
#   on_session_end   agent duration_secs status
#
# Contract:
#   - Bash 3.2-safe. No mapfile, no GNU-only flags.
#   - Never aborts the caller — every code path returns 0. A broken event
#     write must never break the agent launch.
#   - Honors:
#       ASHLR_SESSION_EVENTS      "0" disables all writes (kill switch).
#       ASHLR_SESSION_EVENTS_PATH Override log file location.
#                                 Default: ~/.ashlr-workbench/session-events.jsonl
#       ASHLR_SESSION_ID          Caller-provided session id (shared with
#                                 session-log.sh if set there first).

# Guard against double-sourcing.
if [ -n "${_ASHLR_SESSION_EVENTS_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_SESSION_EVENTS_SOURCED=1

SESSION_EVENTS_FILE="${ASHLR_SESSION_EVENTS_PATH:-$HOME/.ashlr-workbench/session-events.jsonl}"

# ─── Internal helpers ─────────────────────────────────────────────────────────

# _se_ts — ISO-8601 UTC timestamp, millisecond precision where available.
_se_ts() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)"
  case "$ts" in
    *3NZ|"") ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" ;;
  esac
  printf '%s' "$ts"
}

# _se_session_id — return (or synthesize) a stable id for this shell's lifetime.
_se_session_id() {
  local session="${ASHLR_SESSION_ID:-${_ASHLR_SESSION_LOG_ID:-${_SE_SESSION_ID:-}}}"
  if [ -z "$session" ]; then
    session="$(printf '%s-%s-%s' "${1:-wb}" "$$" "$(date +%s)" \
      | shasum 2>/dev/null | cut -c1-12)"
    [ -z "$session" ] && session="${1:-wb}-$$"
    _SE_SESSION_ID="$session"
    export _SE_SESSION_ID
    # Also export as ASHLR_SESSION_ID so session-log.sh picks it up if sourced later.
    export ASHLR_SESSION_ID="$session"
  fi
  printf '%s' "$session"
}

# _se_escape_json_string VAL — minimal JSON string escaping (no backslash/quote injection).
_se_escape_json_string() {
  # Replace backslash first (must come before quote), then double-quote,
  # then the three JSON control chars we care about in practice.
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g'    \
    | tr -d '\000-\031'
}

# _se_emit KEY=VALUE... — write one JSONL event object.
# Caller passes key=value pairs; we handle quoting.
# This approach avoids eval and is bash 3.2-safe.
_se_emit() {
  [ "${ASHLR_SESSION_EVENTS:-1}" = "0" ] && return 0
  mkdir -p "$(dirname "$SESSION_EVENTS_FILE")" 2>/dev/null || return 0

  local ts; ts="$(_se_ts)"
  local pairs="" pair key val

  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    val="$(_se_escape_json_string "$val")"
    if [ -n "$pairs" ]; then
      pairs="${pairs},\"${key}\":\"${val}\""
    else
      pairs="\"${key}\":\"${val}\""
    fi
  done

  printf '{%s}\n' "$pairs" >> "$SESSION_EVENTS_FILE" 2>/dev/null || true
  return 0
}

# ─── Public API ───────────────────────────────────────────────────────────────

# on_agent_start AGENT PID MODEL MCP_COUNT
#   Emitted once when a start-<agent>.sh script successfully launches the agent
#   binary (just before exec/run). PID is the agent process's PID (or the
#   launcher's $$ for daemons started via docker). MODEL is the model id string.
#   MCP_COUNT is the number of MCP servers configured (integer or "unknown").
on_agent_start() {
  local agent="${1:-unknown}" pid="${2:-0}" model="${3:-unknown}" mcp_count="${4:-0}"
  local session; session="$(_se_session_id "$agent")"
  _se_emit \
    "ts=$(_se_ts)" \
    "event=agent_start" \
    "agent=$agent" \
    "session=$session" \
    "pid=$pid" \
    "model=$model" \
    "mcp_count=$mcp_count"
}

# on_agent_error AGENT EXIT_CODE STDERR_SNIPPET
#   Emitted when an agent process exits with a non-zero code, or when a
#   preflight check fails before launch. STDERR_SNIPPET should be the last
#   ~200 chars of stderr, single-line.
on_agent_error() {
  local agent="${1:-unknown}" exit_code="${2:-1}" stderr_snippet="${3:-}"
  local session; session="$(_se_session_id "$agent")"
  _se_emit \
    "ts=$(_se_ts)" \
    "event=agent_error" \
    "agent=$agent" \
    "session=$session" \
    "exit_code=$exit_code" \
    "stderr=$stderr_snippet"
}

# on_mcp_server_spawn AGENT SERVER_NAME
#   Emitted for each MCP stdio server that the agent config registers. Call
#   once per server from the start script, before launching the agent.
on_mcp_server_spawn() {
  local agent="${1:-unknown}" server_name="${2:-unknown}"
  local session; session="$(_se_session_id "$agent")"
  _se_emit \
    "ts=$(_se_ts)" \
    "event=mcp_server_spawn" \
    "agent=$agent" \
    "session=$session" \
    "server=$server_name"
}

# on_session_end AGENT DURATION_SECS STATUS
#   Emitted from the EXIT trap in start-<agent>.sh. DURATION_SECS is wall-clock
#   seconds (integer). STATUS is "ok" | "error" | "killed".
on_session_end() {
  local agent="${1:-unknown}" duration="${2:-0}" status="${3:-ok}"
  local session; session="$(_se_session_id "$agent")"
  _se_emit \
    "ts=$(_se_ts)" \
    "event=session_end" \
    "agent=$agent" \
    "session=$session" \
    "duration=$duration" \
    "status=$status"
}
