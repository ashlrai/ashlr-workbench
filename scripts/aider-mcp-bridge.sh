#!/usr/bin/env bash
# aider-mcp-bridge.sh — Thin MCP-to-Aider subprocess bridge
#
# Exposes the 10 ashlr-plugin MCP tools as Aider /run shell commands so that
# Aider users can invoke them without upstream MCP protocol support in Aider.
#
# How it works:
#   1. This script registers thin wrapper commands under $AIDER_MCP_BRIDGE_BIN
#      (default: a per-session temp dir).
#   2. Each wrapper builds a JSON-RPC 2.0 tools/call request, pipes it to the
#      appropriate ashlr-plugin MCP server, and prints the result to stdout
#      (which Aider captures as /run output).
#   3. start-aider.sh sources this file and calls aider_mcp_bridge_init before
#      launching Aider, prepending $AIDER_MCP_BRIDGE_BIN to PATH so /run finds
#      the wrappers.
#
# Supported tools (one wrapper each):
#   ashlr__read   ashlr__grep   ashlr__bash   ashlr__edit   ashlr__ls
#   ashlr__tree   ashlr__diff   ashlr__http   ashlr__orient ashlr__savings
#
# Usage (sourced by start-aider.sh):
#   . "$(dirname "$0")/aider-mcp-bridge.sh"
#   aider_mcp_bridge_init      # creates wrappers, prepends PATH
#   aider_mcp_bridge_cleanup   # called from EXIT trap in start-aider.sh
#
# Direct invocation / self-test:
#   bash scripts/aider-mcp-bridge.sh
#   AIDER_MCP_BRIDGE_DRY_RUN=1 bash scripts/aider-mcp-bridge.sh
#
# Environment:
#   ASHLR_PLUGIN_DIR         path to ashlr-plugin  (default: ~/Desktop/ashlr-plugin)
#   AIDER_MCP_BRIDGE_BIN     where wrappers live   (default: mktemp dir)
#   AIDER_MCP_BRIDGE_TIMEOUT seconds per MCP call  (default: 30)
#   AIDER_MCP_BRIDGE_DRY_RUN if non-empty, report but don't write wrappers

set -euo pipefail

# Guard against double-sourcing.
if [ -n "${_AIDER_MCP_BRIDGE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_AIDER_MCP_BRIDGE_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────
: "${ASHLR_PLUGIN_DIR:=${HOME}/Desktop/ashlr-plugin}"
: "${AIDER_MCP_BRIDGE_TIMEOUT:=30}"
: "${AIDER_MCP_BRIDGE_DRY_RUN:=}"

# ─── Tool → server mapping ────────────────────────────────────────────────────
# Format: TOOL_NAME|SERVER_TS_PATH_RELATIVE_TO_ASHLR_PLUGIN_DIR
_BRIDGE_TOOL_SERVER_MAP="
ashlr__read|servers/efficiency-server.ts
ashlr__grep|servers/efficiency-server.ts
ashlr__edit|servers/efficiency-server.ts
ashlr__savings|servers/efficiency-server.ts
ashlr__bash|servers/bash-server.ts
ashlr__ls|servers/tree-server.ts
ashlr__tree|servers/tree-server.ts
ashlr__diff|servers/diff-server.ts
ashlr__http|servers/http-server.ts
ashlr__orient|servers/orient-server.ts
"

# ─── Helpers ──────────────────────────────────────────────────────────────────

_bridge_find_runtime() {
  if command -v bun  >/dev/null 2>&1; then printf 'bun';  return 0; fi
  if command -v node >/dev/null 2>&1; then printf 'node'; return 0; fi
  return 1
}

# _bridge_call_tool <server_ts> <tool_name> <args_json>
# Spawns the MCP server, sends initialize + tools/call, prints result text.
_bridge_call_tool() {
  local server_ts="$1"
  local tool_name="$2"
  local args_json="${3:-{}}"
  local timeout_s="${AIDER_MCP_BRIDGE_TIMEOUT}"

  if [ ! -f "$server_ts" ]; then
    printf 'aider-mcp-bridge: server not found: %s\n' "$server_ts" >&2
    printf 'Hint: clone ashlr-plugin to %s then: cd %s && bun install\n' \
      "$ASHLR_PLUGIN_DIR" "$ASHLR_PLUGIN_DIR" >&2
    return 1
  fi

  local runtime
  if ! runtime="$(_bridge_find_runtime)"; then
    printf 'aider-mcp-bridge: bun/node not on PATH\n' >&2
    printf 'Hint: install bun: curl -fsSL https://bun.sh/install | bash\n' >&2
    return 1
  fi

  local init_msg call_msg
  init_msg='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"aider-mcp-bridge","version":"1.0"}}}'
  call_msg="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool_name}\",\"arguments\":${args_json}}}"

  local tmpout tmperr
  tmpout="$(mktemp /tmp/aider-mcp-out-XXXXXX)"
  tmperr="$(mktemp /tmp/aider-mcp-err-XXXXXX)"

  local server_dir
  server_dir="$(dirname "$server_ts")"

  (
    cd "$server_dir" 2>/dev/null || true
    printf '%s\n%s\n' "$init_msg" "$call_msg" | "$runtime" "$server_ts"
  ) >"$tmpout" 2>"$tmperr" &
  local child_pid=$!

  local elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    printf 'aider-mcp-bridge: timeout after %ds waiting for %s\n' "$timeout_s" "$tool_name" >&2
    rm -f "$tmpout" "$tmperr"
    return 1
  fi
  wait "$child_pid" 2>/dev/null || true

  local output errors
  output="$(cat "$tmpout" 2>/dev/null)"
  errors="$(cat "$tmperr" 2>/dev/null)"
  rm -f "$tmpout" "$tmperr"

  if [ -z "$output" ]; then
    printf 'aider-mcp-bridge: no output from %s\n' "$tool_name" >&2
    [ -n "$errors" ] && printf '%s\n' "$errors" >&2
    return 1
  fi

  # Extract result from the id=2 tools/call response.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$output" | python3 -c "
import json, sys
tool = '${tool_name}'
raw = sys.stdin.read()
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get('id') != 2:
        continue
    if 'error' in obj:
        msg = obj['error'].get('message', json.dumps(obj['error']))
        print('[' + tool + ' error] ' + msg, file=sys.stderr)
        sys.exit(1)
    elif 'result' in obj:
        content = obj['result'].get('content', [])
        parts = [c.get('text','') for c in content if c.get('type') == 'text']
        print('\n'.join(parts) if parts else json.dumps(obj['result']))
        sys.exit(0)
# No id=2 found — dump raw
print(raw)
"
  else
    printf '%s\n' "$output" | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"$//' | head -50
  fi
}

# ─── _bridge_write_core <bin_dir> ─────────────────────────────────────────────
# Write _bridge-core.sh and _bridge-parse.py into bin_dir.
# Uses a separate Python file to avoid any nested quoting issues in bash.
_bridge_write_core() {
  local bin_dir="$1"
  local core="$bin_dir/_bridge-core.sh"
  local pyparse="$bin_dir/_bridge-parse.py"

  # Write the Python JSON-RPC response parser as a standalone script.
  # This avoids all nested-heredoc and quoting problems.
  cat > "$pyparse" << 'PYEOF'
#!/usr/bin/env python3
# _bridge-parse.py — extract text content from an MCP tools/call response.
# Usage: python3 _bridge-parse.py <tool_name> < jsonrpc_output
import json, sys

tool = sys.argv[1] if len(sys.argv) > 1 else "tool"
raw = sys.stdin.read()

for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("id") != 2:
        continue
    if "error" in obj:
        msg = obj["error"].get("message", json.dumps(obj["error"]))
        print("[" + tool + " error] " + msg, file=sys.stderr)
        sys.exit(1)
    content = obj.get("result", {}).get("content", [])
    parts = [c.get("text", "") for c in content if c.get("type") == "text"]
    print("\n".join(parts) if parts else json.dumps(obj.get("result", {})))
    sys.exit(0)

# No id=2 response found — print raw output so user can debug
print(raw)
PYEOF

  chmod +x "$pyparse"

  # Write the bash core helper. No Python inline — delegates to _bridge-parse.py.
  cat > "$core" << 'COREEOF'
#!/usr/bin/env bash
# _bridge-core.sh — shared MCP call helper. Sourced by tool wrappers.
# shellcheck shell=bash

_bridge_find_runtime() {
  command -v bun  >/dev/null 2>&1 && { printf 'bun';  return 0; }
  command -v node >/dev/null 2>&1 && { printf 'node'; return 0; }
  return 1
}

_bridge_call_tool() {
  local server_ts="$1" tool_name="$2" args_json="${3:-{}}"
  local timeout_s="${AIDER_MCP_BRIDGE_TIMEOUT:-30}"
  local runtime
  runtime="$(_bridge_find_runtime)" || {
    printf 'aider-mcp-bridge: bun/node not on PATH\n' >&2
    return 1
  }
  [ -f "$server_ts" ] || {
    printf 'aider-mcp-bridge: server not found: %s\nHint: clone ashlr-plugin and run bun install\n' \
      "$server_ts" >&2
    return 1
  }
  local init_msg='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"aider-mcp-bridge","version":"1.0"}}}'
  local call_msg
  call_msg="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool_name}\",\"arguments\":${args_json}}}"
  local tmpout tmperr
  tmpout="$(mktemp /tmp/aider-mcp-out-XXXXXX)"
  tmperr="$(mktemp /tmp/aider-mcp-err-XXXXXX)"
  local server_dir
  server_dir="$(dirname "$server_ts")"
  (
    cd "$server_dir" 2>/dev/null || true
    printf '%s\n%s\n' "$init_msg" "$call_msg" | "$runtime" "$server_ts"
  ) >"$tmpout" 2>"$tmperr" &
  local child_pid=$! elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    printf 'aider-mcp-bridge: timeout after %ds waiting for %s\n' "$timeout_s" "$tool_name" >&2
    rm -f "$tmpout" "$tmperr"
    return 1
  fi
  wait "$child_pid" 2>/dev/null || true
  local output errors
  output="$(cat "$tmpout" 2>/dev/null)"
  errors="$(cat "$tmperr" 2>/dev/null)"
  rm -f "$tmpout" "$tmperr"
  if [ -z "$output" ]; then
    printf 'aider-mcp-bridge: no output from %s\n' "$tool_name" >&2
    [ -n "$errors" ] && printf '%s\n' "$errors" >&2
    return 1
  fi
  # Delegate JSON parsing to _bridge-parse.py (lives next to this script).
  local pyparse
  pyparse="$(dirname "$0")/_bridge-parse.py"
  if command -v python3 >/dev/null 2>&1 && [ -f "$pyparse" ]; then
    printf '%s\n' "$output" | python3 "$pyparse" "$tool_name"
  else
    printf '%s\n' "$output" | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"$//' | head -50
  fi
}
COREEOF

  chmod +x "$core"
}

# ─── _bridge_write_wrapper <bin_dir> <tool_name> <server_ts_abs> ─────────────
# Write a thin wrapper script for one tool.
_bridge_write_wrapper() {
  local bin_dir="$1"
  local tool_name="$2"
  local server_ts="$3"
  local wrapper="$bin_dir/$tool_name"

  printf '#!/usr/bin/env bash\n' > "$wrapper"
  printf '# Auto-generated wrapper for %s\n' "$tool_name" >> "$wrapper"
  printf '# Usage inside Aider: /run %s [args]\n' "$tool_name" >> "$wrapper"
  printf '# Examples:\n' >> "$wrapper"
  printf '#   /run %s /path/to/file\n' "$tool_name" >> "$wrapper"
  printf '#   /run %s --key value\n' "$tool_name" >> "$wrapper"
  printf '#   /run %s key=value\n' "$tool_name" >> "$wrapper"
  printf 'set -euo pipefail\n' >> "$wrapper"
  printf 'TOOL_NAME=%s\n' "$tool_name" >> "$wrapper"
  printf "SERVER_TS='%s'\n" "$server_ts" >> "$wrapper"
  printf ': "${AIDER_MCP_BRIDGE_TIMEOUT:=30}"\n' >> "$wrapper"
  printf '\n' >> "$wrapper"
  printf '# Source the shared core helper (lives next to this wrapper).\n' >> "$wrapper"
  printf '_CORE="$(dirname "$0")/_bridge-core.sh"\n' >> "$wrapper"
  printf '[ -f "$_CORE" ] || { printf '"'"'aider-mcp-bridge: _bridge-core.sh missing at %s\n'"'"' "$_CORE" >&2; exit 1; }\n' >> "$wrapper"
  printf '. "$_CORE"\n' >> "$wrapper"
  printf '\n' >> "$wrapper"
  printf '# Build JSON args from positional + flag arguments.\n' >> "$wrapper"
  printf '_escape_json() {\n' >> "$wrapper"
  printf '  if command -v python3 >/dev/null 2>&1; then\n' >> "$wrapper"
  printf '    printf '"'"'%%s'"'"' "$1" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read())[1:-1])"\n' >> "$wrapper"
  printf '  else\n' >> "$wrapper"
  printf '    printf '"'"'%%s'"'"' "$1" | sed '"'"'s/\\\\/\\\\\\\\/g; s/"/\\\\"/g\'"'"'\n' >> "$wrapper"
  printf '  fi\n' >> "$wrapper"
  printf '}\n' >> "$wrapper"
  printf '\n' >> "$wrapper"
  printf '_build_args_json() {\n' >> "$wrapper"
  printf '  local json="{"  first=1  i=0\n' >> "$wrapper"
  printf '  local bare_args=()\n' >> "$wrapper"
  printf '  while [ $i -lt $# ]; do\n' >> "$wrapper"
  printf '    local arg="${@:$((i+1)):1}"\n' >> "$wrapper"
  printf '    case "$arg" in\n' >> "$wrapper"
  printf '      --*)\n' >> "$wrapper"
  printf '        local key="${arg#--}"\n' >> "$wrapper"
  printf '        i=$((i+1))\n' >> "$wrapper"
  printf '        if [ $i -lt $# ]; then\n' >> "$wrapper"
  printf '          local val="${@:$((i+1)):1}"\n' >> "$wrapper"
  printf '          local esc; esc="$(_escape_json "$val")"\n' >> "$wrapper"
  printf '          [ "$first" -eq 0 ] && json="${json},"\n' >> "$wrapper"
  printf '          json="${json}\\"${key}\\":\\"${esc}\\""\n' >> "$wrapper"
  printf '          first=0\n' >> "$wrapper"
  printf '        fi ;;\n' >> "$wrapper"
  printf '      *=*)\n' >> "$wrapper"
  printf '        local key="${arg%%=*}" val="${arg#*=}"\n' >> "$wrapper"
  printf '        local esc; esc="$(_escape_json "$val")"\n' >> "$wrapper"
  printf '        [ "$first" -eq 0 ] && json="${json},"\n' >> "$wrapper"
  printf '        json="${json}\\"${key}\\":\\"${esc}\\""\n' >> "$wrapper"
  printf '        first=0 ;;\n' >> "$wrapper"
  printf '      *) bare_args+=("$arg") ;;\n' >> "$wrapper"
  printf '    esac\n' >> "$wrapper"
  printf '    i=$((i+1))\n' >> "$wrapper"
  printf '  done\n' >> "$wrapper"
  printf '  # Map bare args by tool type\n' >> "$wrapper"
  printf '  if [ ${#bare_args[@]} -gt 0 ]; then\n' >> "$wrapper"
  printf '    case "$TOOL_NAME" in\n' >> "$wrapper"
  printf '      ashlr__bash)\n' >> "$wrapper"
  printf '        local cmd="${bare_args[*]}"; local esc; esc="$(_escape_json "$cmd")"\n' >> "$wrapper"
  printf '        [ "$first" -eq 0 ] && json="${json},"\n' >> "$wrapper"
  printf '        json="${json}\\"command\\":\\"${esc}\\""; first=0 ;;\n' >> "$wrapper"
  printf '      ashlr__http)\n' >> "$wrapper"
  printf '        local esc; esc="$(_escape_json "${bare_args[0]}")"\n' >> "$wrapper"
  printf '        [ "$first" -eq 0 ] && json="${json},"\n' >> "$wrapper"
  printf '        json="${json}\\"url\\":\\"${esc}\\""; first=0 ;;\n' >> "$wrapper"
  printf '      *)\n' >> "$wrapper"
  printf '        local esc; esc="$(_escape_json "${bare_args[0]}")"\n' >> "$wrapper"
  printf '        [ "$first" -eq 0 ] && json="${json},"\n' >> "$wrapper"
  printf '        json="${json}\\"path\\":\\"${esc}\\""; first=0 ;;\n' >> "$wrapper"
  printf '    esac\n' >> "$wrapper"
  printf '  fi\n' >> "$wrapper"
  printf '  printf '"'"'%%s'"'"' "${json}}"\n' >> "$wrapper"
  printf '}\n' >> "$wrapper"
  printf '\n' >> "$wrapper"
  printf 'ARGS_JSON="$(_build_args_json "$@")"\n' >> "$wrapper"
  printf '_bridge_call_tool "$SERVER_TS" "$TOOL_NAME" "$ARGS_JSON"\n' >> "$wrapper"

  chmod +x "$wrapper"
}

# ─── aider_mcp_bridge_init ────────────────────────────────────────────────────
aider_mcp_bridge_init() {
  if [ -z "${AIDER_MCP_BRIDGE_BIN:-}" ]; then
    AIDER_MCP_BRIDGE_BIN="$(mktemp -d /tmp/aider-mcp-bridge-XXXXXX)"
    export AIDER_MCP_BRIDGE_BIN
    _AIDER_MCP_BRIDGE_TMPDIR="$AIDER_MCP_BRIDGE_BIN"
    export _AIDER_MCP_BRIDGE_TMPDIR
  fi

  if [ -n "${AIDER_MCP_BRIDGE_DRY_RUN:-}" ]; then
    printf 'aider-mcp-bridge: DRY RUN — wrappers would go in %s\n' "$AIDER_MCP_BRIDGE_BIN" >&2
    printf 'aider-mcp-bridge: ASHLR_PLUGIN_DIR=%s\n' "$ASHLR_PLUGIN_DIR" >&2
    return 0
  fi

  mkdir -p "$AIDER_MCP_BRIDGE_BIN"
  _bridge_write_core "$AIDER_MCP_BRIDGE_BIN"

  local line tool_name server_rel server_abs count=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    tool_name="${line%%|*}"
    server_rel="${line##*|}"
    server_abs="${ASHLR_PLUGIN_DIR}/${server_rel}"
    _bridge_write_wrapper "$AIDER_MCP_BRIDGE_BIN" "$tool_name" "$server_abs"
    count=$((count + 1))
  done <<EOF
$(printf '%s' "$_BRIDGE_TOOL_SERVER_MAP" | grep -v '^$')
EOF

  export PATH="${AIDER_MCP_BRIDGE_BIN}:${PATH}"

  printf 'aider-mcp-bridge: %d tool wrappers ready in %s\n' "$count" "$AIDER_MCP_BRIDGE_BIN" >&2
  printf 'aider-mcp-bridge: Use /run ashlr__<tool> [args] inside Aider\n' >&2
  printf 'aider-mcp-bridge: Examples:\n' >&2
  printf '  /run ashlr__read /path/to/file\n' >&2
  printf '  /run ashlr__grep --pattern "function" --path .\n' >&2
  printf '  /run ashlr__bash --command "ls -la"\n' >&2
}

# ─── aider_mcp_bridge_cleanup ─────────────────────────────────────────────────
aider_mcp_bridge_cleanup() {
  if [ -n "${_AIDER_MCP_BRIDGE_TMPDIR:-}" ] && [ -d "${_AIDER_MCP_BRIDGE_TMPDIR}" ]; then
    rm -rf "${_AIDER_MCP_BRIDGE_TMPDIR}" 2>/dev/null || true
  fi
}

# ─── Direct invocation — self-test ───────────────────────────────────────────
# BASH_SOURCE is not set when piped to bash; fall back to checking $0.
_BRIDGE_SELF="${BASH_SOURCE[0]:-${0}}"
if [ "$_BRIDGE_SELF" = "${0}" ]; then
  printf 'aider-mcp-bridge: self-test\n'
  printf '  ASHLR_PLUGIN_DIR=%s\n' "$ASHLR_PLUGIN_DIR"
  printf '  AIDER_MCP_BRIDGE_TIMEOUT=%s\n' "$AIDER_MCP_BRIDGE_TIMEOUT"

  _rc=0
  if _rt="$(_bridge_find_runtime 2>/dev/null)"; then
    printf '  runtime: %s (%s)\n' "$_rt" "$(command -v "$_rt" 2>/dev/null || echo 'not found')"
  else
    printf '  runtime: MISSING (install bun: curl -fsSL https://bun.sh/install | bash)\n'
    _rc=1
  fi

  if [ -d "$ASHLR_PLUGIN_DIR" ]; then
    printf '  ashlr-plugin: found at %s\n' "$ASHLR_PLUGIN_DIR"
  else
    printf '  ashlr-plugin: MISSING at %s\n' "$ASHLR_PLUGIN_DIR"
    _rc=1
  fi

  printf '  tools:\n'
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _tname="${_line%%|*}"
    _srel="${_line##*|}"
    _sabs="${ASHLR_PLUGIN_DIR}/${_srel}"
    if [ -f "$_sabs" ]; then
      printf '    %s -> OK\n' "$_tname"
    else
      printf '    %s -> MISSING (%s)\n' "$_tname" "$_sabs"
    fi
  done <<TOOLEOF
$(printf '%s' "$_BRIDGE_TOOL_SERVER_MAP" | grep -v '^$')
TOOLEOF

  if [ -n "${AIDER_MCP_BRIDGE_DRY_RUN:-}" ]; then
    printf 'aider-mcp-bridge: dry-run complete\n'
    exit 0
  fi

  # Full init into a temp dir to verify wrapper generation works
  _test_bin="$(mktemp -d /tmp/aider-mcp-self-test-XXXXXX)"
  AIDER_MCP_BRIDGE_BIN="$_test_bin" aider_mcp_bridge_init 2>/dev/null
  _found=0
  for _t in ashlr__read ashlr__grep ashlr__bash; do
    [ -x "$_test_bin/$_t" ] && _found=$((_found + 1))
  done
  rm -rf "$_test_bin"
  if [ "$_found" -eq 3 ]; then
    printf '  wrapper generation: OK (%d/3 spot-checked)\n' "$_found"
  else
    printf '  wrapper generation: FAIL (only %d/3 wrappers created)\n' "$_found"
    _rc=1
  fi

  printf 'aider-mcp-bridge: self-test done (exit %d)\n' "$_rc"
  exit "$_rc"
fi
