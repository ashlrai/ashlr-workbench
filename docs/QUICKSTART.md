# Quickstart

Fifteen minutes. You go from a cold workbench to four running agents and a
tangible workflow that combines them.

Assumptions:

- You are on Apple Silicon macOS.
- LM Studio is installed and `qwen/qwen3-coder-30b` is downloaded and loaded
  on `http://localhost:1234`.
- `bun`, `git`, `gh`, and `docker` are on your PATH.
- `~/Desktop/ashlr-plugin/` exists and its deps are installed
  (`cd ~/Desktop/ashlr-plugin && bun install`).

If any of the above is not true, stop and fix that first. The health check in
step 1 will tell you what is missing.

---

## 1. Prereqs check (2 minutes)

The workbench ships an `aw` command-line tool. After installation (step 2)
you run:

```bash
aw health
```

`aw health` runs five checks in order and prints `ok` / `fail` for each:

| # | Check                      | What it does                                        |
|---|----------------------------|-----------------------------------------------------|
| 1 | `lmstudio`                 | `curl http://localhost:1234/v1/models` — must list `qwen/qwen3-coder-30b` |
| 2 | `ollama` (optional)        | `curl http://localhost:11434/api/tags` — warn-only  |
| 3 | `ashlr-plugin`             | `~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh` is executable and `bun install` has run |
| 4 | `docker`                   | `docker info` succeeds — required for OpenHands     |
| 5 | `genome`                   | `~/Desktop/.ashlrcode/genome/manifest.json` exists  |

If you have not yet installed the workbench, skip ahead to step 2 and come
back here.

Manual equivalent, if `aw` is not yet on your PATH:

```bash
curl -s http://localhost:1234/v1/models | jq '.data[].id'
curl -s http://localhost:11434/api/tags | jq '.models[].name'
ls -l ~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh
docker info >/dev/null && echo docker-ok
ls ~/Desktop/.ashlrcode/genome/manifest.json
```

Expected output includes `qwen/qwen3-coder-30b` in the first command and a
file listing for every other line. If LM Studio does not list the model,
open LM Studio, search for `qwen/qwen3-coder-30b`, click Load.

---

## 2. Install the workbench (2 minutes)

```bash
cd ~/Desktop
git clone git@github.com:ashlrai/ashlr-workbench.git  # or: already here
cd ashlr-workbench

# Put aw on PATH via a symlink into ~/.local/bin (or /usr/local/bin if you prefer):
mkdir -p ~/.local/bin
ln -sf "$(pwd)/bin/aw" ~/.local/bin/aw

# Ensure ~/.local/bin is on PATH. Add to ~/.zshrc if missing:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify:

```bash
which aw          # /Users/you/.local/bin/aw -> /Users/you/Desktop/ashlr-workbench/bin/aw
aw --help
aw health
```

If `aw` is not found, either your shell did not pick up the new PATH
(start a new terminal tab) or the symlink target does not exist yet (the
workbench is still being built; fall back to the raw scripts in
`scripts/start-<agent>.sh`).

---

## 3. First session: Aider (3 minutes)

Aider is the simplest of the four — a single REPL that reads your repo,
proposes diffs, and lets you approve them.

```bash
# Start Aider against a real project. Pick one:
aw start aider ~/Desktop/ashlr-plugin
# Equivalent raw script:
# ~/Desktop/ashlr-workbench/scripts/start-aider.sh ~/Desktop/ashlr-plugin
```

You will see Aider's banner, then a `>` prompt. Try a tiny, reviewable task:

```
> /add servers/diff-server.ts
> Add a one-line comment at the top describing what this server does.
```

Expected: Aider prints a unified diff, asks `Apply edit? (y/n)`, and on `y`
the file is changed in place. No commit is made automatically — the
workbench's `aider.conf.yml` sets `auto-commits: false`.

Quit with `/exit` or `Ctrl-D`. Revert the test edit:

```bash
cd ~/Desktop/ashlr-plugin
git checkout -- servers/diff-server.ts
```

What you just confirmed: LM Studio is serving Qwen3-Coder, Aider can talk to
it, and the workbench's config is being honored (streaming output, no
auto-commits, custom colors).

---

## 4. First session: Goose (3 minutes)

Goose is the MCP-rich daily driver. The workbench wires all 10 ashlr-plugin
MCP servers into Goose so the agent has `ashlr__grep`, `ashlr__read`, etc.
out of the box.

```bash
aw start goose ~/Desktop/ashlr-plugin
# Raw equivalent:
# ~/Desktop/ashlr-workbench/scripts/start-goose.sh ~/Desktop/ashlr-plugin
```

At the Goose prompt, ask it to use an ashlr tool explicitly. This is the
quickest way to confirm the MCP wiring works end-to-end:

```
Use the ashlr__grep tool to find every place that "snipCompact" is referenced
in this repo. Summarize the top 3 call sites.
```

Expected: Goose displays a tool-call block for `ashlr__grep` with pattern
`snipCompact`, shows the (compact) output, then writes a short summary.

If the tool call never fires, see `docs/troubleshooting.md` under "MCP server
timeout" and "Goose ignores ashlr tools".

Quit with `/exit`.

What you confirmed: Goose is reading the workbench config, the ashlr-plugin
MCP servers are healthy, and genome-aware grep works (or falls back to
ripgrep cleanly — either is acceptable).

---

## 5. First session: OpenHands (3 minutes)

OpenHands is the autonomous, sandboxed agent. It runs in a Docker container,
ships a web UI on `http://localhost:3000`, and is comfortable running
unattended for an hour on a long task.

```bash
aw start openhands
# Raw equivalent:
# ~/Desktop/ashlr-workbench/scripts/start-openhands.sh
```

First launch pulls the `docker.openhands.dev/openhands/openhands:1.6` image
(~2 GB). Subsequent launches are ~5 seconds.

When the console prints `OpenHands running on http://localhost:3000`:

```bash
open http://localhost:3000
```

In the browser:

1. Pick **LM Studio** from the provider list (or confirm the pre-selected
   local provider).
2. Model should already be `qwen/qwen3-coder-30b`.
3. Create a new session. Attach a project by pasting
   `/workspace/ashlr-plugin` as the workspace path (OpenHands mounts
   `~/Desktop/ashlr-plugin` at `/workspace/ashlr-plugin` by default — see
   `agents/openhands/README.md` for the exact mounts).
4. Task: `Add a GitHub Actions workflow that runs "bun test" on push.
   Open a PR titled "ci: run bun test on push". Do not merge.`

Expected: OpenHands runs a command loop: lists the repo, reads `package.json`,
writes `.github/workflows/test.yml`, runs `git checkout -b`, `git add`,
`git commit`, `gh pr create`, prints the PR URL. Takes 3-10 minutes on a
local Qwen3-Coder depending on your Mac.

Tear down when done:

```bash
aw stop openhands
# Raw equivalent:
# ~/Desktop/ashlr-workbench/scripts/stop-openhands.sh
```

What you confirmed: Docker, the mounted ashlr-plugin volume, the staged
Linux-aarch64 bun binary inside the container, and the full MCP chain
(ashlr-efficiency, ashlr-github, ashlr-bash, ...) all work.

---

## 6. First session: ashlrcode (2 minutes)

ashlrcode is Mason's own CLI — a Claude-Code-style REPL that defaults to
xAI Grok and falls back to LM Studio. The workbench overlays a per-workspace
config so your personal `~/.ashlrcode/` is untouched.

```bash
# Make sure XAI_API_KEY is set (or rely on the overlay's embedded key):
export XAI_API_KEY="xai-..."

aw start ashlrcode --prompt "Summarize this repo in 5 bullets."
# Raw equivalent:
# ~/Desktop/ashlr-workbench/scripts/start-ashlrcode.sh "Summarize this repo in 5 bullets."
```

For an interactive REPL:

```bash
aw start ashlrcode
# Inside the REPL:
> /model           # see primary + fallbacks
> /model lmstudio-local
> Tell me what ashlr__orient does.
> /cost
> /exit
```

Expected: the one-shot prompt returns a 5-bullet summary in ~10 s on Grok
or ~60 s on LM Studio. `/cost` shows token usage per provider.

What you confirmed: ashlrcode picks up `ASHLRCODE_CONFIG_DIR`, registers
all 12 MCP servers (10 ashlr + supabase + roblox-studio), and can swap
between Grok and local Qwen.

---

## 7. Combining them (end of session)

A small, realistic workflow that touches three of the four agents:

**Scenario.** You want to add a `--json` flag to the `ashlr__savings` CLI
surface and get it merged on a feature branch.

```bash
cd ~/Desktop/ashlr-plugin
git checkout -b feat/savings-json
```

Step 1 — **plan with ashlrcode** (2-3 min). Use plan mode to survey before
writing code:

```bash
aw start ashlrcode
> /plan
> What files would I touch to add a --json output mode to the savings
  subcommand? Don't make changes, just list them with a 1-line rationale
  each.
> /exit
```

Step 2 — **implement with Aider** (5-10 min). Open Aider with the files the
plan surfaced:

```bash
aw start aider .
> /add scripts/savings-status-line.ts
> /add servers/efficiency-server.ts
> Add a --json flag that prints the same stats as a single-line JSON object.
  Keep the human-readable output as the default.
```

Review each diff, `y` or `n`, then quit.

Step 3 — **commit + PR with ashlrcode** (1 min). ashlrcode reads `git diff`
and drafts a commit message and PR body:

```bash
aw start ashlrcode --prompt "Write a commit message for the staged changes. \
  Then stage everything, commit, push the branch, and open a PR via gh."
```

Or do the PR step with OpenHands if you want it fully autonomous:

```bash
aw start openhands
# In the UI: "Open a PR for branch feat/savings-json titled 'feat(savings):
#  add --json output mode'. Use the last commit message as the body."
```

What you just built: a 3-agent pipeline (plan → edit → PR) where each agent
does the shape of work it is best at. This is the core idea of the
workbench — no single agent is best at everything.

---

## Next steps

- **Per-agent deep dives.** Read the doc for each agent you plan to use:
  - [`docs/agents/aider.md`](agents/aider.md)
  - [`docs/agents/goose.md`](agents/goose.md)
  - [`docs/agents/openhands.md`](agents/openhands.md)
  - [`docs/agents/ashlrcode.md`](agents/ashlrcode.md)
- **Workflow recipes.** [`docs/workflows.md`](workflows.md) has six
  tested recipes: refactor across files, add a feature, fix a bug, draft a
  PR description, review a PR, and scaffold a new project.
- **Architecture.** [`docs/architecture.md`](architecture.md) shows how
  `aw`, the agents, the MCP servers, LM Studio, and the genome fit together.
- **Cheatsheet.** [`docs/CHEATSHEET.md`](CHEATSHEET.md) is one printable
  page — keep it next to your keyboard.
- **When things break.** [`docs/troubleshooting.md`](troubleshooting.md).

## Mental model to take away

1. **LM Studio** is the default brain. It holds the weights. Everything else
   is an agent (harness) pointed at that brain, plus extra tools.
2. **`aw`** is the remote — the single CLI that starts, stops, and checks
   the agents.
3. **The 10 ashlr-plugin MCP servers** are the shared toolbelt. Every
   agent picks them up from the same place on disk.
4. **The genome** at `~/Desktop/.ashlrcode/genome/` is the shared memory.
   It survives across agents and across sessions.
5. You pick the agent for the shape of the task, not the other way around.
