# ashlr-plugin: the MCP toolbelt

The 10 MCP servers shipped by
[ashlr-plugin](https://github.com/ashlrai/ashlr-plugin) are the
workbench's superpower. Every agent in `/agents/` consumes the same
set, so learning these tools once pays off across Goose, OpenHands, and
ashlrcode. (Aider does not consume MCP — see note at the end.)

## MCP in one paragraph

MCP (Model Context Protocol) is a JSON-RPC 2.0 protocol that lets an
agent call "tools" implemented by independent subprocess servers. Each
server exposes a schema for its tools; the agent advertises those tools
to the LLM; the LLM emits a tool-call; the agent forwards it over stdio
to the server; the server returns a result. This decouples tools from
agents — any MCP-speaking agent can use any MCP server without code
changes. The ashlr-plugin servers are Bun-interpreted TypeScript files
under `~/Desktop/ashlr-plugin/servers/`.

## Why these specifically

ashlr-plugin's servers exist because built-in agent tools (Claude Code's
`Read`, Goose's `developer.shell`, OpenHands' file ops) burn tokens on
large payloads. ashlr's servers:

- **Compact outputs** via `snipCompact` (head + tail, elided middle) on
  anything over 2 KB.
- **Route to the genome** when `.ashlrcode/genome/` exists, so
  `ashlr__grep` returns top-ranked sections instead of ripgrep output.
- **Summarize** some tool results via a local LLM (when reachable) — a
  tier-2 optimization on top of snipCompact.
- **Track savings** so you can run `ashlr__savings` and see lifetime
  tokens / dollars not burned.

Net effect on Mason's daily work: mean −79.5% tokens on files ≥ 2 KB,
per ashlr-plugin's own benchmark.

## Per-server reference (10 entries)

Each entry: what the server exposes, when it is useful, how the agents
invoke it.

### 1. `ashlr-efficiency` — the core three

Server file: `servers/efficiency-server.ts`.

Tools exposed:

- `ashlr__read` — read a file with snipCompact truncation.
- `ashlr__grep` — search a repo; genome-aware if `.ashlrcode/genome/`
  is present.
- `ashlr__edit` — strict single-match search/replace; returns a diff.
- `ashlr__savings` — lifetime token + cost savings.

When useful:

- **Every file read** on any sizable file. 2 KB is a low bar.
- **Every grep** in a project with a genome. Dramatic speedup on
  orientation queries.
- **Targeted edits** you want applied atomically with a diff confirmation.

Agent invocation examples:

- Goose: `ashlr__grep` is auto-preferred if `grep` is requested. Or
  explicit: "Use ashlr__grep to find..."
- ashlrcode: same. Additionally, hooks in
  `~/.ashlr-plugin/hooks/pretooluse-read.sh` nudge Claude-Code-style
  agents to prefer `ashlr__read` over the built-in `Read` tool for
  files > 2 KB. You've seen those reminders if you've edited files
  in this repo.

### 2. `ashlr-tree` — compact project structure

Server file: `servers/tree-server.ts`.

Tools exposed: `ashlr__tree`.

Output: Unicode box-drawing tree with per-directory size and file
count, honors `.gitignore` automatically inside git repos.

When useful:

- **First-time repo entry.** One call gives you what `ls -la` +
  `find` + a few `cat`s would take 4–5 calls to produce.
- **Orientation queries** paired with `ashlr__orient`.
- **Debugging "what's in this dir"** without needing a full recursive
  listing.

Flags: `depth` (default 4), `sizes`, `loc` (slow; reads every file),
`pattern` (regex filter), `maxEntries` (default 500 cap).

### 3. `ashlr-orient` — meta-orientation

Server file: `servers/orient-server.ts`.

Tools exposed: `ashlr__orient` (single tool).

Semantics: "How does X work here?" in one round-trip. The server
internally:

1. Scans the baseline tree.
2. Does keyword-derived file discovery (genome retriever if present,
   else ripgrep).
3. Reads top-matching files with snipCompact.
4. Synthesizes via a local LLM (LM Studio reachable) or returns raw
   compact snippets otherwise.

When useful:

- **Onboarding a new repo.** "Use ashlr__orient with query 'how does
  auth work here' and summarize in 10 lines."
- **Replacing the 3–5 orientation calls** an agent would otherwise
  make sequentially.
- **Pre-plan surveys** you want to save into `/plan` output.

Args: `query` (required), `dir`, `depth: "quick" | "thorough"`,
`endpointOverride` (alt LLM URL).

### 4. `ashlr-bash` — shell with a control plane

Server file: `servers/bash-server.ts`.

Tools exposed:

- `ashlr__bash` — one-shot exec with compacted output.
- `ashlr__bash_start` — start a long-running session (returns a handle).
- `ashlr__bash_list` — list active sessions.
- `ashlr__bash_tail` — stream recent output from a session.
- `ashlr__bash_stop` — stop a session.

When useful:

- **Background processes** — dev server, test watcher, log tailer — that
  the agent needs to keep talking to across turns.
- **Huge command output** — `bun run build` where stdout is 5 K lines.
  The server compacts; your prompt doesn't explode.
- **"Does it crash?" loops** — start, trigger, tail, stop.

Typical pattern:

```
ashlr__bash_start { cmd: "bun test --watch" } → {sessionId: "abc"}
ashlr__bash_tail  { sessionId: "abc", lines: 40 }
... edits ...
ashlr__bash_tail  { sessionId: "abc", lines: 40 }
ashlr__bash_stop  { sessionId: "abc" }
```

### 5. `ashlr-diff` — cheap diffs

Server file: `servers/diff-server.ts`.

Tools exposed: `ashlr__diff`.

Modes: `fileA vs fileB`, `git HEAD vs working tree`, `git <range>`.

When useful:

- **Pre-commit review** by an agent without it needing to `cat` both
  files.
- **PR description generation** — feed `git diff main..HEAD` into the
  prompt.
- **Regression hunting** across two revisions.

### 6. `ashlr-logs` — structured log tail

Server file: `servers/logs-server.ts`.

Tools exposed: `ashlr__logs`.

Reads from a configurable set of log files (system logs, app logs,
`./logs/`) and returns the last N entries with timestamp grouping.

When useful:

- **"Something broke at 10:42 UTC."** `ashlr__logs` with a time
  filter beats `tail | grep`.
- **Multi-file tails** — reading the top 50 lines of 4 different files
  in one call.

### 7. `ashlr-http` — fetch and summarize

Server file: `servers/http-server.ts`.

Tools exposed: `ashlr__http`.

Does an HTTP GET, then tier-1 snipCompact on the body. Optional tier-2
LLM summarize is pending (HTML/JSON summarize has hallucination risk —
see the plugin's roadmap).

When useful:

- **Reading a docs page.** Faster than browsing with OpenHands'
  headless browser.
- **Poking a health endpoint.** `ashlr__http` to `http://localhost:3000/healthz`.
- **Fetching a schema URL** for codegen.

Security note: honors HTTPS cert validation by default. If you're
hitting self-signed local endpoints, you'll need
`NODE_TLS_REJECT_UNAUTHORIZED=0` in the agent env — only ever for dev.

### 8. `ashlr-sql` — compacted database queries

Server file: `servers/sql-server.ts`.

Tools exposed: `ashlr__sql`.

Supports SQLite and Postgres (MySQL is on the roadmap). Executes a
query, returns the first N rows with columns + summarized types.

When useful:

- **Debugging against a dev database.** Schema queries, row counts,
  EXPLAIN outputs.
- **Auditing an RLS policy.** `SELECT` then a comparison `SELECT` with
  a mocked auth context.
- **Quick data exploration** during a bug hunt.

Wire up a connection string via server config or env var (see the
plugin README).

### 9. `ashlr-genome` — write-side of the genome

Server file: `servers/genome-server.ts`.

Tools exposed:

- `ashlr__genome_propose` — queue a proposed update to a section.
- `ashlr__genome_consolidate` — merge pending proposals.
- `ashlr__genome_status` — report pending + recent mutations.

When useful:

- **Capturing decisions mid-session.** Agent proposes an addition to
  `knowledge/decisions.md`, you consolidate later.
- **Building up project memory over weeks.** A genome that grows slowly
  from many proposals ends up better than one Mason writes by hand.

See `docs/integration/genome.md` for the full model.

### 10. `ashlr-github` — compact GitHub reader

Server file: `servers/github-server.ts`.

Tools exposed:

- `ashlr__pr` — read a PR with compacted diff + comments.
- `ashlr__issue` — read an issue + linked PRs.

Uses local `gh` auth — whatever token `gh auth status` reports is the
effective identity.

When useful:

- **PR review** without the agent having to `gh pr diff` + `gh pr view`
  + `gh api repos/.../comments`.
- **"What was this bug in the tracker?"** with linked-PR context pulled
  in automatically.

## Invocation examples across agents

Same task, different agents:

### Task: "Find all references to `sessionId` in this repo"

Goose:

```
> ashlr__grep sessionId
```

ashlrcode:

```
> Use ashlr__grep to find "sessionId" and show me the top 5 call sites.
```

OpenHands (in the chat UI):

```
Use the ashlr__grep tool to enumerate sessionId references.
Summarize by file.
```

Aider:

```
(can't — Aider has no MCP client; use `/run rg sessionId` instead)
```

### Task: "Summarize how auth works here"

Any MCP agent:

```
> ashlr__orient query="how does auth work in this repo"
```

## Adding a new MCP server to all agents

If you write a new server, wire it in three places:

1. **Goose** — append to `extensions:` in `agents/goose/config.yaml`:
   ```yaml
   my-server:
     enabled: true
     type: stdio
     name: my-server
     cmd: bash
     args: [${ASHLR_PLUGIN_ROOT}/scripts/mcp-entrypoint.sh, servers/my-server.ts]
     timeout: 300
   ```
2. **OpenHands** — append to `mcpServers:` in `agents/openhands/mcp.json`:
   ```json
   "my-server": {
     "command": "bash",
     "args": ["-c", "cd /host/ashlr-plugin && exec /host/bun/bun run servers/my-server.ts"]
   }
   ```
3. **ashlrcode** — append to `mcpServers:` in
   `agents/ashlrcode/settings.json`:
   ```json
   "my-server": {
     "command": "bash",
     "args": ["/Users/masonwyatt/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh",
              "servers/my-server.ts"]
   }
   ```

Then restart each agent. `aw doctor` will show the new server under
"MCP servers."

## Genome flow through MCP

```
  agent calls ashlr__grep "how does X work"
        │
        ▼
  efficiency-server.ts detects .ashlrcode/genome/ exists
        │
        ▼
  retrieveSectionsV2 ranks manifest.json sections by
    tag overlap + query terms, picks top K
        │
        ▼
  returns the section bodies (pre-compacted)
        │
        ▼
  agent gets ~80% fewer tokens vs raw ripgrep output
```

If no genome is present, it falls back to ripgrep. The tool call is
the same either way — transparent to the agent.

## About Aider + MCP

Aider does not speak MCP today. If you want ashlr tool behavior inside
an Aider session, either:

- Use `/run rg <pattern>` for grep equivalence (no genome benefit).
- Do the orientation step in Goose or ashlrcode first, then bring
  specific files into Aider with `/add`.

Aider's team has discussed MCP; follow the upstream repo for news.

## References

- ashlr-plugin on GitHub: https://github.com/ashlrai/ashlr-plugin
- Benchmark JSON: `~/Desktop/ashlr-plugin/docs/benchmarks.json`
- Core lib: `@ashlr/core-efficiency` (bundled in the plugin today)
- Plugin landing page: https://plugin.ashlr.ai/
- MCP spec: https://modelcontextprotocol.io
