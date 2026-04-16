# Cheatsheet

One page. Print this.

## `aw` commands

| Command                              | What it does                                               |
|--------------------------------------|------------------------------------------------------------|
| `aw health`                          | Run 5-check preflight (LM Studio, Ollama, plugin, Docker, genome) |
| `aw start aider [DIR] [--flags]`     | Launch Aider in DIR against LM Studio                      |
| `aw start goose [DIR]`               | Launch Goose with workbench config + MCP fanout            |
| `aw start openhands`                 | Start the OpenHands Docker container on :3000              |
| `aw start ashlrcode [--prompt "..."]`| Launch ashlrcode REPL (or one-shot) with workbench overlay |
| `aw stop openhands`                  | Stop + remove the OpenHands container                      |
| `aw logs openhands [-f]`             | Tail the OpenHands container logs                          |
| `aw status`                          | Show running agents + their PIDs/container IDs             |
| `aw doctor`                          | Verbose diagnostics (supersets `aw health`)                |
| `aw genome status`                   | Show pending + recent genome mutations                     |
| `aw genome init [PROJECT]`           | Initialize a project genome                                |

## Which agent for which task

```
                    ┌─ is the task "change these exact files"? ─ yes ─▶ AIDER
                    │
     start here ────┤─ is the task exploratory and MCP-heavy?  ─ yes ─▶ GOOSE
                    │   (SQL, HTTP, genome, multi-tool)
                    │
                    ├─ should it run autonomously for >20 min? ─ yes ─▶ OPENHANDS
                    │   (sandboxed, web browsing, long-horizon)
                    │
                    └─ default / "Claude-Code-style" mix ─────▶ ASHLRCODE
                        (plan mode, Grok primary, LM Studio fallback)
```

## Top MCP tools (ashlr-plugin)

| Tool                         | 1-line purpose                                                   |
|------------------------------|------------------------------------------------------------------|
| `ashlr__read`                | File read with snipCompact truncation on payloads >2 KB          |
| `ashlr__grep`                | Genome-aware retrieval if genome exists; ripgrep fallback        |
| `ashlr__edit`                | Strict single-match search/replace edit, returns a diff only     |
| `ashlr__tree`                | Token-efficient project tree (sizes, LOC, gitignore-aware)       |
| `ashlr__orient`              | "How does X work here?" in one call (tree + grep + reads + synth)|
| `ashlr__bash`                | One-shot shell exec with compacted output                        |
| `ashlr__bash_start/tail/stop`| Long-running bash sessions with streaming tail                   |
| `ashlr__diff`                | Token-cheap file/file or git diff                                |
| `ashlr__http`                | Fetch + summarize URL content                                    |
| `ashlr__logs`                | Structured tail of common log files                              |
| `ashlr__sql`                 | Query + summarize against SQLite / Postgres                      |
| `ashlr__savings`             | Report lifetime tokens saved by ashlr-plugin                     |
| `ashlr__genome_propose`      | Queue an update to a genome section                              |
| `ashlr__genome_consolidate`  | Merge pending proposals into the genome                          |
| `ashlr__genome_status`       | Pending + recent genome mutations                                |
| `ashlr__issue` / `ashlr__pr` | Compact GitHub issue/PR reader via local `gh` auth               |

## Common URLs + ports

| Service        | URL                                | Notes                            |
|----------------|------------------------------------|----------------------------------|
| LM Studio      | `http://localhost:1234/v1`         | OpenAI-compatible, API key `lm-studio` |
| Ollama         | `http://localhost:11434`           | Fallback provider                |
| OpenHands UI   | `http://localhost:3000`            | Container `ashlr-openhands`      |
| ashlrcode xAI  | `https://api.x.ai/v1`              | Primary for ashlrcode            |
| Anthropic      | `https://api.anthropic.com/v1`     | Used by Claude Code + ashlrcode  |

## File paths

| Path                                               | What it is                         |
|----------------------------------------------------|------------------------------------|
| `~/Desktop/ashlr-workbench/`                       | This workbench                     |
| `~/Desktop/ashlr-workbench/agents/<name>/`         | Per-agent config + README          |
| `~/Desktop/ashlr-workbench/scripts/start-*.sh`     | Raw launch scripts (under `aw`)    |
| `~/Desktop/ashlr-plugin/`                          | MCP servers + hooks + commands     |
| `~/Desktop/.ashlrcode/genome/`                     | Workspace-level genome             |
| `<project>/.ashlrcode/genome/`                     | Per-project genome (optional)      |
| `~/.ashlrcode/settings.json`                       | Your personal ashlrcode config (untouched by workbench) |
| `~/.config/goose/config.yaml`                      | Your personal Goose config (untouched)                  |

## Per-agent keyboard + REPL shortcuts

### Aider

| Keys / command           | Effect                                            |
|--------------------------|---------------------------------------------------|
| `/add <file>`            | Add file to chat context                          |
| `/drop <file>`           | Remove from context                               |
| `/ask <q>`               | Ask without requesting edits                      |
| `/diff`                  | Show pending diff                                 |
| `/undo`                  | Revert last aider-produced commit                 |
| `/run <cmd>`             | Run shell cmd, feed output to chat                |
| `/clear`                 | Clear chat history                                |
| `Ctrl-C` (twice)         | Quit                                              |

### Goose

| Keys / command           | Effect                                            |
|--------------------------|---------------------------------------------------|
| `/extensions`            | List enabled MCP extensions                       |
| `/tools`                 | List available tools across extensions            |
| `/mode`                  | Toggle approve-each-action vs auto mode           |
| `/history`               | Show conversation history                         |
| `/clear`                 | Clear session                                     |
| `/exit`                  | Quit                                              |

### OpenHands (web UI)

| Action                   | Where                                             |
|--------------------------|---------------------------------------------------|
| New session              | Top-left "+"                                      |
| Attach workspace         | Session settings → Workspace path                 |
| Toggle confirmation mode | Settings → Security → Confirmation Mode          |
| View file diffs          | Sidebar → Files tab                               |
| Stop agent mid-task      | Big red stop button (top of chat pane)            |

### ashlrcode

| Command                  | Effect                                            |
|--------------------------|---------------------------------------------------|
| `/plan`                  | Enter plan mode (read-only exploration)           |
| `/model [name]`          | Show or switch active model                       |
| `/cost`                  | Show token usage + cost this session              |
| `/compact`               | Summarize history to free context                 |
| `/sessions`              | List saved sessions                               |
| `/continue`              | Resume last session in this dir                   |
| `/clear`                 | Clear conversation                                |
| `/exit`                  | Quit                                              |

## Fast triage

| Symptom                                  | First check                              |
|------------------------------------------|------------------------------------------|
| Agent stalls after prompt                | `curl http://localhost:1234/v1/models`   |
| `ashlr__*` tools not available in agent  | `aw doctor` → plugin block               |
| OpenHands UI won't load                  | `docker ps | grep ashlr-openhands`       |
| Aider "no model" error                   | Confirm `openai/` prefix in config       |
| `XAI_API_KEY` not set for ashlrcode      | `export XAI_API_KEY=xai-...` and retry   |
