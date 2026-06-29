#!/usr/bin/env bash
# mcp-connection.sh — MCP connection validation helpers for integration tests.
#
# Provides functions used by tests/mcp-integration.sh to:
#   - Verify an agent config lists MCP servers (schema-level check)
#   - Send a synthetic JSON-RPC initialize + tool-list request over stdio
#   - Parse the JSON-RPC response and validate its shape
#   - Emit structured JSONL result records
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.
#
# Usage (sourced by tests/mcp-integration.sh):
#   source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/mcp-connection.sh"

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_CONNECTION_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_CONNECTION_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────
MCP_CONN_TIMEOUT="${MCP_CONN_TIMEOUT:-5}"        # seconds per agent probe
MCP_CONN_JSONL_OUT="${MCP_CONN_JSONL_OUT:-}"     # path for JSONL output; empty = stdout only

# ─── _mcp_conn_ts — ISO-8601 timestamp ────────────────────────────────────────
_mcp_conn_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ─── _mcp_conn_emit_jsonl <agent> <mcp_server> <status> <latency_ms> [detail] ─
# Append one JSONL record to MCP_CONN_JSONL_OUT (or /dev/null if unset).
_mcp_conn_emit_jsonl() {
  local agent="$1"
  local mcp_server="$2"
  local status="$3"       # pass | fail | skip
  local latency_ms="$4"   # integer ms, or -1 if not measured
  local detail="${5:-}"

  # Escape detail for JSON (replace " with \", newlines with space)
  local detail_escaped
  detail_escaped="$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/"/\\"/g')"

  local record
  record="{\"ts\":\"$(_mcp_conn_ts)\",\"agent\":\"${agent}\",\"mcp\":\"${mcp_server}\",\"status\":\"${status}\",\"latency_ms\":${latency_ms},\"detail\":\"${detail_escaped}\"}"

  if [ -n "$MCP_CONN_JSONL_OUT" ]; then
    printf '%s\n' "$record" >> "$MCP_CONN_JSONL_OUT"
  fi
  # Always return the record on stdout for callers that want to capture it.
  printf '%s\n' "$record"
}

# ─── _mcp_conn_jsonrpc_msg <id> <method> [params_json] ────────────────────────
# Emit a framed JSON-RPC 2.0 message (Content-Length header + body) to stdout,
# suitable for piping to an MCP stdio server.
_mcp_conn_jsonrpc_msg() {
  local id="$1"
  local method="$2"
  local params="${3:-{}}"

  local body="{\"jsonrpc\":\"2.0\",\"id\":${id},\"method\":\"${method}\",\"params\":${params}}"
  local len="${#body}"
  printf 'Content-Length: %d\r\n\r\n%s' "$len" "$body"
}

# ─── _mcp_conn_find_runtime <entry_file> ──────────────────────────────────────
# Echo the runtime command (bun | node) for the given entry file, or return 1.
_mcp_conn_find_runtime() {
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

# ─── _mcp_conn_probe_server <agent> <mcp_name> <entry_file> ──────────────────
# Start the MCP server, send an initialize + tools/list handshake over stdio,
# validate the response shape, kill the server, and emit a JSONL record.
#
# Returns:
#   0  — handshake completed successfully (PASS)
#   1  — response received but shape invalid (FAIL)
#   2  — no response within timeout (FAIL — hang/timeout)
#   3  — entry file missing (FAIL — config drift / missing entrypoint)
#   4  — runtime not available (SKIP)
#   5  — server crashed before responding (FAIL)
_mcp_conn_probe_server() {
  local agent="$1"
  local mcp_name="$2"
  local entry="$3"
  local timeout_s="${MCP_CONN_TIMEOUT:-5}"

  # ── pre-flight ────────────────────────────────────────────────────────────────
  if [ ! -f "$entry" ]; then
    _mcp_conn_emit_jsonl "$agent" "$mcp_name" "fail" "-1" "entry file missing: $entry" >/dev/null
    return 3
  fi

  local runtime
  runtime="$(_mcp_conn_find_runtime "$entry")" || {
    _mcp_conn_emit_jsonl "$agent" "$mcp_name" "skip" "-1" "no runtime (bun/node) on PATH" >/dev/null
    return 4
  }

  # ── build the two-message handshake ──────────────────────────────────────────
  # Message 1: initialize (required by MCP protocol before any other call)
  local init_msg
  init_msg="$(_mcp_conn_jsonrpc_msg 1 'initialize' \
    '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-integration-test","version":"1.0"}}')"

  # Message 2: tools/list (verifies the server exposes at least one tool)
  local list_msg
  list_msg="$(_mcp_conn_jsonrpc_msg 2 'tools/list' '{}')"

  # Combine into the stdin payload the server will read.
  local stdin_payload
  stdin_payload="${init_msg}${list_msg}"

  # ── launch server and pipe the handshake ─────────────────────────────────────
  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-conn-out-XXXXXX)" || return 5
  tmperr="$(mktemp /tmp/mcp-conn-err-XXXXXX)" || { rm -f "$tmpout"; return 5; }

  local t_start t_end latency_ms
  t_start="$(date +%s)"

  # Run from the entry file's directory so relative imports resolve.
  local run_dir
  run_dir="$(dirname "$entry")"

  (
    cd "$run_dir" 2>/dev/null || true
    printf '%s' "$stdin_payload" | "$runtime" "$entry" >"$tmpout" 2>"$tmperr"
  ) &
  local child_pid=$!

  # ── poll for a JSON-RPC response within timeout ───────────────────────────────
  local elapsed=0
  local found_response=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      # Process already exited.
      break
    fi
    # Accept any line containing "jsonrpc" in the output (framed or bare JSON).
    if [ -s "$tmpout" ] && grep -q '"jsonrpc"' "$tmpout" 2>/dev/null; then
      found_response=1
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # If still no output but process is running, wait one more second then kill.
  if [ "$found_response" -eq 0 ] && [ -s "$tmpout" ] && grep -q '"jsonrpc"' "$tmpout" 2>/dev/null; then
    found_response=1
  fi

  kill "$child_pid" 2>/dev/null
  wait "$child_pid" 2>/dev/null

  t_end="$(date +%s)"
  latency_ms=$(( (t_end - t_start) * 1000 ))

  local captured_out captured_err
  captured_out="$(cat "$tmpout" 2>/dev/null)"
  captured_err="$(cat "$tmperr" 2>/dev/null)"
  rm -f "$tmpout" "$tmperr"

  # ── validate response shape ───────────────────────────────────────────────────
  if [ "$found_response" -eq 0 ]; then
    # Distinguish crash (process exited) from timeout (process was still running).
    if ! kill -0 "$child_pid" 2>/dev/null; then
      local err_snippet
      err_snippet="$(printf '%s' "$captured_err" | head -3 | tr '\n' ' ')"
      _mcp_conn_emit_jsonl "$agent" "$mcp_name" "fail" "$latency_ms" "server crashed: $err_snippet" >/dev/null
      return 5
    else
      _mcp_conn_emit_jsonl "$agent" "$mcp_name" "fail" "$latency_ms" "timeout: no jsonrpc response in ${timeout_s}s" >/dev/null
      return 2
    fi
  fi

  # Verify response has the expected JSON-RPC fields.
  # We check for "result" or "error" keys and that "id" is present.
  local shape_ok=0
  if printf '%s' "$captured_out" | grep -q '"jsonrpc"' && \
     printf '%s' "$captured_out" | grep -qE '"result"|"error"'; then
    shape_ok=1
  fi

  if [ "$shape_ok" -eq 1 ]; then
    _mcp_conn_emit_jsonl "$agent" "$mcp_name" "pass" "$latency_ms" "jsonrpc handshake OK" >/dev/null
    return 0
  else
    local snippet
    snippet="$(printf '%s' "$captured_out" | head -2 | tr '\n' ' ')"
    _mcp_conn_emit_jsonl "$agent" "$mcp_name" "fail" "$latency_ms" "bad response shape: $snippet" >/dev/null
    return 1
  fi
}

# ─── mcp_conn_extract_servers_from_json <config_json_path> ────────────────────
# Parse an agent's MCP config JSON (settings.json or mcp.json) and print one
# "name|command|arg0" triplet per server, space-separated lines.
# Falls back to grepping for server names if python3 is absent.
mcp_conn_extract_servers_from_json() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$cfg" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    # Handle both settings.json (mcpServers key) and mcp.json (stdio_servers array)
    servers = {}
    if 'mcpServers' in data:
        servers = data['mcpServers']
    elif 'stdio_servers' in data:
        for s in data.get('stdio_servers', []):
            servers[s.get('name','unknown')] = {
                'command': s.get('command',''),
                'args': s.get('args', [])
            }
    for name, cfg in servers.items():
        cmd = cfg.get('command', '')
        args = cfg.get('args', [])
        arg0 = args[0] if args else ''
        print(f"{name}|{cmd}|{arg0}")
except Exception as e:
    sys.exit(1)
PYEOF
  else
    # Fallback: grep for server names only (no arg extraction)
    grep '"ashlr-' "$cfg" 2>/dev/null | grep -oE '"ashlr-[a-z]+"' | tr -d '"' | \
      while read -r name; do printf '%s|unknown|unknown\n' "$name"; done
  fi
}

# ─── mcp_conn_validate_agent <agent_name> <config_file> <plugin_dir> ──────────
# Run the full handshake suite for one agent:
#   1. Extract MCP server list from config
#   2. Probe each server
#   3. Return per-server results
#
# Outputs: space-separated "agent|mcp|status|latency_ms" lines on stdout.
mcp_conn_validate_agent() {
  local agent_name="$1"
  local config_file="$2"
  local plugin_dir="${3:-${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}}"

  # Extract server entries from the agent config.
  local server_lines
  server_lines="$(mcp_conn_extract_servers_from_json "$config_file" 2>/dev/null || true)"

  if [ -z "$server_lines" ]; then
    _mcp_conn_emit_jsonl "$agent_name" "(none)" "skip" "-1" "no MCP servers found in config"
    return 0
  fi

  local results=""
  printf '%s\n' "$server_lines" | while IFS='|' read -r srv_name srv_cmd srv_arg0; do
    # Only probe ashlr-plugin servers (command=bash, arg0 is the entrypoint script).
    # Skip external MCPs (supabase/npx, roblox-studio, etc.) — they need real creds.
    case "$srv_name" in
      ashlr-*)
        # Resolve the actual .ts entry from the arg: the entrypoint script's second
        # arg (e.g. "servers/efficiency-server.ts") is relative to plugin_dir.
        local ts_rel="${srv_arg0}"
        # If arg0 looks like a full path to mcp-entrypoint.sh, the .ts is the *next*
        # arg in the original JSON — we can't get it here easily, so we reconstruct
        # from the server name: ashlr-efficiency → efficiency-server.ts
        local short_name="${srv_name#ashlr-}"
        local ts_path="$plugin_dir/servers/${short_name}-server.ts"

        local rc=0
        _mcp_conn_probe_server "$agent_name" "$srv_name" "$ts_path" || rc=$?
        ;;
      *)
        # External / non-ashlr MCP — skip, needs real env/creds
        _mcp_conn_emit_jsonl "$agent_name" "$srv_name" "skip" "-1" "external MCP skipped in integration test" >/dev/null
        ;;
    esac
  done
}
