#!/usr/bin/env bash
# session-replay-log.sh — Structured JSONL emitter for the cross-agent session
# replay log.  Sourced by each start-<agent>.sh (alongside session-log.sh and
# session-events.sh) to record the full lifecycle of every agent session into a
# single replay-capable log at ~/.ashlr-workbench/session-replay.jsonl.
#
# Event types emitted:
#   session_init    — agent started, LLM endpoint chosen, MCP servers initialised
#   tool_call       — one tool invocation (name, args summary, latency_ms)
#   llm_response    — one LLM turn (prompt_tokens, completion_tokens, latency_ms)
#   session_end     — session closed (duration_secs, status, tool_count, llm_turns)
#
# Contract:
#   - Bash 3.2-safe (macOS default). No mapfile, no sha256sum, no GNU-only flags.
#   - Never aborts the caller — every failure path returns 0.
#   - Honors:
#       ASHLR_REPLAY_LOG        "0" disables all writes (kill switch).
#       ASHLR_REPLAY_LOG_PATH   Override log file location.
#                               Default: ~/.ashlr-workbench/session-replay.jsonl
#       ASHLR_SESSION_ID        Shared session id from session-log.sh / session-events.sh.
#
# Usage (in a start-<agent>.sh):
#   source "$(dirname "$0")/lib/session-replay-log.sh"
#   replay_session_init "aider" "lmstudio/qwen3-coder-30b" "5" "$PROJECT_DIR"
#   # ... agent runs ...
#   replay_session_end "aider" "$duration" "ok" "$tool_count" "$llm_turns"

# Guard against double-sourcing.
if [ -n "${_ASHLR_REPLAY_LOG_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_REPLAY_LOG_SOURCED=1

REPLAY_LOG_FILE="${ASHLR_REPLAY_LOG_PATH:-$HOME/.ashlr-workbench/session-replay.jsonl}"

# ─── Internal helpers ─────────────────────────────────────────────────────────

# _rpl_ts — ISO-8601 UTC timestamp, millisecond precision where available.
_rpl_ts() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)"
  case "$ts" in
    *3NZ|"") ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" ;;
  esac
  printf '%s' "$ts"
}

# _rpl_epoch_ms — millisecond epoch (falls back to second * 1000 on BSD date).
_rpl_epoch_ms() {
  local ms
  # GNU date: date +%s%3N  — macOS date does not support %3N
  ms="$(date +%s%3N 2>/dev/null)"
  case "$ms" in
    *3N|"") ms="$(( $(date +%s) * 1000 ))" ;;
  esac
  printf '%s' "$ms"
}

# _rpl_session_id AGENT — return or synthesise a stable session id.
_rpl_session_id() {
  local agent="${1:-wb}"
  local session="${ASHLR_SESSION_ID:-${_ASHLR_SESSION_LOG_ID:-${_SE_SESSION_ID:-${_RPL_SESSION_ID:-}}}}"
  if [ -z "$session" ]; then
    session="$(printf '%s-%s-%s' "$agent" "$$" "$(date +%s)" \
      | shasum 2>/dev/null | cut -c1-12)"
    [ -z "$session" ] && session="${agent}-$$"
    _RPL_SESSION_ID="$session"
    export _RPL_SESSION_ID
    export ASHLR_SESSION_ID="$session"
  fi
  printf '%s' "$session"
}

# _rpl_escape VAL — minimal JSON string escaping.
_rpl_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g'    \
    | tr -d '\000-\031'
}

# _rpl_emit KEY=VALUE... — append one JSONL event.
_rpl_emit() {
  [ "${ASHLR_REPLAY_LOG:-1}" = "0" ] && return 0
  mkdir -p "$(dirname "$REPLAY_LOG_FILE")" 2>/dev/null || return 0

  local pairs="" pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    val="$(_rpl_escape "$val")"
    if [ -n "$pairs" ]; then
      pairs="${pairs},\"${key}\":\"${val}\""
    else
      pairs="\"${key}\":\"${val}\""
    fi
  done

  printf '{%s}\n' "$pairs" >> "$REPLAY_LOG_FILE" 2>/dev/null || true
  return 0
}

# ─── Per-session counters (in-memory, reset by replay_session_init) ───────────
_RPL_TOOL_COUNT=0
_RPL_LLM_TURNS=0

# ─── Public API ───────────────────────────────────────────────────────────────

# replay_session_init AGENT LLM_ENDPOINT MCP_COUNT CWD
#   Emit session_init — must be called once per start-<agent>.sh, before the
#   agent binary is launched.
replay_session_init() {
  local agent="${1:-unknown}"
  local llm_endpoint="${2:-unknown}"
  local mcp_count="${3:-0}"
  local cwd="${4:-$PWD}"
  local session; session="$(_rpl_session_id "$agent")"
  _RPL_TOOL_COUNT=0
  _RPL_LLM_TURNS=0
  _rpl_emit \
    "ts=$(_rpl_ts)" \
    "event=session_init" \
    "agent=$agent" \
    "session=$session" \
    "llm_endpoint=$llm_endpoint" \
    "mcp_count=$mcp_count" \
    "cwd=$cwd" \
    "pid=$$"
}

# replay_tool_call AGENT TOOL_NAME ARGS_SUMMARY LATENCY_MS
#   Emit one tool_call event.  ARGS_SUMMARY should be a short single-line
#   description of the arguments (e.g. the file path for a Read call).
#   LATENCY_MS is optional — pass "" or "0" when not available.
replay_tool_call() {
  local agent="${1:-unknown}"
  local tool_name="${2:-unknown}"
  local args_summary="${3:-}"
  local latency_ms="${4:-0}"
  local session; session="$(_rpl_session_id "$agent")"
  _RPL_TOOL_COUNT=$(( _RPL_TOOL_COUNT + 1 ))
  _rpl_emit \
    "ts=$(_rpl_ts)" \
    "event=tool_call" \
    "agent=$agent" \
    "session=$session" \
    "tool=$tool_name" \
    "args=$args_summary" \
    "latency_ms=$latency_ms" \
    "seq=$_RPL_TOOL_COUNT"
}

# replay_llm_response AGENT MODEL PROMPT_TOKENS COMPLETION_TOKENS LATENCY_MS
#   Emit one llm_response event.  Token counts may be "0" when unavailable.
replay_llm_response() {
  local agent="${1:-unknown}"
  local model="${2:-unknown}"
  local prompt_tokens="${3:-0}"
  local completion_tokens="${4:-0}"
  local latency_ms="${5:-0}"
  local session; session="$(_rpl_session_id "$agent")"
  _RPL_LLM_TURNS=$(( _RPL_LLM_TURNS + 1 ))
  _rpl_emit \
    "ts=$(_rpl_ts)" \
    "event=llm_response" \
    "agent=$agent" \
    "session=$session" \
    "model=$model" \
    "prompt_tokens=$prompt_tokens" \
    "completion_tokens=$completion_tokens" \
    "latency_ms=$latency_ms" \
    "turn=$_RPL_LLM_TURNS"
}

# replay_session_end AGENT DURATION_SECS STATUS [TOOL_COUNT] [LLM_TURNS]
#   Emit session_end.  TOOL_COUNT and LLM_TURNS default to the in-shell counters
#   incremented by replay_tool_call / replay_llm_response.
replay_session_end() {
  local agent="${1:-unknown}"
  local duration="${2:-0}"
  local status="${3:-ok}"
  local tool_count="${4:-$_RPL_TOOL_COUNT}"
  local llm_turns="${5:-$_RPL_LLM_TURNS}"
  local session; session="$(_rpl_session_id "$agent")"
  _rpl_emit \
    "ts=$(_rpl_ts)" \
    "event=session_end" \
    "agent=$agent" \
    "session=$session" \
    "duration_secs=$duration" \
    "status=$status" \
    "tool_count=$tool_count" \
    "llm_turns=$llm_turns"
}
