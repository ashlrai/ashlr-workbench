# Shared Session Log

A single append-only JSONL file at `~/.ashlr/session-log.jsonl` that every
Ashlr-ecosystem coding agent writes to. When you switch tools mid-feature
(say, Claude Code → Goose → Aider), the new tool can read what the previous
one did instead of starting from a cold context. This is the minimum-viable
shared substrate for cross-agent continuity.

The log is local-only, append-only, and small by design. Writes are atomic
under POSIX `O_APPEND` semantics (as long as each entry stays under ~4KB),
so multiple agents writing concurrently is the common case — no locks, no
coordination daemon, no database. Just a JSONL file.

## Schema

| Field     | Type     | Required | Notes                                                              |
|-----------|----------|----------|--------------------------------------------------------------------|
| `ts`      | string   | yes      | ISO-8601 UTC, e.g. `2026-04-16T05:58:00.123Z`. Auto-filled on append. |
| `agent`   | string   | yes      | `claude-code` / `openhands` / `goose` / `aider` / `ashlrcode` / any string. |
| `event`   | string   | yes      | `session_start` / `session_end` / `tool_call` / `file_edit` / `message` / `observation` / any string. |
| `cwd`     | string   | no       | Absolute working directory at time of the event.                   |
| `session` | string   | no       | Opaque per-agent session id for grouping related entries.          |
| `tool`    | string   | no       | Tool name for `tool_call` / `file_edit` events.                    |
| `path`    | string   | no       | Affected file path for `file_edit` / `observation` events.         |
| `summary` | string   | no       | ≤120-char human-readable line used by `aw-log tail/recent`.        |
| `meta`    | object   | no       | Free-form structured payload. Keep small (4KB atomicity cap).      |

The contract is additive only: new optional fields are fine, existing
fields never change meaning. Consumers must ignore unknown fields.

## Where it lives & how it rotates

- Default path: `~/.ashlr/session-log.jsonl`.
- Override via env: `ASHLR_SESSION_LOG_PATH=/some/other/path`.
- Rotates automatically when the file exceeds **10 MB** — the current file is
  renamed to `session-log.jsonl.1` (overwriting any prior `.1`) and a fresh
  empty file is created. Only one generation of history is kept.
- `ASHLR_SESSION_LOG=0` disables all writes ecosystem-wide (reads still work).

### Privacy

The file lives entirely on your machine under `~/.ashlr/`. Nothing leaves
the host. It is however world-readable by default to other processes running
as the same user — don't put secrets in `meta`. Agents should log what
they're about to do (file paths, tool names, short summaries), not full
transcripts or file contents.

## Enabling it per agent

### Claude Code

Enabled automatically via the `PostToolUse` hook shipped in
`~/Desktop/ashlr-plugin` (built in parallel with this module). After
installing the plugin, every tool invocation inside Claude Code emits a
`tool_call` entry. No per-user config required.

If you need to disable it for a session:

```bash
ASHLR_SESSION_LOG=0 claude
```

### OpenHands

Add a post-step hook to your OpenHands agent config. Minimal append
snippet (Python, runs in the OpenHands runtime):

```python
import json, os, datetime

def log_event(event: str, **fields):
    path = os.environ.get("ASHLR_SESSION_LOG_PATH",
                          os.path.expanduser("~/.ashlr/session-log.jsonl"))
    if os.environ.get("ASHLR_SESSION_LOG") == "0":
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    entry = {
        "ts": datetime.datetime.utcnow().isoformat(timespec="milliseconds") + "Z",
        "agent": "openhands",
        "event": event,
        "cwd": os.getcwd(),
        **fields,
    }
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")

# Call from your tool-execution wrapper:
log_event("tool_call", tool="str_replace_editor", path=file_path,
          summary=f"edited {file_path}")
```

### Goose

Add a small MCP tool or a direct shell hook. The simplest form is a
shell wrapper invoked from a Goose extension:

```bash
#!/usr/bin/env bash
# ~/.local/bin/ashlr-log-append
set -uo pipefail
LOG="${ASHLR_SESSION_LOG_PATH:-$HOME/.ashlr/session-log.jsonl}"
[ "${ASHLR_SESSION_LOG:-1}" = "0" ] && exit 0
mkdir -p "$(dirname "$LOG")"
TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
AGENT="goose"
EVENT="${1:-observation}"
SUMMARY="${2:-}"
printf '{"ts":"%s","agent":"%s","event":"%s","summary":"%s"}\n' \
  "$TS" "$AGENT" "$EVENT" "$SUMMARY" >> "$LOG"
```

Wire it into a Goose `recipe` or `on_tool_call` hook so each invocation
runs `ashlr-log-append tool_call "ran ripgrep"`.

### Aider

Aider supports `--test-cmd` and shell-wrapper integration. The easiest
path is a subprocess hook invoked around each Aider edit:

```bash
aider \
  --auto-commits false \
  --test-cmd "ashlr-log-append file_edit 'aider edited file'" \
  ...
```

Or, for finer control, wrap the `aider` binary:

```bash
#!/usr/bin/env bash
# ~/.local/bin/aider-logged
LOG="${ASHLR_SESSION_LOG_PATH:-$HOME/.ashlr/session-log.jsonl}"
TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"ts":"%s","agent":"aider","event":"session_start","cwd":"%s"}\n' \
  "$TS" "$PWD" >> "$LOG"
command aider "$@"
TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"ts":"%s","agent":"aider","event":"session_end"}\n' "$TS" >> "$LOG"
```

### ashlrcode

Direct import — ashlrcode ships with `@ashlr/core-efficiency`:

```ts
import { append } from "@ashlr/core-efficiency/src/session-log";

await append({
  agent: "ashlrcode",
  event: "tool_call",
  tool: "Read",
  path: "/abs/path/to/file.ts",
  summary: "read file.ts (1.2KB)",
  cwd: process.cwd(),
});
```

(The short-form subpath export — `@ashlr/core-efficiency/session-log` —
will be added to `package.json` in a follow-up. Use the full `/src/` path
until then.)

## Example workflows

### 1. Resume a half-finished feature after switching tools

You started refactoring `src/auth/session.ts` in Claude Code, got tired
of its rate limit, and want to continue in Goose:

```bash
# Before launching Goose, scan what Claude Code did:
aw-log filter --agent claude-code | head -40

# Start Goose with that context in mind. Goose now sees its own edits
# AND Claude Code's — so when it asks "what's the state of session.ts?"
# the shared log answers.
```

### 2. Parallel monitoring while agents run

Run `aw-log tail` in a side terminal while multiple agents work:

```bash
aw-log tail
# → cyan for Claude Code, magenta for OpenHands, yellow for Goose, etc.
# You see at a glance which agent just edited what.
```

### 3. Audit a session after the fact

```bash
aw-log stats
# entries:       842
# last 24h:      217
# by agent:
#   claude-code    412
#   goose          204
#   aider          226
# by event:
#   tool_call      530
#   file_edit      188
#   ...
```

Spot an anomaly? Drill in:

```bash
aw-log filter --agent aider | less
```

## CLI

See `bin/aw-log` for the operator-side viewer. Subcommands:

| Command                     | What it does                                            |
|-----------------------------|---------------------------------------------------------|
| `aw-log tail [--agent N]`   | Stream new entries as they land, color-per-agent.       |
| `aw-log recent [N]`         | Last N entries (default 20), newest first.              |
| `aw-log stats`              | Counts by agent / event + last-24h activity.            |
| `aw-log filter --agent N`   | All entries for a given agent, newest first.            |
| `aw-log rotate`             | Force rotation.                                         |
| `aw-log help`               | Show usage.                                             |

Honors `NO_COLOR` and non-TTY stdout for piping into `grep` / `less`.

## Library API

If you're writing an agent integration in TypeScript, import from
`@ashlr/core-efficiency`:

```ts
import { append, read, tail, rotate } from "@ashlr/core-efficiency/src/session-log";
```

See `src/session-log/README.md` in the core-efficiency repo for the full
API surface.
