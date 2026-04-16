#!/usr/bin/env bash
# start-openhands.sh — launch OpenHands 1.6.0 wired to LM Studio + ashlr MCP.
#
# What this does (in order):
#   1. Preflight: Docker daemon, LM Studio endpoint, ashlr-plugin on disk.
#   2. Stages a Linux-arm64 `bun` binary under a host cache dir, so stdio MCP
#      servers (which are .ts files run via bun) can execute inside the Linux
#      container. The host's bun is macOS Mach-O, so we can't mount it.
#   3. Ensures ashlr-plugin deps are installed on the host side (one-shot
#      `bun install` inside the plugin dir). This lets us mount the plugin
#      read-only later.
#   4. Runs the container:
#        - mounts Desktop -> /workspace
#        - mounts ~/.openhands -> /.openhands (state dir, V1 convention)
#        - mounts our config.toml + mcp.json into /.openhands/ (authoritative)
#        - mounts ashlr-plugin -> /host/ashlr-plugin (read-only)
#        - mounts staged bun -> /host/bun (read-only)
#        - mounts /var/run/docker.sock so OpenHands can orchestrate its
#          agent-server sandbox container
#        - points LLM at host.docker.internal:1234 (LM Studio)
#
# Idempotent. Running it again restarts the container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$REPO_ROOT/agents/openhands"

# ---- config ----
CONTAINER_NAME="ashlr-openhands"
IMAGE="ghcr.io/openhands/openhands:1.6.0"
AGENT_SERVER_IMAGE="ghcr.io/openhands/agent-server:1.15.0-python"
LLM_BASE_URL="http://host.docker.internal:1234/v1"
LLM_MODEL="openai/qwen/qwen3-coder-30b"    # LiteLLM format; matches LM Studio id
LLM_API_KEY="local-llm"                     # LM Studio ignores the value
CONTEXT_LENGTH="32768"
PORT="3000"

STATE_DIR="$HOME/.openhands"
WORKSPACE_HOST="$HOME/Desktop"
ASHLR_PLUGIN_DIR="$HOME/Desktop/ashlr-plugin"
CACHE_DIR="$HOME/.cache/ashlr-workbench"
BUN_DIR="$CACHE_DIR/bun-linux-aarch64"
BUN_VERSION_URL="https://github.com/oven-sh/bun/releases/latest/download/bun-linux-aarch64.zip"

# ---- logging ----
log() { printf "\033[36m[start]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[start]\033[0m %s\n" "$*"; }
err() { printf "\033[31m[start]\033[0m %s\n" "$*" >&2; }

# ---- 1. preflight ----
log "Preflight checks..."

if ! command -v docker >/dev/null 2>&1; then
  err "Docker CLI not found. Install Docker Desktop."; exit 1
fi
if ! docker info >/dev/null 2>&1; then
  err "Docker daemon not running. Start Docker Desktop."; exit 1
fi

# LM Studio
if ! curl -sSf --max-time 3 "$LLM_BASE_URL/models" >/dev/null 2>&1; then
  # Translate host.docker.internal URL to localhost for host-side probe
  PROBE_URL="${LLM_BASE_URL/host.docker.internal/localhost}"
  if ! curl -sSf --max-time 3 "$PROBE_URL/models" >/dev/null 2>&1; then
    warn "LM Studio not reachable at $PROBE_URL (model served inside container may still work,"
    warn "but please verify LM Studio is serving on port 1234 with a model loaded)."
  fi
fi

# ashlr-plugin
if [ ! -d "$ASHLR_PLUGIN_DIR" ]; then
  err "ashlr-plugin not found at $ASHLR_PLUGIN_DIR"
  err "Clone it there or adjust ASHLR_PLUGIN_DIR in this script."
  exit 1
fi

# ---- 2. stage linux bun ----
mkdir -p "$BUN_DIR"
if [ ! -x "$BUN_DIR/bun" ]; then
  log "Downloading bun-linux-aarch64 to $BUN_DIR ..."
  tmpzip="$(mktemp -t bun-XXXX.zip)"
  if ! curl -sSL --fail "$BUN_VERSION_URL" -o "$tmpzip"; then
    err "Failed to download $BUN_VERSION_URL"; exit 1
  fi
  # Unzip into a tmpdir so we can flatten the layout
  tmpdir="$(mktemp -d)"
  if ! unzip -q "$tmpzip" -d "$tmpdir"; then
    err "Failed to unzip bun archive. Install unzip (brew install unzip)."; rm -f "$tmpzip"; rm -rf "$tmpdir"; exit 1
  fi
  # The zip contains a subdir like bun-linux-aarch64/bun
  found="$(find "$tmpdir" -type f -name bun | head -1)"
  if [ -z "$found" ]; then
    err "bun binary not found in archive"; rm -f "$tmpzip"; rm -rf "$tmpdir"; exit 1
  fi
  mv "$found" "$BUN_DIR/bun"
  chmod +x "$BUN_DIR/bun"
  rm -f "$tmpzip"
  rm -rf "$tmpdir"
  log "Staged $BUN_DIR/bun"
else
  log "Using cached $BUN_DIR/bun"
fi

# ---- 3. ensure ashlr-plugin deps on host ----
if [ ! -d "$ASHLR_PLUGIN_DIR/node_modules/@modelcontextprotocol/sdk" ]; then
  log "Installing ashlr-plugin deps on host (one-time)..."
  if command -v bun >/dev/null 2>&1; then
    ( cd "$ASHLR_PLUGIN_DIR" && bun install --silent ) || warn "bun install returned non-zero; continuing"
  else
    warn "Host 'bun' not found. MCP servers may fail on first call."
    warn "Install: curl -fsSL https://bun.sh/install | bash"
  fi
fi

# ---- 4. prepare state + sync config files into it ----
# Docker Desktop on macOS uses virtiofs, which forbids nested file mounts
# inside an already-bind-mounted directory. So we *copy* the config files
# into the state dir on each launch instead of bind-mounting them
# individually. The repo copies in agents/openhands/ remain authoritative —
# any drift is overwritten on the next start.
mkdir -p "$STATE_DIR"

if [ ! -f "$AGENT_DIR/config.toml" ]; then
  err "Missing $AGENT_DIR/config.toml"; exit 1
fi
if [ ! -f "$AGENT_DIR/mcp.json" ]; then
  err "Missing $AGENT_DIR/mcp.json"; exit 1
fi

log "Syncing config.toml + mcp.json into $STATE_DIR ..."
cp -f "$AGENT_DIR/config.toml" "$STATE_DIR/config.toml"
cp -f "$AGENT_DIR/mcp.json"    "$STATE_DIR/mcp.json"

# OpenHands V1 reads MCP server config from settings.json's `mcp_config` field
# (the Web UI Settings → MCP tab writes to the same key). Auto-loading
# /.openhands/mcp.json on boot is not yet a thing in 1.6, so we splice the
# mcp.json contents into settings.json on every start. Idempotent.
SETTINGS_JSON="$STATE_DIR/settings.json"
if [ ! -f "$SETTINGS_JSON" ]; then
  echo '{}' > "$SETTINGS_JSON"
fi
log "Splicing MCP server list into $SETTINGS_JSON ..."
python3 - "$SETTINGS_JSON" "$AGENT_DIR/mcp.json" "$LLM_MODEL" "$LLM_BASE_URL" "$LLM_API_KEY" <<'PY' || warn "Failed to update settings.json — MCP servers may not appear until you load them via the Settings UI."
import json, sys
settings_path, mcp_path, llm_model, llm_base, llm_key = sys.argv[1:6]
with open(settings_path) as f:
    s = json.load(f)
with open(mcp_path) as f:
    m = json.load(f)
# Strip _comment keys from the mcp config payload before persisting.
clean = {k: v for k, v in m.items() if not k.startswith('_')}
s["mcp_config"] = clean
# Keep LLM in sync with what we pass via env, in case the UI is the one
# users edit going forward.
s["llm_model"] = llm_model
s["llm_base_url"] = llm_base
s["llm_api_key"] = llm_key
with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
print(f"settings.json updated ({len(clean.get('mcpServers', {}))} MCP servers).")
PY

# ---- 5. remove any stale container with same name ----
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  log "Removing stale container $CONTAINER_NAME ..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# ---- 6. launch ----
# On macOS, host.docker.internal resolves automatically via Docker Desktop.
# On Linux we need --add-host=host.docker.internal:host-gateway. Bash 3.2-safe:
ADD_HOST=""
if [ "$(uname -s)" = "Linux" ]; then
  ADD_HOST="--add-host=host.docker.internal:host-gateway"
fi

log "Launching $CONTAINER_NAME from $IMAGE ..."

# Note: ADD_HOST is intentionally unquoted so an empty value expands to nothing.
docker run -d \
  --name "$CONTAINER_NAME" \
  --pull=missing \
  -p "${PORT}:3000" \
  $ADD_HOST \
  -e LOG_ALL_EVENTS=true \
  -e SANDBOX_VOLUMES="${WORKSPACE_HOST}:/workspace:rw" \
  -e SANDBOX_USER_ID="$(id -u)" \
  -e WORKSPACE_MOUNT_PATH_IN_SANDBOX=/workspace \
  -e LLM_BASE_URL="$LLM_BASE_URL" \
  -e LLM_MODEL="$LLM_MODEL" \
  -e LLM_API_KEY="$LLM_API_KEY" \
  -e OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH" \
  -e AGENT_SERVER_IMAGE_REPOSITORY="ghcr.io/openhands/agent-server" \
  -e AGENT_SERVER_IMAGE_TAG="1.15.0-python" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$STATE_DIR:/.openhands" \
  -v "$WORKSPACE_HOST:/workspace:rw" \
  -v "$ASHLR_PLUGIN_DIR:/host/ashlr-plugin:ro" \
  -v "$BUN_DIR:/host/bun:ro" \
  "$IMAGE" >/dev/null

# ---- 7. wait for GUI ----
log "Waiting for GUI on http://localhost:${PORT} ..."
ok=0
for i in $(seq 1 40); do
  if curl -sSf --max-time 2 "http://localhost:${PORT}" >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 1
done

if [ "$ok" -eq 1 ]; then
  printf '\n\033[32m[start] OpenHands up.\033[0m\n\n'
  cat <<EOF
  GUI:        http://localhost:${PORT}
  Container:  $CONTAINER_NAME
  Image:      $IMAGE
  LLM:        $LLM_MODEL via $LLM_BASE_URL
  State:      $STATE_DIR
  Workspace:  $WORKSPACE_HOST -> /workspace
  MCP:        10 ashlr-plugin servers (see agents/openhands/README.md)

Tail logs:    docker logs -f $CONTAINER_NAME
Stop:         $REPO_ROOT/scripts/stop-openhands.sh

EOF
else
  warn "GUI did not come up within 40s. Recent logs:"
  docker logs --tail 50 "$CONTAINER_NAME" || true
  exit 1
fi
