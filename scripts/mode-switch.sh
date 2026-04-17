#!/bin/bash
# mode-switch.sh — switch between coding / trading / both / lean model configs
# Usage: mode-switch.sh <coding|trading|both|lean|status>
set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
LMS="${HOME}/.lmstudio/bin/lms"

# Colors (respect NO_COLOR)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G='\033[32m' Y='\033[33m' C='\033[36m' D='\033[2m' R='\033[0m' B='\033[1m'
else
  G='' Y='' C='' D='' R='' B=''
fi

ollama_unload() {
  curl -sf "$OLLAMA_URL/api/generate" -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null 2>&1 || true
}

ollama_load() {
  # Send a trivial request to force-load the model
  curl -sf "$OLLAMA_URL/api/generate" -d "{\"model\":\"$1\",\"keep_alive\":\"5m\",\"prompt\":\"\",\"stream\":false}" >/dev/null 2>&1 || true
}

ollama_loaded() {
  curl -sf "$OLLAMA_URL/api/ps" 2>/dev/null | grep -q "\"$1\"" 2>/dev/null
}

lms_loaded() {
  if [ -x "$LMS" ]; then
    "$LMS" ps 2>/dev/null | grep -qi "$1" 2>/dev/null
  else
    return 1
  fi
}

show_status() {
  printf "${B}Model status${R}\n\n"

  # Ollama
  printf "  ${C}Ollama${R} ($OLLAMA_URL)\n"
  local ollama_ps
  ollama_ps=$(curl -sf "$OLLAMA_URL/api/ps" 2>/dev/null)
  if [ -n "$ollama_ps" ] && echo "$ollama_ps" | grep -q '"name"'; then
    echo "$ollama_ps" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for m in d.get('models', []):
    size_gb = m.get('size', 0) / 1e9
    print(f'    {m[\"name\"]:30s} {size_gb:.1f} GB loaded')
" 2>/dev/null || printf "    ${D}(running, models unclear)${R}\n"
  else
    printf "    ${D}(no models loaded)${R}\n"
  fi

  # LM Studio
  printf "\n  ${C}LM Studio${R} (localhost:1234)\n"
  if [ -x "$LMS" ]; then
    "$LMS" ps 2>/dev/null | tail -n +2 | while IFS= read -r line; do
      printf "    %s\n" "$line"
    done
    [ $("$LMS" ps 2>/dev/null | wc -l) -le 1 ] && printf "    ${D}(no models loaded)${R}\n"
  else
    printf "    ${D}(lms CLI not found)${R}\n"
  fi

  # RAM estimate
  printf "\n  ${C}RAM estimate${R}\n"
  local swap
  swap=$(sysctl -n vm.swapusage 2>/dev/null | grep -o 'used = [0-9.]*' | grep -o '[0-9.]*')
  if [ -n "$swap" ]; then
    local swap_gb
    swap_gb=$(echo "$swap / 1024" | bc -l 2>/dev/null | cut -c1-4)
    if [ "$(echo "$swap > 1024" | bc 2>/dev/null)" = "1" ]; then
      printf "    ${Y}Swap: ${swap_gb}GB used (reduce model load)${R}\n"
    else
      printf "    ${G}Swap: ${swap_gb}GB used (healthy)${R}\n"
    fi
  fi
}

mode_coding() {
  printf "${B}Switching to coding mode${R}\n"
  printf "  Unloading Ollama gemma4:26b... "
  ollama_unload "gemma4:26b"
  printf "${G}done${R}\n"

  printf "  LM Studio Qwen3-Coder should be loaded in the GUI\n"
  printf "  ${D}(LM Studio model loading requires the GUI — verify at localhost:1234)${R}\n"
  printf "\n${G}Coding mode active.${R} ~16GB model RAM.\n"
}

mode_trading() {
  printf "${B}Switching to trading mode${R}\n"
  printf "  Loading Ollama gemma4:26b... "
  ollama_load "gemma4:26b"
  printf "${G}done${R}\n"

  if [ -x "$LMS" ]; then
    printf "  Unloading LM Studio models... "
    "$LMS" unload --all 2>/dev/null || true
    printf "${G}done${R}\n"
  fi
  printf "\n${G}Trading mode active.${R} ~34GB model RAM.\n"
}

mode_both() {
  printf "${B}Loading both models${R}\n"
  printf "  ${Y}Warning: ~50GB model RAM — may cause swap on 128GB machine${R}\n"
  printf "  Loading Ollama gemma4:26b... "
  ollama_load "gemma4:26b"
  printf "${G}done${R}\n"
  printf "  LM Studio Qwen3-Coder should be loaded in the GUI\n"
  printf "\n${Y}Both models active.${R} ~50GB model RAM. Monitor swap.\n"
}

mode_lean() {
  printf "${B}Entering lean mode — unloading all heavy models${R}\n"
  printf "  Unloading Ollama gemma4:26b... "
  ollama_unload "gemma4:26b"
  printf "${G}done${R}\n"

  if [ -x "$LMS" ]; then
    printf "  Unloading LM Studio models... "
    "$LMS" unload --all 2>/dev/null || true
    printf "${G}done${R}\n"
  fi
  printf "\n${G}Lean mode active.${R} Only llama3.2:3b available (2GB). Max headroom.\n"
}

case "${1:-help}" in
  coding)  mode_coding ;;
  trading) mode_trading ;;
  both)    mode_both ;;
  lean)    mode_lean ;;
  status)  show_status ;;
  -h|--help|help)
    printf "Usage: mode-switch.sh <coding|trading|both|lean|status>\n\n"
    printf "  coding   Load Qwen3-Coder, unload gemma4 (~16GB)\n"
    printf "  trading  Load gemma4:26b, unload Qwen3-Coder (~34GB)\n"
    printf "  both     Load both (~50GB, may swap)\n"
    printf "  lean     Unload everything heavy (~2GB)\n"
    printf "  status   Show loaded models + RAM\n"
    ;;
  *)
    printf "Unknown mode: %s\n" "$1" >&2
    printf "Run with --help for usage\n" >&2
    exit 1
    ;;
esac
