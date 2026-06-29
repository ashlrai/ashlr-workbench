#!/usr/bin/env bash
# gen-tool-matrix.sh — Auto-generate the MCP Capability Matrix + Tool Inventory.
#
# What it does:
#   1. Scans ashlr-plugin servers/ to extract each MCP server's tool list +
#      schemas (uses JSON-RPC tools/list handshake when bun is available, or
#      falls back to static grep-based extraction from the .ts source).
#   2. For each agent, queries its config file to infer which MCPs it loads.
#   3. Generates docs/generated/tool-matrix.html — rows=agents, cols=MCP
#      servers, cells show tools available + latency/status from last probe.
#   4. Generates docs/TOOL-INVENTORY.md — "agent X exposes tools: [list]"
#   5. When called with --health-embed, writes a compact summary to stdout
#      suitable for embedding in `aw health` output (used by healthcheck.sh).
#   6. Detects tool additions/removals vs. the previous matrix and emits a
#      change log to stdout (and appends to docs/generated/tool-matrix.changelog).
#
# Usage:
#   scripts/gen-tool-matrix.sh                # regenerate both HTML + MD
#   scripts/gen-tool-matrix.sh --health-embed  # quick survey, print summary
#   scripts/gen-tool-matrix.sh --diff-only     # print change log, no regen
#   scripts/gen-tool-matrix.sh --help
#
# Environment overrides:
#   ASHLR_PLUGIN_DIR  — path to ashlr-plugin checkout (default: ~/Desktop/ashlr-plugin)
#   MATRIX_CACHE_DIR  — where snapshots/cache are stored (default: ~/.cache/ashlr-workbench/matrix)
#   MATRIX_PROBE_TIMEOUT — seconds per tools/list probe (default: 4)
#   NO_COLOR          — disable ANSI output
#
# Designed for macOS bash 3.2 — no mapfile, no GNU-only flags.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared config (provides ASHLR_PLUGIN_DIR, etc.)
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

# ─── Paths ────────────────────────────────────────────────────────────────────
PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
SERVERS_DIR="$PLUGIN_DIR/servers"
AGENTS_DIR="$WORKBENCH/agents"
DOCS_DIR="$WORKBENCH/docs"
GENERATED_DIR="$DOCS_DIR/generated"
HTML_OUT="$GENERATED_DIR/tool-matrix.html"
MD_OUT="$DOCS_DIR/TOOL-INVENTORY.md"
CHANGELOG="$GENERATED_DIR/tool-matrix.changelog"
CACHE_DIR="${MATRIX_CACHE_DIR:-$HOME/.cache/ashlr-workbench/matrix}"
SNAPSHOT_FILE="$CACHE_DIR/last-snapshot.txt"
PROBE_TIMEOUT="${MATRIX_PROBE_TIMEOUT:-4}"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

have() { command -v "$1" >/dev/null 2>&1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
HEALTH_EMBED=0
DIFF_ONLY=0
for _arg in "$@"; do
  case "$_arg" in
    --health-embed) HEALTH_EMBED=1 ;;
    --diff-only)    DIFF_ONLY=1 ;;
    --help|-h)
      printf "Usage: %s [--health-embed|--diff-only|--help]\n" "$(basename "$0")"
      printf "  (no flags)       Regenerate HTML + Markdown tool matrix\n"
      printf "  --health-embed   Quick probe + print compact summary for healthcheck\n"
      printf "  --diff-only      Print change log vs. previous snapshot, then exit\n"
      exit 0
      ;;
    *) printf "Unknown flag: %s\n" "$_arg" >&2; exit 2 ;;
  esac
done

# ─── Static tool registry ─────────────────────────────────────────────────────
# Canonical tool names per MCP server, used when live probe is unavailable.
# Keys are server short-names (matching <name>-server.ts).
# Values are space-separated tool name lists.
_STATIC_TOOLS_efficiency="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
_STATIC_TOOLS_sql="ashlr__sql"
_STATIC_TOOLS_bash="ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list"
_STATIC_TOOLS_tree="ashlr__tree ashlr__ls"
_STATIC_TOOLS_http="ashlr__http ashlr__webfetch ashlr__websearch"
_STATIC_TOOLS_diff="ashlr__diff ashlr__diff_semantic"
_STATIC_TOOLS_logs="ashlr__logs"
_STATIC_TOOLS_genome="ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status"
_STATIC_TOOLS_orient="ashlr__orient"
_STATIC_TOOLS_github="ashlr__pr ashlr__pr_comment ashlr__pr_approve ashlr__issue ashlr__issue_create ashlr__issue_close"

# Canonical server descriptions (for HTML/MD output)
_DESC_efficiency="Token-efficient Read/Grep/Edit and session savings reporter"
_DESC_sql="Read-only SQL query tool for SQLite/Postgres/MySQL"
_DESC_bash="Sandboxed bash with background-process support"
_DESC_tree="Directory tree listing with smart depth limits"
_DESC_http="HTTP fetch with response summarization"
_DESC_diff="Compact unified diffs between files, commits, or strings"
_DESC_logs="Log tail/grep with intelligent truncation"
_DESC_genome="Genome-RAG codebase index (propose/consolidate/status)"
_DESC_orient="Fast 'what is this repo' orientation summary"
_DESC_github="Compact GitHub PR + issue reader"

# Ordered list of all known ashlr-plugin server short names
ALL_SERVERS="efficiency sql bash tree http diff logs genome orient github"

# All agents
ALL_AGENTS="aider goose ashlrcode openhands"

# ─── Helper: get static tool list for a server ────────────────────────────────
_static_tools_for() {
  local name="$1"
  # Use indirect variable lookup compatible with bash 3.2
  eval "printf '%s' \"\${_STATIC_TOOLS_${name}:-}\""
}

_desc_for() {
  local name="$1"
  eval "printf '%s' \"\${_DESC_${name}:-${name} MCP server}\""
}

# ─── Helper: probe tools/list via JSON-RPC stdio ──────────────────────────────
# Returns newline-separated tool names on stdout; empty if probe fails.
# Sets _PROBE_LATENCY_MS to integer latency.
_PROBE_LATENCY_MS=0
_probe_server_tools() {
  local name="$1"
  local ts_file="$SERVERS_DIR/${name}-server.ts"

  _PROBE_LATENCY_MS=0

  [ -f "$ts_file" ] || return 1
  have bun           || return 1

  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-matrix-out-XXXXXX)" || return 1
  tmperr="$(mktemp /tmp/mcp-matrix-err-XXXXXX)" || { rm -f "$tmpout"; return 1; }

  # Build the JSON-RPC initialize + tools/list sequence.
  # MCP framing: Content-Length header + \r\n\r\n + body.
  local init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"matrix-probe","version":"1.0"}}}'
  local init_len="${#init_body}"
  local list_body='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  local list_len="${#list_body}"

  local payload
  payload="$(printf 'Content-Length: %d\r\n\r\n%s' "$init_len" "$init_body")"
  payload="${payload}$(printf 'Content-Length: %d\r\n\r\n%s' "$list_len" "$list_body")"

  local t0 t1
  t0="$(date +%s)"

  # Launch server, send payload, capture output for up to PROBE_TIMEOUT seconds.
  (
    cd "$PLUGIN_DIR" 2>/dev/null || true
    printf '%s' "$payload" | timeout "$PROBE_TIMEOUT" bun "$ts_file" >"$tmpout" 2>"$tmperr"
  ) 2>/dev/null || true

  t1="$(date +%s)"
  _PROBE_LATENCY_MS=$(( (t1 - t0) * 1000 ))

  # Extract tool names from the tools/list response.
  # The response contains: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"..."},...]}
  # Use python3 if available for robust JSON parsing, else grep.
  local tools_out=""
  if [ -s "$tmpout" ]; then
    if have python3; then
      tools_out="$(python3 - "$tmpout" 2>/dev/null <<'PYEOF'
import json, sys, re
data = open(sys.argv[1]).read()
# Find all JSON objects in the stream (servers write multiple frames)
for chunk in re.split(r'Content-Length:[^\r\n]*\r?\n\r?\n', data):
    chunk = chunk.strip()
    if not chunk:
        continue
    try:
        obj = json.loads(chunk)
        if obj.get('id') == 2 and 'result' in obj:
            tools = obj['result'].get('tools', [])
            for t in tools:
                print(t.get('name', ''))
            sys.exit(0)
    except Exception:
        pass
PYEOF
)"
    else
      # Fallback: grep for "name" fields inside a tools array
      tools_out="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmpout" 2>/dev/null \
                   | sed 's/.*"\([^"]*\)"$/\1/' \
                   | grep -v '^$' || true)"
    fi
  fi

  rm -f "$tmpout" "$tmperr"

  if [ -n "$tools_out" ]; then
    printf '%s\n' "$tools_out"
    return 0
  fi
  return 1
}

# ─── Helper: extract which MCP servers an agent config loads ──────────────────
# Prints space-separated server short-names (e.g. "efficiency sql bash ...")
_agent_mcps() {
  local agent="$1"
  local cfg=""
  case "$agent" in
    ashlrcode)  cfg="$AGENTS_DIR/ashlrcode/settings.json" ;;
    goose)      cfg="$AGENTS_DIR/goose/config.yaml" ;;
    aider)      cfg="$AGENTS_DIR/aider/aider.conf.yml" ;;
    openhands)  cfg="$AGENTS_DIR/openhands/mcp.json" ;;
  esac

  [ -f "$cfg" ] || { printf ''; return; }

  case "$cfg" in
    *.json)
      if have python3; then
        python3 - "$cfg" 2>/dev/null <<'PYEOF'
import json, sys, re
try:
    d = json.load(open(sys.argv[1]))
    servers = []
    # Claude Code / ashlrcode format: mcpServers dict
    for key in d.get('mcpServers', {}).keys():
        m = re.match(r'^ashlr-(.+)$', key)
        if m:
            servers.append(m.group(1))
    # OpenHands format: stdio_servers array
    for s in d.get('stdio_servers', []):
        m = re.match(r'^ashlr-(.+)$', s.get('name', ''))
        if m:
            servers.append(m.group(1))
    print(' '.join(servers))
except Exception:
    pass
PYEOF
      else
        grep -o '"ashlr-[^"]*"' "$cfg" 2>/dev/null \
          | sed 's/"ashlr-\([^"]*\)"/\1/' \
          | tr '\n' ' ' || true
      fi
      ;;
    *.yaml|*.yml)
      # Goose config: extensions with name: ashlr-X
      grep -E '^\s+name:\s+ashlr-' "$cfg" 2>/dev/null \
        | sed 's/.*ashlr-\([^[:space:]]*\).*/\1/' \
        | tr '\n' ' ' || true
      ;;
    *)
      # aider: no native MCP config — aider uses no MCPs in this workbench
      printf ''
      ;;
  esac
}

# ─── Build the data matrix ────────────────────────────────────────────────────
# Populates associative-ish data via flat variables:
#   _CELL_<agent>_<server>  = "pass:<latency>ms" | "static" | "skip" | "fail"
#   _TOOLS_<agent>_<server> = space-separated tool names
#   _AGENT_SERVERS_<agent>  = space-separated server short-names for this agent
#   _SERVER_STATUS_<server> = "live" | "static" | "unavailable"
#   _SERVER_LATENCY_<server> = integer ms (0 if static)

_build_matrix() {
  local _plugin_present=0
  local _runtime_ok=0
  [ -d "$SERVERS_DIR" ] && _plugin_present=1
  have bun && _runtime_ok=1

  # Per-agent: which servers are configured?
  local _agent
  for _agent in $ALL_AGENTS; do
    local _mcps
    _mcps="$(_agent_mcps "$_agent")"
    eval "_AGENT_SERVERS_${_agent}=\"\$_mcps\""
  done

  # Per-server: probe or fall back to static
  local _srv
  for _srv in $ALL_SERVERS; do
    local _status="unavailable"
    local _latency=0
    local _tools=""

    if [ "$_plugin_present" -eq 1 ] && [ "$_runtime_ok" -eq 1 ]; then
      local _probe_out
      _probe_out="$(_probe_server_tools "$_srv" 2>/dev/null || true)"
      _latency="$_PROBE_LATENCY_MS"
      if [ -n "$_probe_out" ]; then
        _status="live"
        _tools="$(printf '%s' "$_probe_out" | tr '\n' ' ' | sed 's/ $//')"
      else
        # Probe failed — use static registry + mark as static
        _status="static"
        _tools="$(_static_tools_for "$_srv")"
      fi
    elif [ "$_plugin_present" -eq 1 ]; then
      _status="static"
      _tools="$(_static_tools_for "$_srv")"
    else
      _status="unavailable"
      _tools="$(_static_tools_for "$_srv")"
    fi

    eval "_SERVER_STATUS_${_srv}=\"\$_status\""
    eval "_SERVER_LATENCY_${_srv}=\"\$_latency\""
    eval "_SERVER_TOOLS_${_srv}=\"\$_tools\""
  done

  # Per cell: does agent load this server + which tools?
  for _agent in $ALL_AGENTS; do
    local _agent_mcps_var
    eval "_agent_mcps_var=\"\${_AGENT_SERVERS_${_agent}:-}\""
    for _srv in $ALL_SERVERS; do
      local _has=0
      # Check if this server appears in agent's MCP list
      local _srv_in_list
      for _srv_in_list in $_agent_mcps_var; do
        if [ "$_srv_in_list" = "$_srv" ]; then
          _has=1
          break
        fi
      done

      local _cell_status="skip"
      local _cell_tools=""
      if [ "$_has" -eq 1 ]; then
        eval "_cell_status=\"\${_SERVER_STATUS_${_srv}}\""
        eval "_cell_tools=\"\${_SERVER_TOOLS_${_srv}:-}\""
      fi
      eval "_CELL_${_agent}_${_srv}=\"\$_cell_status\""
      eval "_TOOLS_${_agent}_${_srv}=\"\$_cell_tools\""
    done
  done
}

# ─── Snapshot helpers (for diff/change detection) ─────────────────────────────
_snapshot_key() {
  local srv="$1"
  eval "printf '%s' \"\${_SERVER_TOOLS_${srv}:-}\""
}

_write_snapshot() {
  mkdir -p "$CACHE_DIR"
  local _ts
  _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  {
    printf '# ashlr-workbench tool-matrix snapshot — %s\n' "$_ts"
    local _srv
    for _srv in $ALL_SERVERS; do
      eval "printf '%s=%s\n' \"$_srv\" \"\${_SERVER_TOOLS_${_srv}:-}\""
    done
  } > "$SNAPSHOT_FILE"
}

_diff_vs_snapshot() {
  [ -f "$SNAPSHOT_FILE" ] || { printf '(no previous snapshot — first run)\n'; return; }

  local _any_change=0
  local _srv
  for _srv in $ALL_SERVERS; do
    local _prev=""
    _prev="$(grep "^${_srv}=" "$SNAPSHOT_FILE" 2>/dev/null | cut -d= -f2- || true)"
    local _curr
    eval "_curr=\"\${_SERVER_TOOLS_${_srv}:-}\""

    if [ "$_prev" = "$_curr" ]; then
      continue
    fi
    _any_change=1
    printf 'CHANGED: ashlr-%s\n' "$_srv"

    # Find added tools
    local _t
    for _t in $_curr; do
      if ! printf '%s' " $_prev " | grep -q " ${_t} "; then
        printf '  + %s  (added)\n' "$_t"
      fi
    done
    # Find removed tools
    for _t in $_prev; do
      if ! printf '%s' " $_curr " | grep -q " ${_t} "; then
        printf '  - %s  (removed)\n' "$_t"
      fi
    done
  done

  if [ "$_any_change" -eq 0 ]; then
    printf '(no tool changes detected)\n'
  fi
}

_append_changelog() {
  local _diff_text="$1"
  if printf '%s' "$_diff_text" | grep -q '^CHANGED:'; then
    mkdir -p "$GENERATED_DIR"
    local _ts
    _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    {
      printf '\n## %s\n' "$_ts"
      printf '%s\n' "$_diff_text"
    } >> "$CHANGELOG"
  fi
}

# ─── Generate Markdown tool inventory ─────────────────────────────────────────
_gen_markdown() {
  local _ts
  _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  {
    printf '# Tool Inventory\n\n'
    printf '> Auto-generated by `scripts/gen-tool-matrix.sh` on %s.  \n' "$_ts"
    printf '> Do not edit by hand — regenerate with `aw health` or `scripts/gen-tool-matrix.sh`.\n\n'
    printf '## MCP Servers\n\n'
    printf 'The ashlr-plugin ships %s MCP servers. Each server exposes a focused tool surface.\n\n' "$(printf '%s\n' $ALL_SERVERS | wc -l | tr -d ' ')"

    local _srv
    for _srv in $ALL_SERVERS; do
      local _desc _tools _status _latency
      _desc="$(_desc_for "$_srv")"
      eval "_tools=\"\${_SERVER_TOOLS_${_srv}:-}\""
      eval "_status=\"\${_SERVER_STATUS_${_srv}:-unavailable}\""
      eval "_latency=\"\${_SERVER_LATENCY_${_srv}:-0}\""

      local _status_badge="[unavailable]"
      case "$_status" in
        live)   _status_badge="[live, ${_latency}ms]" ;;
        static) _status_badge="[static — plugin not probed]" ;;
      esac

      printf '### `ashlr-%s`\n\n' "$_srv"
      printf '**Description:** %s  \n' "$_desc"
      printf '**Status:** %s\n\n' "$_status_badge"
      printf '**Tools:**\n\n'

      if [ -n "$_tools" ]; then
        for _tool in $_tools; do
          printf -- '- `%s`\n' "$_tool"
        done
      else
        printf -- '- *(no tools detected)*\n'
      fi
      printf '\n'

      printf '**Loaded by agents:**\n\n'
      local _any_agent=0
      local _agent
      for _agent in $ALL_AGENTS; do
        eval "_cell_s=\"\${_CELL_${_agent}_${_srv}:-skip}\""
        if [ "$_cell_s" != "skip" ]; then
          printf -- '- %s\n' "$_agent"
          _any_agent=1
        fi
      done
      [ "$_any_agent" -eq 0 ] && printf -- '- *(none)*\n'
      printf '\n---\n\n'
    done

    printf '## Agent Tool Surface\n\n'
    printf 'For each agent, the tools available via its loaded MCP servers:\n\n'

    local _agent
    for _agent in $ALL_AGENTS; do
      printf '### %s\n\n' "$_agent"
      local _any_tool=0
      local _srv
      for _srv in $ALL_SERVERS; do
        eval "_cell_s=\"\${_CELL_${_agent}_${_srv}:-skip}\""
        if [ "$_cell_s" != "skip" ]; then
          eval "_cell_tools=\"\${_TOOLS_${_agent}_${_srv}:-}\""
          if [ -n "$_cell_tools" ]; then
            printf '**`ashlr-%s`:** ' "$_srv"
            # print comma-separated
            local _first=1
            for _t in $_cell_tools; do
              if [ "$_first" -eq 1 ]; then
                printf '`%s`' "$_t"
                _first=0
              else
                printf ', `%s`' "$_t"
              fi
            done
            printf '\n\n'
            _any_tool=1
          fi
        fi
      done
      [ "$_any_tool" -eq 0 ] && printf '*(no MCP tools configured — uses native agent tools only)*\n\n'
    done

    printf '## Cross-Reference Matrix\n\n'
    printf '| MCP Server | %s |\n' "$(printf '%s | ' $ALL_AGENTS | sed 's/ | $//')"
    printf '|---|%s|\n' "$(printf '---|' $ALL_AGENTS)"
    for _srv in $ALL_SERVERS; do
      local _row
      _row="| \`ashlr-${_srv}\`"
      for _agent in $ALL_AGENTS; do
        eval "_cell_s=\"\${_CELL_${_agent}_${_srv}:-skip}\""
        case "$_cell_s" in
          live)        _row="${_row} | ✓ live" ;;
          static)      _row="${_row} | ✓ (static)" ;;
          unavailable) _row="${_row} | ✓ (unavail)" ;;
          skip)        _row="${_row} | —" ;;
          *)           _row="${_row} | ?" ;;
        esac
      done
      printf '%s |\n' "$_row"
    done
    printf '\n'

    printf '_Legend: ✓ live = probed OK; ✓ (static) = plugin present, probe skipped; ✓ (unavail) = plugin missing; — = agent does not load this server_\n'

  } > "$MD_OUT"
}

# ─── Generate HTML matrix ─────────────────────────────────────────────────────
_gen_html() {
  local _ts
  _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "$GENERATED_DIR"

  # Collect all tools for the global list
  local _all_tools=""
  local _srv
  for _srv in $ALL_SERVERS; do
    eval "_t=\"\${_SERVER_TOOLS_${_srv}:-}\""
    _all_tools="${_all_tools} ${_t}"
  done
  local _tool_count
  _tool_count="$(printf '%s\n' $_all_tools | grep -c '[^[:space:]]' || echo 0)"

  {
    cat <<HTML_HEADER
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ashlr-workbench MCP Capability Matrix</title>
  <style>
    :root {
      --bg: #1e1e1e; --surface: #252526; --border: #3c3c3c;
      --text: #d4d4d4; --dim: #858585; --green: #4ec9b0;
      --yellow: #dcdcaa; --red: #f48771; --blue: #9cdcfe;
      --live: #4ec9b0; --static: #dcdcaa; --skip: #3c3c3c; --fail: #f48771;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: var(--bg); color: var(--text); font-family: 'Cascadia Code', 'Fira Code', monospace; font-size: 13px; padding: 24px; }
    h1 { color: var(--blue); font-size: 18px; margin-bottom: 4px; }
    .meta { color: var(--dim); font-size: 11px; margin-bottom: 24px; }
    .stats { display: flex; gap: 24px; margin-bottom: 24px; flex-wrap: wrap; }
    .stat { background: var(--surface); border: 1px solid var(--border); border-radius: 4px; padding: 10px 16px; }
    .stat-val { font-size: 24px; font-weight: bold; color: var(--green); }
    .stat-lbl { color: var(--dim); font-size: 11px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 32px; }
    th { background: var(--surface); color: var(--blue); padding: 8px 12px; text-align: left; border: 1px solid var(--border); font-size: 11px; letter-spacing: 0.05em; text-transform: uppercase; }
    td { padding: 6px 12px; border: 1px solid var(--border); vertical-align: top; font-size: 12px; }
    tr:hover td { background: rgba(255,255,255,0.03); }
    .srv-cell { color: var(--yellow); font-weight: bold; white-space: nowrap; }
    .agent-hdr { color: var(--green); }
    .cell-live    { background: rgba(78,201,176,0.12); }
    .cell-static  { background: rgba(220,220,170,0.10); }
    .cell-skip    { color: var(--dim); background: var(--skip); text-align: center; }
    .cell-unavail { color: var(--dim); background: rgba(244,135,113,0.08); }
    .badge { display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 10px; margin-right: 4px; }
    .badge-live   { background: rgba(78,201,176,0.25); color: var(--live); }
    .badge-static { background: rgba(220,220,170,0.2); color: var(--yellow); }
    .badge-unavail{ background: rgba(244,135,113,0.2); color: var(--red); }
    .tool-list { margin-top: 4px; }
    .tool { display: inline-block; background: rgba(150,150,200,0.15); border-radius: 2px; padding: 0 4px; margin: 1px 2px 1px 0; font-size: 10px; color: var(--text); }
    .latency { color: var(--dim); font-size: 10px; }
    .section-hdr { color: var(--blue); font-size: 15px; margin: 24px 0 12px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
    .desc { color: var(--dim); font-size: 11px; margin-top: 2px; }
    .srv-name { color: var(--yellow); }
    code { font-family: inherit; }
    .legend { font-size: 11px; color: var(--dim); margin-bottom: 16px; }
    .legend span { display: inline-block; margin-right: 16px; }
    .dot-live   { color: var(--live);   }
    .dot-static { color: var(--yellow); }
    .dot-skip   { color: var(--dim);    }
  </style>
</head>
<body>
  <h1>ashlr-workbench MCP Capability Matrix</h1>
  <div class="meta">Generated: ${_ts} &nbsp;·&nbsp; Source: <code>scripts/gen-tool-matrix.sh</code></div>
HTML_HEADER

    # Stats row
    local _live_count=0
    for _srv in $ALL_SERVERS; do
      eval "_s=\"\${_SERVER_STATUS_${_srv}:-unavailable}\""
      [ "$_s" = "live" ] && _live_count=$((_live_count+1))
    done
    local _srv_count
    _srv_count="$(printf '%s\n' $ALL_SERVERS | wc -l | tr -d ' ')"
    local _agent_count
    _agent_count="$(printf '%s\n' $ALL_AGENTS | wc -l | tr -d ' ')"

    cat <<HTML_STATS
  <div class="stats">
    <div class="stat"><div class="stat-val">${_agent_count}</div><div class="stat-lbl">Agents</div></div>
    <div class="stat"><div class="stat-val">${_srv_count}</div><div class="stat-lbl">MCP Servers</div></div>
    <div class="stat"><div class="stat-val">${_tool_count}</div><div class="stat-lbl">Total Tools</div></div>
    <div class="stat"><div class="stat-val">${_live_count}/${_srv_count}</div><div class="stat-lbl">Live Probed</div></div>
  </div>
HTML_STATS

    # Legend
    cat <<'HTML_LEGEND'
  <div class="legend">
    <span><span class="dot-live">✓</span> live — probed via JSON-RPC tools/list</span>
    <span><span class="dot-static">◌</span> static — from registry (plugin not probed)</span>
    <span><span class="dot-skip">—</span> not loaded by this agent</span>
  </div>
HTML_LEGEND

    # Matrix table: rows=servers, cols=agents
    printf '  <h2 class="section-hdr">Agent × MCP Server Matrix</h2>\n'
    printf '  <table>\n'
    printf '    <thead><tr>\n'
    printf '      <th>MCP Server</th>\n'
    for _agent in $ALL_AGENTS; do
      printf '      <th class="agent-hdr">%s</th>\n' "$_agent"
    done
    printf '    </tr></thead>\n'
    printf '    <tbody>\n'

    for _srv in $ALL_SERVERS; do
      eval "_srv_status=\"\${_SERVER_STATUS_${_srv}:-unavailable}\""
      eval "_srv_latency=\"\${_SERVER_LATENCY_${_srv}:-0}\""
      _srv_desc="$(_desc_for "$_srv")"

      printf '    <tr>\n'
      # Server name + status badge
      local _badge_class _badge_label
      case "$_srv_status" in
        live)        _badge_class="badge-live";   _badge_label="live" ;;
        static)      _badge_class="badge-static"; _badge_label="static" ;;
        unavailable) _badge_class="badge-unavail";_badge_label="unavail" ;;
        *)           _badge_class="badge-static"; _badge_label="?" ;;
      esac
      printf '      <td class="srv-cell"><code>ashlr-%s</code><span class="badge %s">%s</span>' \
        "$_srv" "$_badge_class" "$_badge_label"
      if [ "$_srv_status" = "live" ] && [ "$_srv_latency" -gt 0 ]; then
        printf '<span class="latency">%dms</span>' "$_srv_latency"
      fi
      printf '<div class="desc">%s</div></td>\n' "$_srv_desc"

      for _agent in $ALL_AGENTS; do
        eval "_cell_s=\"\${_CELL_${_agent}_${_srv}:-skip}\""
        eval "_cell_tools=\"\${_TOOLS_${_agent}_${_srv}:-}\""
        case "$_cell_s" in
          live|static|unavailable)
            local _td_class
            case "$_cell_s" in
              live)        _td_class="cell-live" ;;
              static)      _td_class="cell-static" ;;
              unavailable) _td_class="cell-unavail" ;;
              *)           _td_class="" ;;
            esac
            printf '      <td class="%s">' "$_td_class"
            if [ -n "$_cell_tools" ]; then
              printf '<div class="tool-list">'
              for _t in $_cell_tools; do
                printf '<span class="tool">%s</span>' "$_t"
              done
              printf '</div>'
            else
              printf '✓'
            fi
            printf '</td>\n'
            ;;
          skip|*)
            printf '      <td class="cell-skip">—</td>\n'
            ;;
        esac
      done
      printf '    </tr>\n'
    done

    printf '    </tbody>\n'
    printf '  </table>\n'

    # Per-server detail section
    printf '  <h2 class="section-hdr">MCP Server Details</h2>\n'
    for _srv in $ALL_SERVERS; do
      eval "_srv_tools=\"\${_SERVER_TOOLS_${_srv}:-}\""
      eval "_srv_status=\"\${_SERVER_STATUS_${_srv}:-unavailable}\""
      eval "_srv_latency=\"\${_SERVER_LATENCY_${_srv}:-0}\""
      _srv_desc="$(_desc_for "$_srv")"

      printf '  <div style="margin-bottom:16px;padding:12px;background:var(--surface);border:1px solid var(--border);border-radius:4px;">\n'
      printf '    <div class="srv-name"><code>ashlr-%s</code></div>\n' "$_srv"
      printf '    <div class="desc">%s</div>\n' "$_srv_desc"
      if [ "$_srv_status" = "live" ]; then
        printf '    <div class="latency" style="margin-top:4px;">Probe latency: %dms</div>\n' "$_srv_latency"
      fi
      printf '    <div class="tool-list" style="margin-top:8px;">'
      if [ -n "$_srv_tools" ]; then
        for _t in $_srv_tools; do
          printf '<span class="tool">%s</span>' "$_t"
        done
      else
        printf '<span style="color:var(--dim)">no tools detected</span>'
      fi
      printf '</div>\n'
      printf '  </div>\n'
    done

    cat <<'HTML_FOOTER'
</body>
</html>
HTML_FOOTER
  } > "$HTML_OUT"
}

# ─── Health embed output ───────────────────────────────────────────────────────
_health_embed_output() {
  local _live_count=0
  local _static_count=0
  local _unavail_count=0
  local _total_tools=0

  local _srv
  for _srv in $ALL_SERVERS; do
    eval "_s=\"\${_SERVER_STATUS_${_srv}:-unavailable}\""
    eval "_t=\"\${_SERVER_TOOLS_${_srv}:-}\""
    local _tc=0
    for _ in $_t; do _tc=$((_tc+1)); done
    _total_tools=$((_total_tools+_tc))
    case "$_s" in
      live)        _live_count=$((_live_count+1)) ;;
      static)      _static_count=$((_static_count+1)) ;;
      unavailable) _unavail_count=$((_unavail_count+1)) ;;
    esac
  done

  local _srv_count
  _srv_count="$(printf '%s\n' $ALL_SERVERS | wc -l | tr -d ' ')"

  printf '%s Tool Matrix:%s %d servers, %d tools total ' \
    "$C_BOLD" "$C_RESET" "$_srv_count" "$_total_tools"

  if [ "$_live_count" -gt 0 ]; then
    printf '(%s%d live%s' "$C_GREEN" "$_live_count" "$C_RESET"
    [ "$_static_count" -gt 0 ] && printf ', %s%d static%s' "$C_YELLOW" "$_static_count" "$C_RESET"
    [ "$_unavail_count" -gt 0 ] && printf ', %s%d unavail%s' "$C_DIM" "$_unavail_count" "$C_RESET"
    printf ')'
  elif [ "$_static_count" -gt 0 ]; then
    printf '(%s%d static%s' "$C_YELLOW" "$_static_count" "$C_RESET"
    [ "$_unavail_count" -gt 0 ] && printf ', %s%d unavail%s' "$C_DIM" "$_unavail_count" "$C_RESET"
    printf ')'
  else
    printf '(%sunavailable%s)' "$C_RED" "$C_RESET"
  fi
  printf '\n'
  printf '  Matrix: %s\n' "$HTML_OUT"
  printf '  Inventory: %s\n' "$MD_OUT"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Build the data matrix (probing or static)
  _build_matrix

  if [ "$DIFF_ONLY" -eq 1 ]; then
    _diff_vs_snapshot
    exit 0
  fi

  # Compute diff before writing new snapshot
  local _diff_out
  _diff_out="$(_diff_vs_snapshot)"

  # Write new snapshot
  _write_snapshot

  # Append changelog entry if anything changed
  _append_changelog "$_diff_out"

  if [ "$HEALTH_EMBED" -eq 1 ]; then
    _health_embed_output
    # Also print diff if non-trivial
    if printf '%s' "$_diff_out" | grep -q '^CHANGED:'; then
      printf '%s  Tool changes detected:%s\n' "$C_YELLOW" "$C_RESET"
      printf '%s\n' "$_diff_out" | while IFS= read -r _line; do
        printf '    %s\n' "$_line"
      done
    fi
    return 0
  fi

  # Full generation mode
  printf '%sGenerating tool matrix...%s\n' "$C_BOLD" "$C_RESET"

  # Generate outputs
  mkdir -p "$GENERATED_DIR"
  _gen_markdown
  _gen_html

  # Print diff if non-trivial
  if printf '%s' "$_diff_out" | grep -q '^CHANGED:'; then
    printf '\n%sTool changes vs. previous snapshot:%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s\n' "$_diff_out"
    printf '\n(Change log appended to %s)\n' "$CHANGELOG"
  else
    printf '  %s\n' "$_diff_out"
  fi

  printf '\n%sDone.%s\n' "$C_GREEN" "$C_RESET"
  printf '  HTML  : %s\n' "$HTML_OUT"
  printf '  MD    : %s\n' "$MD_OUT"
  printf '  Cache : %s\n' "$SNAPSHOT_FILE"
}

main
