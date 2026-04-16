# CLAUDE.md — ashlr-workbench

Project-level instructions for Claude Code working inside this repo.

## What this repo is

The ashlr-workbench wires four coding agents (OpenHands, Goose, Aider,
ashlrcode) to one local LLM (LM Studio + Qwen3-Coder-30B) and ten MCP servers
(provided by the `ashlr-plugin` checkout at `~/Desktop/ashlr-plugin`). The
unified `bin/aw` CLI is the user-facing entrypoint; everything else is
plumbing.

This is infrastructure code — clarity beats cleverness, idempotency beats
ergonomics, and any breaking change ripples to four downstream consumers. Read
the existing scripts before adding to them.

## File-ownership conventions

| Path                                | Owner / purpose                                     |
|-------------------------------------|-----------------------------------------------------|
| `bin/aw`                            | Unified CLI dispatcher                              |
| `scripts/start-<agent>.sh`          | Per-agent launcher (one script per agent)           |
| `scripts/stop-<agent>.sh`           | Per-agent stopper (only for daemons — OpenHands)    |
| `scripts/healthcheck.sh`            | End-to-end health probe                             |
| `scripts/update-all.sh`             | Pulls/upgrades every component                      |
| `scripts/install-<agent>.sh`        | One-shot installer for an agent                     |
| `agents/<name>/`                    | The agent's config file(s) + a README.md            |
| `agents/<name>/<config>`            | Source-of-truth config; never edit runtime copies   |
| `mcp/`                              | (reserved) shared MCP wrapper scripts               |
| `docs/`                             | Cross-cutting docs (per-agent docs live in agents/) |

When you change behavior:

- **Per-agent config change** → only touch `agents/<name>/`
- **Per-agent launch behavior** → only touch `scripts/start-<name>.sh`
- **Cross-cutting CLI behavior** → `bin/aw` + corresponding healthcheck section
- **New external dependency** → update `.env.example` and the README requirements list

## Verification

Before committing any change to the workbench, run:

```bash
./bin/aw help            # smoke-test: parses + dispatches
./bin/aw status          # exercises status path (must not crash even when nothing is up)
./scripts/healthcheck.sh # full 13-point check (warnings are OK; failures are not)
```

For shell scripts, also run:

```bash
shellcheck bin/aw scripts/*.sh   # if shellcheck is installed
bash -n bin/aw                   # at minimum, syntax check
```

## How to add a new agent

1. **Pick a name** matching the agent's CLI binary (e.g. `cline`, `crush`).
2. `mkdir agents/<name>/` and put the agent's authoritative config there.
   Add a `README.md` describing the config and any quirks.
3. Create `scripts/start-<name>.sh`:
   - Source-of-truth: `agents/<name>/<config>`
   - Sanity-check LM Studio (`http://localhost:1234/v1/models`)
   - Sanity-check the agent binary is on PATH
   - Point the agent at `qwen/qwen3-coder-30b` via env or `--config`
4. (Optional) `scripts/stop-<name>.sh` if it has a daemon.
5. Wire it into `bin/aw`:
   - Add to `require_agent`'s case statement
   - Add a status line in `cmd_status`
   - Add a doctor check in `cmd_doctor` if it needs special diagnosis
6. Add a config-validation line in `scripts/healthcheck.sh` (`validate_json`,
   `validate_yaml`, or `validate_toml`).
7. Add a row to the agent-lineup table in `README.md` and update the
   architecture diagram.

## Hard rules — DO NOT

- **DO NOT** commit `.env`, anything under `~/.openhands/`, or any API key.
  `.gitignore` covers the obvious files; if you create a new state file, add
  it to `.gitignore` in the same commit.
- **DO NOT** edit `agents/<name>/config/` or other regenerated runtime dirs —
  they're produced by the start scripts and gitignored.
- **DO NOT** let any agent default to a cloud LLM. LM Studio is the primary;
  cloud keys are opt-in.
- **DO NOT** symlink `bin/aw` into `/usr/local/bin/` automatically. The user
  must approve that step (it requires sudo on stock macOS).
- **DO NOT** force-push to `main`. Branch + PR for anything non-trivial.

## Style

- Bash scripts target macOS bash 3.2 — no `mapfile`, `readarray`, GNU-only
  flags, or `[[ -v ... ]]`. Test with `/bin/bash -n` before committing.
- Use `set -uo pipefail` (not `-e`) so we can handle non-zero gracefully.
- Color output via `\033[...]` directly; respect `NO_COLOR` and `[ -t 1 ]`.
- ASCII status glyphs: `✓` (ok) / `⚠` (warn) / `✗` (fail) / `•` (info).
- Comments explain *why*, not *what*. The shell mostly speaks for itself.

## Useful context for the agent

- Mason's working style is in `~/.claude/CLAUDE.md` (global). The same
  philosophy applies here: investigate first, deploy parallel agents for
  research, surface assumptions, no half-measures.
- The ashlr-plugin lives at `~/Desktop/ashlr-plugin` and is the source of all
  10 MCP servers. Don't duplicate its logic — wire the existing servers in.
- LM Studio model id in this repo is `qwen/qwen3-coder-30b`. LiteLLM (used by
  OpenHands) requires the `openai/` prefix: `openai/qwen/qwen3-coder-30b`.
