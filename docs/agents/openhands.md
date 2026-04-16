# OpenHands

Sandboxed, web-based, autonomous agent. The workbench's **long-horizon**
worker — happy to run unattended for an hour on a multi-step task.

## What it is

[OpenHands](https://github.com/All-Hands-AI/OpenHands) is a containerized
coding agent with a browser UI. It runs in Docker, mounts your workspace
as a volume, and iterates command-by-command (bash, file ops, web browse,
MCP tool calls) until the task is done or it fails gracefully.

The workbench runs OpenHands 1.6 with the
`docker.openhands.dev/openhands/openhands:1.6` image, points it at
**LM Studio** running Qwen3-Coder-30B, and wires in all 10 ashlr-plugin
MCP servers.

Config lives in:

- `agents/openhands/config.toml` — legacy V0 config, still read by V1 for
  some keys. Authoritative runtime settings are env vars in the launcher.
- `agents/openhands/mcp.json` — mounted at `/.openhands/mcp.json` inside
  the container. Registers the 10 MCP servers.
- `scripts/start-openhands.sh` — container bootstrap: stages a
  Linux-aarch64 bun binary, mounts the plugin read-only, launches
  `ashlr-openhands` on :3000.
- `scripts/stop-openhands.sh` — graceful stop + container removal.

## When to use it

1. **End-to-end tasks.** "Scaffold a CI workflow, open a PR, don't merge."
   OpenHands happily does all three steps across git, file edits, and
   `gh` without you in the loop.
2. **Multi-hour refactors.** With `auto` approval and a thinking model,
   OpenHands can work on a task while you go to lunch.
3. **Environment-heavy work.** Need a sandboxed place to `npm install`
   sketchy packages, or run a database migration you can't test on your
   host? The container gives you that isolation.
4. **Browser-assisted tasks.** OpenHands ships a headless browser. "Open
   this doc, copy the schema, generate a Zod parser" works because the
   agent can actually read the page.
5. **Parallel agents.** You can run OpenHands on one task while using
   Goose or Aider interactively on another.

## When NOT to use it

- **Small, known edits.** Aider is dramatically faster for "change line
  42 in foo.ts."
- **When you want to see and approve each diff.** OpenHands' approval
  UX is coarser than Aider's. Use confirmation mode if you really need
  gates, but Aider is better for this shape of work.
- **No Docker on the machine.** OpenHands requires Docker. No exceptions.
- **You need the host filesystem fully open.** OpenHands only sees what
  you mount into the container. Paths outside the mount are invisible.
- **Very low RAM budgets.** The container + Qwen3-Coder-30B pushes 30+ GB
  of resident memory in active use. On a 16 GB Mac this isn't viable.

## How to start it

```bash
# First-time (rebuilds to 1.6 if needed; pulls the image):
./scripts/upgrade-openhands.sh   # run once per major release

# Start:
aw start openhands
# Raw:
./scripts/start-openhands.sh

# Open UI:
open http://localhost:3000

# Stop:
aw stop openhands
./scripts/stop-openhands.sh
```

The start script's steps:

1. Check Docker is running.
2. Ensure the Linux-aarch64 bun binary is staged at
   `~/.cache/ashlr-workbench/bun-linux-aarch64/bun` (downloads on first run).
3. Kill any existing `ashlr-openhands` container.
4. `docker run` with:
   - `-p 3000:3000` — web UI.
   - Mounts: `~/.openhands`, `~/Desktop/ashlr-plugin:/host/ashlr-plugin:ro`,
     bun cache dir at `/host/bun:ro`, the workspace dir you pick.
   - Env: `LLM_*` vars pointing at `http://host.docker.internal:1234` for
     LM Studio, plus `SANDBOX_USE_HOST_NETWORK=false`.
   - Mounts `agents/openhands/config.toml` at `/.openhands/config.toml`.
   - Mounts `agents/openhands/mcp.json` at `/.openhands/mcp.json`.
5. Prints `OpenHands running on http://localhost:3000`.

## Config explained

### `config.toml` (inside container at `/.openhands/config.toml`)

Mostly V0-legacy settings; V1 reads env vars as authoritative. Kept in
the repo so settings are greppable.

```toml
[sandbox]
timeout = 120
use_host_network = false

[agent]
name = "CodeActAgent"            # Default agent. Thinking models: try others per OpenHands docs.
enable_prompt_extensions = true
enable_history_truncation = true
enable_mcp = true
mcp_config_path = "/.openhands/mcp.json"

[security]
confirmation_mode = false        # Off for local dev. Flip on if touching prod.
security_analyzer = ""
```

### `mcp.json` (inside container at `/.openhands/mcp.json`)

```json
{
  "mcpServers": {
    "ashlr-efficiency": {
      "command": "bash",
      "args": ["-c",
        "cd /host/ashlr-plugin && exec /host/bun/bun run servers/efficiency-server.ts"]
    },
    "ashlr-sql":     { ... },
    "ashlr-bash":    { ... },
    "ashlr-tree":    { ... },
    "ashlr-http":    { ... },
    "ashlr-diff":    { ... },
    "ashlr-logs":    { ... },
    "ashlr-genome":  { ... },
    "ashlr-orient":  { ... },
    "ashlr-github":  { ... }
  }
}
```

All 10 ashlr servers. The Supabase and Roblox MCPs that ashlrcode
registers are host-specific and are not mounted into the OpenHands
container (no credential plumbing).

### Env vars in `start-openhands.sh`

The file to audit when debugging "which model is OpenHands calling?":

```bash
LLM_BASE_URL=http://host.docker.internal:1234/v1
LLM_API_KEY=lm-studio
LLM_MODEL=openai/qwen/qwen3-coder-30b    # V1 uses litellm model naming
```

To swap to Claude: set `LLM_BASE_URL=https://api.anthropic.com/v1`,
`LLM_API_KEY=$ANTHROPIC_API_KEY`, `LLM_MODEL=anthropic/claude-3-7-sonnet-20250219`
and restart.

## Using the UI

First-time setup after a fresh `aw start openhands`:

1. Visit `http://localhost:3000`.
2. Settings → LLM: confirm provider is "LM Studio" (or matches the env
   vars from the launcher).
3. Settings → MCP: should show 10 `ashlr-*` servers as healthy.
4. New Chat. Attach a workspace path (e.g. `/workspace/ashlr-plugin` —
   whatever you mounted).
5. Enter a task, hit submit.

Useful UI patterns:

- **Stop** mid-task with the red stop button. State is preserved.
- **Continue** by saying "continue from where you left off" — the agent
  has access to the prior event log.
- **Confirmation mode** toggle in Settings → Security: flip this on if
  you want per-action approval. Slows things down a lot; use for prod.
- **Download artifacts** via the Files tab on the right. OpenHands shows
  all touched files, with diffs.

## Worked examples

### 1. "Add CI on push"

Task you type into the chat:

```
Add a GitHub Actions workflow .github/workflows/test.yml that:
 - runs on push and pull_request
 - checks out the repo
 - sets up Bun via oven-sh/setup-bun@v1
 - runs `bun install` then `bun test`
Open a PR titled "ci: add bun test workflow". Do not merge.
```

Expected behavior: OpenHands writes the file, `git checkout -b`, commits,
pushes, calls `gh pr create`, prints the URL. Runtime: 3–10 min on
local Qwen.

### 2. "Find and fix a bug"

```
There's a bug where session expiry is computed in UTC but compared in
local time somewhere in the auth module. Find it, fix it, add a test,
and leave the fix on a branch named bugfix/session-tz.
```

OpenHands grep-greps via `ashlr__grep`, reads candidate files, proposes
a fix, writes a test, runs `bun test`, iterates until green, and
switches to the branch.

### 3. "Upgrade a dependency"

```
Bump the version of @modelcontextprotocol/sdk to the latest stable.
Run the type-check and fix any breakage. Don't commit; leave changes
staged.
```

Good task for OpenHands because it involves: `bun update`, type error
loop, small edits across several files, re-run tests.

## Integration points

- **LLM.** `LLM_BASE_URL` + `LLM_API_KEY` + `LLM_MODEL` env vars. Points
  at LM Studio by default. Host access uses `host.docker.internal`.
- **MCP.** 10 ashlr servers over stdio, spawned inside the container.
  The plugin dir is mounted read-only at `/host/ashlr-plugin`; a
  Linux-native bun lives at `/host/bun/bun`.
- **Filesystem.** Only mounted paths are visible. Workspace dir is
  mounted rw; the plugin dir is ro.
- **Git + GitHub.** `gh` is pre-installed in the image. Authenticate
  in-UI (Settings → Git) or mount your `~/.gh` / SSH config if you want
  host auth.
- **Hooks.** No OpenHands hook integration with the workbench today.
  Hooks exist in ashlr-plugin but are Claude-Code-specific.

## Known limitations

- **First-turn latency can be 30+ seconds** while the container warms up
  its file-system cache and MCP servers start cold.
- **Cold-start image pull** on first launch is ~2 GB. One-time cost.
- **No seamless resume after container stop.** `aw stop openhands` kills
  the container. Session event log is persisted in `~/.openhands/` but
  you may need to "continue" manually in a new session.
- **Thinking models need more context.** If you swap to
  Claude-Sonnet-thinking, bump `timeout` in `config.toml` to 300+.
- **Network inside the sandbox is bridge-mode** by default. Hosts in the
  sandbox reach your Mac via `host.docker.internal`, not `localhost`.
  LM Studio, Ollama, your dev server — all reachable only via that
  hostname.
- **Container eats disk.** `docker system df` periodically and prune when
  over 30 GB.
- **Env vars change per major release.** OpenHands 1.x → 2.x may rename
  `LLM_*`. Re-read the upstream docs before upgrading.

## Upstream references

- OpenHands docs: https://docs.openhands.dev
- Local LLM setup: https://docs.openhands.dev/openhands/usage/llms/local-llms
- MCP in OpenHands: https://docs.openhands.dev/overview/model-context-protocol
- V1 release notes: https://github.com/All-Hands-AI/OpenHands/releases
- Workbench `agents/openhands/README.md` — exact launch commands and
  container tags.

## See also

- `docs/troubleshooting.md` → OpenHands section for "won't start",
  "stalls mid-task", and MCP failure modes.
- `docs/workflows.md` → recipes #1 and #4 use OpenHands.
