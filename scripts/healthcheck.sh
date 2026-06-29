#!/usr/bin/env bash
# healthcheck.sh — verify the ashlr-workbench is functional end-to-end.
#
# Runs ~13+ checks across:
#   - Docker daemon
#   - LM Studio + loaded model
#   - Ollama (optional)
#   - OpenHands container
#   - ashlr-plugin install + 10 MCP servers (smoke-startable)
#   - Free disk + RAM
#   - Each agent CLI on PATH
#   - Workbench git branch + cleanliness
#   - Each agent's config file is valid JSON / YAML / TOML
#
# Exit code:
#   0 if all checks pass or only produced warnings
#   1 if any FAIL (✗) condition is hit
#
# Designed for macOS bash 3.2 — no GNU-specific flags, no `mapfile`, etc.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="$(cd "$SCRIPT_DIR/.." && pwd)"
ASHLR_PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
LM_STUDIO_URL="${LM_STUDIO_URL:-http://localhost:1234/v1}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
OPENHANDS_CONTAINER="ashlr-openhands"

# Source the MCP probe library (provides validate_mcp_servers).
# shellcheck source=scripts/lib/mcp-probe.sh
. "$SCRIPT_DIR/lib/mcp-probe.sh"

# Source the config validation library (provides validate_all_agent_configs).
# shellcheck source=scripts/lib/config-validate.sh
. "$SCRIPT_DIR/lib/config-validate.sh"

# Source the MCP connection library (provides run_mcp_handshake_checks).
# shellcheck source=scripts/lib/mcp-connection.sh
. "$SCRIPT_DIR/lib/mcp-connection.sh"

# Source the config schema registry (provides config_registry_check_all).
# shellcheck source=scripts/lib/config-schema-registry.sh
. "$SCRIPT_DIR/lib/config-schema-registry.sh"

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
fi

PASS=0; WARN=0; FAIL=0

ok()    { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; PASS=$((PASS+1)); }
warn()  { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; WARN=$((WARN+1)); }
bad()   { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; FAIL=$((FAIL+1)); }
section() { printf "\n%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ─── 1. Docker ────────────────────────────────────────────────────────────────
section "Docker"
if ! have docker; then
  bad "docker CLI not installed"
elif docker info >/dev/null 2>&1; then
  ok "docker daemon running"
else
  bad "docker daemon not running (start Docker Desktop)"
fi

# ─── 1b. MCP server liveliness ────────────────────────────────────────────────
section "MCP Server Liveliness"
validate_mcp_servers

# ─── 2. LM Studio ─────────────────────────────────────────────────────────────
section "LM Studio ($LM_STUDIO_URL)"
if curl -fsS --max-time 3 "$LM_STUDIO_URL/models" >/dev/null 2>&1; then
  ok "endpoint reachable"
  # Match both compact ({"id":"…"}) and pretty-printed ({"id": "…"}) shapes.
  MODEL_LINE="$(curl -s --max-time 3 "$LM_STUDIO_URL/models" \
                | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
                | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  if [ -n "$MODEL_LINE" ]; then
    ok "model loaded: $MODEL_LINE"
  else
    warn "no model loaded — load qwen/qwen3-coder-30b"
  fi
else
  bad "endpoint not responding (start LM Studio + Start Server)"
fi

# ─── 3. Ollama (optional) ─────────────────────────────────────────────────────
section "Ollama ($OLLAMA_URL)"
if curl -fsS --max-time 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  ok "endpoint reachable"
else
  warn "not running (optional fallback — \`ollama serve\`)"
fi

# ─── 3b. LLM Backend Auto-Discovery ──────────────────────────────────────────
section "LLM Backend Auto-Discovery"

# Source the router library to get access to probing + policy functions.
_HC_ROUTER_SH="$SCRIPT_DIR/lib/llm-router.sh"
if [ ! -f "$_HC_ROUTER_SH" ]; then
  warn "llm-router.sh not found at $_HC_ROUTER_SH — skipping backend discovery"
else
  # shellcheck source=scripts/lib/llm-router.sh
  . "$_HC_ROUTER_SH"
  # Probe all endpoints with a short timeout so healthcheck stays fast.
  ASHLR_LLM_PROBE_TIMEOUT="${ASHLR_LLM_PROBE_TIMEOUT:-3}" \
  ASHLR_LLM_ROUTER_EVENTS=0 \
  llm_router_init

  # Report each core backend.
  _hc_lr_avail() { eval "printf '%s' \"\${_LLM_RT_${1}_avail:-0}\""; }
  _hc_lr_ms()    { eval "printf '%s' \"\${_LLM_RT_${1}_ms:-99999}\""; }
  _hc_lr_model() { eval "printf '%s' \"\${_LLM_RT_${1}_model:-}\""; }

  for _backend in lmstudio ollama xai anthropic; do
    _av="$(_hc_lr_avail "$_backend")"
    _ms="$(_hc_lr_ms   "$_backend")"
    _mo="$(_hc_lr_model "$_backend")"
    if [ "$_av" = "1" ]; then
      if [ -n "$_mo" ]; then
        ok "${_backend}: up (${_ms}ms, model: ${_mo})"
      else
        ok "${_backend}: up (${_ms}ms)"
      fi
    else
      case "$_backend" in
        lmstudio) bad  "${_backend}: not responding (start LM Studio + Start Server)" ;;
        ollama)   warn "${_backend}: not running (optional — \`ollama serve\`)" ;;
        xai)
          if [ -z "${XAI_API_KEY:-}" ]; then
            warn "${_backend}: no XAI_API_KEY set (optional cloud backend)"
          else
            bad "${_backend}: unreachable (key set but endpoint failed)"
          fi
          ;;
        anthropic)
          if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
            warn "${_backend}: no ANTHROPIC_API_KEY set (optional cloud backend)"
          else
            bad "${_backend}: unreachable (key set but endpoint failed)"
          fi
          ;;
      esac
    fi
  done

  # Report auto-discovered Ollama models.
  if command -v ollama >/dev/null 2>&1; then
    _ollama_models="$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"
    if [ -n "$_ollama_models" ]; then
      _model_count="$(printf '%s' "$_ollama_models" | wc -w | tr -d ' ')"
      ok "ollama: ${_model_count} model(s) discovered (${_ollama_models})"
    else
      warn "ollama: running but no models installed (\`ollama pull <model>\`)"
    fi
  else
    warn "ollama CLI not on PATH — cannot auto-discover models"
  fi

  # Report routing policy status.
  _policy_path="${ASHLR_LLM_ROUTING_POLICY:-${HOME}/.ashlr-workbench/llm-routing-policy.json}"
  if [ -f "$_policy_path" ]; then
    _agent_count="$(python3 -c "import json; d=json.load(open('$_policy_path')); print(len(d))" 2>/dev/null || echo 0)"
    ok "routing policy: ${_agent_count} agent(s) configured (${_policy_path})"
  else
    warn "routing policy: no policy file yet (${_policy_path}) — run agents to populate"
  fi

  # Report active primary/fallback.
  if [ -n "${LLM_PRIMARY_BACKEND:-}" ] && [ "${LLM_PRIMARY_BACKEND}" != "none" ]; then
    ok "active primary: ${LLM_PRIMARY} (${LLM_PRIMARY_MS}ms)"
  else
    warn "active primary: none available"
  fi
  if [ -n "${LLM_FALLBACK_BACKEND:-}" ] && [ "${LLM_FALLBACK_BACKEND}" != "none" ]; then
    ok "active fallback: ${LLM_FALLBACK} (${LLM_FALLBACK_MS}ms)"
  else
    warn "active fallback: none (single-backend mode)"
  fi
fi

# ─── 4. OpenHands container ───────────────────────────────────────────────────
section "OpenHands"
if have docker && docker inspect "$OPENHANDS_CONTAINER" >/dev/null 2>&1; then
  STATE="$(docker inspect -f '{{.State.Status}}' "$OPENHANDS_CONTAINER" 2>/dev/null || echo unknown)"
  case "$STATE" in
    running)
      ok "container $OPENHANDS_CONTAINER running"
      if curl -fsS --max-time 3 http://localhost:3000 >/dev/null 2>&1; then
        ok "GUI responding on http://localhost:3000"
      else
        warn "container running but GUI not responding yet"
      fi
      ;;
    *)
      warn "container exists but status=$STATE (\`aw start openhands\`)"
      ;;
  esac
else
  warn "container not present (\`aw start openhands\` to launch)"
fi

# ─── 5. ashlr-plugin install ──────────────────────────────────────────────────
section "ashlr-plugin"
if [ -d "$ASHLR_PLUGIN_DIR" ]; then
  ok "directory present at $ASHLR_PLUGIN_DIR"
  if [ -f "$ASHLR_PLUGIN_DIR/.claude-plugin/plugin.json" ]; then
    PLUGIN_VER="$(grep '"version"' "$ASHLR_PLUGIN_DIR/.claude-plugin/plugin.json" \
                  | head -1 | cut -d'"' -f4 || echo unknown)"
    ok "plugin.json valid (v$PLUGIN_VER)"
  else
    bad "plugin.json missing"
  fi
  if [ -d "$ASHLR_PLUGIN_DIR/node_modules/@modelcontextprotocol/sdk" ]; then
    ok "MCP SDK installed (node_modules present)"
  else
    warn "MCP SDK missing — run: cd $ASHLR_PLUGIN_DIR && bun install"
  fi
  if [ -d "$ASHLR_PLUGIN_DIR/.ashlrcode/genome" ]; then
    GENOME_COUNT="$(find "$ASHLR_PLUGIN_DIR/.ashlrcode/genome" -type f 2>/dev/null | wc -l | tr -d ' ')"
    ok "genome initialized ($GENOME_COUNT entries)"
  else
    warn "genome not initialized (run \`/ashlr-genome-init\`)"
  fi
else
  bad "ashlr-plugin not found at $ASHLR_PLUGIN_DIR"
fi

# ─── 6. MCP servers — each must be parseable by bun ───────────────────────────
section "MCP servers (smoke-startable)"
MCP_SERVERS="efficiency sql bash tree http diff logs genome orient github"
if [ -d "$ASHLR_PLUGIN_DIR/servers" ] && have bun; then
  for s in $MCP_SERVERS; do
    server_file="$ASHLR_PLUGIN_DIR/servers/${s}-server.ts"
    if [ ! -f "$server_file" ]; then
      bad "ashlr-${s}: missing $server_file"
      continue
    fi
    # `bun build --no-bundle --target=node` parses the file without executing
    # it. Output is discarded; we only care about the exit code. This catches
    # syntax errors / broken imports without spawning the full MCP loop.
    if ( cd "$ASHLR_PLUGIN_DIR" && bun build --no-bundle --target=node \
          "servers/${s}-server.ts" >/dev/null 2>&1 ); then
      ok "ashlr-${s} parses cleanly"
    else
      warn "ashlr-${s} parse failed (deps may be missing)"
    fi
  done
else
  if [ ! -d "$ASHLR_PLUGIN_DIR/servers" ]; then
    bad "$ASHLR_PLUGIN_DIR/servers missing — cannot validate MCP servers"
  fi
  if ! have bun; then
    warn "bun not on PATH — skipping MCP parse checks"
  fi
fi
# External (non-plugin) MCPs configured for ashlrcode
if have npx; then ok "supabase MCP launchable via npx"; else warn "npx missing — supabase MCP unavailable"; fi
if [ -x "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP" ]; then
  ok "roblox-studio MCP binary present"
else
  warn "roblox-studio MCP not installed (optional)"
fi

# ─── 7. Disk + RAM ────────────────────────────────────────────────────────────
section "Resources"
FREE_KB="$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$FREE_KB" ]; then
  FREE_GB=$(( FREE_KB / 1024 / 1024 ))
  if [ "$FREE_GB" -ge 20 ]; then
    ok "free disk: ${FREE_GB} GB"
  else
    warn "free disk: ${FREE_GB} GB (< 20 GB recommended)"
  fi
fi
if [ "$(uname -s)" = "Darwin" ] && have vm_stat; then
  PG_FREE=$(vm_stat | awk '/Pages free/ {gsub("\\.",""); print $3}')
  PG_INACT=$(vm_stat | awk '/Pages inactive/ {gsub("\\.",""); print $3}')
  PG_SIZE=$(vm_stat | awk '/page size of/ {print $8}')
  if [ -n "$PG_FREE" ] && [ -n "$PG_SIZE" ]; then
    RAM_GB=$(( (PG_FREE + PG_INACT) * PG_SIZE / 1024 / 1024 / 1024 ))
    if [ "$RAM_GB" -ge 8 ]; then
      ok "free RAM: ${RAM_GB} GB"
    else
      warn "free RAM: ${RAM_GB} GB (< 8 GB recommended for 30B models)"
    fi
  fi
fi

# ─── 8. Agent CLIs on PATH ────────────────────────────────────────────────────
section "Agent CLIs"
for tool in goose aider ashlrcode bun; do
  if have "$tool"; then ok "$tool ($(command -v "$tool"))"; else bad "$tool not on PATH"; fi
done

# ─── 9. Workbench git ─────────────────────────────────────────────────────────
section "Workbench git"
if have git && [ -d "$WORKBENCH/.git" ]; then
  BRANCH="$(cd "$WORKBENCH" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  DIRTY="$(cd "$WORKBENCH" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  ok "branch: $BRANCH"
  if [ "$DIRTY" = "0" ]; then
    ok "tree clean"
  else
    warn "$DIRTY uncommitted change(s)"
  fi
else
  warn "workbench is not a git repo"
fi

# ─── 10. Agent configs valid (schema-aware) ───────────────────────────────────
# config-validate.sh provides typed assertion functions and validate_all_agent_configs.
# It checks that every required section/key is present in each agent config and
# compares against the schema baselines in agents/*/schema.json.  When an agent
# is upgraded and renames a key, this catches it immediately with a precise error:
#   'config.toml: missing [sandbox].runtime_container_image — expected from OpenHands 1.6+ schema'
section "Agent configs (schema validation)"
validate_all_agent_configs

# ─── 10b. Config Schema Registry — migration staleness check ─────────────────
# config-schema-registry.sh checks that every agent config is at the canonical
# schema version and has no unapplied migration rules.  A warning here means a
# config key has been renamed upstream but the local file hasn't been updated.
# Run: bash scripts/lib/config-schema-registry.sh --migrate-all v1.0
section "Config Schema Registry (migration staleness)"
config_registry_check_all

# ─── 11. Agent-MCP Handshakes ─────────────────────────────────────────────────
# Runs tests/mcp-integration.sh in a subprocess and folds its pass/fail/skip
# counts into the healthcheck totals.  The integration test performs a real
# JSON-RPC stdio handshake with each ashlr-plugin MCP server for each agent,
# catching config schema drift, missing entrypoints, and socket lifecycle issues.
section "Agent-MCP Handshakes"

_MCP_INT_SCRIPT="$WORKBENCH/tests/mcp-integration.sh"
if [ ! -f "$_MCP_INT_SCRIPT" ]; then
  bad "mcp-integration.sh not found at $_MCP_INT_SCRIPT"
elif [ ! -x "$_MCP_INT_SCRIPT" ]; then
  bad "mcp-integration.sh is not executable — run: chmod +x $_MCP_INT_SCRIPT"
else
  # Run the integration suite; capture combined output so we can parse counts.
  # We pass NO_COLOR=1 so the output is parseable regardless of terminal state.
  _MCP_INT_JSONL="$(mktemp /tmp/mcp-int-hc-XXXXXX.jsonl)"
  _MCP_INT_OUTPUT="$(
    NO_COLOR=1 \
    MCP_CONN_TIMEOUT="${MCP_CONN_TIMEOUT:-5}" \
    MCP_INTEGRATION_JSONL="$_MCP_INT_JSONL" \
    bash "$_MCP_INT_SCRIPT" 2>&1
  )" || true
  rm -f "$_MCP_INT_JSONL"

  # Extract the summary line: "X passed, Y failed, Z skipped"
  _MCP_INT_SUMMARY="$(printf '%s' "$_MCP_INT_OUTPUT" | grep 'Result:' | tail -1 || true)"
  _MCP_INT_PASS="$(printf '%s' "$_MCP_INT_SUMMARY" | grep -oE '[0-9]+ passed'  | grep -oE '[0-9]+'  || echo 0)"
  _MCP_INT_FAIL="$(printf '%s' "$_MCP_INT_SUMMARY" | grep -oE '[0-9]+ failed'  | grep -oE '[0-9]+'  || echo 0)"
  _MCP_INT_SKIP="$(printf '%s' "$_MCP_INT_SUMMARY" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+'  || echo 0)"

  if [ "${_MCP_INT_FAIL:-0}" -gt 0 ]; then
    bad "Agent-MCP handshakes: ${_MCP_INT_PASS} passed, ${_MCP_INT_FAIL} failed, ${_MCP_INT_SKIP} skipped"
    # Print the first few failure lines for quick diagnosis.
    printf '%s' "$_MCP_INT_OUTPUT" | grep -i 'FAIL' | head -10 | while IFS= read -r _line; do
      printf "    %s\n" "$_line"
    done
  elif [ -n "$_MCP_INT_SUMMARY" ]; then
    if [ "${_MCP_INT_SKIP:-0}" -gt 0 ] && [ "${_MCP_INT_PASS:-0}" -eq 0 ]; then
      warn "Agent-MCP handshakes: all probes skipped (plugin/runtime unavailable) — ${_MCP_INT_SKIP} skipped"
    else
      ok "Agent-MCP handshakes: ${_MCP_INT_PASS} passed, ${_MCP_INT_SKIP} skipped"
    fi
  else
    warn "Agent-MCP handshakes: integration test produced no summary — run manually: bash $_MCP_INT_SCRIPT"
  fi
fi

# ─── 12. Tool Matrix (cached, non-blocking) ───────────────────────────────────
# Runs gen-tool-matrix.sh with --health-embed to produce a quick survey of the
# MCP tool surface and embed a one-line summary here.  The script uses a cache
# at ~/.cache/ashlr-workbench/matrix so it only re-probes when the plugin
# changes; passing --health-embed skips full HTML/MD regeneration and just
# prints the summary line.
section "Tool Matrix"

_MATRIX_SCRIPT="$SCRIPT_DIR/gen-tool-matrix.sh"
if [ ! -f "$_MATRIX_SCRIPT" ]; then
  warn "gen-tool-matrix.sh not found at $_MATRIX_SCRIPT"
elif [ ! -x "$_MATRIX_SCRIPT" ]; then
  warn "gen-tool-matrix.sh not executable — run: chmod +x $_MATRIX_SCRIPT"
else
  # Run with NO_COLOR so the summary line is parseable; capture output.
  _MATRIX_OUTPUT="$(
    NO_COLOR=1 \
    ASHLR_PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}" \
    bash "$_MATRIX_SCRIPT" --health-embed 2>/dev/null
  )" || true

  if [ -n "$_MATRIX_OUTPUT" ]; then
    # Print each output line indented under the section.
    printf '%s\n' "$_MATRIX_OUTPUT" | while IFS= read -r _mline; do
      printf "  %s\n" "$_mline"
    done
    # Count this as a pass if summary line was produced.
    ok "Tool matrix generated"
  else
    warn "Tool matrix: gen-tool-matrix.sh produced no output (run manually to debug)"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n%sResult:%s %s%d passed%s, %s%d warnings%s, %s%d failed%s\n" \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN" "$PASS" "$C_RESET" \
  "$C_YELLOW" "$WARN" "$C_RESET" \
  "$C_RED" "$FAIL" "$C_RESET"

[ "$FAIL" -eq 0 ]
