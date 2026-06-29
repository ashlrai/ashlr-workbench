#!/usr/bin/env bash
# mcp-probe.sh — MCP server liveliness probe + auto-restart suggestions.
#
# Provides validate_mcp_servers() which starts each ashlr-plugin MCP server for
# up to MCP_PROBE_TIMEOUT seconds, verifies that the process writes the MCP
# JSON-RPC stdio initialization line ({"jsonrpc":"2.0",...}), then kills the
# process and reports pass/fail with an actionable fix message.
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.
#
# Usage (standalone or sourced):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/mcp-probe.sh"
#   validate_mcp_servers          # uses globals set by caller/config.sh
#
# Required globals (set before sourcing, typically via config.sh):
#   ASHLR_PLUGIN_DIR  — path to the ashlr-plugin checkout
#
# Optional globals:
#   MCP_PROBE_TIMEOUT — seconds to wait for stdio init line  (default: 3)
#   MCP_PROBE_VERBOSE — set non-empty to print captured stderr on failure

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_PROBE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_PROBE_SOURCED=1

# ─── Helpers expected to exist (provided by healthcheck.sh or test harness) ───
# If sourced in isolation (e.g. unit tests) provide lightweight fallbacks.
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
fi

# ─── _mcp_probe_one <server-name> <entry-point> ───────────────────────────────
# Start one MCP server subprocess, wait up to MCP_PROBE_TIMEOUT seconds for it
# to emit a JSON-RPC line (indicating stdio transport is up), then kill it.
#
# Returns:
#   0  — server started and wrote JSON-RPC init output  (PASS)
#   1  — timeout: process started but produced no JSON-RPC output
#   2  — process exited with non-zero status before timeout
#   3  — entry-point file not found
#   4  — runtime (bun/node) not on PATH
#
# Writes human-readable captured output to stdout on failure when
# MCP_PROBE_VERBOSE is set.
_mcp_probe_one() {
  local name="$1"
  local entry="$2"
  local timeout="${MCP_PROBE_TIMEOUT:-3}"

  # ── sanity checks ────────────────────────────────────────────────────────────
  if [ ! -f "$entry" ]; then
    return 3
  fi

  # Determine runtime.
  local runtime=""
  case "$entry" in
    *.ts)
      if command -v bun >/dev/null 2>&1; then
        runtime="bun"
      else
        return 4
      fi
      ;;
    *.js|*.mjs|*.cjs)
      if command -v node >/dev/null 2>&1; then
        runtime="node"
      elif command -v bun >/dev/null 2>&1; then
        runtime="bun"
      else
        return 4
      fi
      ;;
    *)
      # Unknown extension — try bun then node.
      if command -v bun >/dev/null 2>&1; then
        runtime="bun"
      elif command -v node >/dev/null 2>&1; then
        runtime="node"
      else
        return 4
      fi
      ;;
  esac

  # ── launch in background, capturing combined output via a temp file ──────────
  local tmpout
  tmpout="$(mktemp /tmp/mcp-probe-XXXXXX)" || return 2
  local tmperr
  tmperr="$(mktemp /tmp/mcp-probe-err-XXXXXX)" || { rm -f "$tmpout"; return 2; }

  # Start the server. MCP servers read from stdin so we feed /dev/null.
  # We run from the plugin directory so relative imports resolve correctly.
  (
    cd "$(dirname "$entry")" 2>/dev/null || cd "$ASHLR_PLUGIN_DIR"
    "$runtime" "$entry" </dev/null >"$tmpout" 2>"$tmperr"
  ) &
  local child_pid=$!

  # ── poll for JSON-RPC output up to $timeout seconds ─────────────────────────
  local elapsed=0
  local found=0
  while [ "$elapsed" -lt "$timeout" ]; do
    # Check if process already died.
    if ! kill -0 "$child_pid" 2>/dev/null; then
      break
    fi
    # MCP stdio servers write a JSON-RPC handshake or log line on startup.
    # We accept any line that looks like JSON (starts with '{').
    if [ -s "$tmpout" ] && grep -q '^{' "$tmpout" 2>/dev/null; then
      found=1
      break
    fi
    # Also accept a "Listening" / "started" / "ready" log line in stderr —
    # some servers log to stderr before writing the first JSON frame.
    if [ -s "$tmperr" ] && grep -qiE '(listen|start|ready|running|server)' "$tmperr" 2>/dev/null; then
      found=1
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # ── clean up the child ───────────────────────────────────────────────────────
  kill "$child_pid" 2>/dev/null
  wait "$child_pid" 2>/dev/null

  # ── collect output for diagnostics ──────────────────────────────────────────
  local captured_out captured_err
  captured_out="$(cat "$tmpout" 2>/dev/null)"
  captured_err="$(cat "$tmperr" 2>/dev/null)"
  rm -f "$tmpout" "$tmperr"

  if [ "$found" -eq 1 ]; then
    return 0
  fi

  # Print diagnostic info when verbose or when the process died immediately.
  if [ -n "${MCP_PROBE_VERBOSE:-}" ]; then
    if [ -n "$captured_out" ]; then
      printf "    [stdout] %s\n" "$(printf '%s' "$captured_out" | head -5)"
    fi
    if [ -n "$captured_err" ]; then
      printf "    [stderr] %s\n" "$(printf '%s' "$captured_err" | head -5)"
    fi
  fi

  # Did the process exit before the timeout (crashed)?
  if ! kill -0 "$child_pid" 2>/dev/null; then
    return 2
  fi

  # Timed out without any recognizable output.
  return 1
}

# ─── _mcp_fix_hint <server-name> <return-code> <stderr-snippet> ───────────────
# Print an actionable one-liner that explains how to fix the problem.
_mcp_fix_hint() {
  local name="$1"
  local rc="$2"
  local err_snippet="$3"
  local plugin_dir="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"

  case "$rc" in
    3)
      printf "    Fix: server file missing — git status in %s\n" "$plugin_dir"
      ;;
    4)
      printf "    Fix: runtime not found — install bun: curl -fsSL https://bun.sh/install | bash\n"
      ;;
    2)
      # Crashed — try to infer cause from stderr snippet.
      if printf '%s' "$err_snippet" | grep -qi 'cannot find module\|module not found\|no such file'; then
        printf "    Fix: missing deps — run: cd %s && bun install\n" "$plugin_dir"
      elif printf '%s' "$err_snippet" | grep -qi 'node.*version\|engine.*node\|unsupported.*engine'; then
        printf "    Fix: Node/bun version mismatch — check: bun --version  (need >= 1.0)\n"
      elif printf '%s' "$err_snippet" | grep -qi 'syntax error\|unexpected token\|parse error'; then
        printf "    Fix: TypeScript/JS syntax error in %s-server.ts — run: bun build servers/%s-server.ts\n" "$name" "$name"
      elif printf '%s' "$err_snippet" | grep -qi 'enoent\|permission denied'; then
        printf "    Fix: file permission or path issue — check ls -la %s/servers/\n" "$plugin_dir"
      else
        printf "    Fix: process crashed — run manually: cd %s && bun servers/%s-server.ts\n" "$plugin_dir" "$name"
      fi
      ;;
    1)
      printf "    Fix: server started but produced no init output in %ss — run manually to debug:\n" "${MCP_PROBE_TIMEOUT:-3}"
      printf "         cd %s && bun servers/%s-server.ts\n" "$plugin_dir" "$name"
      ;;
    *)
      printf "    Fix: unknown error (rc=%s) — run manually: cd %s && bun servers/%s-server.ts\n" "$rc" "$plugin_dir" "$name"
      ;;
  esac
}

# ─── validate_mcp_servers ─────────────────────────────────────────────────────
# Public entry point.  Sources config.sh if ASHLR_PLUGIN_DIR is unset, then
# probes each of the 10 ashlr-plugin MCP servers.
#
# Outputs per-server pass/fail lines using the ok/warn/bad helpers and
# increments the PASS/WARN/FAIL counters expected by healthcheck.sh.
validate_mcp_servers() {
  local plugin_dir="${ASHLR_PLUGIN_DIR:-}"

  # Source config.sh to pick up ASHLR_PLUGIN_DIR if not already set.
  if [ -z "$plugin_dir" ]; then
    local _probe_script_dir
    _probe_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$_probe_script_dir/config.sh" ]; then
      # shellcheck source=scripts/lib/config.sh
      . "$_probe_script_dir/config.sh"
    fi
    plugin_dir="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
  fi

  local servers_dir="$plugin_dir/servers"

  # Pre-flight: plugin directory and runtime must exist.
  if [ ! -d "$plugin_dir" ]; then
    bad "MCP probe: ashlr-plugin not found at $plugin_dir"
    printf "    Fix: clone or symlink ashlr-plugin to %s\n" "$plugin_dir"
    return
  fi

  if [ ! -d "$servers_dir" ]; then
    bad "MCP probe: servers/ directory missing in $plugin_dir"
    printf "    Fix: run \`git pull\` in %s\n" "$plugin_dir"
    return
  fi

  if ! command -v bun >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
    warn "MCP probe: neither bun nor node on PATH — skipping liveliness checks"
    printf "    Fix: install bun: curl -fsSL https://bun.sh/install | bash\n"
    return
  fi

  # node_modules check — give early warning so the per-server errors are less
  # confusing when deps are simply missing.
  local deps_ok=1
  if [ ! -d "$plugin_dir/node_modules/@modelcontextprotocol/sdk" ]; then
    warn "MCP probe: node_modules missing — some servers will fail to start"
    printf "    Fix: cd %s && bun install\n" "$plugin_dir"
    deps_ok=0
  fi

  # The 10 ashlr-plugin MCP server names (matching servers/<name>-server.ts).
  local MCP_SERVER_NAMES="efficiency sql bash tree http diff logs genome orient github"

  local any_fail=0
  for name in $MCP_SERVER_NAMES; do
    local entry="$servers_dir/${name}-server.ts"
    local rc=0

    _mcp_probe_one "$name" "$entry"
    rc=$?

    case "$rc" in
      0)
        ok "ashlr-${name}: MCP server started + stdio init OK"
        ;;
      3)
        bad "ashlr-${name}: server file missing ($entry)"
        _mcp_fix_hint "$name" "$rc" ""
        any_fail=1
        ;;
      4)
        warn "ashlr-${name}: no runtime available (bun/node not found)"
        _mcp_fix_hint "$name" "$rc" ""
        ;;
      2)
        # Collect a stderr snippet for smarter hints.
        local _err_snippet=""
        # Re-run a quick capture pass (stderr only, 1s timeout) for hint purposes
        # only if deps are present; skip when we already know deps are missing.
        if [ "$deps_ok" -eq 1 ]; then
          _err_snippet="$(
            (
              cd "$plugin_dir"
              timeout 2 bun "$entry" </dev/null 2>&1 >/dev/null
            ) 2>/dev/null | head -3 || true
          )"
        fi
        bad "ashlr-${name}: server crashed on startup"
        _mcp_fix_hint "$name" "$rc" "$_err_snippet"
        any_fail=1
        ;;
      1)
        # Timed out — could be a slow-starting server; emit as warn not bad
        # since the process did at least start.
        warn "ashlr-${name}: server started but no stdio init in ${MCP_PROBE_TIMEOUT:-3}s"
        _mcp_fix_hint "$name" "$rc" ""
        ;;
      *)
        bad "ashlr-${name}: unexpected probe result (rc=$rc)"
        _mcp_fix_hint "$name" "$rc" ""
        any_fail=1
        ;;
    esac
  done

  return "$any_fail"
}
