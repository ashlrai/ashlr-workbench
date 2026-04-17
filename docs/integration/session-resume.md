# Session Resume

`aw resume` restores context from your last coding session so you can pick up
exactly where you left off. Instead of re-explaining what you were working on,
the resume command gathers that context automatically and feeds it to ashlrcode
as a structured prompt.

## Quick start

```bash
# Resume your last session in the current project directory
aw resume

# Resume the last session from any project
aw resume --global

# See what happened in the last session before resuming
aw summary
```

## What gets restored

When you run `aw resume`, four sources of context are gathered:

### 1. Session log activity

The last 20 entries from `~/.ashlr/session-log.jsonl` for the most recent
session. This includes tool calls (Read, Edit, Bash, etc.), session
start/end markers, and any summaries logged by the agent.

Example output in the resume prompt:

```
### Last session activity (from session log)
- [2026-04-16 05:30] tool_call: Read
- [2026-04-16 05:31] tool_call: Edit
- [2026-04-16 05:35] tool_call: Bash
- [2026-04-16 05:36] session_end
```

### 2. Git state

Current branch, commits ahead of main, recent commit log (`git log -5`),
and any uncommitted changes (`git diff --stat`). This tells the agent what
changed since the last session ended and whether there is work in progress.

### 3. Genome auto-observations

If the project has a `.ashlrcode/genome/knowledge/discoveries.md`, its
contents are included. These are auto-observations the genome system
captured during previous sessions — patterns noticed, risks identified,
and architectural decisions recorded.

Over time, the genome builds a richer picture of the project. Each resume
session benefits from everything the genome has learned, not just the last
session's activity.

### 4. Project conventions

The first 500 characters of `CLAUDE.md` or `AGENTS.md` from the project
root. This grounds the agent in the project's coding standards, file
ownership rules, and hard constraints.

## How it works

1. **Find the last session** — Scans the session log backward for the most
   recent `session_end` (or `session_start`) event matching the current
   working directory. Falls back to any session if `--global` is passed or
   no cwd-specific session exists.

2. **Build resume context** — Gathers session activity, git state, genome
   observations, and project conventions into a structured Markdown prompt.

3. **Write to temp file** — The resume prompt is written to a temporary file
   that is cleaned up on exit.

4. **Launch ashlrcode** — Starts ashlrcode with the resume context prepended,
   using the same configuration and environment as `aw start ashlrcode`.

5. **Print banner** — Shows a summary of what was restored so you know at a
   glance what the agent will see.

## `aw resume` vs `aw start ashlrcode`

| | `aw start ashlrcode` | `aw resume` |
|---|---|---|
| Session log context | None | Last 20 entries |
| Git state | None (agent can check) | Pre-gathered |
| Genome observations | None (agent can check) | Pre-loaded |
| Project conventions | None | First 500 chars |
| Use case | Fresh task, new direction | Continue previous work |

Use `aw start ashlrcode` when you are starting something new. Use `aw resume`
when you are continuing where you left off — after a break, overnight, or
after a context reset.

## `aw summary`

View a summary of the most recent session without launching an agent:

```bash
aw summary             # human-readable output
aw summary --json      # machine-readable JSON
```

Output includes:
- Session ID, agent, and project
- Duration and time since last activity
- Tool call breakdown (by type)
- Files touched
- Last action taken

This is useful for quickly checking what happened before deciding whether to
resume or start fresh.

## How the session log feeds the resume

The session log (`~/.ashlr/session-log.jsonl`) is a shared JSONL file written
by all workbench agents. Each entry includes:

```json
{
  "ts": "2026-04-16T05:30:00.000Z",
  "agent": "ashlrcode",
  "event": "tool_call",
  "tool": "Read",
  "cwd": "/Users/mason/Desktop/sports-trader",
  "session": "abc123def456"
}
```

The `session` field correlates entries within a single session. The resume
command uses this to find all activity from your last session without mixing
in entries from other sessions or other agents.

## How genome improves resume quality over time

The first time you resume in a project, the genome section may be empty. As
you work, the genome accumulates:

- **Discoveries** — patterns the agent noticed (e.g., "auth uses JWT, not
  sessions")
- **Conventions** — coding standards inferred from the codebase
- **Architecture** — structural observations about the project

Each subsequent resume benefits from this accumulated knowledge. After a few
sessions, the resume prompt gives the agent a much richer starting point than
the session log alone could provide.

## Example workflow

**Morning session:**
```bash
cd ~/Desktop/sports-trader
aw start ashlrcode
# Work on JWT auth migration for 2 hours
# Ctrl-D to exit
```

**Afternoon resume:**
```bash
cd ~/Desktop/sports-trader
aw resume
```

The agent sees:
```
Resuming session abc123 from 4h ago
  Project: ~/Desktop/sports-trader (branch: feature/jwt-auth)
  Last activity: 23 tool calls, ended with 'Bash'
  Genome: 5 auto-observations available
```

And the resume prompt includes your morning's tool calls, the 3 commits you
made, the uncommitted test file, and the genome's observation that "the /api/users
endpoint has no rate limiting."

**Next morning:**
```bash
cd ~/Desktop/sports-trader
aw summary          # quick check: what did I do yesterday?
aw resume           # pick up where I left off
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ASHLR_SESSION_LOG_PATH` | `~/.ashlr/session-log.jsonl` | Override session log location |
| `ASHLR_RESUME_CONTEXT` | (set by resume) | Path to the temp resume prompt file |

## Troubleshooting

**"no previous session found"** — The session log is empty or has no
`session_end`/`session_start` entries. Run `aw start ashlrcode` first to
create a session, then try `aw resume` next time.

**Resume shows wrong project** — By default, `aw resume` matches sessions
by your current working directory. Make sure you `cd` into the project
before running `aw resume`. Use `--global` to ignore directory matching.

**Genome section is empty** — The genome needs to be initialized for the
project. Run `ashlr genome init` in the project directory, then the next
session's observations will appear in future resumes.
