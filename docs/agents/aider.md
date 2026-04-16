# Aider

Git-native surgical-edit REPL. Point it at a repo, tell it what to change,
review each diff, accept or reject. No MCP, no autonomy — by design.

## What it is

Aider ([aider.chat](https://aider.chat)) is an open-source AI pair
programmer that runs in your terminal. It builds a "repo map" of your
codebase, chats with an LLM, emits strict search/replace diffs, applies
them in place, and (optionally) commits each edit to git.

Inside this workbench it is configured to talk to **LM Studio** running
`qwen/qwen3-coder-30b`. Every token stays on your Mac.

Config lives in:

- `agents/aider/aider.conf.yml` — canonical Aider config (model, endpoint,
  colors, history paths).
- `scripts/start-aider.sh` — launcher that health-checks LM Studio,
  `cd`s into the target repo, and execs `aider --config <the yml>`.

## When to use it

1. **You know the file.** "In `src/auth/session.ts` add an `expiresAt`
   param to `createSession()` and update all callers." Aider is the fastest
   path here.
2. **You want reviewable diffs.** Every edit is a unified diff you approve
   or reject. Great for PR-style work where each change matters.
3. **Rename a symbol across the repo.** Aider's repo map lets it find all
   usages without you naming every file.
4. **Port a test to a new harness.** Drop the old test and the new harness
   files into context; tell Aider what to do.
5. **Quick shell + code loop.** `/run npm test` pipes output back into the
   chat — fast edit-test-edit cycles.

## When NOT to use it

- **Exploratory work.** Aider has no MCP tools. Use Goose or ashlrcode if
  you need `ashlr__grep`, `ashlr__orient`, SQL, HTTP, etc.
- **Multi-hour autonomous tasks.** Aider is interactive; it will wait for
  you at every edit. Use OpenHands.
- **Working in a repo you don't know yet.** Aider expects you to guide
  which files it looks at. On unfamiliar repos, `orient` with Goose first,
  then hand off to Aider.
- **Non-code tasks.** Writing docs, summarizing logs, drafting prose —
  Aider is overkill.
- **Anything that needs an approval model stricter than "y/n on each
  diff."** Aider doesn't do role-based permissions.

## How to start it

```bash
# Current dir is the target repo:
aw start aider

# Specific repo:
aw start aider ~/Desktop/some-project

# Forward extra flags after the directory:
aw start aider . --model openai/qwen3-235b-a22b-thinking-2507
aw start aider . --no-git
aw start aider . path/to/file.ts   # pre-add a file
```

Under the hood `aw start aider` is exactly
`./scripts/start-aider.sh $@`. The script fails fast if LM Studio is not
reachable, which saves you a confusing timeout later.

## Config explained

The important bits of `agents/aider/aider.conf.yml`:

```yaml
model: openai/qwen3-coder-30b
openai-api-base: http://localhost:1234/v1
openai-api-key: lm-studio       # LM Studio ignores the value, Aider needs *something*

auto-commits: false             # You commit, Aider does not.
dirty-commits: false            # Don't "save-as-you-go" on dirty trees.
attribute-author: false         # Don't alter git author to "aider".
gitignore: true                 # Honor .gitignore when building the repo map.
aiderignore: .aiderignore       # + extra ignore patterns if present.

map-tokens: 4096                # Repo map budget. Qwen handles this well.
map-refresh: auto               # Auto-rebuild when files change.

watch-files: true               # `# aider do-the-thing` comments trigger edits.

auto-lint: false                # Don't run your linter. You or AGENT.md can.
auto-test: false                # Same.

analytics-disable: true         # No telemetry.
check-update: false             # No phone-home.
```

Why these defaults:

- **`auto-commits: false`**: workbench style is "agent produces diffs,
  human reviews + commits." This is also why `dirty-commits: false`
  and `attribute-author: false`.
- **`map-tokens: 4096`**: Qwen3-Coder-30B tolerates a chunky repo map.
  On a small repo (<500 files) this is approximately "include
  everything." On bigger repos the tree is summarized.
- **`watch-files: true`**: drop `# aider: extract this into a helper` in
  code, save the file, and Aider notices on the next turn without you
  switching windows.

## Common commands inside Aider

| Command                           | Effect                                            |
|-----------------------------------|---------------------------------------------------|
| `/add <file>`                     | Add a file to the chat context                    |
| `/drop <file>`                    | Remove it                                         |
| `/ls`                             | Show files currently in chat                      |
| `/diff`                           | Show pending diff since last commit               |
| `/undo`                           | Revert the last aider-made commit                 |
| `/run <cmd>`                      | Run a shell command, pipe output back into chat   |
| `/test <cmd>`                     | Like `/run` but marks as a test run               |
| `/ask <q>`                        | Ask a question, no edits produced                 |
| `/architect <msg>`                | High-level plan mode (if using a thinking model)  |
| `/code <msg>`                     | Force implementation mode (default)               |
| `/model [name]`                   | Switch model mid-session                          |
| `/clear`                          | Drop chat history (keeps files in context)        |
| `/reset`                          | Drop chat + files                                 |
| `/help`                           | Full command list                                 |
| `Ctrl-D` or `/exit`               | Quit                                              |

## Worked examples

### 1. Add a parameter and update callers

```
> /add src/auth/session.ts
> Add an expiresAt: Date param to createSession(). Default to 24h from now
  when omitted. Update all callers in this file to pass it explicitly.
```

Aider produces a diff, asks to apply. After `y`, you inspect:

```
> /diff
> /run bun test auth
```

If tests fail, paste the output or just say "fix." Aider reads the
`/run` output from history.

### 2. Watch-files trigger

Edit `src/db/migrations.ts` in your editor, drop a comment:

```typescript
// aider: refactor this to use the shared Migration class from ../types
```

Save. On Aider's next turn you get a diff to review.

### 3. Repo-wide rename

```
> Rename symbol `UserId` to `AccountId` everywhere. Keep the current
  file's type alias for backwards compat; deprecate it with a JSDoc.
```

Aider uses the repo map to find usages. Confirm the list of files before
accepting.

### 4. Port a test file

```
> /add test/old/session.test.ts
> /add test/new-harness/shared.ts
> Rewrite session.test.ts to use the new harness pattern shown in
  shared.ts. Keep every assertion; drop the setup boilerplate.
```

## Integration points

- **Models.** Aider is OpenAI-compatible. Points at LM Studio by default;
  swap with `--model openai/<id>` or edit the config. See
  `docs/models.md`.
- **Git.** Aider produces diffs against HEAD. If you have uncommitted
  changes, Aider still runs, but `dirty-commits: false` means it won't
  commit until your tree is clean.
- **MCP.** None. Aider does not speak MCP. If you need `ashlr__grep`,
  `ashlr__orient`, etc., do the exploration in Goose or ashlrcode,
  then bring the findings into Aider as `/add` files or explicit context.
- **Hooks.** No hook integration. If you want pre-commit checks, put
  them in `.git/hooks/` or run `/run` yourself.

## Known limitations

- **Edit format is brittle on long files.** For files >800 LOC, Aider
  sometimes fails to locate the exact search string. `/clear` and retry,
  or switch to `--edit-format udiff`.
- **Repo map cost.** First turn on a large repo builds the map (10–30 s).
  Cache lives in `.aider.tags.cache.v3/`.
- **No multi-file atomicity.** If Aider produces diffs for 4 files and
  you accept all 4, each is applied separately. If one fails mid-way,
  the others still landed.
- **`watch-files` surprises.** If you have autoformat-on-save + Aider
  watching, formatting the file can trigger Aider. Turn off
  watch-files or disable autoformat during Aider sessions.
- **No image support.** Text-only. If you need to paste a screenshot,
  use ashlrcode or Claude Code.

## Upstream references

- Aider docs: https://aider.chat/docs/
- Config reference: https://aider.chat/docs/config/aider_conf.html
- Edit formats: https://aider.chat/docs/more/edit-formats.html
- Repo map: https://aider.chat/docs/repomap.html
- LM Studio: https://lmstudio.ai/
- Workbench `agents/aider/README.md`: concrete launch commands and colors.

## See also

- `docs/workflows.md` for recipes that combine Aider with other agents
  (plan with ashlrcode, edit with Aider, PR with OpenHands).
- `docs/troubleshooting.md` → Aider section.
