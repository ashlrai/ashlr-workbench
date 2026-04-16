# ashlr-workbench docs

Deep documentation for the workbench. The top-level `README.md` links here.

## Start here

- **[QUICKSTART.md](QUICKSTART.md)** — 15-minute tutorial. Zero to four
  running agents.
- **[CHEATSHEET.md](CHEATSHEET.md)** — one-page printable reference.
- **[architecture.md](architecture.md)** — how `aw`, the agents, the
  MCP servers, LM Studio, and the genome fit together.

## Per-agent deep dives

- **[agents/aider.md](agents/aider.md)** — surgical git-native edits.
- **[agents/goose.md](agents/goose.md)** — MCP-rich daily driver.
- **[agents/openhands.md](agents/openhands.md)** — sandboxed,
  autonomous, long-horizon.
- **[agents/ashlrcode.md](agents/ashlrcode.md)** — multi-provider
  Claude-Code-style REPL.

## Integration

- **[integration/ashlr-plugins.md](integration/ashlr-plugins.md)** —
  the 10 ashlr-plugin MCP servers: purpose + invocation per agent.
- **[integration/mcp-servers.md](integration/mcp-servers.md)** — MCP
  protocol primer, debugging, adding a new server.
- **[integration/genome.md](integration/genome.md)** — genome layout,
  read/propose/consolidate flow, multi-agent safety.

## Tactics

- **[models.md](models.md)** — decision guide: which model for which
  agent for which task.
- **[workflows.md](workflows.md)** — six recipes: refactor, new feature,
  bug fix, PR description, PR review, new project.
- **[troubleshooting.md](troubleshooting.md)** — concrete problems +
  fixes, sorted by frequency.

## Reading order, by role

- **First time on the workbench.** QUICKSTART → CHEATSHEET → pick an
  agent deep-dive → workflows.
- **Debugging something broken right now.** troubleshooting → architecture
  (to map the blast radius) → the specific agent doc.
- **Adding a new agent or MCP server.** architecture → integration/mcp-servers
  → integration/ashlr-plugins.
- **Tuning for cost / privacy / speed.** models → workflows.
