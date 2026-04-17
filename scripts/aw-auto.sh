#!/usr/bin/env bash
# aw-auto.sh — Autonomous project builder.
#
# One command to scaffold and build a project from a prompt. Auto-detects the
# project mode (greenfield / existing / template) and runs ashlrcode in
# autonomous mode.
#
# Usage:
#   aw auto "Build a Tinder for vibecoded projects"
#   aw auto "Add dark mode" --cwd ~/Desktop/Koala
#   aw auto "Build an artist encyclopedia for Kendrick" --timeout 7200

set -uo pipefail

# ─── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors (NO_COLOR-aware) ─────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
bad()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
dim()  { printf "%s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${C_BOLD}aw auto${C_RESET} — autonomous project builder

${C_BOLD}USAGE${C_RESET}
  aw auto "Build a Tinder for vibecoded projects"
  aw auto "Add dark mode" --cwd ~/Desktop/Koala
  aw auto "Build an artist encyclopedia for Kendrick" --timeout 7200

${C_BOLD}OPTIONS${C_RESET}
  ${C_CYAN}--cwd${C_RESET} <dir>             target directory (default: current directory)
  ${C_CYAN}--timeout${C_RESET} <seconds>      max runtime (default: 3600)
  ${C_CYAN}--max-iterations${C_RESET} <n>     max agent turns (default: 200)
  ${C_CYAN}-h, --help${C_RESET}              show this help

${C_BOLD}MODES${C_RESET} (auto-detected)
  ${C_GREEN}greenfield${C_RESET}   empty folder — scaffolds from scratch
  ${C_GREEN}existing${C_RESET}     has package.json / src/ / git history — continues work
  ${C_GREEN}template${C_RESET}     goal mentions "artist encyclopedia" — uses factory

${C_BOLD}EXAMPLES${C_RESET}
  aw auto "Build a CLI that converts markdown to PDF"
  aw auto "Refactor the auth module" --cwd ~/projects/myapp --timeout 1800
  aw auto "Build an artist encyclopedia for Kendrick Lamar"
EOF
}

# ─── Parse args ──────────────────────────────────────────────────────────────
GOAL=""
TARGET_DIR="$PWD"
TIMEOUT=3600
MAX_ITER=200

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --cwd)
      TARGET_DIR="${2:-}"
      if [ -z "$TARGET_DIR" ]; then
        bad "--cwd requires a directory path"
        exit 2
      fi
      shift 2
      ;;
    --cwd=*)
      TARGET_DIR="${1#--cwd=}"
      shift
      ;;
    --timeout)
      TIMEOUT="${2:-3600}"
      shift 2 || { bad "--timeout requires a value"; exit 2; }
      ;;
    --timeout=*)
      TIMEOUT="${1#--timeout=}"
      shift
      ;;
    --max-iterations)
      MAX_ITER="${2:-200}"
      shift 2 || { bad "--max-iterations requires a value"; exit 2; }
      ;;
    --max-iterations=*)
      MAX_ITER="${1#--max-iterations=}"
      shift
      ;;
    --*)
      bad "unknown flag: $1"
      echo "Run 'aw auto --help' for usage."
      exit 2
      ;;
    *)
      if [ -z "$GOAL" ]; then
        GOAL="$1"
      else
        GOAL="$GOAL $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$GOAL" ]; then
  bad "no goal provided"
  echo "Usage: aw auto \"Build something amazing\""
  exit 2
fi

# ─── Auto-detect mode ───────────────────────────────────────────────────────
detect_mode() {
  local dir="$1" goal="$2"

  # Template: artist encyclopedia
  if echo "$goal" | grep -qi "artist encyclopedia\|encyclopedia.*artist\|like swiftiepedia\|like yeuniverse"; then
    echo "template"
    return
  fi

  # Existing project: has package.json or src/ or .git with commits
  if [ -f "$dir/package.json" ] || [ -d "$dir/src" ] || git -C "$dir" log --oneline -1 >/dev/null 2>&1; then
    echo "existing"
    return
  fi

  # Empty / new folder
  echo "greenfield"
}

MODE="$(detect_mode "$TARGET_DIR" "$GOAL")"

# ─── Banner ──────────────────────────────────────────────────────────────────
printf "\n"
printf "  %saw auto%s — autonomous local builder\n" "$C_BOLD" "$C_RESET"
printf "  %sgoal:%s     %s\n" "$C_DIM" "$C_RESET" "$GOAL"
printf "  %smode:%s     %s\n" "$C_DIM" "$C_RESET" "$MODE"
printf "  %starget:%s   %s\n" "$C_DIM" "$C_RESET" "$TARGET_DIR"
printf "  %stimeout:%s  %ss  %smax-iterations:%s %s\n" \
  "$C_DIM" "$C_RESET" "$TIMEOUT" "$C_DIM" "$C_RESET" "$MAX_ITER"
printf "\n"

# ─── Session log ─────────────────────────────────────────────────────────────
# shellcheck source=lib/session-log.sh
. "$SCRIPT_DIR/lib/session-log.sh"
log_session_start "aw-auto" "$TARGET_DIR"
trap 'log_session_end "aw-auto" "$TARGET_DIR"' EXIT

# ─── Preflight: ensure ashlrcode is available ────────────────────────────────
if ! command -v ashlrcode >/dev/null 2>&1; then
  bad "ashlrcode not found on PATH"
  echo "Install: npm install -g ashlrcode"
  exit 1
fi

# ─── Execute based on mode ───────────────────────────────────────────────────
run_greenfield() {
  mkdir -p "$TARGET_DIR"
  cd "$TARGET_DIR" || { bad "cannot cd to $TARGET_DIR"; exit 1; }
  git init 2>/dev/null || true
  ok "greenfield: initialized $TARGET_DIR"
  ashlrcode --autonomous --goal "$GOAL" --initial-scaffold --timeout "$TIMEOUT" --max-iterations "$MAX_ITER"
}

run_existing() {
  cd "$TARGET_DIR" || { bad "cannot cd to $TARGET_DIR"; exit 1; }
  ok "existing: working in $TARGET_DIR"
  ashlrcode --autonomous --goal "$GOAL" --timeout "$TIMEOUT" --max-iterations "$MAX_ITER"
}

run_template() {
  local FACTORY="$HOME/Desktop/artist-encyclopedia-factory"

  if [ -d "$FACTORY" ]; then
    ok "template: using artist-encyclopedia-factory"
    cd "$FACTORY" || { bad "cannot cd to $FACTORY"; exit 1; }

    # Extract artist name from goal
    local ARTIST
    ARTIST="$(echo "$GOAL" | sed -n 's/.*encyclopedia.*for \(.*\)/\1/ip' | sed 's/[,.].*//; s/^ *//; s/ *$//')"
    [ -z "$ARTIST" ] && ARTIST="Unknown Artist"
    ok "template: artist = $ARTIST"

    # Run ashlrcode in the factory with a template-aware goal
    ashlrcode --autonomous \
      --goal "Create a new artist encyclopedia for $ARTIST using the factory template system. Run the new-artist script if it exists, or create artists/$ARTIST.json with the ArtistBundle schema, then build and test the site." \
      --timeout "$TIMEOUT" \
      --max-iterations "$MAX_ITER"
  else
    warn "factory not found at $FACTORY — falling back to greenfield"
    run_greenfield
  fi
}

case "$MODE" in
  greenfield) run_greenfield ;;
  existing)   run_existing   ;;
  template)   run_template   ;;
  *)
    bad "unknown mode: $MODE"
    exit 1
    ;;
esac

# Forward ashlrcode's exit code (set implicitly by the last command)
exit $?
