#!/usr/bin/env bash
# aw-session.sh — Launch an interactive ashlrcode session with model routing,
# genome injection, and one-shot prompt support.
#
# Called by `bin/aw` when no subcommand is given. Not intended to be invoked
# directly, but will work standalone.
#
# Usage:
#   ./scripts/aw-session.sh                          # interactive (default: qwen)
#   ./scripts/aw-session.sh --model fast "2+2"       # one-shot with llama3.2:3b
#   ./scripts/aw-session.sh --model gemma "design"    # one-shot via gemma4:26b (hard reasoning)
#
# Environment:
#   AW_MODEL          model alias (qwen|fast|gemma|auto) — overridden by --model

set -uo pipefail

# ─── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="$(cd "$SCRIPT_DIR/.." && pwd)"
WB_CONFIG_DIR="$WORKBENCH/agents/ashlrcode"
WB_SETTINGS="$WB_CONFIG_DIR/settings.json"
SESSION_CONFIG="$WB_CONFIG_DIR/session-config.json"

ASHLR_PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
LM_STUDIO_URL="${LM_STUDIO_URL:-http://localhost:1234/v1}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

# ─── Colors (NO_COLOR-aware) ──────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
fi

warn()  { printf "  %s!%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
bad()   { printf "  %sx%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
dim()   { printf "%s%s%s\n" "$C_DIM"  "$*" "$C_RESET" >&2; }

# ─── Parse args ───────────────────────────────────────────────────────────────
MODEL_ALIAS="${AW_MODEL:-qwen}"
PROMPT=""
EXTRA_AC_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      MODEL_ALIAS="${2:-qwen}"
      shift 2 || { bad "--model requires a value"; exit 2; }
      ;;
    --model=*)
      MODEL_ALIAS="${1#--model=}"
      shift
      ;;
    --*)
      # Pass unknown flags through to ashlrcode
      EXTRA_AC_ARGS+=("$1")
      shift
      ;;
    *)
      # Everything else is the prompt
      if [ -z "$PROMPT" ]; then
        PROMPT="$1"
      else
        PROMPT="$PROMPT $1"
      fi
      shift
      ;;
  esac
done

# ─── Model routing ────────────────────────────────────────────────────────────
# Each alias resolves to: display name, endpoint URL, model id, provider type.
case "$MODEL_ALIAS" in
  qwen|auto)
    DISPLAY_MODEL="Qwen3-Coder-30B"
    ENDPOINT_URL="$LM_STUDIO_URL"
    MODEL_ID="qwen/qwen3-coder-30b"
    PROVIDER="openai"
    API_KEY="lm-studio"
    ;;
  fast)
    DISPLAY_MODEL="llama3.2:3b"
    ENDPOINT_URL="$OLLAMA_URL"
    MODEL_ID="llama3.2:3b"
    PROVIDER="ollama"
    API_KEY=""
    ;;
  gemma)
    DISPLAY_MODEL="gemma4:26b (reasoning)"
    ENDPOINT_URL="$OLLAMA_URL"
    MODEL_ID="gemma4:26b"
    PROVIDER="ollama"
    API_KEY=""
    ;;
  *)
    bad "unknown model alias: $MODEL_ALIAS (valid: qwen, fast, gemma, auto)"
    exit 2
    ;;
esac

# ─── Secrets ──────────────────────────────────────────────────────────────────
# Reuse the same secret-loading pattern from start-ashlrcode.sh.
load_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}
load_env_file "$WORKBENCH/.env"
load_env_file "$HOME/.ashlrcode/.env"

# Last-resort XAI_API_KEY from user's global settings
if [ -z "${XAI_API_KEY:-}" ] && [ -f "$HOME/.ashlrcode/settings.json" ]; then
  # shellcheck disable=SC2155
  export XAI_API_KEY="$(awk -F'"' '/"apiKey"[[:space:]]*:[[:space:]]*"xai-/ {print $4; exit}' "$HOME/.ashlrcode/settings.json" 2>/dev/null || true)"
fi

# ─── Check endpoint health ───────────────────────────────────────────────────
check_endpoint() {
  local url="$1" name="$2" timeout="${3:-3}"
  if ! curl -fsS --max-time "$timeout" "$url" >/dev/null 2>&1; then
    warn "$name not responding at $url"
    warn "Start the service or use a different --model"
    return 1
  fi
  return 0
}

case "$PROVIDER" in
  openai)
    check_endpoint "$ENDPOINT_URL/models" "LM Studio" 3 || exit 1
    ;;
  ollama)
    check_endpoint "$OLLAMA_URL/api/tags" "Ollama" 2 || exit 1
    ;;
  anthropic)
    # No preflight for cloud APIs — auth errors surface at call time
    ;;
esac

# ─── Genome injection ────────────────────────────────────────────────────────
# Walk up from cwd looking for .ashlrcode/genome/manifest.json
GENOME_DIR=""
GENOME_CONTEXT=""
GENOME_SECTION_COUNT=0

find_genome() {
  local dir="$1"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.ashlrcode/genome/manifest.json" ]; then
      GENOME_DIR="$dir/.ashlrcode/genome"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if find_genome "$PWD"; then
  # Count sections from manifest
  if command -v python3 >/dev/null 2>&1; then
    GENOME_SECTION_COUNT="$(python3 -c "
import json, sys
try:
    m = json.load(open('$GENOME_DIR/manifest.json'))
    print(len(m.get('sections', [])))
except: print(0)
" 2>/dev/null || echo 0)"
  else
    # Rough count: lines containing "path" keys in the manifest
    GENOME_SECTION_COUNT="$(grep -c '"path"' "$GENOME_DIR/manifest.json" 2>/dev/null || echo 0)"
  fi

  # Read the top 3 sections by priority (lowest priority number = highest importance)
  if command -v python3 >/dev/null 2>&1; then
    GENOME_CONTEXT="$(python3 -c "
import json, os, sys
try:
    base = '$GENOME_DIR'
    m = json.load(open(os.path.join(base, 'manifest.json')))
    sections = sorted(m.get('sections', []), key=lambda s: s.get('priority', 50))[:3]
    for s in sections:
        p = os.path.join(base, s['path'])
        if os.path.isfile(p):
            print(f\"--- {s.get('name', s['path'])} ---\")
            print(open(p).read().strip())
            print()
except Exception as e:
    print(f'[genome load error: {e}]', file=sys.stderr)
" 2>/dev/null || true)"
  fi
fi

# ─── Export ashlrcode config ──────────────────────────────────────────────────
# Point ashlrcode at the workbench config dir (picks up MCP servers, hooks, etc.)
export ASHLRCODE_CONFIG_DIR="$WB_CONFIG_DIR"
export ASHLR_MCP_EXTRA="$WB_SETTINGS"

# Override model via AC_MODEL env var (ashlrcode reads this)
export AC_MODEL="$MODEL_ID"

# For local providers, set the base URL so ashlrcode routes correctly
case "$PROVIDER" in
  openai)
    export OPENAI_API_KEY="${API_KEY}"
    export OPENAI_BASE_URL="$ENDPOINT_URL"
    ;;
  ollama)
    export OLLAMA_HOST="$OLLAMA_URL"
    ;;
  anthropic)
    export ANTHROPIC_API_KEY="$API_KEY"
    ;;
esac

# If genome dir found, point ashlrcode at it
if [ -n "$GENOME_DIR" ]; then
  export ASHLRCODE_GENOME_DIR="$GENOME_DIR"
fi

# ─── Session log ──────────────────────────────────────────────────────────────
# shellcheck source=lib/session-log.sh
. "$SCRIPT_DIR/lib/session-log.sh"
log_session_start ashlrcode "$PWD"
trap 'log_session_end ashlrcode "$PWD"' EXIT

# ─── Welcome banner (interactive only) ───────────────────────────────────────
if [ -z "$PROMPT" ] && [ -t 1 ]; then
  printf "\n"
  printf "  %sashlr workbench%s %s·%s %s%s%s %s·%s %s%s%s\n" \
    "$C_BOLD" "$C_RESET" \
    "$C_DIM" "$C_RESET" \
    "$C_CYAN" "$DISPLAY_MODEL" "$C_RESET" \
    "$C_DIM" "$C_RESET" \
    "$C_DIM" "$ENDPOINT_URL" "$C_RESET"

  # Genome line
  if [ -n "$GENOME_DIR" ]; then
    printf "  %sgenome:%s %s sections loaded %s·%s session log active\n" \
      "$C_GREEN" "$C_RESET" \
      "$GENOME_SECTION_COUNT" \
      "$C_DIM" "$C_RESET"
  else
    printf "  %sno genome%s %s·%s session log active\n" \
      "$C_DIM" "$C_RESET" \
      "$C_DIM" "$C_RESET"
  fi

  printf "  %stype your prompt, or /help for commands%s\n\n" \
    "$C_DIM" "$C_RESET"
fi

# ─── Build ashlrcode args ────────────────────────────────────────────────────
AC_ARGS=()

# Inject genome context as a system-level preamble via --system-prompt if available
# (ashlrcode reads ASHLRCODE_GENOME_DIR natively in v2.1+, so this is a fallback)

# Pass extra flags (--continue, --yolo, etc.)
if [ ${#EXTRA_AC_ARGS[@]} -gt 0 ]; then
  AC_ARGS+=("${EXTRA_AC_ARGS[@]}")
fi

# If a prompt was given, pass it as the inline message (one-shot mode)
if [ -n "$PROMPT" ]; then
  AC_ARGS+=("$PROMPT")
fi

# ─── Launch ───────────────────────────────────────────────────────────────────
# Run (don't exec) so the EXIT trap fires and writes session_end.
ashlrcode "${AC_ARGS[@]+"${AC_ARGS[@]}"}"
exit $?
