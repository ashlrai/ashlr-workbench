# Aider MCP Bridge

Aider does not natively speak the Model Context Protocol (MCP). This bridge
closes that gap by exposing the 10 ashlr-plugin MCP tools as ordinary shell
commands that Aider can invoke with its built-in `/run` command.

## How it works

```
  ┌────────────────────────────────────────────────────────────────────┐
  │ Aider session                                                      │
  │   /run ashlr__read /path/to/file                                   │
  │         │                                                          │
  │         ▼                                                          │
  │   $PATH/ashlr__read  (thin wrapper script in tmp dir)              │
  │         │                                                          │
  │         ▼                                                          │
  │   _bridge_call_tool()  (from _bridge-core.sh)                      │
  │         │                                                          │
  │         ├── initialize  JSON-RPC 2.0 →  bun efficiency-server.ts  │
  │         └── tools/call  JSON-RPC 2.0 →                            │
  │                                         ← result content          │
  │         │                                                          │
  │         ▼                                                          │
  │   stdout → Aider terminal (result text)                            │
  └────────────────────────────────────────────────────────────────────┘
```

When `aw start aider` (or `scripts/start-aider.sh`) runs, it:

1. Sources `scripts/aider-mcp-bridge.sh`.
2. Calls `aider_mcp_bridge_init`, which writes 10 wrapper scripts to a
   per-session temp directory and prepends it to `PATH`.
3. Launches Aider normally. Aider sees the wrappers on `PATH`.
4. On exit, the `EXIT` trap calls `aider_mcp_bridge_cleanup` to remove
   the temp directory.

The wrappers spawn the MCP server as a subprocess, send JSON-RPC 2.0
`initialize` + `tools/call` messages over stdio, parse the response, and
print the result text — exactly what `/run` needs.

## Prerequisites

| Requirement | Check | Fix |
|---|---|---|
| ashlr-plugin cloned | `ls ~/Desktop/ashlr-plugin/servers/` | `git clone https://github.com/ashlrai/ashlr-plugin ~/Desktop/ashlr-plugin` |
| bun on PATH | `which bun` | `curl -fsSL https://bun.sh/install \| bash` |
| bun deps installed | `ls ~/Desktop/ashlr-plugin/node_modules/` | `cd ~/Desktop/ashlr-plugin && bun install` |
| python3 on PATH | `which python3` | Install via Homebrew: `brew install python3` (used for JSON parsing; optional — grep fallback exists) |

## Available tools (10)

| Command | MCP tool | Description |
|---|---|---|
| `ashlr__read` | ashlr-efficiency | Read file with snipCompact truncation (head+tail for large files) |
| `ashlr__grep` | ashlr-efficiency | Genome-aware repo search; ranks results by relevance |
| `ashlr__edit` | ashlr-efficiency | Strict search/replace with diff output |
| `ashlr__savings` | ashlr-efficiency | Lifetime token + cost savings report |
| `ashlr__bash` | ashlr-bash | Run a shell command with head+tail output compression |
| `ashlr__ls` | ashlr-tree | Compact directory listing |
| `ashlr__tree` | ashlr-tree | Unicode project tree with per-dir size and file count |
| `ashlr__diff` | ashlr-diff | Semantic + structural diff between two files |
| `ashlr__http` | ashlr-http | HTTP fetch with snipCompact output |
| `ashlr__orient` | ashlr-orient | Codebase orientation summary (architecture, key files, patterns) |

## Usage examples inside Aider

All examples use `/run <wrapper> [args]`.

### Read a file

```
/run ashlr__read /path/to/file.ts
```

Long files are automatically truncated (head + tail) to save tokens.

### Search a codebase

```
/run ashlr__grep --pattern "function myHelper" --path .
/run ashlr__grep --pattern "TODO" --path src/
```

If the project has a `.ashlrcode/genome/` directory, results are
genome-ranked. Otherwise falls back to ripgrep / grep.

### Run a shell command

```
/run ashlr__bash --command "ls -la src/"
/run ashlr__bash --command "git log --oneline -10"
/run ashlr__bash echo hello world
```

Output is compressed (head + tail with elided middle) so large command
outputs don't flood the Aider terminal.

### Edit a file

```
/run ashlr__edit --path src/foo.ts --search "old text" --replace "new text"
```

Returns a unified diff. Fails if the search string is not unique (same
safety guarantee as ashlrcode's `Edit` tool).

### Get a project tree

```
/run ashlr__tree --path . --depth 3
/run ashlr__ls --path src/
```

### Fetch a URL

```
/run ashlr__http --url https://api.example.com/data
/run ashlr__http https://example.com
```

### Orient in an unfamiliar codebase

```
/run ashlr__orient --path .
```

Summarises architecture, entry points, key patterns, and file structure
in one compact response.

## Argument syntax

The wrappers accept three styles:

| Style | Example | Becomes |
|---|---|---|
| `--key value` | `--pattern "foo"` | `{"pattern":"foo"}` |
| `key=value` | `pattern=foo` | `{"pattern":"foo"}` |
| Bare arg | `/path/to/file` | `{"path":"/path/to/file"}` (default key) |

For `ashlr__bash`, all bare arguments are joined as the command string:

```
/run ashlr__bash ls -la src/
# → {"command":"ls -la src/"}
```

For `ashlr__http`, the first bare arg becomes `url`:

```
/run ashlr__http https://example.com
# → {"url":"https://example.com"}
```

## Changing the plugin directory

The bridge reads `ASHLR_PLUGIN_DIR` (default `~/Desktop/ashlr-plugin`).
Override before launching:

```bash
ASHLR_PLUGIN_DIR=~/code/ashlr-plugin aw start aider
```

## Running the bridge manually (debugging)

```bash
# Dry-run: shows what would be registered without writing wrappers
AIDER_MCP_BRIDGE_DRY_RUN=1 bash scripts/aider-mcp-bridge.sh

# Full self-test: writes wrappers to a temp dir, lists tools + server paths
bash scripts/aider-mcp-bridge.sh
```

## Running the integration tests

```bash
bats tests/aider-mcp-bridge.bats

# With live MCP calls (requires ashlr-plugin + bun):
ASHLR_PLUGIN_DIR=~/Desktop/ashlr-plugin bats tests/aider-mcp-bridge.bats

# Quiet output:
NO_COLOR=1 bats tests/aider-mcp-bridge.bats
```

---

## Troubleshooting

### `bun: command not found` in wrapper

The wrapper executes in a non-interactive subshell that may not source
`~/.zshrc`. Add bun to `~/.zshenv` (not `~/.zshrc`):

```bash
echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.zshenv
```

Then relaunch Aider.

### `server not found: .../servers/efficiency-server.ts`

The ashlr-plugin is either not cloned or `ASHLR_PLUGIN_DIR` points
somewhere wrong.

```bash
# Check
ls "$ASHLR_PLUGIN_DIR/servers/"

# Fix
git clone https://github.com/ashlrai/ashlr-plugin ~/Desktop/ashlr-plugin
cd ~/Desktop/ashlr-plugin && bun install
```

### `no output from ashlr__bash` or timeout

The MCP server started but did not respond within `AIDER_MCP_BRIDGE_TIMEOUT`
seconds (default 30). Increase the timeout:

```bash
AIDER_MCP_BRIDGE_TIMEOUT=60 aw start aider
```

Or test the server directly:

```bash
cd ~/Desktop/ashlr-plugin
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' \
  | bun run servers/bash-server.ts
```

### `[ashlr__read error] ...`

The MCP server returned a JSON-RPC error. The message after `error]`
is the server's error detail. Common causes:

- File path does not exist.
- Permission denied.
- Server-side validation failed (e.g. `path` required but not passed).

### `python3: command not found` warning

The bridge uses python3 to parse the JSON-RPC response. Without it,
it falls back to `grep + sed` which handles most responses but may
truncate large outputs. Install python3 to get full fidelity:

```bash
brew install python3
```

### Wrappers not found after Aider restarts

The bridge bin dir is per-session (created fresh on each `aw start aider`).
It is cleaned up when Aider exits. This is intentional — stale wrappers
from old plugin versions should not persist.

### Calling a tool manually outside Aider

After `aw start aider` sources the bridge, the wrappers are on PATH for
the entire shell session. You can call them directly:

```bash
ashlr__read /path/to/file
ashlr__bash --command "git status"
```

Or source the bridge yourself:

```bash
. scripts/aider-mcp-bridge.sh
aider_mcp_bridge_init
ashlr__read /path/to/file
```
