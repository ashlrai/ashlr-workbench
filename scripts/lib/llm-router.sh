#!/usr/bin/env bash
# llm-router.sh — Multi-backend LLM router with fallback + latency-based selection.
#
# Pings all configured LLM endpoints once per session startup, ranks them by
# latency + availability, and exports LLM_PRIMARY / LLM_FALLBACK /
# FALLBACK_THRESHOLD for each agent launch script.
#
# Supported backends:
#   lmstudio   — LM Studio OpenAI-compat server (default :1234)
#   ollama     — Ollama API (:11434)
#   xai        — xAI cloud API (requires XAI_API_KEY)
#   anthropic  — Anthropic cloud API (requires ANTHROPIC_API_KEY)
#
# Public API (after sourcing):
#   llm_router_init                           — probe all endpoints, rank, export vars
#   llm_router_status                         — print latency matrix to stdout
#   llm_router_select <agent>                 — select primary+fallback for <agent>
#                                               and export LLM_PRIMARY/LLM_FALLBACK
#   on_routing_decision AGENT PRIMARY FALLBACK — emit routing event to session-events.jsonl
#
# Exported variables (after llm_router_init):
#   LLM_PRIMARY            — "backend:model" of best available endpoint
#   LLM_FALLBACK           — "backend:model" of next-best endpoint (or "none")
#   FALLBACK_THRESHOLD     — latency ceiling in ms; if primary > this, use fallback
#   LLM_ROUTER_READY       — "1" when init has completed
#
# Override hooks:
#   ASHLR_LLM_PROBE_TIMEOUT    — per-endpoint probe timeout in seconds (default: 3)
#   ASHLR_LLM_FALLBACK_MS      — fallback threshold in ms (default: 2000)
#   ASHLR_LLM_ROUTER_EVENTS    — "0" disables routing event writes
#   ASHLR_LLM_ROUTER_LOG       — path for routing-specific jsonl log
#                                 (default: same as session-events.jsonl)
#
# Bash 3.2-safe. No mapfile, no GNU-only flags.
# Never aborts the caller — every code path returns 0.

# Guard against double-sourcing.
if [ -n "${_ASHLR_LLM_ROUTER_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_LLM_ROUTER_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────

# Source config.sh if not already loaded (provides URL + model defaults).
_LLM_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${_ASHLR_CONFIG_SOURCED:-}" ]; then
  # shellcheck source=config.sh
  . "$_LLM_ROUTER_DIR/config.sh"
fi

: "${ASHLR_LLM_PROBE_TIMEOUT:=3}"
: "${ASHLR_LLM_FALLBACK_MS:=2000}"
: "${ASHLR_LLM_ROUTER_EVENTS:=1}"

# Default event log path — reuse session-events path if set, else own path.
_LLM_ROUTER_LOG_DEFAULT="${ASHLR_SESSION_EVENTS_PATH:-${HOME}/.ashlr-workbench/session-events.jsonl}"
: "${ASHLR_LLM_ROUTER_LOG:=${_LLM_ROUTER_LOG_DEFAULT}}"

# ─── Internal state (associative via naming convention) ───────────────────────
# We can't use bash 4 associative arrays because macOS ships bash 3.2.
# Instead we store per-backend results as:
#   _LLM_RT_<BACKEND>_avail  = "1" or "0"
#   _LLM_RT_<BACKEND>_ms     = latency in ms (integer) or 99999 if down
#   _LLM_RT_<BACKEND>_model  = model id string (may be empty)
#   _LLM_RT_<BACKEND>_url    = base URL probed

# Known backends (ordered for deterministic ranking).
_LLM_ROUTER_BACKENDS="lmstudio ollama xai anthropic"

# ─── Timestamp helper ─────────────────────────────────────────────────────────
_lr_ts() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null)"
  case "$ts" in
    *3NZ|"") ts="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" ;;
  esac
  printf '%s' "$ts"
}

# _lr_now_ms — current epoch in milliseconds (best effort).
_lr_now_ms() {
  local s
  # python3 is the most portable sub-millisecond timer on macOS bash 3.2.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null && return 0
  fi
  # Fallback: seconds * 1000.
  s="$(date +%s)"
  printf '%s' "$((s * 1000))"
}

# ─── JSON emitter (routing-decision events) ───────────────────────────────────
_lr_emit() {
  [ "${ASHLR_LLM_ROUTER_EVENTS:-1}" = "0" ] && return 0
  mkdir -p "$(dirname "$ASHLR_LLM_ROUTER_LOG")" 2>/dev/null || return 0
  local pairs="" pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    # minimal JSON escaping
    val="$(printf '%s' "$val" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | tr -d '\000-\031')"
    if [ -n "$pairs" ]; then
      pairs="${pairs},\"${key}\":\"${val}\""
    else
      pairs="\"${key}\":\"${val}\""
    fi
  done
  printf '{%s}\n' "$pairs" >> "$ASHLR_LLM_ROUTER_LOG" 2>/dev/null || true
  return 0
}

# ─── Per-backend probe functions ──────────────────────────────────────────────

# _lr_probe_lmstudio — probe LM Studio OpenAI-compat /v1/models endpoint.
_lr_probe_lmstudio() {
  local url="${LM_STUDIO_URL:-http://localhost:1234/v1}"
  local t0 t1 ms model avail

  t0="$(_lr_now_ms)"
  local raw
  raw="$(curl -fsS --max-time "${ASHLR_LLM_PROBE_TIMEOUT}" "${url}/models" 2>/dev/null)"
  local rc=$?
  t1="$(_lr_now_ms)"
  ms=$(( t1 - t0 ))

  if [ "$rc" -eq 0 ] && [ -n "$raw" ]; then
    avail="1"
    model="$(printf '%s' "$raw" \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    [ -z "$model" ] && model="${LM_STUDIO_MODEL:-qwen/qwen3-coder-30b}"
  else
    avail="0"
    ms=99999
    model=""
  fi

  _LLM_RT_lmstudio_avail="$avail"
  _LLM_RT_lmstudio_ms="$ms"
  _LLM_RT_lmstudio_model="$model"
  _LLM_RT_lmstudio_url="$url"
  export _LLM_RT_lmstudio_avail _LLM_RT_lmstudio_ms _LLM_RT_lmstudio_model _LLM_RT_lmstudio_url
}

# _lr_probe_ollama — probe Ollama /api/tags endpoint.
_lr_probe_ollama() {
  local url="${OLLAMA_URL:-http://localhost:11434}"
  local t0 t1 ms model avail

  t0="$(_lr_now_ms)"
  local raw
  raw="$(curl -fsS --max-time "${ASHLR_LLM_PROBE_TIMEOUT}" "${url}/api/tags" 2>/dev/null)"
  local rc=$?
  t1="$(_lr_now_ms)"
  ms=$(( t1 - t0 ))

  if [ "$rc" -eq 0 ] && [ -n "$raw" ]; then
    avail="1"
    # Pick the reasoning model if available, else first available model.
    local reasoning_model="${OLLAMA_MODEL_REASONING:-gemma4:26b}"
    if printf '%s' "$raw" | grep -q "\"$reasoning_model\""; then
      model="$reasoning_model"
    else
      model="$(printf '%s' "$raw" \
        | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/' || true)"
      [ -z "$model" ] && model="${OLLAMA_MODEL_FAST:-llama3.2:3b}"
    fi
  else
    avail="0"
    ms=99999
    model=""
  fi

  _LLM_RT_ollama_avail="$avail"
  _LLM_RT_ollama_ms="$ms"
  _LLM_RT_ollama_model="$model"
  _LLM_RT_ollama_url="$url"
  export _LLM_RT_ollama_avail _LLM_RT_ollama_ms _LLM_RT_ollama_model _LLM_RT_ollama_url
}

# _lr_probe_xai — probe xAI v1/models endpoint (requires XAI_API_KEY).
_lr_probe_xai() {
  local url="${XAI_BASE_URL:-https://api.x.ai/v1}"
  local avail ms model

  if [ -z "${XAI_API_KEY:-}" ]; then
    _LLM_RT_xai_avail="0"
    _LLM_RT_xai_ms=99999
    _LLM_RT_xai_model=""
    _LLM_RT_xai_url="$url"
    _LLM_RT_xai_skip="no_key"
    export _LLM_RT_xai_avail _LLM_RT_xai_ms _LLM_RT_xai_model _LLM_RT_xai_url _LLM_RT_xai_skip
    return 0
  fi

  local t0 t1
  t0="$(_lr_now_ms)"
  local raw
  raw="$(curl -fsS --max-time "${ASHLR_LLM_PROBE_TIMEOUT}" \
    -H "Authorization: Bearer ${XAI_API_KEY}" \
    "${url}/models" 2>/dev/null)"
  local rc=$?
  t1="$(_lr_now_ms)"
  ms=$(( t1 - t0 ))

  if [ "$rc" -eq 0 ] && [ -n "$raw" ]; then
    avail="1"
    model="$(printf '%s' "$raw" \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | grep -i 'grok' \
      | head -1 \
      | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    [ -z "$model" ] && model="grok-3"
  else
    avail="0"
    ms=99999
    model=""
  fi

  _LLM_RT_xai_avail="$avail"
  _LLM_RT_xai_ms="$ms"
  _LLM_RT_xai_model="$model"
  _LLM_RT_xai_url="$url"
  export _LLM_RT_xai_avail _LLM_RT_xai_ms _LLM_RT_xai_model _LLM_RT_xai_url
}

# _lr_probe_anthropic — probe Anthropic v1/models endpoint (requires ANTHROPIC_API_KEY).
_lr_probe_anthropic() {
  local url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com/v1}"
  local avail ms model

  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    _LLM_RT_anthropic_avail="0"
    _LLM_RT_anthropic_ms=99999
    _LLM_RT_anthropic_model=""
    _LLM_RT_anthropic_url="$url"
    _LLM_RT_anthropic_skip="no_key"
    export _LLM_RT_anthropic_avail _LLM_RT_anthropic_ms _LLM_RT_anthropic_model _LLM_RT_anthropic_url _LLM_RT_anthropic_skip
    return 0
  fi

  local t0 t1
  t0="$(_lr_now_ms)"
  local raw
  raw="$(curl -fsS --max-time "${ASHLR_LLM_PROBE_TIMEOUT}" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    "${url}/models" 2>/dev/null)"
  local rc=$?
  t1="$(_lr_now_ms)"
  ms=$(( t1 - t0 ))

  if [ "$rc" -eq 0 ] && [ -n "$raw" ]; then
    avail="1"
    model="$(printf '%s' "$raw" \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | grep -i 'claude-sonnet\|claude-3' \
      | head -1 \
      | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    [ -z "$model" ] && model="claude-sonnet-4-5"
  else
    avail="0"
    ms=99999
    model=""
  fi

  _LLM_RT_anthropic_avail="$avail"
  _LLM_RT_anthropic_ms="$ms"
  _LLM_RT_anthropic_model="$model"
  _LLM_RT_anthropic_url="$url"
  export _LLM_RT_anthropic_avail _LLM_RT_anthropic_ms _LLM_RT_anthropic_model _LLM_RT_anthropic_url
}

# ─── Ranking ──────────────────────────────────────────────────────────────────

# _lr_get_avail BACKEND  → prints "0" or "1"
_lr_get_avail() {
  eval "printf '%s' \"\${_LLM_RT_${1}_avail:-0}\""
}

# _lr_get_ms BACKEND → prints latency int
_lr_get_ms() {
  eval "printf '%s' \"\${_LLM_RT_${1}_ms:-99999}\""
}

# _lr_get_model BACKEND → prints model id
_lr_get_model() {
  eval "printf '%s' \"\${_LLM_RT_${1}_model:-}\""
}

# _lr_get_url BACKEND → prints url
_lr_get_url() {
  eval "printf '%s' \"\${_LLM_RT_${1}_url:-}\""
}

# _lr_rank_backends — write sorted backend list to stdout, best first.
# Available backends come first, sorted by latency ascending.
# Unavailable backends are appended last.
_lr_rank_backends() {
  local b avail ms
  # Build two lists: available and unavailable
  local avail_list="" unavail_list=""
  for b in $_LLM_ROUTER_BACKENDS; do
    avail="$(_lr_get_avail "$b")"
    if [ "$avail" = "1" ]; then
      ms="$(_lr_get_ms "$b")"
      # prepend ms for sort: "00450 lmstudio"
      avail_list="${avail_list}$(printf '%05d %s\n' "$ms" "$b")"
    else
      unavail_list="${unavail_list}${b} "
    fi
  done

  # Sort available by latency (numeric sort on first field)
  if [ -n "$avail_list" ]; then
    printf '%s' "$avail_list" | sort -n | awk '{print $2}'
  fi

  # Append unavailable in original order
  for b in $unavail_list; do
    printf '%s\n' "$b"
  done
}

# ─── Public: llm_router_init ──────────────────────────────────────────────────

# llm_router_init — probe all endpoints, rank, export LLM_PRIMARY / LLM_FALLBACK.
# Safe to call multiple times; re-probes on each call (idempotent).
llm_router_init() {
  local ts; ts="$(_lr_ts)"

  # Probe all backends.
  _lr_probe_lmstudio
  _lr_probe_ollama
  _lr_probe_xai
  _lr_probe_anthropic

  # Rank.
  local ranked_list
  ranked_list="$(_lr_rank_backends)"

  # Pick primary (first available backend).
  local primary_backend="" primary_model="" primary_url=""
  local b
  for b in $ranked_list; do
    if [ "$(_lr_get_avail "$b")" = "1" ]; then
      primary_backend="$b"
      primary_model="$(_lr_get_model "$b")"
      primary_url="$(_lr_get_url "$b")"
      break
    fi
  done

  # Pick fallback (second available backend).
  local fallback_backend="" fallback_model="" fallback_url="" found_primary=0
  for b in $ranked_list; do
    if [ "$b" = "$primary_backend" ]; then
      found_primary=1
      continue
    fi
    if [ "$found_primary" = "1" ] && [ "$(_lr_get_avail "$b")" = "1" ]; then
      fallback_backend="$b"
      fallback_model="$(_lr_get_model "$b")"
      fallback_url="$(_lr_get_url "$b")"
      break
    fi
  done

  # Export final routing vars.
  if [ -n "$primary_backend" ]; then
    LLM_PRIMARY="${primary_backend}:${primary_model}"
    LLM_PRIMARY_URL="$primary_url"
    LLM_PRIMARY_BACKEND="$primary_backend"
    LLM_PRIMARY_MODEL="$primary_model"
    LLM_PRIMARY_MS="$(_lr_get_ms "$primary_backend")"
  else
    LLM_PRIMARY="none:"
    LLM_PRIMARY_URL=""
    LLM_PRIMARY_BACKEND="none"
    LLM_PRIMARY_MODEL=""
    LLM_PRIMARY_MS=99999
  fi

  if [ -n "$fallback_backend" ]; then
    LLM_FALLBACK="${fallback_backend}:${fallback_model}"
    LLM_FALLBACK_URL="$fallback_url"
    LLM_FALLBACK_BACKEND="$fallback_backend"
    LLM_FALLBACK_MODEL="$fallback_model"
    LLM_FALLBACK_MS="$(_lr_get_ms "$fallback_backend")"
  else
    LLM_FALLBACK="none:"
    LLM_FALLBACK_URL=""
    LLM_FALLBACK_BACKEND="none"
    LLM_FALLBACK_MODEL=""
    LLM_FALLBACK_MS=99999
  fi

  FALLBACK_THRESHOLD="${ASHLR_LLM_FALLBACK_MS}"
  LLM_ROUTER_READY="1"

  export LLM_PRIMARY LLM_PRIMARY_URL LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL LLM_PRIMARY_MS
  export LLM_FALLBACK LLM_FALLBACK_URL LLM_FALLBACK_BACKEND LLM_FALLBACK_MODEL LLM_FALLBACK_MS
  export FALLBACK_THRESHOLD LLM_ROUTER_READY

  # Emit routing_init event.
  _lr_emit \
    "ts=${ts}" \
    "event=routing_init" \
    "primary=${LLM_PRIMARY}" \
    "primary_ms=${LLM_PRIMARY_MS}" \
    "fallback=${LLM_FALLBACK}" \
    "fallback_ms=${LLM_FALLBACK_MS}" \
    "threshold_ms=${FALLBACK_THRESHOLD}"

  return 0
}

# ─── Public: llm_router_select ────────────────────────────────────────────────

# llm_router_select AGENT — pick primary+fallback for a named agent and export.
# Applies agent-specific preferences (aider prefers lmstudio, etc.) but always
# falls back gracefully if preferred backend is down.
#
# After calling:
#   LLM_PRIMARY, LLM_FALLBACK, FALLBACK_THRESHOLD are (re-)exported
#   Routing decision is logged to session-events.jsonl
llm_router_select() {
  local agent="${1:-unknown}"

  # Ensure init has run.
  if [ "${LLM_ROUTER_READY:-0}" != "1" ]; then
    llm_router_init
  fi

  # Agent-specific backend preference order.
  local pref_order
  case "$agent" in
    aider)
      # Aider works best with OpenAI-compat endpoints; prefer lmstudio, then ollama.
      pref_order="lmstudio ollama xai anthropic"
      ;;
    goose)
      # Goose is model-agnostic; prefer lowest latency local first.
      pref_order="lmstudio ollama xai anthropic"
      ;;
    openhands)
      # OpenHands runs in Docker and uses host.docker.internal; lmstudio is
      # authoritative. Fall back to cloud if local is down.
      pref_order="lmstudio xai anthropic ollama"
      ;;
    ashlrcode)
      # ashlrcode prefers xAI/Anthropic cloud when keys are set; local otherwise.
      if [ -n "${XAI_API_KEY:-}" ]; then
        pref_order="xai anthropic lmstudio ollama"
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        pref_order="anthropic xai lmstudio ollama"
      else
        pref_order="lmstudio ollama xai anthropic"
      fi
      ;;
    *)
      pref_order="lmstudio ollama xai anthropic"
      ;;
  esac

  # Walk preference order and pick first available.
  local primary_backend="" primary_model="" primary_ms=99999
  local fallback_backend="" fallback_model="" fallback_ms=99999
  local b found_primary=0

  for b in $pref_order; do
    if [ "$(_lr_get_avail "$b")" = "1" ]; then
      if [ "$found_primary" = "0" ]; then
        primary_backend="$b"
        primary_model="$(_lr_get_model "$b")"
        primary_ms="$(_lr_get_ms "$b")"
        found_primary=1
      else
        fallback_backend="$b"
        fallback_model="$(_lr_get_model "$b")"
        fallback_ms="$(_lr_get_ms "$b")"
        break
      fi
    fi
  done

  # Update exported vars.
  if [ -n "$primary_backend" ]; then
    LLM_PRIMARY="${primary_backend}:${primary_model}"
    LLM_PRIMARY_URL="$(_lr_get_url "$primary_backend")"
    LLM_PRIMARY_BACKEND="$primary_backend"
    LLM_PRIMARY_MODEL="$primary_model"
    LLM_PRIMARY_MS="$primary_ms"
  fi

  if [ -n "$fallback_backend" ]; then
    LLM_FALLBACK="${fallback_backend}:${fallback_model}"
    LLM_FALLBACK_URL="$(_lr_get_url "$fallback_backend")"
    LLM_FALLBACK_BACKEND="$fallback_backend"
    LLM_FALLBACK_MODEL="$fallback_model"
    LLM_FALLBACK_MS="$fallback_ms"
  else
    LLM_FALLBACK="none:"
    LLM_FALLBACK_URL=""
    LLM_FALLBACK_BACKEND="none"
    LLM_FALLBACK_MODEL=""
    LLM_FALLBACK_MS=99999
  fi

  export LLM_PRIMARY LLM_PRIMARY_URL LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL LLM_PRIMARY_MS
  export LLM_FALLBACK LLM_FALLBACK_URL LLM_FALLBACK_BACKEND LLM_FALLBACK_MODEL LLM_FALLBACK_MS
  export FALLBACK_THRESHOLD

  # Emit routing_select event.
  on_routing_decision "$agent" "$LLM_PRIMARY" "$LLM_FALLBACK"
  return 0
}

# ─── Public: on_routing_decision ──────────────────────────────────────────────

# on_routing_decision AGENT PRIMARY FALLBACK
#   Emit a structured routing_decision event to session-events.jsonl.
on_routing_decision() {
  local agent="${1:-unknown}" primary="${2:-none:}" fallback="${3:-none:}"
  _lr_emit \
    "ts=$(_lr_ts)" \
    "event=routing_decision" \
    "agent=${agent}" \
    "primary=${primary}" \
    "primary_ms=${LLM_PRIMARY_MS:-99999}" \
    "fallback=${fallback}" \
    "fallback_ms=${LLM_FALLBACK_MS:-99999}" \
    "threshold_ms=${FALLBACK_THRESHOLD:-${ASHLR_LLM_FALLBACK_MS}}"
}

# ─── Public: llm_router_status ────────────────────────────────────────────────

# llm_router_status — print a formatted latency matrix to stdout.
# Called by `aw llm-status`.
llm_router_status() {
  # Ensure init has run.
  if [ "${LLM_ROUTER_READY:-0}" != "1" ]; then
    llm_router_init
  fi

  # Colors (NO_COLOR-aware)
  local C_RESET="" C_BOLD="" C_GREEN="" C_RED="" C_YELLOW="" C_CYAN="" C_DIM=""
  if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
  fi

  printf '\n%sLLM Endpoint Latency Matrix%s\n' "$C_BOLD" "$C_RESET"
  printf '%s\n' "─────────────────────────────────────────────────────────"

  local b avail ms model url status_str latency_str
  for b in $_LLM_ROUTER_BACKENDS; do
    avail="$(_lr_get_avail "$b")"
    ms="$(_lr_get_ms "$b")"
    model="$(_lr_get_model "$b")"
    url="$(_lr_get_url "$b")"

    if [ "$avail" = "1" ]; then
      if [ "$ms" -lt 500 ]; then
        latency_str="${C_GREEN}${ms}ms${C_RESET}"
      elif [ "$ms" -lt 2000 ]; then
        latency_str="${C_YELLOW}${ms}ms${C_RESET}"
      else
        latency_str="${C_RED}${ms}ms${C_RESET}"
      fi
      status_str="${C_GREEN}up${C_RESET}"
    else
      latency_str="${C_DIM}—${C_RESET}"
      status_str="${C_RED}down${C_RESET}"
      model="${C_DIM}(unavailable)${C_RESET}"
    fi

    # Check if this is primary or fallback
    local role_tag=""
    case "${LLM_PRIMARY_BACKEND:-}" in
      "$b") role_tag=" ${C_CYAN}[PRIMARY]${C_RESET}" ;;
    esac
    case "${LLM_FALLBACK_BACKEND:-}" in
      "$b") role_tag=" ${C_DIM}[FALLBACK]${C_RESET}" ;;
    esac

    printf '  %-12s %s  %-10s  %s%s\n' \
      "$b" "$status_str" "$latency_str" "$model" "$role_tag"

    if [ -n "$url" ]; then
      printf '  %s            %s%s%s\n' "            " "$C_DIM" "$url" "$C_RESET"
    fi
  done

  printf '%s\n' "─────────────────────────────────────────────────────────"
  printf '%s  Primary:  %s%s%s  (%sms)\n' \
    "" "$C_GREEN" "${LLM_PRIMARY:-none}" "$C_RESET" "${LLM_PRIMARY_MS:-?}"
  printf '%s  Fallback: %s%s%s  (%sms)\n' \
    "" "$C_DIM" "${LLM_FALLBACK:-none}" "$C_RESET" "${LLM_FALLBACK_MS:-?}"
  printf '%s  Threshold: if primary > %sms → use fallback\n' \
    "" "${FALLBACK_THRESHOLD:-${ASHLR_LLM_FALLBACK_MS}}"
  printf '\n'
}

# ─── Aider-specific degradation helper ───────────────────────────────────────

# llm_router_aider_args — echo the right aider --openai-api-base + --model flags
# for the selected primary/fallback given the current threshold check.
# Callers use this like: aider_flags="$(llm_router_aider_args)" ; aider $aider_flags ...
# (start-aider.sh instead uses the exported LLM_* vars directly for max flexibility.)
llm_router_aider_args() {
  if [ "${LLM_ROUTER_READY:-0}" != "1" ]; then
    llm_router_init
  fi
  local use_backend="$LLM_PRIMARY_BACKEND"
  local use_model="$LLM_PRIMARY_MODEL"
  local use_url="$LLM_PRIMARY_URL"

  # Runtime threshold check: if primary latency exceeds threshold, use fallback.
  local primary_ms="${LLM_PRIMARY_MS:-99999}"
  local threshold="${FALLBACK_THRESHOLD:-${ASHLR_LLM_FALLBACK_MS}}"
  if [ "$primary_ms" -gt "$threshold" ] && [ "${LLM_FALLBACK_BACKEND:-none}" != "none" ]; then
    use_backend="$LLM_FALLBACK_BACKEND"
    use_model="$LLM_FALLBACK_MODEL"
    use_url="$LLM_FALLBACK_URL"
  fi

  # Emit the right flags depending on backend.
  case "$use_backend" in
    lmstudio|ollama)
      printf '%s' "--openai-api-base ${use_url} --model openai/${use_model}"
      ;;
    xai)
      printf '%s' "--openai-api-base ${use_url} --model ${use_model}"
      ;;
    anthropic)
      printf '%s' "--model ${use_model}"
      ;;
    *)
      # Fallback to LM Studio defaults.
      printf '%s' "--openai-api-base ${LM_STUDIO_URL:-http://localhost:1234/v1} --model openai/${LM_STUDIO_MODEL:-qwen/qwen3-coder-30b}"
      ;;
  esac
}
