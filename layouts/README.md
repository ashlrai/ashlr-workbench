# Layouts

Multi-pane workspace configurations for cmux/tmux, wired into `aw layout`.

## Available Layouts

### workbench (wb) — daily driver

```
aw layout workbench [dir]

+----------------------+-----------------+
|                      |                 |
|   aw (interactive)   |  aw log tail    |
|   Qwen3-Coder-30B   |  (live feed)    |
|                      |                 |
+----------------------+                 |
|                      |                 |
|   shell ($SHELL)     |                 |
|                      |                 |
+----------------------+-----------------+
```

Default layout for everyday coding. Left column has your interactive `aw`
session and a plain shell for git/build commands. Right column streams the
cross-agent session log so you can see what happened across sessions.

### feature (feat) — build a feature

```
aw layout feature <dir>

+----------------------+-----------------+
|   Claude Code        |   aw (local)    |
|   (architect)        |   (implementer) |
+----------------------+-----------------+
|   test watcher       |   git + log     |
+----------------------+-----------------+
```

Claude Code (cloud) plans the architecture while `aw` (local Qwen3-Coder-30B)
implements. Bottom-left auto-detects your test runner (bun/npm/pytest). Bottom-
right watches git status and recent session log entries.

### parallel (par) — multi-repo work

```
aw layout parallel <dir1> <dir2> <dir3>

+------------+------------+
| aw (dir1)  | aw (dir2)  |
+------------+------------+
| aw (dir3)  | overseer   |
+------------+------------+
```

Three `aw` sessions running in parallel across different repos, plus a Claude
Code pane that acts as overseer — reviewing diffs, catching duplication, and
coordinating cross-repo API contracts.

### research (res) — explore unfamiliar code

```
aw layout research <dir>

+----------------------+-----------------+
|                      |  aw --model     |
|   OpenHands browser  |  gemma          |
|   (localhost:3000)   |  (deep Q&A)    |
|                      +-----------------+
|                      |  README / docs  |
+----------------------+-----------------+
```

Left pane launches OpenHands in your browser for autonomous exploration.
Right-top runs `aw --model gemma` (gemma4:26b) for deep reasoning about the
codebase. Right-bottom shows the project README.

## Usage

```bash
aw layout workbench           # open in current dir
aw layout wb ~/my-project     # shorthand, specific dir
aw layout feature ./app       # feature build in ./app
aw layout parallel a/ b/ c/   # 3-way parallel
aw layout research ~/new-lib  # explore new-lib
aw layout help                # list available layouts
```

## Requirements

- **cmux** (preferred): set `$CMUX_SOCKET_PATH` and have cmux on PATH
- **tmux** (fallback): standard tmux installation

All layouts check for cmux first, then fall back to tmux. If neither is
available, the script exits with an error.

## Creating Custom Layouts

1. Copy an existing layout as a starting point:
   ```bash
   cp layouts/workbench.sh layouts/my-layout.sh
   chmod +x layouts/my-layout.sh
   ```

2. Follow the conventions:
   - `set -euo pipefail` at the top
   - Accept `<dir>` as first arg, default to pwd where appropriate
   - Set `SESSION` name based on layout + project basename
   - Support both cmux and tmux (copy the dispatch pattern)
   - Print fallback paste commands for cmux (it doesn't always accept --command)

3. Wire it into `bin/aw` by adding a case to the `layout)` dispatcher:
   ```bash
   my-layout|ml) exec "$WORKBENCH/layouts/my-layout.sh" "$@" ;;
   ```
