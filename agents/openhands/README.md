# OpenHands 1.6 with ashlr-plugin MCP

OpenHands is the web-based coding agent we run locally, powered by LM Studio
serving Qwen3-Coder-30B-A3B-Instruct. This directory holds the config that
wires OpenHands to our local LLM plus the 10 ashlr-plugin MCP servers.

## TL;DR

```bash
# One-time: upgrade from 0.38 to 1.6.0
./scripts/upgrade-openhands.sh

# Start
./scripts/start-openhands.sh

# Use
open http://localhost:3000

# Stop
./scripts/stop-openhands.sh
```

## What's here

| File | Purpose |
| --- | --- |
| `config.toml` | Source-of-truth doc of every OpenHands config knob. Copied into `~/.openhands/config.toml` on each launch. V1 ignores most of it; env vars + `settings.json` are what actually drive behavior. |
| `mcp.json` | Source-of-truth registry for the 10 ashlr MCP servers. Copied into `~/.openhands/mcp.json` and *also* spliced into `~/.openhands/settings.json` (V1's runtime config) on each launch. |
| `README.md` | This file. |

And in `scripts/`:

| Script | Purpose |
| --- | --- |
| `upgrade-openhands.sh` | Stops the old 0.38 container, backs up `~/.openhands-state`, pulls 1.6.0. |
| `start-openhands.sh` | Stages Linux `bun`, launches `ashlr-openhands` container. |
| `stop-openhands.sh` | Stops and removes the container. |

## First-run config

`start-openhands.sh` writes the LLM and MCP settings into
`~/.openhands/settings.json` on every launch (the same file the Web UI
edits). On first run you should still verify in the GUI:

1. Open http://localhost:3000.
2. Click **Settings** (gear icon).
3. Confirm values (pre-filled by the launcher):
   - **Custom Model**: `openai/qwen/qwen3-coder-30b`
   - **Base URL**: `http://host.docker.internal:1234/v1`
   - **API Key**: `local-llm`
4. Go to **Settings → MCP** and verify all 10 ashlr servers are listed and
   green. If not, see [Troubleshooting](#troubleshooting).

> **Why we splice settings.json:** OpenHands V1 (1.x) deprecated the legacy
> `config.toml` for runtime configuration. The Web Settings UI writes to
> `~/.openhands/settings.json` and that's the only place the agent reads
> MCP and LLM config from at boot. We mount our `mcp.json` into the state
> dir for human reference + future-proofing, but `start-openhands.sh` also
> programmatically merges its `mcp_config` block into `settings.json` so
> servers light up immediately, no clicking required.

## MCP tools available to the agent

Once the 10 servers connect, the OpenHands agent will see these tools (names
match what the ashlr-plugin exposes to Claude Code):

| Server | Tools |
| --- | --- |
| `ashlr-efficiency` | `ashlr__read`, `ashlr__grep`, `ashlr__edit`, `ashlr__savings` |
| `ashlr-bash` | `ashlr__bash`, `ashlr__bash_start`, `ashlr__bash_stop`, `ashlr__bash_list`, `ashlr__bash_tail` |
| `ashlr-tree` | `ashlr__tree` |
| `ashlr-http` | `ashlr__http` |
| `ashlr-diff` | `ashlr__diff` |
| `ashlr-logs` | `ashlr__logs` |
| `ashlr-sql` | `ashlr__sql` |
| `ashlr-genome` | `ashlr__genome_propose`, `ashlr__genome_consolidate`, `ashlr__genome_status` |
| `ashlr-orient` | `ashlr__orient` |
| `ashlr-github` | `ashlr__pr`, `ashlr__issue` |

> **Note on "12 servers":** the kickoff brief mentioned 12 servers, but
> `ashlr-plugin/.claude-plugin/plugin.json` declares 10. We register all 10.
> If the plugin grows, add entries to `mcp.json` using the same pattern.

## How the MCP wiring works (important!)

The OpenHands 1.6 container is a slim Python image — no Node, no Bun. But
ashlr's MCP servers are TypeScript files that need Bun. To keep the servers
running *inside* the OpenHands container (stdio transport), `start-openhands.sh`
does the following:

1. **Stages a Linux-aarch64 `bun` binary** under `~/.cache/ashlr-workbench/bun-linux-aarch64/bun`.
   The host's `bun` is macOS Mach-O and can't run in a Linux container.
2. **Mounts that binary** read-only at `/host/bun` inside the container.
3. **Mounts the plugin directory** (`~/Desktop/ashlr-plugin`) read-only at
   `/host/ashlr-plugin`.
4. **Runs `bun install` on the host** against the plugin so `node_modules`
   is present when the container spawns a server.
5. `mcp.json` entries invoke `bash -c "cd /host/ashlr-plugin && exec /host/bun/bun run servers/<name>-server.ts"`.

**Tradeoff vs. TCP transport**: we considered running MCP servers on the
host and exposing them via `host.docker.internal:<port>`. That requires
wrapping each stdio server in an HTTP/SSE bridge. The chosen approach
keeps things stdio-native at the cost of staging a Linux bun binary and
cross-platform plugin mount. Stdio wins on simplicity for a single dev.

## Container mounts reference

| Host | Container | Mode | Why |
| --- | --- | --- | --- |
| `/var/run/docker.sock` | `/var/run/docker.sock` | rw | OpenHands needs this to spawn its agent-server sandbox container. |
| `~/.openhands` | `/.openhands` | rw | V1 state dir (conversations, settings, secrets, copied config.toml + mcp.json). |
| `~/Desktop` | `/workspace` | rw | Default working area for the agent. |
| `~/Desktop/ashlr-plugin` | `/host/ashlr-plugin` | ro | Source of the MCP server `.ts` files + `node_modules/`. |
| `~/.cache/ashlr-workbench/bun-linux-aarch64` | `/host/bun` | ro | Linux bun runtime (host bun is macOS Mach-O, can't be reused). |

> Note: we *don't* mount `agents/openhands/config.toml` or `mcp.json` as
> individual file mounts — Docker Desktop's virtiofs refuses to nest a
> file mount inside an already-bind-mounted directory. The launcher
> copies them in instead.

## Troubleshooting

### Docker daemon not running
```
[start] Docker daemon not running. Start Docker Desktop.
```
Open Docker Desktop and wait for the whale icon to go solid.

### LM Studio not responding
```
[start] LM Studio not reachable at http://localhost:1234/v1/models
```
- Open LM Studio.
- Verify server is running (Developer tab → "Status" toggle ON).
- Verify a model is loaded (`qwen/qwen3-coder-30b` in the top-left dropdown).
- Check port 1234 isn't blocked: `curl http://localhost:1234/v1/models`.

### Model not loaded
The GUI works but chat errors with `litellm.BadRequestError: model not found`.
1. In LM Studio: Developer tab → ensure `qwen/qwen3-coder-30b` (or a model
   whose API identifier matches what's in `start-openhands.sh` `LLM_MODEL`)
   is loaded.
2. `curl http://localhost:1234/v1/models` to confirm the id.
3. If the id differs, edit `LLM_MODEL` in `scripts/start-openhands.sh` and
   restart.

### MCP server shows "failed" in Settings → MCP
Check the OpenHands logs for the offending server name:
```bash
docker logs ashlr-openhands --tail 100 | grep -i mcp
```
Common causes:
- **`/host/bun/bun: not found`**: the Linux bun stage didn't run. Delete
  `~/.cache/ashlr-workbench/bun-linux-aarch64` and re-run
  `./scripts/start-openhands.sh`.
- **`Cannot find module '@modelcontextprotocol/sdk'`**: the host `bun install`
  didn't run. From a shell on the host:
  ```bash
  cd ~/Desktop/ashlr-plugin && bun install
  ```
  then restart OpenHands.
- **`Permission denied`**: on the bun binary — `chmod +x ~/.cache/ashlr-workbench/bun-linux-aarch64/bun`.

### GUI never comes up on port 3000
```bash
docker logs ashlr-openhands --tail 100
```
Look for `INFO: Uvicorn running on http://0.0.0.0:3000`. If absent:
- Port 3000 is taken: `lsof -i :3000`. Either free it or edit `PORT` in
  `start-openhands.sh`.
- Image pull failed: `docker pull ghcr.io/openhands/openhands:1.6.0` and
  inspect the error.

### Container name already in use
```
docker: Error response from daemon: Conflict. The container name "/ashlr-openhands" is already in use
```
Run `./scripts/stop-openhands.sh` then `./scripts/start-openhands.sh`.

### Old 0.38 container still running
`./scripts/upgrade-openhands.sh` stops any container whose image contains
`openhands`. If you've renamed yours, stop it manually:
```bash
docker stop <name> && docker rm <name>
```

## Known gaps / follow-ups

- **12 vs 10 servers**: the brief mentioned 12, plugin ships 10
  (efficiency, sql, bash, tree, http, diff, logs, genome, orient, github).
  Reconcile with the ashlr-plugin roadmap before adding placeholders.
- **GitHub org rename**: the project moved from `All-Hands-AI/OpenHands` to
  `OpenHands/OpenHands` and the image from `ghcr.io/all-hands-ai/openhands`
  to `ghcr.io/openhands/openhands` between 0.x and 1.x. The upgrade script
  handles both names by matching on substring.
- **config.toml is ~deprecated in V1**: OpenHands 1.6 logs
  `config.toml not found` even when the file exists at `/.openhands/config.toml`
  because V1 looks for it relative to its CWD, and most keys have moved to
  env vars + `settings.json`. The `config.toml` we ship is **documentation**
  of what each setting does — `start-openhands.sh` env vars and the
  programmatic `settings.json` splice are the source of truth.
- **`OLLAMA_CONTEXT_LENGTH=32768`**: included per brief, even though we're
  on LM Studio not Ollama. It's a no-op with LM Studio but future-proofs
  the script if someone swaps the backend.
- **Image tag `1.6.0` vs `docker.openhands.dev/openhands/openhands:1.6`**:
  both resolve to the same manifest today. We use the ghcr form to stay
  explicit about the registry.
- **Linux-aarch64 only**: the staged bun binary is
  `bun-linux-aarch64`. On an Intel Mac (or a Linux x86 host running Docker
  containers as amd64), edit `BUN_VERSION_URL` in `start-openhands.sh`
  to grab `bun-linux-x64.zip` instead.

## Useful commands

```bash
# Tail logs
docker logs -f ashlr-openhands

# Shell into the container
docker exec -it ashlr-openhands bash

# Inside the container, test an MCP server manually:
#   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bash -c "cd /host/ashlr-plugin && /host/bun/bun run servers/efficiency-server.ts"

# Check state dir
ls -la ~/.openhands

# Nuke state and start fresh (destructive!)
./scripts/stop-openhands.sh && rm -rf ~/.openhands && ./scripts/start-openhands.sh
```
