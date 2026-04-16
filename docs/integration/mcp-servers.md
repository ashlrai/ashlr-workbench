# MCP Servers: protocol primer + debugging

A just-enough reference for Mason to run, debug, and extend MCP servers
in this workbench. Read `docs/integration/ashlr-plugins.md` for the
per-server catalog; this doc is the plumbing.

## Protocol summary

MCP (Model Context Protocol) is a JSON-RPC 2.0 protocol spoken over
stdio between an agent (client) and a tool provider (server). The server
advertises a set of tools + schemas; the client exposes those tools to
the LLM; the LLM emits a `tools/call`; the client forwards it and
returns the result.

Wire format, in brief:

```
                  stdin (UTF-8, newline-delimited JSON)
  ┌──────────┐ ────────────────────────────────────▶ ┌──────────────┐
  │ Agent     │                                       │ MCP server   │
  │ (client)  │ ◀──────────────────────────────────── │ (subprocess) │
  └──────────┘                  stdout                └──────────────┘
```

Messages are single-line JSON objects. Every request has an `id`; the
matching response has the same `id`. Notifications (no response
expected) omit `id`.

## Lifecycle

1. **Spawn.** Agent execs the command line from its config. Process
   starts, opens stdio.
2. **Initialize.** Client sends `initialize` with protocol version and
   client info. Server responds with `serverInfo` and capability list.
3. **List tools.** Client sends `tools/list`. Server returns schemas.
4. **Call loop.** Client sends `tools/call` as the LLM requests. Server
   responds with `content` + optional `isError`.
5. **Shutdown.** Client closes stdin; server exits.

## Debugging an ashlr MCP server by hand

Every ashlr server is a Bun-interpreted TypeScript file. You can exercise
it directly:

```bash
cd ~/Desktop/ashlr-plugin

# Send an initialize message, get back serverInfo:
echo '{"jsonrpc":"2.0","id":1,"method":"initialize",
       "params":{"protocolVersion":"2024-11-05",
                 "capabilities":{},
                 "clientInfo":{"name":"manual","version":"0"}}}' \
  | bun run servers/efficiency-server.ts
```

You should see a single JSON line with `result.serverInfo.name`:
`"ashlr-efficiency"`.

List tools:

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | bun run servers/efficiency-server.ts
```

Invoke one tool (a real `ashlr__read`):

```bash
cat <<'EOF' | bun run servers/efficiency-server.ts
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"m","version":"0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ashlr__read","arguments":{"path":"README.md"}}}
EOF
```

Two JSON lines come back: the init response and the tool response. If
either is missing, the server crashed; the stderr is where you look.

## The standard launch wrapper

Every agent launches ashlr servers via
`~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh`. That script:

1. Ensures `bun` is on PATH (handles non-interactive shell cases).
2. `cd`s to the plugin root.
3. `exec`s `bun run <server-file>`.

If you ever see a `bun: command not found` from an agent, it's almost
always because the agent spawned under a non-interactive shell that
didn't load your PATH. Fix by adding to `~/.zshenv` (not `~/.zshrc`):

```bash
export PATH="$HOME/.bun/bin:$PATH"
```

## Security model

MCP servers run as **subprocesses of the agent**, which means:

- They inherit the agent's environment (env vars, PATH, CWD).
- They share the agent's privileges on the host. If the agent can
  write `~/.ssh/authorized_keys`, so can any MCP server it spawns.
- They do not have network isolation by default — an MCP server can
  make HTTPS calls, open sockets, whatever it wants.

Implications:

1. **Only register MCP servers you trust.** A malicious `mcp.json`
   entry is equivalent to rooting the agent.
2. **`${ENV_VAR}` expansion in config** happens at spawn time. If you
   commit a config with `${SUPABASE_ACCESS_TOKEN}` references, the
   value is read from your shell at launch — good. If you commit the
   literal token, it is exposed — bad.
3. **In OpenHands**, MCP servers run inside the container — isolated
   from your host filesystem except via the mounts you set up. Better
   blast radius than host-native agents.

## Adding a new MCP server

### Write the server

Minimal skeleton, saved as `servers/my-server.ts` in a plugin-like repo:

```typescript
#!/usr/bin/env bun
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "my-server", version: "0.0.1" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: "my__echo",
    description: "Echo a string back.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
    },
  }],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  if (name === "my__echo") {
    return { content: [{ type: "text", text: String(args?.text ?? "") }] };
  }
  return {
    content: [{ type: "text", text: `Unknown tool: ${name}` }],
    isError: true,
  };
});

const transport = new StdioServerTransport();
await server.connect(transport);
```

### Register with each agent

See the "Adding a new MCP server" section in
`docs/integration/ashlr-plugins.md` for the three config edits.

### Test before you wire it

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}' \
  | bun run my-server.ts
```

Don't register an untested server across all four agents — you'll get
confusing "failed to start" messages everywhere.

## Common failure modes

### "failed to start" in Goose or ashlrcode

Probable causes:

1. Bun not on PATH for the agent's subshell. Fix via `~/.zshenv`.
2. Missing deps. `cd ~/Desktop/ashlr-plugin && bun install`.
3. Syntax error in the server. Run by hand to see the stack.
4. Entrypoint script is not executable. `chmod +x scripts/mcp-entrypoint.sh`.

### Tool call times out

Usually the server is taking longer than the agent's timeout (`300`s
in Goose's config, no explicit default in ashlrcode). Options:

- Increase the timeout in the agent config.
- Split heavy work inside the tool implementation (stream partial
  responses).
- Check if the server is hitting an external service that's down
  (`ashlr__http` against a dead URL).

### Container-side "/host/bun: not found" (OpenHands)

The Linux-aarch64 bun binary didn't get staged in the mount. Re-run:

```bash
aw stop openhands
rm -rf ~/.cache/ashlr-workbench/bun-linux-aarch64/
aw start openhands
```

### Agent reports a tool exists but the LLM never calls it

This is an LLM-behavior problem, not an MCP problem. Typically:

- The LLM is too small to reliably emit tool calls (older 7B models).
- The system prompt is missing guidance about tool use.
- Another tool is occluding this one in the schema list (pick better
  names / descriptions).

## Further reading

- MCP spec: https://modelcontextprotocol.io
- Reference SDK:
  https://github.com/modelcontextprotocol/typescript-sdk
- ashlr-plugin servers (good reading material):
  `~/Desktop/ashlr-plugin/servers/`
