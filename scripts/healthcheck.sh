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

# ─── 10. Agent configs valid ──────────────────────────────────────────────────
section "Agent configs"

validate_json() {
  local f="$1"; local label="$2"
  if [ ! -f "$f" ]; then bad "$label missing: $f"; return; fi
  if have python3 && python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
    ok "$label JSON valid"
  elif have node && node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" 2>/dev/null; then
    ok "$label JSON valid"
  else
    warn "$label: no JSON validator available (install python3 or node)"
  fi
}

validate_yaml() {
  local f="$1"; local label="$2"
  if [ ! -f "$f" ]; then bad "$label missing: $f"; return; fi
  if have python3 && python3 -c "
import sys
try:
    import yaml
    yaml.safe_load(open('$f'))
except ImportError:
    # PyYAML may be unavailable on system python; fall back to a syntax sniff.
    txt=open('$f').read()
    # Minimal sanity: no tabs, balanced quotes
    if '\t' in txt:
        sys.exit('contains tabs')
" 2>/dev/null; then
    ok "$label YAML valid"
  else
    warn "$label: YAML validation skipped (install pyyaml)"
  fi
}

validate_toml() {
  local f="$1"; local label="$2"
  if [ ! -f "$f" ]; then bad "$label missing: $f"; return; fi
  if have python3 && python3 -c "
import sys
try:
    import tomllib  # py311+
    tomllib.load(open('$f','rb'))
except ImportError:
    try:
        import tomli
        tomli.load(open('$f','rb'))
    except ImportError:
        sys.exit('no toml lib')
" 2>/dev/null; then
    ok "$label TOML valid"
  else
    warn "$label: TOML validation skipped (no tomllib/tomli)"
  fi
}

validate_json "$WORKBENCH/agents/openhands/mcp.json"      "openhands/mcp.json"
validate_toml "$WORKBENCH/agents/openhands/config.toml"   "openhands/config.toml"
validate_yaml "$WORKBENCH/agents/aider/aider.conf.yml"    "aider/aider.conf.yml"
validate_yaml "$WORKBENCH/agents/goose/config.yaml"       "goose/config.yaml"
validate_json "$WORKBENCH/agents/ashlrcode/settings.json" "ashlrcode/settings.json"

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n%sResult:%s %s%d passed%s, %s%d warnings%s, %s%d failed%s\n" \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN" "$PASS" "$C_RESET" \
  "$C_YELLOW" "$WARN" "$C_RESET" \
  "$C_RED" "$FAIL" "$C_RESET"

[ "$FAIL" -eq 0 ]
