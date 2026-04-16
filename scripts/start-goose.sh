#!/usr/bin/env bash
# start-goose.sh — launch Goose with the workbench config and ashlr-plugin MCPs.
#
# Goose does not currently support a `--config` CLI flag (see aaif-goose/goose
# #6787). It reads `$GOOSE_PATH_ROOT/config/config.yaml` when GOOSE_PATH_ROOT
# is set, falling back to the OS-native app-config dir otherwise. We point
# GOOSE_PATH_ROOT at `agents/goose/` and copy `config.yaml` → `config/config.yaml`
# on every launch so edits to the source-of-truth file take effect immediately
# without stomping the user's global `~/.config/goose/config.yaml`.
#
# The copy also expands `${ASHLR_PLUGIN_ROOT}` in the YAML — Goose's config
# loader does NOT interpolate env vars inside string values, so we do it here
# with envsubst.

set -euo pipefail

# ─── Flags ────────────────────────────────────────────────────────────────────
show_help() {
  cat <<EOF
Usage: start-goose.sh [--help] [-- <goose args>]

Launches an interactive Goose session with:
  - LM Studio (http://localhost:1234) as the LLM provider
  - Qwen3-Coder-30B as the model
  - All 10 ashlr-plugin MCP servers registered as extensions
  - ~/Desktop as the working directory

Options:
  -h, --help         Show this help and exit.
  --                 Pass everything after this to \`goose session\`.

Environment overrides:
  ASHLR_PLUGIN_ROOT  Path to the ashlr-plugin checkout.
                     Default: ~/Desktop/ashlr-plugin
  GOOSE_WORKSPACE    Directory to cd into before launching Goose.
                     Default: ~/Desktop

Examples:
  ./scripts/start-goose.sh
  ./scripts/start-goose.sh -- --debug          # pass --debug to goose session
  GOOSE_WORKSPACE=~/code/foo ./scripts/start-goose.sh
EOF
}

passthrough_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    --) shift; passthrough_args=("$@"); break ;;
    *)
      echo "unknown arg: $1 (try --help)" >&2
      exit 2
      ;;
  esac
done

# ─── Resolve paths ────────────────────────────────────────────────────────────
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workbench_root="$(cd "$script_dir/.." && pwd)"
agent_dir="$workbench_root/agents/goose"
source_cfg="$agent_dir/config.yaml"
runtime_cfg_dir="$agent_dir/config"
runtime_cfg="$runtime_cfg_dir/config.yaml"

: "${ASHLR_PLUGIN_ROOT:=$HOME/Desktop/ashlr-plugin}"
: "${GOOSE_WORKSPACE:=$HOME/Desktop}"

# ─── Session log (cross-agent trace) ──────────────────────────────────────────
# shellcheck source=lib/session-log.sh
. "$script_dir/lib/session-log.sh"
log_session_start goose "$GOOSE_WORKSPACE"
trap 'log_session_end goose "$GOOSE_WORKSPACE"' EXIT

# ─── Sanity checks ────────────────────────────────────────────────────────────
if ! command -v goose >/dev/null 2>&1; then
  echo "Error: goose is not installed. Run ./scripts/install-goose.sh first." >&2
  exit 1
fi

if [ ! -f "$source_cfg" ]; then
  echo "Error: missing config source at $source_cfg" >&2
  exit 1
fi

if [ ! -d "$ASHLR_PLUGIN_ROOT" ]; then
  echo "Warning: ASHLR_PLUGIN_ROOT=$ASHLR_PLUGIN_ROOT does not exist." >&2
  echo "         MCP extensions will fail to start. Set ASHLR_PLUGIN_ROOT to" >&2
  echo "         the path of your ashlr-plugin checkout, or install it at" >&2
  echo "         ~/Desktop/ashlr-plugin." >&2
fi

if ! curl -sf -m 2 "${OPENAI_HOST:-http://localhost:1234}/v1/models" >/dev/null 2>&1; then
  echo "Warning: LM Studio doesn't appear to be serving on http://localhost:1234." >&2
  echo "         Open LM Studio → Developer tab → Start Server, and load the" >&2
  echo "         qwen3-coder-30b model before running goose session." >&2
fi

# ─── Materialize runtime config ───────────────────────────────────────────────
# envsubst expands only ${ASHLR_PLUGIN_ROOT}. Whitelisting via SHELL_FORMAT
# prevents accidental interpolation of other env vars (e.g. $HOME values that
# happen to appear in comments).
mkdir -p "$runtime_cfg_dir"
export ASHLR_PLUGIN_ROOT
if command -v envsubst >/dev/null 2>&1; then
  envsubst '${ASHLR_PLUGIN_ROOT}' < "$source_cfg" > "$runtime_cfg"
else
  # envsubst ships with gettext; fall back to sed if it's missing (rare on
  # macOS where gettext isn't default-installed).
  sed "s|\${ASHLR_PLUGIN_ROOT}|${ASHLR_PLUGIN_ROOT}|g" "$source_cfg" > "$runtime_cfg"
fi

# ─── Launch ───────────────────────────────────────────────────────────────────
# GOOSE_PATH_ROOT overrides Goose's path-resolution logic; see
# crates/goose/src/config/paths.rs in the aaif-goose repo.
# GOOSE_DISABLE_KEYRING=1 makes Goose read OPENAI_API_KEY from the YAML/env
# instead of the macOS keychain — essential because LM Studio uses a dummy key
# and we don't want to stash 'lm-studio' in the user's keychain.
export GOOSE_PATH_ROOT="$agent_dir"
export GOOSE_DISABLE_KEYRING=1

echo "Starting Goose session…"
echo "  config:    $runtime_cfg"
echo "  workspace: $GOOSE_WORKSPACE"
echo "  plugin:    $ASHLR_PLUGIN_ROOT"
echo ""

cd "$GOOSE_WORKSPACE"
# Run (don't `exec`) so the EXIT trap fires after goose returns. `exec` would
# replace this shell and skip the session_end log. The '${args+"${args[@]}"}'
# form is bash 3.2-safe for an empty array under `set -u`.
goose session ${passthrough_args+"${passthrough_args[@]}"}
exit $?
