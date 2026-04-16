# ashlrcode

Multi-provider, MCP-native, Claude-Code-style REPL. Mason's own published
CLI, wired as a fallback-friendly daily agent inside the workbench.

## What it is

[ashlrcode](https://www.npmjs.com/package/ashlrcode) (`ac` for short) is
a Node/Bun-based coding agent with a Claude-Code-compatible UX. It speaks
xAI Grok, Anthropic, OpenAI, and any OpenAI-compatible endpoint, and ships
with first-class MCP support, plan mode, per-rule permission gates, and
session persistence.

Config lives in:

- `agents/ashlrcode/settings.json` — workbench overlay. Adds LM Studio
  as a fallback and registers the 12 MCP servers.
- `scripts/start-ashlrcode.sh` — launcher that points ashlrcode at the
  overlay via `ASHLRCODE_CONFIG_DIR`, without touching your personal
  `~/.ashlrcode/settings.json`.

The workbench explicitly does not modify your home-dir config. You can
drop the env vars at any point and go back to global ashlrcode.

## When to use it

1. **"I want Claude Code for my own stack."** If you like Claude Code's
   ergonomics (plan mode, `/compact`, `/cost`, session resume) but want
   to pick Grok or local Qwen for the LLM, ashlrcode is the answer.
2. **Planning before edits.** `/plan` is read-only; it surveys the repo
   and produces a plan file. Feed that plan to Aider for the edits.
3. **Fast iteration over mid-complexity tasks.** Grok at speed is a
   sweet spot for "implement this helper, write a test, adjust the
   caller."
4. **Multi-provider work.** Swap between Grok (fast cloud) and LM Studio
   (private local) mid-session with `/model`. Useful when you realize
   the task is sensitive and you should go local.
5. **MCP-heavy sessions that need Supabase / Roblox / custom servers.**
   ashlrcode's overlay registers more MCP servers than the other agents
   by default, including `supabase` and `roblox-studio` for those
   workflows.

## When NOT to use it

- **Deep search-replace refactors.** Aider's edit format is stricter
  and less prone to hallucinated diffs than ashlrcode's.
- **Autonomous multi-hour tasks.** OpenHands is the right choice.
- **If you have not set `XAI_API_KEY`** and you don't want to fall back
  to LM Studio. ashlrcode won't run without at least one working
  provider.

## How to start it

```bash
# Interactive REPL:
aw start ashlrcode

# One-shot message (echoes and exits):
aw start ashlrcode --prompt "Summarize this repo in 5 bullets."

# Resume the last session in this dir:
aw start ashlrcode -- --continue

# Raw launcher:
./scripts/start-ashlrcode.sh
./scripts/start-ashlrcode.sh "fix the null-deref in src/foo.ts"
./scripts/start-ashlrcode.sh --help
```

Launcher behavior:

1. Exports `ASHLRCODE_CONFIG_DIR=agents/ashlrcode` — ashlrcode ≥ 2.1 picks
   this up and reads `settings.json` from there.
2. Exports `ASHLR_MCP_EXTRA=<path to settings.json>` — advisory fallback
   for older builds that merge an extra MCP config path.
3. If `XAI_API_KEY` is empty, tries to extract it from your personal
   `~/.ashlrcode/settings.json` as a soft fallback.
4. `exec ashlrcode "$@"`.

## Config explained

Trimmed shape of `agents/ashlrcode/settings.json`:

```json
{
  "providers": {
    "primary": {
      "provider": "xai",
      "apiKeyEnvVar": "XAI_API_KEY",
      "model": "grok-4-1-fast-reasoning",
      "baseURL": "https://api.x.ai/v1"
    },
    "fallbacks": [
      {
        "provider": "openai",
        "apiKey": "lm-studio",
        "model": "qwen/qwen3-coder-30b",
        "baseURL": "http://localhost:1234/v1",
        "label": "lmstudio-local"
      }
    ]
  },

  "maxTokens": 8192,
  "approveMode": "default",        // default | auto | strict
  "autoAcceptEdits": false,
  "dangerouslySkipPermissions": false,

  "hooks": {
    "preToolUse": [
      { "toolName": "Bash", "inputPattern": "rm -rf",   "action": "deny",
        "message": "Refusing rm -rf — destructive command blocked" },
      { "toolName": "Read", "inputPattern": "\\.env",   "action": "deny" },
      { "toolName": "Bash", "inputPattern": "git push", "action": "ask"  },
      { "toolName": "Bash", "inputPattern": "npm publish", "action": "ask" },
      { "toolName": "Bash", "inputPattern": "npm run test:", "action": "allow" }
    ],
    "sessionStart": [
      { "command": "bash ~/.claude/scripts/auto-sync.sh", "timeout": 15000 }
    ]
  },

  "mcpServers": {
    "ashlr-efficiency": { ... },   // 10 ashlr servers
    "ashlr-sql":        { ... },
    "ashlr-bash":       { ... },
    "ashlr-tree":       { ... },
    "ashlr-http":       { ... },
    "ashlr-diff":       { ... },
    "ashlr-logs":       { ... },
    "ashlr-genome":     { ... },
    "ashlr-orient":     { ... },
    "ashlr-github":     { ... },
    "supabase":         { "command": "npx", "args": ["-y", "@supabase/mcp-server-supabase", ...] },
    "roblox-studio":    { "command": "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP", ... }
  },

  "permissionRules": [
    { "tool": "Bash(npm run test:*)",  "action": "allow" },
    { "tool": "Bash(bun run build:*)", "action": "allow" },
    { "tool": "Bash(git diff:*)",      "action": "allow" },
    { "tool": "Bash(curl:*)",          "action": "allow" },
    { "tool": "Read(.env*)",           "action": "deny"  },
    { "tool": "Bash(rm -rf:*)",        "action": "deny"  }
  ]
}
```

Highlights:

- **Primary is xAI Grok.** Swap by editing `providers.primary` or adding
  to `fallbacks`.
- **LM Studio is the explicit fallback** for offline or sensitive work.
  `/model lmstudio-local` in the REPL to switch.
- **12 MCP servers total** — 10 ashlr + `supabase` + `roblox-studio`.
  Adjust freely.
- **Hooks mirror Mason's global config.** Same safety net — deny
  `rm -rf`, deny reading `.env`, ask before `git push`.
- **Secrets via env var.** `${XAI_API_KEY}`, `${SUPABASE_ACCESS_TOKEN}`,
  `${SUPABASE_PROJECT_REF}`. Export in your shell or a gitignored
  `.env`.

## Common commands inside ashlrcode

| Command                 | Effect                                           |
|-------------------------|--------------------------------------------------|
| `/plan`                 | Read-only plan mode; writes to a `plan.md`       |
| `/plan-continue`        | Execute steps from the last plan                 |
| `/model`                | Show active model                                |
| `/model <label>`        | Switch to fallback (e.g. `lmstudio-local`)       |
| `/cost`                 | Tokens + cost this session                       |
| `/compact`              | Summarize history to free context                |
| `/sessions`             | List prior sessions                              |
| `/resume <id>`          | Resume                                           |
| `/continue`             | Resume the last session in this dir              |
| `/mcp`                  | List MCP servers and their health                |
| `/hooks`                | Show loaded hooks                                |
| `/clear`                | Clear this session                               |
| `/help`                 | Full command list                                |
| `/exit` or `Ctrl-D`     | Quit                                             |

## Worked examples

### 1. Plan → edit handoff

```bash
aw start ashlrcode
> /plan
> What files would I touch to add a --json flag to ashlr__savings?
> /exit

# Grok has written a plan. Now switch to Aider:
aw start aider ~/Desktop/ashlr-plugin
> /add servers/efficiency-server.ts
> /add scripts/savings-dashboard.ts
> Apply the plan from ashlrcode: add --json output to ashlr__savings.
```

### 2. One-shot PR description

```bash
aw start ashlrcode --prompt "Read the staged git diff and write a
tight PR description with Summary and Test Plan sections. 80-char
lines. No emojis."
```

### 3. MCP-heavy session

```bash
aw start ashlrcode
> Use ashlr__orient to map out the auth module.
> Then ashlr__grep for all Supabase query sites.
> Use the `supabase` MCP to dump the schema of the users table.
> Suggest a migration that adds a `last_seen_at` timestamptz column.
```

### 4. Switching to local mid-session

```
> /model
primary: xai  (grok-4-1-fast-reasoning)
fallbacks:
  - lmstudio-local  (qwen/qwen3-coder-30b)

> /model lmstudio-local
(switched)

> Now tell me about this repo's secret-handling conventions.
```

## Integration points

- **LLM.** Multi-provider. Config in `providers.primary` + `fallbacks`.
  Env-var indirection via `apiKeyEnvVar`.
- **MCP.** 12 servers registered by the overlay. Easy to add more —
  append to `mcpServers`.
- **Hooks.** Standard Claude-Code-style hook shape (`preToolUse`,
  `postToolUse`, `sessionStart`). The overlay inherits Mason's safety
  hooks explicitly.
- **Permissions.** `approveMode: default` means ask before Write / Edit
  / Bash unless a `permissionRules` entry pre-authorizes. Flip to
  `auto` at your own risk.
- **Session state.** Lives in `~/.ashlrcode/sessions/` (per user) —
  the workbench overlay doesn't redirect this, so sessions you save
  in the workbench show up in your global `/sessions` listing. Deliberate.

## Known limitations

- **Overlay only works on ashlrcode ≥ 2.1.** Older builds ignore
  `ASHLRCODE_CONFIG_DIR`. `ashlrcode --version` to check; upgrade with
  `bun install -g ashlrcode@latest`.
- **`supabase` MCP needs env vars.** If you haven't exported
  `SUPABASE_ACCESS_TOKEN` and `SUPABASE_PROJECT_REF`, that one server
  will fail to start — the others are unaffected.
- **`roblox-studio` MCP is macOS-only.** Expects Roblox Studio at
  `/Applications/RobloxStudio.app`. Remove that entry if you don't use it.
- **Edit quality is model-bound.** On Grok or Claude, edits are great.
  On local Qwen3-Coder-30B, edits are solid but occasionally miss exact
  whitespace — less strict than Aider.
- **Plan mode writes a file.** `plan.md` in the current dir. Add to
  `.gitignore` if you don't want it tracked.
- **No built-in diff gating UI.** ashlrcode shows diffs inline and asks
  y/n; less elaborate than Aider's diff review.

## Upstream references

- ashlrcode on npm: https://www.npmjs.com/package/ashlrcode
- ashlrcode source (if published separately): check
  `package.json` of the installed version.
- ashlr-plugin (MCP servers): https://github.com/ashlrai/ashlr-plugin
- Claude Code MCP docs (analogous config shape):
  https://docs.claude.com/en/docs/claude-code/mcp

## See also

- `docs/workflows.md` — recipes #2, #4, #6 all feature ashlrcode.
- `docs/models.md` — how to pick between Grok and local Qwen.
- `docs/integration/mcp-servers.md` — adding a new MCP server to this
  overlay.
