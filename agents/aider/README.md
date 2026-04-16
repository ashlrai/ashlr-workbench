# Aider — Ashlr Workbench

[Aider](https://aider.chat) is a git-native AI pair programmer that runs in your
terminal. It reads your repo, proposes edits as unified diffs, applies them in
place, and (optionally) commits each change. Inside this workbench it is wired
to **LM Studio** so every token stays on the local machine.

## Why it's in this workbench

Aider is the workbench's **surgical-edit agent**. It is not a general-purpose
autonomous coder — it is a laser-focused "change these exact files" tool:

- **Precise diffs.** Aider's edit format is a strict search/replace; the model
  must quote the original text verbatim. That rules out whole categories of
  hallucinated edits.
- **Git-aware.** It builds a repo map, understands history, and keeps each
  change reviewable.
- **Local-first.** Pointed at `http://localhost:1234/v1` with
  `qwen/qwen3-coder-30b` — zero egress, no API bill.

## What's configured here

| File | Purpose |
|---|---|
| `agents/aider/aider.conf.yml` | Workbench-pinned Aider config (model, endpoint, colors, history paths) |
| `scripts/start-aider.sh` | Launcher that checks LM Studio, `cd`s into the target repo, and exec's aider with this config |

Key knobs already set:

- `model: openai/qwen3-coder-30b` against LM Studio
- `auto-commits: false`, `dirty-commits: false` — you review and commit
- `watch-files: true` — drop a `# aider ...` comment in code to trigger an edit
- `map-tokens: 4096` — generous repo map (Qwen3-Coder handles it)
- `pretty: true`, `stream: true`, custom terminal colors
- `.aiderignore` respected alongside `.gitignore`

## Quickstart

```bash
# 1. Make sure LM Studio is running and has loaded qwen/qwen3-coder-30b.
#    (The launcher will hard-fail with a clear message if the endpoint is down.)

# 2. Launch aider in the current repo:
./scripts/start-aider.sh

# 3. Or target a specific repo:
./scripts/start-aider.sh ~/Desktop/some-project

# 4. Pass extra aider flags after the directory:
./scripts/start-aider.sh . --model openai/qwen3-235b-a22b-thinking-2507
./scripts/start-aider.sh . --no-git          # ephemeral scratch mode
./scripts/start-aider.sh . path/to/file.ts   # pre-add a file to the chat
```

Inside Aider, useful commands:

| Command | Effect |
|---|---|
| `/add <file>` | Add a file to the chat context |
| `/drop <file>` | Remove it |
| `/diff` | Show the pending diff since last commit |
| `/undo` | Revert the last aider-produced commit |
| `/run <cmd>` | Run a shell command and feed output into the chat |
| `/ask <q>` | Ask a question without requesting edits |
| `/help` | Full command list |

## When to use this vs OpenHands vs Goose

| Pick | If you want... |
|---|---|
| **Aider** | Targeted edits to known files, reviewable diffs, repo-aware refactors. "Rename this symbol everywhere," "add a param to this function and update callers," "port this test to the new harness." |
| **OpenHands** | An autonomous agent that spins up a sandboxed VM, runs commands, browses the web, and iterates until a task is done. Good for green-field scaffolding and end-to-end tasks. |
| **Goose** | A Block-made agent with first-class extensions (MCP, SQL, browser) and memory. Best for multi-step workflows that span tools — "query prod, analyze, open a PR." |

Rule of thumb: if you can point at the files that need to change, use Aider.
If the task requires exploration, sandboxed execution, or tool orchestration,
reach for OpenHands or Goose.

## Troubleshooting

**`LM Studio endpoint … not responding`**
LM Studio isn't running or hasn't loaded a model. Open LM Studio, load
`qwen/qwen3-coder-30b`, confirm the server tab shows `http://localhost:1234`,
then retry.

**Model mismatch / "unknown model" error**
The `openai/` prefix is required — it tells Aider to use the OpenAI-compatible
client, not OpenAI proper. Verify with `curl http://localhost:1234/v1/models`
that `qwen/qwen3-coder-30b` appears in the list.

**Edits keep failing to apply**
Aider needs exact text to search-and-replace. If the model keeps missing,
`/clear` the chat, `/add` a smaller set of files, and retry. For very large
files, consider `--edit-format diff-fenced` or switching to the thinking model
(`--model openai/qwen3-235b-a22b-thinking-2507`).

**Slow first response**
Repo-map generation on a cold start can take 10-30s on large repos. Subsequent
turns are fast. Tune with `map-tokens` in `aider.conf.yml` if needed.

**Chat history in commits**
`.aider.chat.history.md` and `.aider.input.history` live in each project's
working dir. Add them to that project's `.gitignore`:
```
.aider.chat.history.md
.aider.input.history
.aider.tags.cache.v3/
```

**Want to disable the repo map entirely**
Pass `--map-tokens 0` to `start-aider.sh` (it forwards extra args to aider).

## References

- Aider docs: https://aider.chat/docs/
- Config reference: https://aider.chat/docs/config/aider_conf.html
- LM Studio: https://lmstudio.ai/
