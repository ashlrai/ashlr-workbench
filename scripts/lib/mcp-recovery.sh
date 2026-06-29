#!/usr/bin/env bash
# mcp-recovery.sh — Resilient MCP startup harness with graceful degradation.
#
# Wraps each MCP server startup attempt in a timeout+health-check loop.
# On failure it captures stderr + exit code, emits a structured JSONL event
# to MCP_FAILURES_JSONL, marks the server unavailable in MCP_UNAVAILABLE,
# and allows the agent to continue with reduced capability.
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.
#
# Public API:
#   mcp_recovery_probe_server <name> <entry>
#       Probe one MCP server.  Returns 0 on success, non-zero on failure.
#       Side-effects: updates MCP_UNAVAILABLE; appends to MCP_FAILURES_JSONL.
#
#   mcp_recovery_probe_all [name entry [name entry ...]]
#       Probe a list of name/entry pairs (alternating args) or the default
#       10 ashlr-plugin servers when called with no arguments.
#       Populates MCP_UNAVAILABLE; appends failure records to MCP_FAILURES_JSONL.
#       Returns 0 when every server started OK, 1 if any failed.
#
#   mcp_recovery_report
#       Print a human-readable resilience summary (% OK, which are flaky).
#       Suitable for embedding in healthcheck sections.
#
# Environment variables (read):
#   ASHLR_PLUGIN_DIR       path to ashlr-plugin checkout      (default: ~/Desktop/ashlr-plugin)
#   MCP_RECOVERY_TIMEOUT   seconds per startup probe           (default: 5)
#   MCP_FAILURES_JSONL     JSONL file for failure events       (default: /tmp/mcp-failures-<pid>.jsonl)
#   MCP_RECOVERY_VERBOSE   non-empty → print captured stderr on failure
#
# Environment variables (written):
#   MCP_UNAVAILABLE        colon-separated list of failed server names
#                          (exported so child processes see it)
#
# Exit code semantics for mcp_recovery_probe_server:
#   0  — server healthy (started + emitted init signal)
#   1  — timeout: process started but produced no recognizable output
#   2  — crash: process exited non-zero before timeout
#   3  — missing binary: entry-point file not found
#   4  — missing runtime: bun/node not on PATH
#   5  — parse error: syntax/import error detected in stderr

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_RECOVERY_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_RECOVERY_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────
: "${MCP_RECOVERY_TIMEOUT:=5}"
: "${ASHLR_PLUGIN_DIR:=$HOME/Desktop/ashlr-plugin}"
: "${MCP_FAILURES_JSONL:=/tmp/mcp-failures-$$.jsonl}"

# MCP_UNAVAILABLE is a colon-separated list of server names that failed to start.
# Exported so that any child process (agent launcher) inherits it.
: "${MCP_UNAVAILABLE:=}"
export MCP_UNAVAILABLE

# ─── Fallback output helpers (if healthcheck.sh helpers are not sourced) ──────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
fi

# ─── _mcp_recovery_ts ─────────────────────────────────────────────────────────
_mcp_recovery_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ─── _mcp_recovery_json_escape <string> ───────────────────────────────────────
# Minimal JSON string escape: backslash, double-quote, and control characters.
_mcp_recovery_json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | tr '\n' ' ' \
    | tr '\r' ' ' \
    | tr '\t' ' '
}

# ─── _mcp_recovery_emit_failure <name> <rc> <stderr_snippet> <suggested_fix> ──
# Append one structured failure record to MCP_FAILURES_JSONL.
_mcp_recovery_emit_failure() {
  local name="$1"
  local rc="$2"
  local raw_err="$3"
  local fix="$4"

  local escaped_err escaped_fix
  escaped_err="$(_mcp_recovery_json_escape "$raw_err")"
  escaped_fix="$(_mcp_recovery_json_escape "$fix")"

  local record
  record="{\"ts\":\"$(_mcp_recovery_ts)\",\"server\":\"${name}\",\"exit_code\":${rc},\"error\":\"${escaped_err}\",\"suggested_fix\":\"${escaped_fix}\"}"

  # Ensure the JSONL directory exists.
  local jsonl_dir
  jsonl_dir="$(dirname "$MCP_FAILURES_JSONL")"
  [ -d "$jsonl_dir" ] || mkdir -p "$jsonl_dir" 2>/dev/null || true

  printf '%s\n' "$record" >> "$MCP_FAILURES_JSONL"
}

# ─── _mcp_recovery_mark_unavailable <name> ────────────────────────────────────
# Add <name> to MCP_UNAVAILABLE (colon-separated, no duplicates).
_mcp_recovery_mark_unavailable() {
  local name="$1"
  case ":${MCP_UNAVAILABLE}:" in
    *":${name}:"*) : ;;   # already present
    *) MCP_UNAVAILABLE="${MCP_UNAVAILABLE:+${MCP_UNAVAILABLE}:}${name}" ;;
  esac
  export MCP_UNAVAILABLE
}

# ─── _mcp_recovery_find_runtime <entry> ───────────────────────────────────────
# Echo the runtime (bun|node) for the given entry file, or return 1.
_mcp_recovery_find_runtime() {
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

# ─── _mcp_recovery_classify_stderr <stderr_text> ──────────────────────────────
# Return a short failure-class token based on stderr content.
#   parse_error | missing_deps | version_mismatch | permission | crash
_mcp_recovery_classify_stderr() {
  local err="$1"
  if printf '%s' "$err" | grep -qiE 'syntax error|unexpected token|parse error|expected.*but|SyntaxError'; then
    printf 'parse_error'
  elif printf '%s' "$err" | grep -qiE 'cannot find module|module not found|no such file|ModuleNotFoundError'; then
    printf 'missing_deps'
  elif printf '%s' "$err" | grep -qiE 'node.*version|engine.*node|unsupported.*engine|requires.*node'; then
    printf 'version_mismatch'
  elif printf '%s' "$err" | grep -qiE 'permission denied|EACCES|EPERM'; then
    printf 'permission'
  else
    printf 'crash'
  fi
}

# ─── _mcp_recovery_fix_hint <name> <rc> <stderr_snippet> ─────────────────────
# Return a one-line suggested fix string for a given failure type.
_mcp_recovery_fix_hint() {
  local name="$1"
  local rc="$2"
  local err="$3"
  local plugin_dir="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"

  case "$rc" in
    3)
      printf 'server file missing — run: git pull in %s' "$plugin_dir" ;;
    4)
      printf 'runtime not found — install bun: curl -fsSL https://bun.sh/install | bash' ;;
    5)
      printf 'TypeScript parse/syntax error — run: cd %s && bun build servers/%s-server.ts' \
        "$plugin_dir" "$name" ;;
    2)
      local cls
      cls="$(_mcp_recovery_classify_stderr "$err")"
      case "$cls" in
        missing_deps)    printf 'missing deps — run: cd %s && bun install' "$plugin_dir" ;;
        version_mismatch) printf 'runtime version mismatch — check: bun --version (need >= 1.0)' ;;
        permission)      printf 'permission error — check: ls -la %s/servers/' "$plugin_dir" ;;
        parse_error)     printf 'syntax error — run: cd %s && bun build servers/%s-server.ts' \
                           "$plugin_dir" "$name" ;;
        *)               printf 'server crashed — run manually: cd %s && bun servers/%s-server.ts' \
                           "$plugin_dir" "$name" ;;
      esac ;;
    1)
      printf 'server hung (no init output in %ss) — run: cd %s && bun servers/%s-server.ts' \
        "${MCP_RECOVERY_TIMEOUT}" "$plugin_dir" "$name" ;;
    *)
      printf 'unknown error (rc=%s) — run: cd %s && bun servers/%s-server.ts' \
        "$rc" "$plugin_dir" "$name" ;;
  esac
}

# ─── mcp_recovery_probe_server <name> <entry> ─────────────────────────────────
# Probe one MCP server with a timeout+health-check loop.
# Updates MCP_UNAVAILABLE and MCP_FAILURES_JSONL on failure.
#
# Returns:
#   0  — healthy
#   1  — timeout
#   2  — crash
#   3  — missing entry file
#   4  — missing runtime
#   5  — parse error (detected via stderr)
mcp_recovery_probe_server() {
  local name="$1"
  local entry="$2"
  local timeout_s="${MCP_RECOVERY_TIMEOUT:-5}"

  # ── Pre-flight: entry file ──────────────────────────────────────────────────
  if [ ! -f "$entry" ]; then
    local fix
    fix="$(_mcp_recovery_fix_hint "$name" 3 "")"
    _mcp_recovery_emit_failure "$name" 3 "entry file not found: $entry" "$fix"
    _mcp_recovery_mark_unavailable "$name"
    return 3
  fi

  # ── Pre-flight: runtime ─────────────────────────────────────────────────────
  local runtime
  runtime="$(_mcp_recovery_find_runtime "$entry")" || {
    local fix
    fix="$(_mcp_recovery_fix_hint "$name" 4 "")"
    _mcp_recovery_emit_failure "$name" 4 "no bun/node runtime on PATH" "$fix"
    _mcp_recovery_mark_unavailable "$name"
    return 4
  }

  # ── Launch server in background, capture stdout + stderr ───────────────────
  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-recovery-out-XXXXXX)" || return 2
  tmperr="$(mktemp /tmp/mcp-recovery-err-XXXXXX)" || { rm -f "$tmpout"; return 2; }

  local run_dir
  run_dir="$(dirname "$entry")"

  (
    cd "$run_dir" 2>/dev/null || true
    "$runtime" "$entry" </dev/null >"$tmpout" 2>"$tmperr"
  ) &
  local child_pid=$!

  # ── Poll with health-check loop up to $timeout_s seconds ───────────────────
  local elapsed=0
  local found=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    # Process already exited — check immediately before sleeping.
    if ! kill -0 "$child_pid" 2>/dev/null; then
      break
    fi
    # Accept any JSON-looking output line (MCP stdio handshake).
    if [ -s "$tmpout" ] && grep -q '^{' "$tmpout" 2>/dev/null; then
      found=1; break
    fi
    # Accept a "started/ready/listening" log line on stderr.
    if [ -s "$tmperr" ] && grep -qiE '(listen|start|ready|running|server)' "$tmperr" 2>/dev/null; then
      found=1; break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # One final check after process may have exited mid-sleep.
  if [ "$found" -eq 0 ] && [ -s "$tmpout" ] && grep -q '^{' "$tmpout" 2>/dev/null; then
    found=1
  fi

  # ── Record liveness BEFORE killing — this is the timeout vs crash discriminator.
  # After kill+wait, kill -0 always fails, so we must capture liveness now.
  local process_was_alive=0
  kill -0 "$child_pid" 2>/dev/null && process_was_alive=1

  # ── Clean up child ──────────────────────────────────────────────────────────
  kill "$child_pid" 2>/dev/null
  wait "$child_pid" 2>/dev/null

  local captured_out captured_err
  captured_out="$(cat "$tmpout" 2>/dev/null)"
  captured_err="$(cat "$tmperr" 2>/dev/null)"
  rm -f "$tmpout" "$tmperr"

  # ── Healthy path ────────────────────────────────────────────────────────────
  if [ "$found" -eq 1 ]; then
    return 0
  fi

  # ── Classify failure ───────────────────────────────────────────────────────
  local rc
  local err_snippet
  err_snippet="$(printf '%s' "$captured_err" | head -5 | tr '\n' ' ')"

  # Detect parse/syntax errors (rc=5) even if process exited early.
  if printf '%s' "$captured_err" | grep -qiE 'syntax error|unexpected token|parse error|SyntaxError'; then
    rc=5
  elif [ "$process_was_alive" -eq 1 ]; then
    # Process was still running at end of timeout loop — timed out without output.
    rc=1
  else
    # Process had already exited before timeout — classify as crash.
    rc=2
  fi

  if [ -n "${MCP_RECOVERY_VERBOSE:-}" ]; then
    [ -n "$captured_out" ] && printf "    [stdout] %s\n" "$(printf '%s' "$captured_out" | head -3)"
    [ -n "$captured_err" ] && printf "    [stderr] %s\n" "$(printf '%s' "$captured_err" | head -3)"
  fi

  local fix
  fix="$(_mcp_recovery_fix_hint "$name" "$rc" "$captured_err")"
  _mcp_recovery_emit_failure "$name" "$rc" "$err_snippet" "$fix"
  _mcp_recovery_mark_unavailable "$name"
  return "$rc"
}

# ─── mcp_recovery_probe_all [name entry ...] ──────────────────────────────────
# Probe all MCP servers. When called with no args, uses the default 10
# ashlr-plugin servers from ASHLR_PLUGIN_DIR/servers/.
#
# Returns 0 if all succeeded, 1 if any failed.
mcp_recovery_probe_all() {
  local plugin_dir="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
  local any_fail=0

  if [ "$#" -gt 0 ]; then
    # Caller passed explicit name/entry pairs.
    while [ "$#" -ge 2 ]; do
      local _name="$1" _entry="$2"; shift 2
      local _rc=0
      mcp_recovery_probe_server "$_name" "$_entry" || _rc=$?
      [ "$_rc" -ne 0 ] && any_fail=1
    done
  else
    # Default: probe all 10 ashlr-plugin servers.
    local default_servers="efficiency sql bash tree http diff logs genome orient github"
    for _sname in $default_servers; do
      local _entry="$plugin_dir/servers/${_sname}-server.ts"
      local _rc=0
      mcp_recovery_probe_server "$_sname" "$_entry" || _rc=$?
      [ "$_rc" -ne 0 ] && any_fail=1
    done
  fi

  return "$any_fail"
}

# ─── mcp_recovery_report ──────────────────────────────────────────────────────
# Print a human-readable MCP resilience summary.
# Uses MCP_UNAVAILABLE (set by prior probe calls) and MCP_FAILURES_JSONL.
# Designed to be called after mcp_recovery_probe_all (or probe_server loops)
# to fold results into the healthcheck output.
mcp_recovery_report() {
  local total_servers="${MCP_RECOVERY_TOTAL_SERVERS:-10}"
  local unavail_count=0
  local unavail_names="${MCP_UNAVAILABLE:-}"

  # Count unavailable servers.
  if [ -n "$unavail_names" ]; then
    # Count colon-separated tokens.
    local _tmp="$unavail_names:"
    while [ -n "$_tmp" ]; do
      case "$_tmp" in
        *:*) _tmp="${_tmp#*:}"; unavail_count=$((unavail_count + 1)) ;;
        *)   break ;;
      esac
    done
  fi

  local ok_count=$(( total_servers - unavail_count ))
  # Guard against negative counts when total_servers is misconfigured.
  [ "$ok_count" -lt 0 ] && ok_count=0

  local pct=0
  if [ "$total_servers" -gt 0 ]; then
    pct=$(( ok_count * 100 / total_servers ))
  fi

  if [ "$unavail_count" -eq 0 ]; then
    ok "MCP Resilience: ${ok_count}/${total_servers} servers startable (${pct}%)"
  else
    warn "MCP Resilience: ${ok_count}/${total_servers} servers startable (${pct}%) — ${unavail_count} unavailable: ${unavail_names}"

    # List each flaky server with its fix hint from the JSONL.
    if [ -f "$MCP_FAILURES_JSONL" ] && command -v python3 >/dev/null 2>&1; then
      python3 - "$MCP_FAILURES_JSONL" <<'PYEOF'
import json, sys
seen = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
        name = r.get("server", "?")
        if name in seen:
            continue
        seen.add(name)
        fix = r.get("suggested_fix", "")
        err = r.get("error", "")[:80]
        print("    flaky: {} — {} | fix: {}".format(name, err, fix))
    except Exception:
        pass
PYEOF
    else
      # Fallback: just print unavailable names.
      local _n
      for _n in $(printf '%s' "$unavail_names" | tr ':' ' '); do
        printf "    flaky: %s\n" "$_n"
      done
    fi
  fi

  # Show JSONL path when it has content.
  if [ -f "$MCP_FAILURES_JSONL" ] && [ -s "$MCP_FAILURES_JSONL" ]; then
    printf "    failures log: %s\n" "$MCP_FAILURES_JSONL"
  fi
}

# ─── mcp_recovery_check_unavailable <name> ────────────────────────────────────
# Return 0 if <name> is marked unavailable in MCP_UNAVAILABLE, 1 otherwise.
# Useful in agent launch scripts: if mcp_recovery_check_unavailable "bash"; then ...
mcp_recovery_check_unavailable() {
  local name="$1"
  case ":${MCP_UNAVAILABLE}:" in
    *":${name}:"*) return 0 ;;
    *)             return 1 ;;
  esac
}
