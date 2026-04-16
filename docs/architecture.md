# Architecture

How the pieces fit, drawn in ASCII. If you understand these three diagrams,
you understand the workbench.

## 1. Layer diagram — from your keystroke to the tokens

You type at a terminal or web UI, `aw` spawns an agent, the agent speaks
OpenAI or Anthropic protocol to a local or remote LLM, and MCP servers are
registered as stdio subprocesses of the agent.

```
┌───────────────────────────────────────────────────────────────────────────┐
│  You                                                                      │
│    terminal                      browser (http://localhost:3000)          │
│        │                             │                                    │
└────────┼─────────────────────────────┼────────────────────────────────────┘
         │                             │
         ▼                             ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  aw CLI  (bin/aw)                                                         │
│    thin dispatcher → scripts/start-<agent>.sh                             │
└────────┬──────────────────────┬─────────────────────┬─────────────────────┘
         │                      │                     │
         ▼                      ▼                     ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────────┐
│  Aider           │  │  Goose           │  │  OpenHands (docker)          │
│  (python)        │  │  (rust)          │  │  ghcr/openhands:1.6          │
│  pid in shell    │  │  pid in shell    │  │  container: ashlr-openhands  │
└──────────────────┘  └──────────────────┘  └──────────────────────────────┘
         │                      │                     │
         │     ┌────────────────┘                     │
         │     │                                      │
         │     │   ┌──────────────────────────────────┘
         │     │   │
         ▼     ▼   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  MCP subprocesses (stdio, JSON-RPC 2.0)                                   │
│    bun run servers/efficiency-server.ts                                   │
│    bun run servers/sql-server.ts                                          │
│    bun run servers/bash-server.ts                                         │
│    bun run servers/tree-server.ts                                         │
│    bun run servers/http-server.ts                                         │
│    bun run servers/diff-server.ts                                         │
│    bun run servers/logs-server.ts                                         │
│    bun run servers/genome-server.ts                                       │
│    bun run servers/orient-server.ts                                       │
│    bun run servers/github-server.ts                                       │
└───────────────────────────────────────────────────────────────────────────┘
         │                      │                     │
         ▼                      ▼                     ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────────┐
│  LM Studio       │  │  Ollama          │  │  Remote APIs                 │
│  :1234  /v1      │  │  :11434          │  │  xAI, Anthropic              │
│  qwen3-coder-30b │  │  gemma4:26b      │  │  (ashlrcode, Claude Code)    │
└──────────────────┘  └──────────────────┘  └──────────────────────────────┘
```

Notes on the layer diagram:

- **`aw` is stateless.** It never proxies tokens; it just selects the right
  start script and sets env vars before `exec`ing the agent process.
- **Agent processes are standard OS processes.** Aider, Goose, and ashlrcode
  run on your host. OpenHands runs inside a Docker container; the agent
  process is inside the container, and stdio to MCP servers happens inside
  the container (see diagram 2).
- **MCP servers are started by the agent, not by `aw`.** Each agent reads
  its own config (`agents/<name>/`), which lists the MCP command line. The
  agent forks one child process per MCP server at startup, keeps the stdio
  open, and shuts them down on exit.
- **LLM traffic is separate from MCP traffic.** The agent's HTTP client
  talks to LM Studio / Ollama / xAI / Anthropic over TCP. MCP runs over
  stdio pipes inside the agent process tree.

## 2. MCP fanout — how each agent finds the 10 servers

All four agents consume the same 10 ashlr-plugin MCP servers. The path is
different per agent but resolves to the same bun-executed TypeScript files
under `~/Desktop/ashlr-plugin/servers/`.

```
  ~/Desktop/ashlr-plugin/
  ├── scripts/mcp-entrypoint.sh        ← common bootstrap (loads bun, cd, exec)
  └── servers/
        efficiency-server.ts           ashlr__read, ashlr__grep, ashlr__edit, ashlr__savings
        sql-server.ts                  ashlr__sql
        bash-server.ts                 ashlr__bash, bash_start/list/tail/stop
        tree-server.ts                 ashlr__tree
        http-server.ts                 ashlr__http
        diff-server.ts                 ashlr__diff
        logs-server.ts                 ashlr__logs
        genome-server.ts               ashlr__genome_propose/consolidate/status
        orient-server.ts               ashlr__orient
        github-server.ts               ashlr__issue, ashlr__pr
```

How each agent wires them:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Aider                                                                   │
│    ✗ no MCP client — Aider is a git-native edit REPL, it does not speak  │
│      MCP today. You get the LLM + repo map; ashlr tools are not in       │
│      scope for Aider sessions.                                           │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  Goose  (agents/goose/config.yaml)                                       │
│    extensions:                                                           │
│      ashlr-efficiency:                                                   │
│        type: stdio                                                       │
│        cmd: bash                                                         │
│        args: [${ASHLR_PLUGIN_ROOT}/scripts/mcp-entrypoint.sh,            │
│               servers/efficiency-server.ts]                              │
│      ashlr-sql:  ...                                                     │
│      (one entry per server, 10 total; + builtin `developer`)             │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  OpenHands  (agents/openhands/mcp.json, mounted at /.openhands/mcp.json) │
│    mcpServers:                                                           │
│      ashlr-efficiency:                                                   │
│        command: bash                                                     │
│        args: ["-c", "cd /host/ashlr-plugin && exec /host/bun/bun run \   │
│               servers/efficiency-server.ts"]                             │
│    (plugin mounted read-only at /host/ashlr-plugin; linux-aarch64 bun    │
│     staged at /host/bun by start-openhands.sh)                           │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  ashlrcode  (agents/ashlrcode/settings.json)                             │
│    mcpServers:                                                           │
│      ashlr-efficiency:                                                   │
│        command: bash                                                     │
│        args: [/Users/masonwyatt/Desktop/ashlr-plugin/scripts/            │
│               mcp-entrypoint.sh, servers/efficiency-server.ts]           │
│    + supabase + roblox-studio (12 total MCP servers for this agent)      │
└──────────────────────────────────────────────────────────────────────────┘
```

Why the paths look different per agent:

- **Goose** prefers env-var indirection (`${ASHLR_PLUGIN_ROOT}`) because
  its config is checked into source control and benefits from relocatable
  paths. The launch script sets `ASHLR_PLUGIN_ROOT=~/Desktop/ashlr-plugin`.
- **OpenHands** runs inside a container, so it needs a container-local bun
  and a volume-mounted plugin dir. The launcher stages both.
- **ashlrcode** just hardcodes the absolute host path — it is host-native
  and Mason's machine, so indirection adds nothing.

## 3. Data flow — the shared genome

The workbench has two levels of shared state:

- **Workspace genome** at `~/Desktop/.ashlrcode/genome/` — high-level vision,
  knowledge, strategies, milestones for the entire `~/Desktop` workspace.
  Shared by every project you open from `~/Desktop`.
- **Per-project genome** at `<project>/.ashlrcode/genome/` — same shape,
  but scoped to one repo. Takes precedence for genome-aware retrieval when
  present.

Both genomes are just directories of markdown files plus a `manifest.json`
that indexes every section with tags, a summary, and a token count.

```
  ~/Desktop/.ashlrcode/genome/
    manifest.json             ← index: {path, title, tags, summary, tokens}
    vision/
      north-star.md
      architecture.md
      principles.md
      anti-patterns.md
    knowledge/
      architecture.md         (discovered from reading ~/Desktop)
      conventions.md
      decisions.md
      dependencies.md
      discoveries.md
      workspace.md            (auto-populated: N repos, M projects)
    strategies/
      active.md
      experiments.md
      graveyard.md
    milestones/
      current.md
      backlog.md
      completed/
    evolution/
      (mutation log, append-only)
```

Lifecycle of a genome entry:

```
    ┌────────────────────────────────────────────────────────────────┐
    │  1. Agent runs (any of the four)                               │
    │     observes something worth remembering                       │
    │       e.g. "this repo uses bun + tsx, no webpack"              │
    └────────────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌────────────────────────────────────────────────────────────────┐
    │  2. Agent calls ashlr__genome_propose                          │
    │       section: knowledge/dependencies.md                       │
    │       content: "bun 1.x for runtime, tsx for one-off scripts"  │
    │     → written to .ashlrcode/genome/pending/<uuid>.json         │
    └────────────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌────────────────────────────────────────────────────────────────┐
    │  3. ashlr__genome_consolidate                                  │
    │       either manually or on a timer / hook                     │
    │       merges pending proposals into the section files          │
    │       via direct merge or optional LLM dedup                   │
    │     → appends a mutation entry to evolution/                   │
    │     → updates manifest.json token counts + updatedAt           │
    └────────────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌────────────────────────────────────────────────────────────────┐
    │  4. Later, another agent calls ashlr__grep "how does X work"   │
    │       efficiency-server.ts checks for .ashlrcode/genome/       │
    │       uses retrieveSectionsV2 to rank sections by tag/query    │
    │       returns the top-matching sections instead of rg output   │
    │     → ~80% token savings on orientation-shaped queries         │
    └────────────────────────────────────────────────────────────────┘
```

Two important invariants:

1. **The genome is append-mostly.** Consolidation edits markdown in place,
   but every change is logged in `evolution/`. You can walk back to any
   previous generation.
2. **Agents do not edit each other's memory directly.** They propose; the
   consolidation step owns the merge. This makes multi-agent workflows
   safe — Goose and OpenHands proposing simultaneously produces a clean
   merge, not a race condition.

## Process topology at runtime

When you have all four agents running on a busy day, `pstree`-style:

```
launchd
 ├── Terminal
 │    ├── zsh (tab 1) ── aider ── python [aider]
 │    │                               └── (no MCP children — aider does not use MCP)
 │    │
 │    ├── zsh (tab 2) ── goose ── bun efficiency-server.ts
 │    │                         ├── bun sql-server.ts
 │    │                         ├── bun bash-server.ts
 │    │                         ├── bun tree-server.ts
 │    │                         ├── bun http-server.ts
 │    │                         ├── bun diff-server.ts
 │    │                         ├── bun logs-server.ts
 │    │                         ├── bun genome-server.ts
 │    │                         ├── bun orient-server.ts
 │    │                         └── bun github-server.ts
 │    │
 │    └── zsh (tab 3) ── ashlrcode ── bun efficiency-server.ts
 │                                   ├── bun …  (same 10 ashlr servers)
 │                                   ├── npx supabase-mcp
 │                                   └── StudioMCP (roblox)
 │
 └── Docker.app
      └── ashlr-openhands container
           └── python [openhands-server]
                ├── bun efficiency-server.ts   (linux-aarch64 bun at /host/bun)
                └── bun …  (same 10 ashlr servers, inside container)
```

All of it is talking to the same LM Studio process on `:1234`. That is why
warming a second model burns memory — each loaded model eats a fresh chunk
of unified memory. See `docs/models.md` for the tradeoffs.

## What is deliberately not in this diagram

- **No orchestrator.** There is no background scheduler, queue, or broker.
  The workbench is a directory of configs; agents are manually started.
- **No shared context server.** Genome is the only shared state. Agents do
  not stream tokens to each other.
- **No tokens-per-second proxy.** `aw` does not sit on the LLM path. If you
  want a proxy (LiteLLM, gptcache, etc.), drop it in between the agent and
  LM Studio and update the agent's `baseURL`.

## Where to edit what

| To change...                          | Edit                                          |
|---------------------------------------|-----------------------------------------------|
| Default model for Aider               | `agents/aider/aider.conf.yml` (`model:`)      |
| Goose MCP list                        | `agents/goose/config.yaml` (`extensions:`)    |
| OpenHands container tag               | `scripts/start-openhands.sh` (image ref)      |
| ashlrcode primary provider            | `agents/ashlrcode/settings.json` (`providers.primary`) |
| Add a new MCP server                  | Append to each agent's config; see `docs/integration/mcp-servers.md` |
| Change `aw health` checks             | `bin/aw` (the `health` subcommand)            |
| Workspace genome sections             | `~/Desktop/.ashlrcode/genome/*/*.md`          |
