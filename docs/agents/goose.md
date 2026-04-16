# Goose

MCP-native, Rust-based, fast-startup coding agent. The workbench's
**daily driver** for interactive, tool-rich sessions.

## What it is

[Goose](https://github.com/aaif-goose/goose) is the Linux Foundation AAIF
fork of Block's original Goose — an Apache-2.0, no-telemetry, MCP-first
agent. It approves actions per turn by default, has first-class extension
support, and reads an OpenAI-compatible endpoint so LM Studio drops in
unchanged.

Config lives in:

- `agents/goose/config.yaml` — canonical workbench config (do edit this).
- `agents/goose/config/config.yaml` — runtime copy, regenerated on each
  launch (do NOT edit; it gets overwritten).
- `scripts/start-goose.sh` — copies the canonical config into place, sets
  `GOOSE_PATH_ROOT` to the agent dir, and execs `goose`.

The launcher isolates your workbench session from your personal
`~/.config/goose/config.yaml` by setting `GOOSE_PATH_ROOT` to
`~/Desktop/ashlr-workbench/agents/goose/`.

## When to use it

1. **Exploring an unfamiliar repo.** Ask Goose to `ashlr__orient` the
   codebase — one tool call returns a synthesized overview instead of
   5 manual `ls`/`grep`/`cat` calls.
2. **Multi-tool workflows in one session.** "Query the Postgres logs
   table, find the error pattern, search the codebase for the throw site,
   open the file in question." Goose with `ashlr__sql` + `ashlr__grep`
   + `ashlr__read` handles this in a single chain of turns.
3. **Interactive debugging loops.** Start a long-running process with
   `ashlr__bash_start`, tail with `ashlr__bash_tail`, make a code change,
   observe the effect — all without leaving the REPL.
4. **Genome-aware work.** The first agent to ergonomically use the
   genome is Goose, because `ashlr__grep` routes through the genome
   retriever when `.ashlrcode/genome/` is present.
5. **When you want approval gates.** Goose's default mode asks before
   running shell commands or writing files — a sensible middle ground
   between Aider's "diff then y/n" and OpenHands' full autonomy.

## When NOT to use it

- **Surgical edits with explicit diffs.** Aider is better here — it is
  built around the edit loop. Goose can edit, but Aider's UX is tighter.
- **Unattended hours-long tasks.** OpenHands has better retry + recovery
  semantics for autonomous work.
- **Working with data that can't leave your machine but you need Claude
  for reasoning.** Goose supports Claude, but ashlrcode's plan mode is
  a better fit for "think hard first" sessions.

## How to start it

```bash
# In the current directory:
aw start goose

# In a specific project:
aw start goose ~/Desktop/some-project

# Raw:
./scripts/start-goose.sh ~/Desktop/some-project
```

The launcher:

1. Copies `agents/goose/config.yaml` → `agents/goose/config/config.yaml`.
2. Exports `GOOSE_PATH_ROOT=/Users/masonwyatt/Desktop/ashlr-workbench/agents/goose`.
3. Exports `ASHLR_PLUGIN_ROOT=/Users/masonwyatt/Desktop/ashlr-plugin`
   (referenced inside the config).
4. `cd`s to the target project.
5. `exec goose session`.

## Config explained

Key blocks of `agents/goose/config.yaml`:

### Provider

```yaml
provider:
  name: openai
  OPENAI_HOST: http://localhost:1234
  OPENAI_API_KEY: lm-studio
  OPENAI_BASE_PATH: v1/chat/completions
model: qwen/qwen3-coder-30b
```

Goose's "openai" provider is a generic OpenAI-compat client. LM Studio
speaks the protocol, so nothing else needs to change. The seemingly
weird `OPENAI_HOST` + `OPENAI_BASE_PATH` split is how Goose
concatenates the endpoint URL.

### Extensions (MCP)

```yaml
extensions:
  ashlr-efficiency:
    enabled: true
    type: stdio
    name: ashlr-efficiency
    cmd: bash
    args:
      - ${ASHLR_PLUGIN_ROOT}/scripts/mcp-entrypoint.sh
      - servers/efficiency-server.ts
    timeout: 300
    bundled: false
  ashlr-sql: ...
  ashlr-bash: ...
  ashlr-tree: ...
  ashlr-http: ...
  ashlr-diff: ...
  ashlr-logs: ...
  ashlr-genome: ...
  ashlr-orient: ...
  ashlr-github: ...
  developer:
    enabled: true
    type: builtin
    bundled: true
```

All 10 ashlr-plugin MCP servers are registered, plus Goose's builtin
`developer` extension (file/shell/text-editor tools). The builtins are
the guaranteed fallback — the ashlr tools are strictly better (token
efficient, genome-aware), but `developer` keeps working on a clean
machine where the plugin isn't set up yet.

### Mode

```yaml
GOOSE_MODE: approve
```

Values:

- `approve` (default): asks before every write/shell action.
- `smart_approve`: auto-approves read-only tools, asks for writes + shell.
- `auto`: fully hands-off; run at your own risk.

Change it in `config.yaml` and relaunch, or toggle in-session with
`/mode`.

## Common commands inside Goose

| Command                      | Effect                                        |
|------------------------------|-----------------------------------------------|
| `/extensions`                | List enabled MCP extensions                   |
| `/tools`                     | List tools available across extensions        |
| `/tool <name>`               | Inspect one tool's schema                     |
| `/mode`                      | Toggle approval mode                          |
| `/history`                   | Show conversation history                     |
| `/sessions`                  | List prior sessions                           |
| `/resume <id>`               | Resume a prior session                        |
| `/configure`                 | Interactive config editor (writes to runtime copy — re-edit `agents/goose/config.yaml` for persistence) |
| `/clear`                     | Clear the session                             |
| `/help`                      | Full command list                             |
| `/exit`                      | Quit                                          |

## Worked examples

### 1. Orient yourself in a fresh repo

```
> Use ashlr__orient with query "what does this repo do and how is it
  organized" to give me a 10-line summary.
```

Goose emits a single `ashlr__orient` call. Output: tree summary + key
file reads + LLM synthesis. Faster and cheaper than asking for a tree
and opening each file manually.

### 2. Cross-tool debugging

```
> I'm seeing ERR_CONN_REFUSED in prod at 10:42 UTC today.
> Use ashlr__logs to find the relevant entries.
> Then ashlr__grep for the handler that emits that error.
> Read the top 200 lines of the handler file.
> Propose a fix. Do not apply yet.
```

Goose chains 4 tools, then stops and waits for approval before any edit.

### 3. Long-running test watcher

```
> Use ashlr__bash_start to run "bun test --watch" in the background.
> Then ashlr__bash_tail to show the last 30 lines.
> Now edit src/foo.ts to add a failing test assertion and show me the
  watcher output after you save.
```

Background sessions live across turns — Goose can run a dev server,
watcher, or tail in parallel with its chat.

### 4. Propose to the genome

```
> Based on what you learned in this session, call ashlr__genome_propose
  to add a note under knowledge/decisions.md capturing: we chose
  Zustand over Redux for the session store because of bundle size.
```

The proposal lands in `pending/`. Later, `ashlr__genome_consolidate`
merges it.

## Integration points

- **LLM.** Default LM Studio → Qwen3-Coder-30B. Swap by editing
  `config.yaml` → `provider:` + `model:`. Claude, OpenAI, Groq, xAI all
  supported via their respective Goose provider blocks.
- **MCP.** 10 ashlr servers + `developer` builtin. Add more by editing
  the `extensions:` map; see `docs/integration/mcp-servers.md`.
- **Genome.** `ashlr__grep` auto-routes through the genome if
  `.ashlrcode/genome/` exists in CWD (or any ancestor). No config needed.
- **Shell.** `ashlr__bash` and `ashlr__bash_start/tail/stop` replace
  Goose's builtin shell for richer control. Builtin `developer.shell`
  still available as fallback.

## Known limitations

- **First tool call latency.** Bun warm-up takes 1–3 s per MCP server
  on the first invocation per session. Not tunable; live with it.
- **Session state on disk.** Goose writes to
  `agents/goose/state/` and `agents/goose/data/`. These are gitignored,
  but if you share the workbench dir across machines you will want to
  clear them.
- **Resume flakiness across config changes.** If you edit
  `agents/goose/config.yaml` (e.g. swap the model) between sessions,
  `/resume` of an old session may fail to load tools. Start a fresh
  session.
- **MCP server errors are quiet.** If a server crashes at startup, Goose
  usually omits it from `/extensions` with no banner. Check
  `$GOOSE_PATH_ROOT/state/` logs or run the server manually (see
  `docs/integration/mcp-servers.md` for the curl-test pattern).
- **`GOOSE_MODE: auto` will run destructive commands.** The workbench
  does not have a safety layer on top of Goose for auto mode. Run in
  `approve` unless you're comfortable.

## Upstream references

- Goose AAIF repo: https://github.com/aaif-goose/goose
- Goose docs: https://goose-docs.ai
- MCP primer: https://modelcontextprotocol.io
- Workbench `agents/goose/README.md`: concrete launch + MCP table.

## See also

- `docs/workflows.md` — Goose features in 3 of the 6 recipes.
- `docs/integration/ashlr-plugins.md` — every MCP tool Goose exposes.
