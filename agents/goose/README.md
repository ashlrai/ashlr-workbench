# Goose (in ashlr-workbench)

[Goose](https://github.com/aaif-goose/goose) is the Linux Foundation AAIF fork of the original Block Goose — an open-source, MCP-native, Rust-based AI agent that runs locally and connects to any LLM. It's Apache-2.0 licensed with no telemetry.

## Why Goose lives in this workbench

Each agent in `/agents` solves a different shape of problem:

- **Goose** — the daily driver for tool-heavy, interactive work. Fast startup, MCP-native, approves actions per-turn by default. Best for "write this function, run the tests, fix the error, run them again" loops where you want to see each step.
- **OpenHands** — long-horizon autonomy. Runs in a sandboxed container, is happy to work for an hour unattended, and is the right call when the task is "build this whole feature end-to-end, I'll review the PR." Heavier to start; ships its own VS Code.
- **Aider** — pair-programming over git. Best when you know exactly which files to edit and want the agent to propose atomic commits you review before accepting. Terminal-first, git-native, no MCP.
- **ashlrcode** — Mason's published npm CLI. Opinionated defaults baked in (genome RAG, token-efficient tools, savings telemetry); use when you want the full ashlr stack without configuring anything.

Rule of thumb: **start here with Goose**. Escalate to OpenHands if the work is long-horizon. Drop down to Aider if you want tighter diff-review discipline.

## Quick start

```bash
# 1. First-time install (prints the command; pass --yes to execute)
./scripts/install-goose.sh --yes

# 2. Start LM Studio, load qwen/qwen3-coder-30b, start the server on :1234

# 3. Launch a session
./scripts/start-goose.sh
```

The start script:
- Materializes `agents/goose/config.yaml` → `agents/goose/config/config.yaml` with `${ASHLR_PLUGIN_ROOT}` expanded
- Sets `GOOSE_PATH_ROOT=agents/goose` so Goose reads the workbench config without touching your global `~/.config/goose/config.yaml`
- Disables the macOS keychain lookup so the placeholder LM Studio "key" is honored
- `cd`s into `~/Desktop` (override with `GOOSE_WORKSPACE=...`)

## MCP tools available in every session

All 10 ashlr-plugin servers are registered as Goose extensions:

| Extension          | Tool surface                                               | When to use                                                             |
| ------------------ | ---------------------------------------------------------- | ----------------------------------------------------------------------- |
| `ashlr-efficiency` | `read`, `grep`, `edit`, `savings`                          | Default. Token-efficient replacements for the builtin file/search tools |
| `ashlr-sql`        | Read-only SQL against SQLite/Postgres/MySQL                | Inspecting app databases without leaving the session                    |
| `ashlr-bash`       | `bash`, `bash_start`, `bash_tail`, `bash_stop`, `bash_list` | Running commands, background processes (dev servers, watchers)          |
| `ashlr-tree`       | Directory tree with smart depth                            | Orienting in an unfamiliar repo                                         |
| `ashlr-http`       | HTTP fetch + summarization                                 | Pulling docs / API responses without blowing context                    |
| `ashlr-diff`       | Unified diffs between files/commits/strings                | Reviewing changes before edits, comparing configs                       |
| `ashlr-logs`       | Log tail/grep with truncation                              | Investigating dev-server or CI output                                   |
| `ashlr-genome`     | `genome_propose`, `genome_consolidate`, `genome_status`    | Building / refreshing the RAG index on a repo                           |
| `ashlr-orient`     | One-shot "what is this repo"                               | First turn in any new repo                                              |
| `ashlr-github`     | PR + issue reader (uses local `gh` auth)                   | Cross-referencing commits, reading PR discussions                       |

Plus Goose's `developer` builtin (file read/write, shell, text editor) as the guaranteed fallback.

### Picking the right tool

- **Before editing a file**: `ashlr__read` (token-efficient snip-compact view) over `developer` read for files >2KB
- **Searching code**: `ashlr__grep` — routes through the genome RAG index if one exists, otherwise falls back to raw grep
- **Running commands**: `ashlr__bash` for one-shot, `ashlr__bash_start` when you need a long-running process (dev server)
- **New-repo orientation**: `ashlr__orient` first, then `ashlr__tree` for structure
- **Before committing**: `ashlr__diff` to spot-check what you're about to commit

## Configuration

The authoritative config is `agents/goose/config.yaml`. Edit it, re-run `start-goose.sh`, and changes take effect. Do not edit `agents/goose/config/config.yaml` — it's regenerated on every launch.

Common edits:

- **Change model**: `GOOSE_MODEL` — must match an id reported by `curl http://localhost:1234/v1/models`
- **Swap provider**: Set `GOOSE_PROVIDER` + the provider's env vars. Anthropic, OpenAI, Ollama, Bedrock, etc. are all supported — see [Goose providers docs](https://goose-docs.ai/docs/getting-started/providers)
- **Disable an extension**: Set `enabled: false` under its block
- **More autonomy**: `GOOSE_MODE: "auto"` (skips approval prompts). `smart_approve` is the safer default.

## Troubleshooting

**"Error: goose is not installed"**
Run `./scripts/install-goose.sh --yes`. On macOS with Homebrew this pulls `block-goose-cli`; otherwise it uses the official curl installer from the aaif-goose releases.

**"LM Studio doesn't appear to be serving on localhost:1234"**
Open LM Studio → Developer tab → click "Start Server". Verify with `curl http://localhost:1234/v1/models` — you should see `qwen/qwen3-coder-30b` in the list. Load it into memory (click the model in the sidebar) before asking Goose to do anything — the first request otherwise blocks for ~30s while the model loads, which sometimes times out at Goose's HTTP layer.

**"The number of tokens to keep from the initial prompt is greater than the context length"**
LM Studio loaded Qwen3-Coder-30B with a context window smaller than Goose's initial prompt (system prompt + 10 MCP tool schemas ≈ 15–25k tokens). In LM Studio, open the model's settings (gear icon on the loaded model) and raise **Context Length** to at least 32768, preferably 65536. Re-load the model after changing. If your Mac doesn't have enough unified memory for a 64k context, temporarily disable extensions you're not using by setting `enabled: false` in `agents/goose/config.yaml`.

**An MCP extension fails to start**
The ashlr-plugin servers self-install their `node_modules` on first launch via `mcp-entrypoint.sh`. If one fails:
1. Check `ASHLR_PLUGIN_ROOT` is set correctly (default: `~/Desktop/ashlr-plugin`)
2. Run `cd "$ASHLR_PLUGIN_ROOT" && bun install` manually
3. Confirm `bun` is on PATH (`which bun`)
4. Restart the Goose session — extensions only reload on session start

**"OPENAI_API_KEY not found"**
The keyring lookup is disabled by `start-goose.sh` (via `GOOSE_DISABLE_KEYRING=1`), so Goose should read `lm-studio` from the config. If you see this error, you're probably launching `goose session` directly instead of via `start-goose.sh` — use the script.

**Goose wrote to `~/.config/goose/config.yaml` instead of ours**
You ran `goose configure` outside the workbench. That writes to the default path. To reset: `rm ~/.config/goose/config.yaml` and re-launch via `start-goose.sh`. Settings made through `/configure` inside a session write to `$GOOSE_PATH_ROOT/config/config.yaml` (which is our runtime copy and gets overwritten on next launch — edit `agents/goose/config.yaml` for persistent changes).

**Slow first tool call**
The first call to a bun-based MCP server takes 1–3s to warm up the ts runtime. Subsequent calls are <100ms. This is expected.

## Further reading

- [Goose AAIF repo](https://github.com/aaif-goose/goose)
- [Goose docs](https://goose-docs.ai)
- [ashlr-plugin](https://github.com/ashlrai/ashlr-plugin) — the MCP servers wired up above
- [Workbench agents overview](../../README.md)
