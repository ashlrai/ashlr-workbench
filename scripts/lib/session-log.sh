#!/usr/bin/env bash
# session-log.sh — shared JSONL writer for the cross-agent session log.
#
# Sourced by each workbench launcher (scripts/start-<agent>.sh) so every agent
# launch leaves a trace in ~/.ashlr/session-log.jsonl alongside what Claude
# Code writes via its PostToolUse hook. Keeps aw-log's "who's been doing what"
# view honest for all four workbench agents, not just Claude Code.
#
# Usage:
#   source "$(dirname "$0")/lib/session-log.sh"
#   log_session_start goose "$PROJECT_DIR"
#   trap 'log_session_end goose "$PROJECT_DIR"' EXIT
#
# Contract:
#   - Bash 3.2-safe (macOS default). No mapfile, no sha256sum, no GNU-only
#     date flags.
#   - Never aborts the caller — every failure path returns 0. A broken
#     telemetry line must never break the launch.
#   - Honors two env vars:
#       ASHLR_SESSION_LOG       "0" disables all writes (kill switch).
#       ASHLR_SESSION_LOG_PATH  Override the log file location
#                               (default: ~/.ashlr/session-log.jsonl).
#       ASHLR_SESSION_ID        Optional caller-provided session id. If unset,
#                               we synthesize one from agent+PPID+epoch.

# Guard against double-sourcing (start-openhands.sh cp's into its own tree).
if [ -n "${_ASHLR_SESSION_LOG_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_SESSION_LOG_SOURCED=1

SESSION_LOG_FILE="${ASHLR_SESSION_LOG_PATH:-$HOME/.ashlr/session-log.jsonl}"

# Emit one JSONL entry. All fields are plain ASCII — agent names and events
# never contain quote/backslash, cwd is expected to be a filesystem path.
# If someone passes a pathological cwd the worst case is a malformed line,
# which aw-log's format_entries silently drops.
log_session_event() {
  # $1 = agent name (goose/aider/ashlrcode/openhands)
  # $2 = event (session_start|session_end)
  # $3 = optional cwd (defaults to $PWD)
  local agent="$1" event="$2" cwd="${3:-$PWD}"
  [ "${ASHLR_SESSION_LOG:-1}" = "0" ] && return 0
  mkdir -p "$(dirname "$SESSION_LOG_FILE")" 2>/dev/null || return 0

  # Prefer millisecond precision (matches claude-code writer); fall back to
  # second-resolution on BSD date where %3N is literal. GNU date on Linux
  # honors %3N; macOS `date` does not, so we detect by output — a literal
  # "3N" in the string means the format specifier did not expand.
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)"
  case "$ts" in
    *3NZ|"") ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" ;;
  esac

  # Build a session id if the caller didn't provide one. shasum is present on
  # both macOS and Linux; sha256sum is Linux-only so we avoid it. Cache the
  # computed id for the lifetime of this sourced shell so the session_start
  # and session_end lines correlate (same session id in both).
  local session="${ASHLR_SESSION_ID:-${_ASHLR_SESSION_LOG_ID:-}}"
  if [ -z "$session" ]; then
    session="$(printf '%s-%s-%s' "$agent" "$PPID" "$(date +%s)" \
      | shasum 2>/dev/null | cut -c1-12)"
    [ -z "$session" ] && session="${agent}-${PPID}"
    _ASHLR_SESSION_LOG_ID="$session"
    export _ASHLR_SESSION_LOG_ID
  fi

  printf '{"ts":"%s","agent":"%s","event":"%s","cwd":"%s","session":"%s"}\n' \
    "$ts" "$agent" "$event" "$cwd" "$session" \
    >> "$SESSION_LOG_FILE" 2>/dev/null || true
  return 0
}

log_session_start() { log_session_event "$1" "session_start" "${2:-}"; }
log_session_end()   { log_session_event "$1" "session_end"   "${2:-}"; }
