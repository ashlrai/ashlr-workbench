#!/usr/bin/env bash
# mcp-tool-inspector.sh — Dynamic MCP Capability Matrix + Per-Agent Tool Suggestions.
#
# Probes all 10 ashlr-plugin MCP servers to extract actual tool signatures,
# permissions, and latencies.  Generates per-agent tool-suggestion prompts
# suitable for injection into session startup.  Detects tool breakage early
# and surfaces fallback suggestions.
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no mapfile, etc.
#
# Public API:
#   mcp_inspector_build_matrix
#       Probe (or fall back to static) all 10 servers.  Populates flat-variable
#       state that the rest of the API reads.  Must be called before any other
#       function.
#
#   mcp_inspector_tool_list [agent]
#       Print newline-separated list of all tools available to <agent>.
#       If agent is omitted, prints all known tools across all servers.
#
#   mcp_inspector_suggest_prompt <agent> [task_hint]
#       Generate a tool-suggestion prompt string for <agent>.  If task_hint is
#       provided the prompt is narrowed to tools relevant to that task keyword.
#
#   mcp_inspector_detect_breakage
#       Return 0 if all configured servers are healthy; 1 if any broken.
#       Prints one line per broken server with a fallback suggestion.
#
#   mcp_inspector_show [agent]
#       Human-readable live tool inventory table with cost/latency footnotes.
#       If agent is provided, show only tools for that agent.
#
#   mcp_inspector_inject_goose_session_hint [agent]
#       Emit GOOSE_SYSTEM_HINT content to stdout (caller exports the env var).
#
#   mcp_inspector_inject_aider_session_hint [agent]
#       Emit aider --system-prompt content to stdout.
#
#   mcp_inspector_inject_ashlrcode_session_hint [agent]
#       Emit text suitable for Claude Code's --system-prompt / CLAUDE.md injection.
#
# Environment variables:
#   ASHLR_PLUGIN_DIR          path to ashlr-plugin checkout (default: ~/Desktop/ashlr-plugin)
#   MCP_INSP_PROBE_TIMEOUT    seconds per tools/list probe     (default: 4)
#   MCP_INSP_CACHE_DIR        directory for result cache        (default: ~/.cache/ashlr-workbench/inspector)
#   MCP_INSP_CACHE_TTL        seconds before cache expires      (default: 300)
#   MCP_INSP_VERBOSE          non-empty → verbose probe output
#   NO_COLOR                  disable ANSI output

# Guard against double-sourcing.
if [ -n "${_ASHLR_MCP_INSPECTOR_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_MCP_INSPECTOR_SOURCED=1

# ─── Defaults ─────────────────────────────────────────────────────────────────
: "${ASHLR_PLUGIN_DIR:=$HOME/Desktop/ashlr-plugin}"
: "${MCP_INSP_PROBE_TIMEOUT:=4}"
: "${MCP_INSP_CACHE_DIR:=$HOME/.cache/ashlr-workbench/inspector}"
: "${MCP_INSP_CACHE_TTL:=300}"

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  _IC_RESET=""; _IC_BOLD=""; _IC_DIM=""
  _IC_RED=""; _IC_GREEN=""; _IC_YELLOW=""; _IC_CYAN=""; _IC_MAGENTA=""
else
  _IC_RESET=$'\033[0m'; _IC_BOLD=$'\033[1m'; _IC_DIM=$'\033[2m'
  _IC_RED=$'\033[31m'; _IC_GREEN=$'\033[32m'; _IC_YELLOW=$'\033[33m'
  _IC_CYAN=$'\033[36m'; _IC_MAGENTA=$'\033[35m'
fi

# ─── Output helpers (fallbacks if not already defined) ────────────────────────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
  info() { printf "  \033[36m•\033[0m %s\n" "$*"; }
fi

# ─── Static tool registry ────────────────────────────────────────────────────
# Canonical tool names per MCP server, used when live probe unavailable.
_INSP_STATIC_efficiency="ashlr__read ashlr__grep ashlr__glob ashlr__savings ashlr__flush"
_INSP_STATIC_sql="ashlr__sql"
_INSP_STATIC_bash="ashlr__bash ashlr__bash_start ashlr__bash_tail ashlr__bash_stop ashlr__bash_list"
_INSP_STATIC_tree="ashlr__tree ashlr__ls"
_INSP_STATIC_http="ashlr__http ashlr__webfetch ashlr__websearch"
_INSP_STATIC_diff="ashlr__diff ashlr__diff_semantic"
_INSP_STATIC_logs="ashlr__logs"
_INSP_STATIC_genome="ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status"
_INSP_STATIC_orient="ashlr__orient"
_INSP_STATIC_github="ashlr__pr ashlr__pr_comment ashlr__pr_approve ashlr__issue ashlr__issue_create ashlr__issue_close"

# Tool descriptions (one-liner each — shown in suggestion prompts)
_INSP_DESC_ashlr__read="Token-efficient file reader (80% cost savings vs native)"
_INSP_DESC_ashlr__grep="Pattern search across codebase with structured output"
_INSP_DESC_ashlr__glob="File glob with smart filtering"
_INSP_DESC_ashlr__savings="Token savings report for the current session"
_INSP_DESC_ashlr__flush="Flush session genome / memory cache"
_INSP_DESC_ashlr__sql="Read-only SQL query (SQLite/Postgres/MySQL)"
_INSP_DESC_ashlr__bash="Sandboxed bash execution with compressed stdout"
_INSP_DESC_ashlr__bash_start="Start a persistent background bash session"
_INSP_DESC_ashlr__bash_tail="Tail output of a background bash session"
_INSP_DESC_ashlr__bash_stop="Stop a background bash session"
_INSP_DESC_ashlr__bash_list="List running background bash sessions"
_INSP_DESC_ashlr__tree="Directory tree listing with depth limits"
_INSP_DESC_ashlr__ls="List directory contents"
_INSP_DESC_ashlr__http="HTTP fetch with response summarization"
_INSP_DESC_ashlr__webfetch="Fetch + summarize a web page"
_INSP_DESC_ashlr__websearch="Web search with ranked snippet output"
_INSP_DESC_ashlr__diff="Compact unified diff between files or commits"
_INSP_DESC_ashlr__diff_semantic="Semantic diff highlighting logical changes"
_INSP_DESC_ashlr__logs="Log tail/grep with intelligent truncation"
_INSP_DESC_ashlr__genome_propose="Propose a genome codebase-summary entry"
_INSP_DESC_ashlr__genome_consolidate="Consolidate genome entries"
_INSP_DESC_ashlr__genome_status="Show genome index status"
_INSP_DESC_ashlr__orient="Fast repo orientation summary"
_INSP_DESC_ashlr__pr="Read GitHub pull request details"
_INSP_DESC_ashlr__pr_comment="Post a comment on a GitHub PR"
_INSP_DESC_ashlr__pr_approve="Approve a GitHub PR"
_INSP_DESC_ashlr__issue="Read a GitHub issue"
_INSP_DESC_ashlr__issue_create="Create a GitHub issue"
_INSP_DESC_ashlr__issue_close="Close a GitHub issue"

# Task-keyword → relevant tool hint (used by suggest_prompt)
# Format: keyword=tool1 tool2 ...
_INSP_TASK_HINTS="
search=ashlr__grep ashlr__glob
read=ashlr__read ashlr__grep
edit=ashlr__read ashlr__grep ashlr__bash
test=ashlr__bash ashlr__logs
debug=ashlr__bash ashlr__logs ashlr__grep
sql=ashlr__sql
database=ashlr__sql
web=ashlr__http ashlr__webfetch ashlr__websearch
fetch=ashlr__http ashlr__webfetch
git=ashlr__diff ashlr__bash ashlr__pr
diff=ashlr__diff ashlr__diff_semantic
pr=ashlr__pr ashlr__pr_comment ashlr__pr_approve
issue=ashlr__issue ashlr__issue_create ashlr__issue_close
github=ashlr__pr ashlr__issue ashlr__pr_comment
log=ashlr__logs ashlr__bash_tail
dir=ashlr__tree ashlr__ls
tree=ashlr__tree ashlr__ls
orient=ashlr__orient ashlr__read
genome=ashlr__genome_propose ashlr__genome_consolidate ashlr__genome_status
"

# Fallback tool mapping: primary_tool → fallback_tool suggestion
_INSP_FALLBACK_ashlr__read="cat / native Read"
_INSP_FALLBACK_ashlr__grep="grep (native)"
_INSP_FALLBACK_ashlr__glob="find (native)"
_INSP_FALLBACK_ashlr__bash="Bash (native)"
_INSP_FALLBACK_ashlr__sql="(no fallback — install ashlr-plugin)"
_INSP_FALLBACK_ashlr__http="curl (native)"
_INSP_FALLBACK_ashlr__webfetch="curl (native)"
_INSP_FALLBACK_ashlr__websearch="(no web search without ashlr-plugin)"
_INSP_FALLBACK_ashlr__diff="git diff (native)"
_INSP_FALLBACK_ashlr__diff_semantic="git diff (native)"
_INSP_FALLBACK_ashlr__logs="tail / grep (native)"
_INSP_FALLBACK_ashlr__orient="cat README (manual)"
_INSP_FALLBACK_ashlr__tree="find (native)"
_INSP_FALLBACK_ashlr__ls="ls (native)"
_INSP_FALLBACK_ashlr__pr="gh pr view (gh CLI)"
_INSP_FALLBACK_ashlr__issue="gh issue view (gh CLI)"
_INSP_FALLBACK_ashlr__genome_propose="(no fallback — genome needs ashlr-plugin)"
_INSP_FALLBACK_ashlr__genome_consolidate="(no fallback — genome needs ashlr-plugin)"
_INSP_FALLBACK_ashlr__genome_status="(no fallback — genome needs ashlr-plugin)"

# All server short-names
_INSP_ALL_SERVERS="efficiency sql bash tree http diff logs genome orient github"
# All agents
_INSP_ALL_AGENTS="aider goose ashlrcode openhands"

# ─── Internal helpers ────────────────────────────────────────────────────────

_insp_have() { command -v "$1" >/dev/null 2>&1; }

_insp_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'; }
_insp_epoch() { date +%s 2>/dev/null || echo 0; }

_insp_static_tools_for() {
  local name="$1"
  eval "printf '%s' \"\${_INSP_STATIC_${name}:-}\""
}

# ─── Cache helpers ────────────────────────────────────────────────────────────

_insp_cache_file() {
  local srv="$1"
  printf '%s/tools-%s.txt' "$MCP_INSP_CACHE_DIR" "$srv"
}

_insp_cache_valid() {
  local srv="$1"
  local cf
  cf="$(_insp_cache_file "$srv")"
  [ -f "$cf" ] || return 1
  local file_epoch now_epoch age
  file_epoch="$(stat -f '%m' "$cf" 2>/dev/null || stat -c '%Y' "$cf" 2>/dev/null || echo 0)"
  now_epoch="$(_insp_epoch)"
  age=$(( now_epoch - file_epoch ))
  [ "$age" -lt "${MCP_INSP_CACHE_TTL:-300}" ]
}

_insp_cache_read() {
  local srv="$1"
  local cf
  cf="$(_insp_cache_file "$srv")"
  [ -f "$cf" ] && cat "$cf"
}

_insp_cache_write() {
  local srv="$1"
  local content="$2"
  mkdir -p "$MCP_INSP_CACHE_DIR" 2>/dev/null || true
  printf '%s\n' "$content" > "$(_insp_cache_file "$srv")" 2>/dev/null || true
}

# ─── Live probe ───────────────────────────────────────────────────────────────
# Probe one server via JSON-RPC tools/list.
# Outputs tool names (one per line) on stdout; returns 0 on success, 1 on fail.
# Sets _INSP_PROBE_LATENCY_MS and _INSP_PROBE_TOOL_COUNT.
_INSP_PROBE_LATENCY_MS=0
_INSP_PROBE_TOOL_COUNT=0

_insp_probe_server() {
  local name="$1"
  local ts_file="${ASHLR_PLUGIN_DIR}/servers/${name}-server.ts"

  _INSP_PROBE_LATENCY_MS=0
  _INSP_PROBE_TOOL_COUNT=0

  [ -f "$ts_file" ] || return 1
  _insp_have bun    || return 1

  local tmpout tmperr
  tmpout="$(mktemp /tmp/mcp-insp-out-XXXXXX)" || return 1
  tmperr="$(mktemp /tmp/mcp-insp-err-XXXXXX)" || { rm -f "$tmpout"; return 1; }

  # Build JSON-RPC initialize + tools/list payload (MCP stdio framing)
  local init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"inspector","version":"1.0"}}}'
  local list_body='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  local init_len="${#init_body}"
  local list_len="${#list_body}"

  local t0 t1
  t0="$(_insp_epoch)"

  (
    cd "$ASHLR_PLUGIN_DIR" 2>/dev/null || true
    printf 'Content-Length: %d\r\n\r\n%sContent-Length: %d\r\n\r\n%s' \
      "$init_len" "$init_body" "$list_len" "$list_body" \
      | timeout "$MCP_INSP_PROBE_TIMEOUT" bun "$ts_file" >"$tmpout" 2>"$tmperr"
  ) 2>/dev/null || true

  t1="$(_insp_epoch)"
  _INSP_PROBE_LATENCY_MS=$(( (t1 - t0) * 1000 ))

  local tools_out=""
  if [ -s "$tmpout" ]; then
    if _insp_have python3; then
      tools_out="$(python3 - "$tmpout" 2>/dev/null <<'PYEOF'
import json, sys, re
data = open(sys.argv[1]).read()
for chunk in re.split(r'Content-Length:[^\r\n]*\r?\n\r?\n', data):
    chunk = chunk.strip()
    if not chunk:
        continue
    try:
        obj = json.loads(chunk)
        if obj.get('id') == 2 and 'result' in obj:
            for t in obj['result'].get('tools', []):
                name = t.get('name', '')
                if name:
                    print(name)
            sys.exit(0)
    except Exception:
        pass
PYEOF
)"
    else
      # grep fallback: pull "name": "..." from the tools/list response frame
      tools_out="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmpout" 2>/dev/null \
                   | sed 's/.*"\([^"]*\)"$/\1/' \
                   | grep -v '^$' || true)"
    fi
  fi

  rm -f "$tmpout" "$tmperr"

  if [ -n "$tools_out" ]; then
    _INSP_PROBE_TOOL_COUNT="$(printf '%s\n' "$tools_out" | grep -c '[^[:space:]]' || echo 0)"
    printf '%s\n' "$tools_out"
    return 0
  fi

  return 1
}

# ─── Matrix build ────────────────────────────────────────────────────────────
# Flat variables set by _build_matrix / mcp_inspector_build_matrix:
#
#   _INSP_SRV_STATUS_<srv>   = live | static | unavailable
#   _INSP_SRV_LATENCY_<srv>  = integer ms
#   _INSP_SRV_TOOLS_<srv>    = space-separated tool names
#   _INSP_SRV_HEALTHY_<srv>  = 1 | 0
#   _INSP_MATRIX_BUILT       = 1 once populated

_INSP_MATRIX_BUILT=0

mcp_inspector_build_matrix() {
  local force="${1:-}"   # pass "force" to skip cache

  local plugin_present=0 runtime_ok=0
  [ -d "${ASHLR_PLUGIN_DIR}/servers" ] && plugin_present=1
  _insp_have bun                        && runtime_ok=1

  local srv
  for srv in $_INSP_ALL_SERVERS; do
    local status="unavailable"
    local latency=0
    local tools=""
    local healthy=0

    if [ "$plugin_present" -eq 1 ] && [ "$runtime_ok" -eq 1 ]; then
      # Try cache first (unless forced)
      local cached_tools=""
      if [ "${force:-}" != "force" ] && _insp_cache_valid "$srv"; then
        cached_tools="$(_insp_cache_read "$srv")"
      fi

      if [ -n "$cached_tools" ]; then
        status="live"
        tools="$(printf '%s' "$cached_tools" | tr '\n' ' ' | sed 's/ $//')"
        healthy=1
        # latency from cache file age is not tracked; use 0
      else
        local probe_out
        probe_out="$(_insp_probe_server "$srv" 2>/dev/null || true)"
        latency="$_INSP_PROBE_LATENCY_MS"
        if [ -n "$probe_out" ]; then
          status="live"
          tools="$(printf '%s\n' "$probe_out" | tr '\n' ' ' | sed 's/ $//')"
          healthy=1
          _insp_cache_write "$srv" "$probe_out"
        else
          status="static"
          tools="$(_insp_static_tools_for "$srv")"
          healthy=0
        fi
      fi
    elif [ "$plugin_present" -eq 1 ]; then
      status="static"
      tools="$(_insp_static_tools_for "$srv")"
      healthy=0
    else
      status="unavailable"
      tools="$(_insp_static_tools_for "$srv")"
      healthy=0
    fi

    eval "_INSP_SRV_STATUS_${srv}=\"\$status\""
    eval "_INSP_SRV_LATENCY_${srv}=\"\$latency\""
    eval "_INSP_SRV_TOOLS_${srv}=\"\$tools\""
    eval "_INSP_SRV_HEALTHY_${srv}=\"\$healthy\""
  done

  _INSP_MATRIX_BUILT=1
}

# ─── Agent config reader ─────────────────────────────────────────────────────
# Returns space-separated server short-names configured for an agent.
# Reads the agent's config file from the workbench agents/ directory.
_insp_agent_servers() {
  local agent="$1"
  local workbench_dir
  workbench_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd 2>/dev/null)" || \
    workbench_dir="$HOME/Desktop/ashlr-workbench"

  local agents_dir="${workbench_dir}/agents"
  local cfg=""
  case "$agent" in
    ashlrcode)  cfg="${agents_dir}/ashlrcode/settings.json" ;;
    goose)      cfg="${agents_dir}/goose/config.yaml" ;;
    aider)      cfg="${agents_dir}/aider/aider.conf.yml" ;;
    openhands)  cfg="${agents_dir}/openhands/mcp.json" ;;
    *)
      # Unknown agent — return all servers
      printf '%s' "$_INSP_ALL_SERVERS"
      return
      ;;
  esac

  [ -f "$cfg" ] || { printf '%s' "$_INSP_ALL_SERVERS"; return; }

  case "$cfg" in
    *.json)
      if _insp_have python3; then
        python3 - "$cfg" 2>/dev/null <<'PYEOF' || printf '%s' "$_INSP_ALL_SERVERS"
import json, sys, re
try:
    d = json.load(open(sys.argv[1]))
    servers = []
    for key in d.get('mcpServers', {}).keys():
        m = re.match(r'^ashlr-(.+)$', key)
        if m:
            servers.append(m.group(1))
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
          | tr '\n' ' ' || printf '%s' "$_INSP_ALL_SERVERS"
      fi
      ;;
    *.yaml|*.yml)
      local result
      result="$(grep -E '^\s+name:\s+ashlr-' "$cfg" 2>/dev/null \
        | sed 's/.*ashlr-\([^[:space:]]*\).*/\1/' \
        | tr '\n' ' ' || true)"
      if [ -z "$result" ]; then
        printf '%s' "$_INSP_ALL_SERVERS"
      else
        printf '%s' "$result"
      fi
      ;;
    *)
      printf '%s' "$_INSP_ALL_SERVERS"
      ;;
  esac
}

# ─── Public: mcp_inspector_tool_list ─────────────────────────────────────────
# Print newline-separated tool names available to [agent], or all tools if no
# agent given.
mcp_inspector_tool_list() {
  local agent="${1:-}"

  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  local seen=""
  local srv

  if [ -n "$agent" ]; then
    local agent_servers
    agent_servers="$(_insp_agent_servers "$agent")"
    for srv in $agent_servers; do
      local tools
      eval "tools=\"\${_INSP_SRV_TOOLS_${srv}:-}\""
      for t in $tools; do
        case " $seen " in
          *" $t "*) : ;;
          *) printf '%s\n' "$t"; seen="$seen $t" ;;
        esac
      done
    done
  else
    for srv in $_INSP_ALL_SERVERS; do
      local tools
      eval "tools=\"\${_INSP_SRV_TOOLS_${srv}:-}\""
      for t in $tools; do
        case " $seen " in
          *" $t "*) : ;;
          *) printf '%s\n' "$t"; seen="$seen $t" ;;
        esac
      done
    done
  fi
}

# ─── Public: mcp_inspector_suggest_prompt ───────────────────────────────────
# Generate a tool-suggestion prompt for an agent.  Optional task_hint narrows
# the suggestion.
# Output goes to stdout (caller captures or prints as needed).
mcp_inspector_suggest_prompt() {
  local agent="${1:-}"
  local task_hint="${2:-}"

  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  # Collect tools available to this agent
  local agent_tools=""
  if [ -n "$agent" ]; then
    agent_tools="$(mcp_inspector_tool_list "$agent" | tr '\n' ' ' | sed 's/ $//')"
  else
    agent_tools="$(mcp_inspector_tool_list | tr '\n' ' ' | sed 's/ $//')"
  fi

  # If task_hint given, filter to relevant tools only
  local relevant_tools=""
  if [ -n "$task_hint" ]; then
    local hint_lower
    hint_lower="$(printf '%s' "$task_hint" | tr '[:upper:]' '[:lower:]')"
    # Walk task hint registry
    local hint_line
    while IFS= read -r hint_line; do
      [ -z "$hint_line" ] && continue
      local kw="${hint_line%%=*}"
      local kw_tools="${hint_line#*=}"
      case "$hint_lower" in
        *"$kw"*)
          for t in $kw_tools; do
            case " $agent_tools " in
              *" $t "*)
                case " $relevant_tools " in
                  *" $t "*) : ;;
                  *) relevant_tools="${relevant_tools} ${t}" ;;
                esac
                ;;
            esac
          done
          ;;
      esac
    done <<EOF
$(printf '%s' "$_INSP_TASK_HINTS" | grep -v '^[[:space:]]*$')
EOF
    # Trim leading space
    relevant_tools="${relevant_tools# }"
  fi

  # Choose what to display
  local display_tools
  if [ -n "$relevant_tools" ]; then
    display_tools="$relevant_tools"
  else
    display_tools="$agent_tools"
  fi

  # Build the prompt string
  local agent_label="${agent:-any agent}"
  if [ -n "$task_hint" ]; then
    printf 'For task "%s", %s has these ashlr tools available: %s\n' \
      "$task_hint" "$agent_label" "$display_tools"
  else
    printf '%s has these ashlr MCP tools available: %s\n' \
      "$agent_label" "$display_tools"
  fi

  # Append tool descriptions for relevant tools (if narrowed)
  if [ -n "$relevant_tools" ]; then
    printf 'Tool details:\n'
    for t in $relevant_tools; do
      local desc
      eval "desc=\"\${_INSP_DESC_${t}:-${t} (no description)}\""
      printf '  %s — %s\n' "$t" "$desc"
    done
  fi
}

# ─── Public: mcp_inspector_detect_breakage ──────────────────────────────────
# Print one line per broken server with fallback suggestion.
# Returns 0 if all healthy, 1 if any broken.
mcp_inspector_detect_breakage() {
  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  local any_broken=0
  local srv

  for srv in $_INSP_ALL_SERVERS; do
    local status healthy
    eval "status=\"\${_INSP_SRV_STATUS_${srv}:-unavailable}\""
    eval "healthy=\"\${_INSP_SRV_HEALTHY_${srv}:-0}\""

    if [ "$healthy" -eq 0 ]; then
      any_broken=1
      local tools
      eval "tools=\"\${_INSP_SRV_TOOLS_${srv}:-}\""

      case "$status" in
        static)
          warn "ashlr-${srv}: probe failed — using static tool list (bun not available or server not responding)"
          ;;
        unavailable)
          bad "ashlr-${srv}: plugin not found — tools unavailable"
          ;;
        *)
          bad "ashlr-${srv}: unknown status (${status})"
          ;;
      esac

      # Suggest fallbacks for each tool in this server
      for t in $tools; do
        local fallback
        eval "fallback=\"\${_INSP_FALLBACK_${t}:-use native equivalent}\""
        info "  fallback for ${t}: ${fallback}"
      done
    fi
  done

  return "$any_broken"
}

# ─── Public: mcp_inspector_show ─────────────────────────────────────────────
# Human-readable live tool inventory with cost/latency footnotes.
mcp_inspector_show() {
  local filter_agent="${1:-}"

  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  local ts
  ts="$(_insp_ts)"

  printf '\n%s%s%s\n' "$_IC_BOLD" "ashlr MCP Tool Inventory" "$_IC_RESET"
  printf '%s%s%s\n' "$_IC_DIM" "Generated: ${ts}" "$_IC_RESET"
  if [ -n "$filter_agent" ]; then
    printf 'Showing tools for agent: %s%s%s\n' "$_IC_CYAN" "$filter_agent" "$_IC_RESET"
  fi
  printf '\n'

  # Column header
  printf '%s%-22s %-12s %-10s %-8s %s%s\n' \
    "$_IC_BOLD" "TOOL" "SERVER" "STATUS" "LATENCY" "DESCRIPTION" "$_IC_RESET"
  printf '%s\n' "──────────────────────────────────────────────────────────────────────────────────────"

  local srv
  for srv in $_INSP_ALL_SERVERS; do
    # If filtering by agent, skip servers not in that agent's config
    if [ -n "$filter_agent" ]; then
      local agent_servers
      agent_servers="$(_insp_agent_servers "$filter_agent")"
      local found_srv=0
      for as in $agent_servers; do
        [ "$as" = "$srv" ] && found_srv=1 && break
      done
      [ "$found_srv" -eq 0 ] && continue
    fi

    local status latency tools healthy
    eval "status=\"\${_INSP_SRV_STATUS_${srv}:-unavailable}\""
    eval "latency=\"\${_INSP_SRV_LATENCY_${srv}:-0}\""
    eval "tools=\"\${_INSP_SRV_TOOLS_${srv}:-}\""
    eval "healthy=\"\${_INSP_SRV_HEALTHY_${srv}:-0}\""

    local status_color latency_str
    case "$status" in
      live)        status_color="${_IC_GREEN}" ;;
      static)      status_color="${_IC_YELLOW}" ;;
      unavailable) status_color="${_IC_RED}" ;;
      *)           status_color="${_IC_DIM}" ;;
    esac

    if [ "$latency" -gt 0 ]; then
      latency_str="${latency}ms"
    else
      latency_str="—"
    fi

    for t in $tools; do
      local desc
      eval "desc=\"\${_INSP_DESC_${t}:-}\""
      # Truncate description at 45 chars for display
      if [ "${#desc}" -gt 45 ]; then
        desc="${desc:0:42}..."
      fi

      local fallback_note=""
      if [ "$healthy" -eq 0 ]; then
        eval "fallback_note=\"\${_INSP_FALLBACK_${t}:-native}\""
        fallback_note=" [fallback: ${fallback_note}]"
      fi

      printf '%-22s %s%-12s%s %s%-10s%s %-8s %s%s%s\n' \
        "$t" \
        "$_IC_DIM" "ashlr-${srv}" "$_IC_RESET" \
        "$status_color" "$status" "$_IC_RESET" \
        "$latency_str" \
        "$_IC_DIM" "${desc}${fallback_note}" "$_IC_RESET"
    done
  done

  # Summary footnotes
  printf '\n'
  local live_count=0 static_count=0 unavail_count=0 total_tools=0
  for srv in $_INSP_ALL_SERVERS; do
    local s h tools_var
    eval "s=\"\${_INSP_SRV_STATUS_${srv}:-unavailable}\""
    eval "h=\"\${_INSP_SRV_HEALTHY_${srv}:-0}\""
    eval "tools_var=\"\${_INSP_SRV_TOOLS_${srv}:-}\""
    case "$s" in
      live)        live_count=$((live_count+1)) ;;
      static)      static_count=$((static_count+1)) ;;
      unavailable) unavail_count=$((unavail_count+1)) ;;
    esac
    for _ in $tools_var; do total_tools=$((total_tools+1)); done
  done

  printf '%sFootnotes:%s\n' "$_IC_BOLD" "$_IC_RESET"
  printf '  %slive%s     = probed via JSON-RPC tools/list  (most accurate)\n' "$_IC_GREEN" "$_IC_RESET"
  printf '  %sstatic%s   = static registry  (bun/plugin not probed — may drift)\n' "$_IC_YELLOW" "$_IC_RESET"
  printf '  %sunavail%s  = ashlr-plugin not installed at %s\n' "$_IC_RED" "$_IC_RESET" "$ASHLR_PLUGIN_DIR"
  printf '\n'
  printf '  Servers: %d  |  Tools: %d  |  Live: %d  |  Static: %d  |  Unavailable: %d\n' \
    "$(printf '%s\n' $_INSP_ALL_SERVERS | wc -l | tr -d ' ')" \
    "$total_tools" "$live_count" "$static_count" "$unavail_count"
  printf '  Cache: %s  (TTL: %ss)\n' "$MCP_INSP_CACHE_DIR" "${MCP_INSP_CACHE_TTL}"
  printf '  Refresh: aw tools --refresh\n'
  printf '\n'
}

# ─── Session hint injectors ──────────────────────────────────────────────────

# Emit a Goose-compatible session hint to stdout.
# Caller: export GOOSE_SYSTEM_HINT="$(mcp_inspector_inject_goose_session_hint goose)"
mcp_inspector_inject_goose_session_hint() {
  local agent="${1:-goose}"
  local task_hint="${2:-}"

  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  local tools
  tools="$(mcp_inspector_tool_list "$agent" | tr '\n' ' ' | sed 's/ $//')"

  printf 'You have these ashlr MCP tools available for this session: %s\n' "$tools"
  printf 'Prefer ashlr__ prefixed tools over native equivalents for token efficiency.\n'
  printf 'Use ashlr__bash for shell commands, ashlr__grep/ashlr__glob for search, '
  printf 'ashlr__read for file reads.\n'

  if [ -n "$task_hint" ]; then
    printf '\n'
    mcp_inspector_suggest_prompt "$agent" "$task_hint"
  fi
}

# Emit an Aider --system-prompt compatible hint to stdout.
# Caller: aider --system-prompt "$(mcp_inspector_inject_aider_session_hint aider)" ...
mcp_inspector_inject_aider_session_hint() {
  local agent="${1:-aider}"
  local task_hint="${2:-}"

  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  local tools
  tools="$(mcp_inspector_tool_list "$agent" | tr '\n' ' ' | sed 's/ $//')"

  if [ -z "$tools" ]; then
    printf 'No ashlr MCP tools detected for aider — using native git/shell tools.\n'
    return
  fi

  printf 'Available ashlr MCP tools: %s. ' "$tools"
  printf 'Use these for file operations, search, and shell commands to reduce token usage.\n'

  if [ -n "$task_hint" ]; then
    printf '\n'
    mcp_inspector_suggest_prompt "$agent" "$task_hint"
  fi
}

# Emit a Claude Code / ashlrcode session hint to stdout.
# Caller: ashlrcode --system-prompt "$(mcp_inspector_inject_ashlrcode_session_hint ashlrcode)"
mcp_inspector_inject_ashlrcode_session_hint() {
  local agent="${1:-ashlrcode}"
  local task_hint="${2:-}"

  if [ "$_INSP_MATRIX_BUILT" -eq 0 ]; then
    mcp_inspector_build_matrix
  fi

  local tools
  tools="$(mcp_inspector_tool_list "$agent" | tr '\n' ' ' | sed 's/ $//')"

  if [ -z "$tools" ]; then
    printf 'ashlr-plugin not detected — using native tools only.\n'
    return
  fi

  printf '# ashlr MCP Tool Hints\n'
  printf 'The following ashlr__ prefixed MCP tools are available and PREFERRED over native equivalents:\n'
  printf '%s\n\n' "$tools"
  printf 'Key rules:\n'
  printf '- Use ashlr__read instead of cat/head/tail (80%% token savings)\n'
  printf '- Use ashlr__grep instead of native grep (structured output)\n'
  printf '- Use ashlr__bash instead of Bash for shell commands (compressed stdout)\n'
  printf '- Use ashlr__orient to understand a new repo before reading files\n'
  printf '- Use ashlr__genome_* to read/update the codebase knowledge graph\n'

  if [ -n "$task_hint" ]; then
    printf '\n'
    mcp_inspector_suggest_prompt "$agent" "$task_hint"
  fi
}
