#!/usr/bin/env bash
# update-all.sh — pull the latest version of every workbench component.
#
# Order matters: cheap checks first, slow downloads last, git pulls in the
# middle so we can bail on a dirty tree before touching anything.
#
# What gets updated:
#   - OpenHands Docker image      (docker pull ghcr.io/openhands/openhands:latest)
#   - Goose                        (brew if installed via tap, else `goose update`)
#   - Aider                        (pipx if available, else pip --user)
#   - ashlrcode                    (npm install -g ashlrcode@latest)
#   - ashlr-plugin                 (git pull + bun install)
#   - ashlr-workbench              (git pull on clean main)
#
# Each step is non-fatal — we report what worked and what didn't at the end.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="$(cd "$SCRIPT_DIR/.." && pwd)"
ASHLR_PLUGIN_DIR="${ASHLR_PLUGIN_DIR:-$HOME/Desktop/ashlr-plugin}"
OPENHANDS_IMAGE="ghcr.io/openhands/openhands:1.6.0"

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_BOLD=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
fi

step()  { printf "\n%s==>%s %s%s%s\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()    { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; OK_LIST+=("$*"); }
skip()  { printf "  %s•%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; SKIP_LIST+=("$*"); }
fail()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; FAIL_LIST+=("$*"); }

OK_LIST=(); SKIP_LIST=(); FAIL_LIST=()

have() { command -v "$1" >/dev/null 2>&1; }

# ─── 1. OpenHands Docker image ────────────────────────────────────────────────
step "OpenHands image ($OPENHANDS_IMAGE)"
if have docker && docker info >/dev/null 2>&1; then
  if docker pull "$OPENHANDS_IMAGE"; then
    ok "pulled $OPENHANDS_IMAGE"
  else
    fail "docker pull failed for $OPENHANDS_IMAGE"
  fi
else
  skip "Docker not running — skipped"
fi

# ─── 2. Goose ─────────────────────────────────────────────────────────────────
step "Goose"
if have brew && brew list goose >/dev/null 2>&1; then
  if brew upgrade goose; then ok "goose upgraded via brew"; else fail "brew upgrade goose"; fi
elif have brew && brew list aaif-goose/tap/goose >/dev/null 2>&1; then
  if brew upgrade aaif-goose/tap/goose; then ok "goose upgraded via tap"; else fail "brew upgrade aaif-goose/tap/goose"; fi
elif have goose; then
  # The Goose binary itself ships an `update` subcommand.
  if goose --help 2>&1 | grep -q "update"; then
    if goose update; then ok "goose self-updated"; else fail "goose update"; fi
  else
    skip "goose installed but no upgrade path detected (manual: re-run install-goose.sh)"
  fi
else
  skip "goose not installed (run scripts/install-goose.sh)"
fi

# ─── 3. Aider ─────────────────────────────────────────────────────────────────
step "Aider"
if have pipx && pipx list 2>/dev/null | grep -q aider-chat; then
  if pipx upgrade aider-chat; then ok "aider upgraded via pipx"; else fail "pipx upgrade aider-chat"; fi
elif have pip; then
  if pip install --user --upgrade aider-chat; then
    ok "aider upgraded via pip --user"
  else
    fail "pip install --upgrade aider-chat"
  fi
elif have pip3; then
  if pip3 install --user --upgrade aider-chat; then
    ok "aider upgraded via pip3 --user"
  else
    fail "pip3 install --upgrade aider-chat"
  fi
else
  skip "no pip/pipx found"
fi

# ─── 4. ashlrcode ─────────────────────────────────────────────────────────────
step "ashlrcode"
if have npm; then
  if npm install -g ashlrcode@latest; then ok "ashlrcode upgraded via npm"; else fail "npm install -g ashlrcode"; fi
elif have bun; then
  if bun add -g ashlrcode@latest; then ok "ashlrcode upgraded via bun"; else fail "bun add -g ashlrcode"; fi
else
  skip "neither npm nor bun on PATH"
fi

# ─── 5. ashlr-plugin (git pull + deps) ────────────────────────────────────────
step "ashlr-plugin ($ASHLR_PLUGIN_DIR)"
if [ -d "$ASHLR_PLUGIN_DIR/.git" ]; then
  if ( cd "$ASHLR_PLUGIN_DIR" && git pull --ff-only ); then
    ok "git pull --ff-only"
    if have bun; then
      if ( cd "$ASHLR_PLUGIN_DIR" && bun install --silent ); then
        ok "bun install"
      else
        fail "bun install in ashlr-plugin"
      fi
    fi
  else
    fail "git pull (uncommitted changes? non-fast-forward?)"
  fi
else
  skip "$ASHLR_PLUGIN_DIR is not a git repo"
fi

# ─── 6. ashlr-workbench (this repo) ───────────────────────────────────────────
step "ashlr-workbench ($WORKBENCH)"
if [ -d "$WORKBENCH/.git" ]; then
  DIRTY="$(cd "$WORKBENCH" && git status --porcelain | wc -l | tr -d ' ')"
  if [ "$DIRTY" != "0" ]; then
    skip "$DIRTY uncommitted change(s) — refusing to pull"
  else
    if ( cd "$WORKBENCH" && git pull --ff-only ); then
      ok "git pull --ff-only"
    else
      fail "git pull failed"
    fi
  fi
else
  skip "workbench is not a git repo"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n%sUpdate summary%s\n" "$C_BOLD" "$C_RESET"
printf "  %supdated:%s %d\n" "$C_GREEN" "$C_RESET" "${#OK_LIST[@]}"
for line in "${OK_LIST[@]}";   do printf "    %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$line"; done
printf "  %sskipped:%s %d\n" "$C_YELLOW" "$C_RESET" "${#SKIP_LIST[@]}"
for line in "${SKIP_LIST[@]}"; do printf "    %s•%s %s\n" "$C_YELLOW" "$C_RESET" "$line"; done
printf "  %sfailed:%s  %d\n" "$C_RED" "$C_RESET" "${#FAIL_LIST[@]}"
for line in "${FAIL_LIST[@]}"; do printf "    %s✗%s %s\n" "$C_RED"    "$C_RESET" "$line"; done

[ "${#FAIL_LIST[@]}" -eq 0 ]
