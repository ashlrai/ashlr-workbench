# ashlr-workbench

Your local coding-agent HQ — four agents, one local LLM, ten MCP servers,
zero cloud dependencies.

## What this is

A curated, fully-local toolbox that wires four open-source coding agents
(OpenHands, Goose, Aider, ashlrcode) to a single LM Studio model
(Qwen3-Coder-30B) and the same set of ten ashlr-plugin MCP servers. The
workbench supplies one CLI (`aw`), one healthcheck, and one update path so the
whole stack feels cohesive instead of four loose tools you have to babysit. No
data leaves the machine unless you opt into a cloud fallback.

## Quick start

```bash
# 1. Clone the supporting plugin (provides the 10 MCP servers)
git clone https://github.com/ashlrai/ashlr-plugin ~/Desktop/ashlr-plugin
cd ~/Desktop/ashlr-plugin && bun install

# 2. Clone the workbench
git clone <this-repo-url> ~/Desktop/ashlr-workbench
cd ~/Desktop/ashlr-workbench
cp .env.example .env   # then edit

# 3. Start LM Studio, load qwen/qwen3-coder-30b, click "Start Server"

# 4. Verify
./bin/aw doctor

# 5. Use
./bin/aw start aider          # interactive session in cwd
./bin/aw start openhands      # autonomous Docker-based agent
```

To put `aw` on your PATH (review first):

```bash
ln -sf ~/Desktop/ashlr-workbench/bin/aw /usr/local/bin/aw
```

## The agent lineup

| Agent      | Form                  | Best for                                                | Cost       |
|------------|-----------------------|---------------------------------------------------------|------------|
| OpenHands  | Docker daemon + GUI   | Autonomous multi-step PRs, browser-driven tasks         | Heavy RAM  |
| Goose      | Native Rust CLI       | Fast tool-using sessions, smart-approve loop            | Light      |
| Aider      | Python CLI            | Surgical file-by-file refactors with explicit diffs     | Light      |
| ashlrcode  | npm/Bun CLI (Mason's) | Personal day-to-day work, hooks-aware, cloud fallback   | Light      |

Pick the one that matches the *shape* of the work — see "Usage examples" below.

## Architecture

```
                ┌─────────────────────────────────────────────┐
                │              ashlr-workbench                │
                │                                             │
                │   bin/aw  →  scripts/{start,health,update}  │
                └─────────────────────────────────────────────┘
                                    │
        ┌───────────────────┬───────┴────────┬──────────────────┐
        ▼                   ▼                ▼                  ▼
   ┌──────────┐        ┌────────┐       ┌────────┐         ┌──────────┐
   │ OpenHands│        │ Goose  │       │ Aider  │         │ashlrcode │
   │ (docker) │        │ (rust) │       │(python)│         │ (bun)    │
   └────┬─────┘        └───┬────┘       └───┬────┘         └────┬─────┘
        │                  │                │                   │
        └──────────────┬───┴────────────────┴───────────────────┘
                       │  same MCP surface
                       ▼
            ┌─────────────────────────┐         ┌────────────────┐
            │  ashlr-plugin (10 MCPs) │   ←──   │  LM Studio     │
            │  efficiency / sql /     │         │  Qwen3-Coder   │
            │  bash / tree / http /   │         │  -30B  :1234   │
            │  diff / logs / genome / │         └────────────────┘
            │  orient / github        │
            └─────────────────────────┘         ┌────────────────┐
                                                │ Ollama :11434  │
                                                │  (fallback)    │
                                                └────────────────┘
```

All four agents talk to the same LLM and the same MCP tools, so behavior is
consistent regardless of which one you launch.

## Requirements

- macOS 14+ (Apple Silicon recommended; Intel works but slower)
- Docker Desktop — for OpenHands
- LM Studio with `qwen/qwen3-coder-30b` loaded — primary LLM
- [Bun](https://bun.sh/) ≥ 1.1 — for ashlr-plugin MCP servers and ashlrcode
- Python 3.12+ — for Aider
- Node ≥ 20 / npm — for `npm install -g ashlrcode`
- ~32 GB free RAM (Qwen3-Coder-30B in 4-bit needs ~24 GB live)
- ~30 GB free disk (Docker images + model)
- Optional: [Ollama](https://ollama.com/) as fallback LLM
- Optional: `gh` CLI for GitHub PAT (`GITHUB_TOKEN="$(gh auth token)"`)

## Installation

```bash
# Plugin (provides the MCP servers all 4 agents share)
git clone https://github.com/ashlrai/ashlr-plugin ~/Desktop/ashlr-plugin
cd ~/Desktop/ashlr-plugin && bun install

# Workbench
git clone <this-repo-url> ~/Desktop/ashlr-workbench
cd ~/Desktop/ashlr-workbench
cp .env.example .env

# Per-agent installers (only run the ones you want)
./scripts/install-goose.sh           # Goose via Homebrew
pipx install aider-chat              # Aider (or: pip install --user aider-chat)
npm install -g ashlrcode             # ashlrcode
# OpenHands needs no install — `aw start openhands` pulls the image on first run
```

After install, verify:

```bash
./bin/aw doctor    # actionable diagnosis
./bin/aw health    # full 13-point check
```

## Usage examples

| Scenario                                              | Best agent | Command                              |
|-------------------------------------------------------|------------|--------------------------------------|
| "Refactor this one file's error handling"             | Aider      | `aw start aider .`                   |
| "Add tests, run them, fix until green — autonomous"   | OpenHands  | `aw start openhands` then GUI prompt |
| "Quick interactive session, mostly tool calls"        | Goose      | `aw start goose`                     |
| "My usual driver — hooks, recall, fast"               | ashlrcode  | `aw start ashlrcode`                 |
| "Open a PR for me end-to-end"                         | OpenHands  | give it a GitHub URL in the GUI      |
| "Explain what this codebase does"                     | Goose      | `aw start goose` → "orient on cwd"   |

## Configuration

Per-agent configs live under `agents/`:

```
agents/openhands/config.toml      # OpenHands runtime settings
agents/openhands/mcp.json         # MCP servers wired into OpenHands
agents/goose/config.yaml          # Goose source-of-truth (copied to runtime on launch)
agents/aider/aider.conf.yml       # Aider model + UX
agents/ashlrcode/settings.json    # ashlrcode overlay (XAI primary, LM Studio fallback)
```

Workbench-wide environment lives in `.env` (see `.env.example`).

## Troubleshooting

| Symptom                                          | Fix                                                       |
|--------------------------------------------------|-----------------------------------------------------------|
| `aw start openhands` says Docker not running     | Launch Docker Desktop, wait for whale icon, retry         |
| LM Studio "endpoint not responding"              | Open LM Studio → Developer → Start Server, load the model |
| MCP server fails to start in any agent           | `cd ~/Desktop/ashlr-plugin && bun install`                |
| OpenHands GUI loads but agent errors on first turn | Confirm `qwen/qwen3-coder-30b` is the loaded model        |
| `aider` not found after install                  | `pipx ensurepath` or add `~/.local/bin` to PATH           |
| `ashlrcode` complains about XAI_API_KEY          | Set in `.env` or run with LM Studio fallback              |

For anything else, run `aw doctor` — it prints the exact fix for each problem
it detects.

## Contributing / extending

To add a new agent:

1. Create `agents/<name>/` with the agent's config file(s).
2. Create `scripts/start-<name>.sh` that launches it pointed at the workbench
   config and the LM Studio endpoint.
3. (If it has a daemon) Create `scripts/stop-<name>.sh`.
4. Add it to the `case` statements in `bin/aw` (`require_agent`, `cmd_start`,
   `cmd_stop`, `cmd_status`).
5. Add validation lines for its config in `scripts/healthcheck.sh`.
6. Update this README's agent-lineup table and architecture diagram.

See `CLAUDE.md` for project-wide conventions.

## License

MIT — see [LICENSE](LICENSE).
