#!/usr/bin/env bash
# install-goose.sh — first-time setup for the Goose CLI in ashlr-workbench.
#
# Detects whether `goose` is already on PATH and, if not, prints the install
# command for the user to run. Pass `--yes` to actually execute the install
# (we default to printing-only so nothing is downloaded without consent).
#
# Goose is the AAIF fork (github.com/aaif-goose/goose), Apache-2.0. We prefer
# the Homebrew cask on macOS because it auto-updates with `brew upgrade` and
# drops a real launchd-manageable binary; the curl installer is the fallback
# for non-brew environments.

set -euo pipefail

YES=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    -h|--help)
      cat <<EOF
Usage: install-goose.sh [--yes]

  --yes, -y    Run the install command instead of just printing it.
  -h, --help   Show this help.

If Goose is already installed, the current version is printed and the script
exits 0. Otherwise the recommended install command is printed (and executed
only when --yes is passed).
EOF
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# ─── Already installed? ───────────────────────────────────────────────────────
if command -v goose >/dev/null 2>&1; then
  # `goose --version` prints to stdout on the aaif fork; fall back to a grep
  # on `goose info` if --version isn't wired up on this build.
  version="$(goose --version 2>/dev/null || goose info 2>/dev/null | head -1 || echo 'unknown')"
  echo "goose already installed: ${version}"
  echo "binary: $(command -v goose)"
  exit 0
fi

# ─── Not installed — pick the right install method ────────────────────────────
os="$(uname -s)"
if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
  # Homebrew-core ships `block-goose-cli` (Apache-2.0, same upstream codebase
  # as aaif-goose; the AAIF fork hasn't cut its own tap at the time of writing).
  # Track issue aaif-goose/goose for a dedicated tap; swap the command when it
  # exists.
  install_cmd='brew install block-goose-cli'
  method='Homebrew'
else
  # Official installer from the AAIF release assets. Pins to the `stable`
  # channel so we don't pull nightlies unexpectedly.
  install_cmd='curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | bash'
  method='curl installer'
fi

echo "Goose is not installed."
echo ""
echo "Recommended install (${method}):"
echo "  ${install_cmd}"
echo ""

if [ "$YES" -eq 1 ]; then
  echo "Running install (--yes passed)…"
  eval "$install_cmd"
  echo ""
  if command -v goose >/dev/null 2>&1; then
    echo "Install complete: $(goose --version 2>/dev/null || echo 'version unknown')"
  else
    echo "Install ran but 'goose' is not on PATH yet — open a new shell or add the" >&2
    echo "installer's bin directory to PATH." >&2
    exit 1
  fi
else
  echo "Re-run with --yes to execute, or run the command manually."
fi
