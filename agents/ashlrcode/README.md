# ashlrcode — Ashlr Workbench

[ashlrcode](https://www.npmjs.com/package/ashlrcode) (`ac` for short) is
Mason's own multi-provider AI coding CLI — a Claude-Code-style REPL that
speaks xAI Grok, Anthropic, OpenAI, and any OpenAI-compatible endpoint (like
LM Studio). Inside this workbench it's wired with an overlay that keeps your
personal `~/.ashlrcode/` intact while registering the workbench's MCP servers.

## Why it's in this workbench

ashlrcode is the workbench's **MCP-rich, multi-provider agent**:

- **You own it.** It's Mason's published CLI, so the workbench eats its own
  dog food.
- **Multi-provider.** Primary = xAI Grok (`grok-4-1-fast-reasoning`). Fallback
  = local LM Studio running `qwen/qwen3-coder-30b` for when you want
  on-device inference or the network is unavailable.
- **MCP-native.** All 10 `ashlr-plugin` MCP servers plus `supabase` and
  `roblox-studio` are registered up front, so the agent has `ashlr__read`,
  `ashlr__grep`, `ashlr__edit`, `ashlr__sql`, `ashlr__bash`, `ashlr__tree`,
  `ashlr__http`, `ashlr__diff`, `ashlr__logs`, `ashlr__orient`, genome, and
  GitHub tools on day one.

## What's configured here

| File | Purpose |
|---|---|
| `agents/ashlrcode/settings.json` | Workbench-specific ashlrcode settings — provider config, hooks, MCP servers, permission rules |
| `scripts/start-ashlrcode.sh` | Launcher that points ashlrcode at the workbench config dir without clobbering `~/.ashlrcode/` |

The overlay layers on top of user defaults:

- **Providers.** Primary remains xAI Grok (`grok-4-1-fast-reasoning`). A new
  `fallbacks[0]` entry adds LM Studio (`http://localhost:1234/v1` with
  `qwen/qwen3-coder-30b`) so you can `/model` swap to local.
- **Hooks.** Same safety hooks as the user's global config —
  deny `rm -rf`, deny `.env` reads, ask before `git push` / `npm publish`.
- **MCP servers (12).** `ashlr-efficiency`, `ashlr-sql`, `ashlr-bash`,
  `ashlr-tree`, `ashlr-http`, `ashlr-diff`, `ashlr-logs`, `ashlr-genome`,
  `ashlr-orient`, `ashlr-github`, `supabase`, `roblox-studio`.
- **Permissions.** `approveMode: default` — agent asks before Write/Edit/Bash
  unless a `permissionRules` entry pre-authorizes it.

### Secrets

`settings.json` is committed to a **public** repo, so it never embeds raw
credentials. Instead it references three env vars:

- `XAI_API_KEY` — primary provider key
- `SUPABASE_ACCESS_TOKEN` — for the Supabase MCP server
- `SUPABASE_PROJECT_REF` — Supabase project to scope the MCP to

`scripts/start-ashlrcode.sh` loads them in this order (later sources do **not**
override earlier ones):

1. `$WORKBENCH/.env` (workbench-local, add to `.gitignore`)
2. `~/.ashlrcode/.env` (user-global)
3. As a last resort, the launcher greps `XAI_API_KEY` out of your existing
   `~/.ashlrcode/settings.json` so the global config keeps working unchanged.

Create a workbench `.env` once:

```bash
cat > /Users/masonwyatt/Desktop/ashlr-workbench/.env <<'EOF'
XAI_API_KEY=xai-...
SUPABASE_ACCESS_TOKEN=sbp_...
SUPABASE_PROJECT_REF=fceiheizgpujpeedgypn
EOF
chmod 600 /Users/masonwyatt/Desktop/ashlr-workbench/.env
```

Make sure `.env` is gitignored at the workbench root before committing
anything else.

## Quickstart

```bash
# Start an interactive REPL with workbench settings
./scripts/start-ashlrcode.sh

# One-shot message
./scripts/start-ashlrcode.sh "audit agents/ for stale configs"

# Resume the last session in this dir
./scripts/start-ashlrcode.sh --continue

# Quick sanity check
./scripts/start-ashlrcode.sh --help
```

The launcher sets two env vars before `exec`'ing `ashlrcode`:

- `ASHLRCODE_CONFIG_DIR=agents/ashlrcode` — primary mechanism for ashlrcode
  v2.1+ to pick up the overlay dir.
- `ASHLR_MCP_EXTRA=<path to settings.json>` — advisory fallback for builds
  that merge an extra MCP config onto `~/.ashlrcode/settings.json`.

Your personal `~/.ashlrcode/settings.json` is **never modified**. Drop the
env vars (or just run `ashlrcode` directly) to go back to the global config.

## Useful REPL commands

| Command | Effect |
|---|---|
| `/plan` | Enter plan mode (read-only exploration, writes to a plan file) |
| `/cost` | Show token usage + cost this session |
| `/compact` | Summarize conversation to free context |
| `/sessions` | List saved sessions |
| `/model` | Show / switch active model (primary vs fallback) |
| `/clear` | Clear conversation |
| `/help` | Full command list |

## When to use this vs Aider vs OpenHands vs Goose

| Pick | If you want... |
|---|---|
| **ashlrcode** | Claude-Code-style multi-tool agent with MCP, plan mode, and your choice of frontier LLM (Grok) or on-device (LM Studio). Best for exploratory work that benefits from MCP tools (SQL, HTTP, genome RAG). |
| **Aider** | Targeted, git-native surgical edits with reviewable diffs. Pairs well with ashlrcode — use ashlrcode to explore and plan, Aider to execute the edits. |
| **OpenHands** | Sandboxed VM, autonomous long-horizon tasks, web browsing. |
| **Goose** | Block's MCP-first agent with a different extension ecosystem — useful for comparing MCP tool behavior across runtimes. |

## Troubleshooting

**`XAI_API_KEY` not set / primary provider fails**
The key is embedded in the overlay, but env wins. Export
`XAI_API_KEY=<your-key>` or run `./scripts/start-ashlrcode.sh` which will
auto-pull it from `~/.ashlrcode/settings.json` if the env var is empty.

**MCP servers show as "failed to start"**
Each `ashlr-*` server runs from `/Users/masonwyatt/Desktop/ashlr-plugin/`.
Check the plugin is present and up to date:
```bash
cd ~/Desktop/ashlr-plugin && git pull && bun install
```
Then confirm the entrypoint is executable:
```bash
ls -l ~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh
```

**Want to skip MCP on startup** (fast REPL boot)
```bash
./scripts/start-ashlrcode.sh --no-mcp
```

**Fallback to local LM Studio**
Make sure LM Studio is serving on `localhost:1234` with
`qwen/qwen3-coder-30b` loaded, then inside the REPL:
```
/model lmstudio-local
```
(or edit `settings.json` to make it primary).

**Overlay not loading**
Older ashlrcode builds ignore `ASHLRCODE_CONFIG_DIR`. Run
`ashlrcode --version` — if it reports `< 2.1.0`, upgrade:
```bash
bun install -g ashlrcode@latest
```

**Clobbered personal config?**
The launcher never writes to `~/.ashlrcode/`. If you ever hand-edit
`agents/ashlrcode/settings.json` and want to sync changes back to your
global config, copy explicitly — there is no auto-sync.

## References

- ashlrcode on npm: https://www.npmjs.com/package/ashlrcode
- ashlr-plugin (MCP servers): https://github.com/ashlrai/ashlr-plugin
- Claude Code MCP docs: https://docs.claude.com/en/docs/claude-code/mcp
