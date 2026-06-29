#!/usr/bin/env bash
# mcp-crash-analyzer.sh — Post-mortem diagnostics + auto-recovery heuristics.
#
# Inspects dead MCP server processes and logs to infer crash class and
# suggest recovery strategy with higher fidelity than a simple exit-code check.
#
# Crash classes (values of the "crash_class" JSON field):
#   oom               — out-of-memory (killed by OS or explicit OOM message)
#   segfault          — segmentation fault / SIGSEGV / core dump
#   model_token_overflow — LM Studio or inference backend token-count overflow
#   dependency        — missing module, bad import, version mismatch
#   transient         — brief network glitch, signal, or unknown one-shot crash
#
# Recovery strategies (values of the "recovery_strategy" JSON field):
#   restart_immediately   — safe to restart right now
#   wait_10s_then_restart — back off briefly before restart
#   require_config_fix    — do not restart; human intervention needed
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.
#
# Public API:
#   analyze_mcp_crash <agent> <server> <exit_code> <stderr> <last_log_lines>
#       Emits a JSON object (one line) to stdout.
#       Fields: agent, server, exit_code, crash_class, recovery_strategy,
#               confidence, reason, ts
#       Returns 0 always.
#
# Environment variables (read):
#   MCP_CRASH_ANALYZER_VERBOSE  non-empty → also print reasoning to stderr
#
# Integration:
#   Source this file then call analyze_mcp_crash.  The caller is responsible
#   for appending the resulting JSON line to the lifecycle JSONL.

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_CRASH_ANALYZER_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_CRASH_ANALYZER_SOURCED=1

# ─── Internal: timestamp ──────────────────────────────────────────────────────
_mca_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ─── Internal: JSON string escape ────────────────────────────────────────────
_mca_json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g'   \
    | tr '\n' ' '       \
    | tr '\r' ' '       \
    | tr '\t' ' '
}

# ─── Internal: detect OOM from combined text ─────────────────────────────────
_mca_is_oom() {
  local text="$1"
  # Kernel OOM killer, Node/Bun heap exhaustion, explicit OOM messages.
  printf '%s' "$text" | grep -qiE \
    'out of memory|oom.?kill|killed.*process|heap.*out.*of.*space|JavaScript heap|Allocation failed|ENOMEM|cannot allocate|memory exhausted|signal 9'
}

# ─── Internal: detect segfault/SIGSEGV ───────────────────────────────────────
_mca_is_segfault() {
  local text="$1"
  # exit_code=139 is SIGSEGV+128 on most Unix systems.
  local exit_code="${2:-0}"
  if [ "$exit_code" -eq 139 ]; then
    return 0
  fi
  printf '%s' "$text" | grep -qiE \
    'segmentation fault|sigsegv|signal 11|core dumped|segfault|bus error|SIGBUS|access violation'
}

# ─── Internal: detect model token-count overflow ─────────────────────────────
_mca_is_token_overflow() {
  local text="$1"
  # LM Studio and similar inference servers emit these when context window exceeded.
  printf '%s' "$text" | grep -qiE \
    'token.*overflow|context.*length.*exceed|max.*token|sequence.*too long|input.*too long|context window|prompt.*too long|KV cache.*full|exceeds.*context|n_ctx|context_length'
}

# ─── Internal: detect dependency / module errors ─────────────────────────────
_mca_is_dependency() {
  local text="$1"
  printf '%s' "$text" | grep -qiE \
    'cannot find module|module not found|ModuleNotFoundError|no such file or directory|import.*error|require.*error|package.*not found|node_modules|bun.*install|missing.*dependency|version.*mismatch|unsupported.*engine|requires.*node|engine.*node|peer.*dep'
}

# ─── Internal: detect transient / one-shot failures ──────────────────────────
_mca_is_transient() {
  local text="$1"
  local exit_code="${2:-0}"
  # Clean exit (rc=0 but treated as crash), SIGTERM, brief network issues.
  printf '%s' "$text" | grep -qiE \
    'SIGTERM|SIGINT|connection reset|ECONNRESET|ECONNREFUSED|ETIMEDOUT|network timeout|socket hang|EPIPE' \
    && return 0
  # exit code 1 with no other signal usually means a one-shot transient error.
  [ "$exit_code" -eq 1 ] && return 0
  return 1
}

# ─── analyze_mcp_crash ────────────────────────────────────────────────────────
# Usage: analyze_mcp_crash <agent> <server> <exit_code> <stderr> <last_log_lines>
#
# Emits a single JSON line to stdout.  Fields:
#   ts                 ISO-8601 timestamp
#   event              "mcp_crash_analysis"
#   agent              agent name
#   server             server name
#   exit_code          numeric exit code
#   crash_class        oom | segfault | model_token_overflow | dependency | transient
#   recovery_strategy  restart_immediately | wait_10s_then_restart | require_config_fix
#   confidence         high | medium | low
#   reason             short human-readable explanation
analyze_mcp_crash() {
  local agent="${1:-unknown}"
  local server="${2:-unknown}"
  local exit_code="${3:-0}"
  local stderr_text="${4:-}"
  local last_log_lines="${5:-}"

  # Combine both text sources for pattern matching.
  local combined
  combined="${stderr_text} ${last_log_lines}"

  local crash_class="transient"
  local recovery_strategy="restart_immediately"
  local confidence="low"
  local reason="unknown failure — treating as transient"

  # ── Priority order: most specific / severe first ───────────────────────────

  # 1. OOM — must restart with lower memory footprint or wait for OS to reclaim.
  if _mca_is_oom "$combined"; then
    crash_class="oom"
    recovery_strategy="wait_10s_then_restart"
    confidence="high"
    reason="out-of-memory detected in crash output; back off before restart"

  # 2. Segfault — process corrupted; restart is usually safe but should be noted.
  elif _mca_is_segfault "$combined" "$exit_code"; then
    crash_class="segfault"
    recovery_strategy="wait_10s_then_restart"
    confidence="high"
    reason="segmentation fault or SIGSEGV detected; restart after brief back-off"

  # 3. Token overflow — LM Studio / inference backend hit context limit.
  elif _mca_is_token_overflow "$combined"; then
    crash_class="model_token_overflow"
    recovery_strategy="require_config_fix"
    confidence="high"
    reason="model context-window or token-count overflow; reduce context or switch model"

  # 4. Dependency / import error — code change or missing install required.
  elif _mca_is_dependency "$combined"; then
    crash_class="dependency"
    recovery_strategy="require_config_fix"
    confidence="high"
    reason="missing module or dependency version mismatch; run bun install or fix config"

  # 5. exit_code=139 (SIGSEGV fallback not caught above by text).
  elif [ "$exit_code" -eq 139 ]; then
    crash_class="segfault"
    recovery_strategy="wait_10s_then_restart"
    confidence="medium"
    reason="exit code 139 indicates SIGSEGV; restart after brief back-off"

  # 6. exit_code=137 (SIGKILL — often OOM or external kill).
  elif [ "$exit_code" -eq 137 ]; then
    crash_class="oom"
    recovery_strategy="wait_10s_then_restart"
    confidence="medium"
    reason="exit code 137 (SIGKILL) — likely OOM or external kill; back off before restart"

  # 7. Transient signals or network errors.
  elif _mca_is_transient "$combined" "$exit_code"; then
    crash_class="transient"
    recovery_strategy="restart_immediately"
    confidence="medium"
    reason="transient failure (signal or network error); safe to restart immediately"

  # 8. Generic non-zero exit — assume transient but with low confidence.
  else
    crash_class="transient"
    recovery_strategy="restart_immediately"
    confidence="low"
    reason="unclassified crash (exit_code=${exit_code}); treating as transient"
  fi

  # ── Emit JSON ───────────────────────────────────────────────────────────────
  local ts
  ts="$(_mca_ts)"
  local esc_agent esc_server esc_reason
  esc_agent="$(_mca_json_escape "$agent")"
  esc_server="$(_mca_json_escape "$server")"
  esc_reason="$(_mca_json_escape "$reason")"

  printf '{"ts":"%s","event":"mcp_crash_analysis","agent":"%s","server":"%s","exit_code":%s,"crash_class":"%s","recovery_strategy":"%s","confidence":"%s","reason":"%s"}\n' \
    "$ts" \
    "$esc_agent" \
    "$esc_server" \
    "$exit_code" \
    "$crash_class" \
    "$recovery_strategy" \
    "$confidence" \
    "$esc_reason"

  if [ -n "${MCP_CRASH_ANALYZER_VERBOSE:-}" ]; then
    printf '[mcp-crash-analyzer] %s/%s exit=%s class=%s strategy=%s confidence=%s\n' \
      "$agent" "$server" "$exit_code" "$crash_class" "$recovery_strategy" "$confidence" >&2
  fi

  return 0
}
