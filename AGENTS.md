# AGENTS.md

Shared rules for every agent that runs out of this workbench. Goose, Aider,
OpenHands, and ashlrcode are all configured to read this file (or a pointer to
it) at session start. The conventions here override the agent's defaults.

## Safety — non-negotiable

1. **Never delete uncommitted work.** Before any destructive operation
   (`rm -rf`, `git reset --hard`, `git clean -fd`, overwriting a file with
   unstaged changes), verify the working tree is clean or stash first. If the
   user explicitly asks for the destructive op, do it — but say what's about
   to be lost.
2. **Never force-push to `main` / `master` / `production`.** Branch + PR for
   anything that lands on a protected branch. If the user insists on a
   force-push to main, warn them with the commit list that's about to be
   discarded and require an explicit "yes, force-push main".
3. **Ask before destructive ops on shared infrastructure.** Dropping tables,
   deleting Docker volumes, removing dotfile directories, killing background
   processes you didn't start — all require confirmation.
4. **Don't bypass hooks** (`--no-verify`, `--no-gpg-sign`) unless the user
   explicitly asks for it. If a pre-commit hook fails, fix the root cause.
5. **Never amend a commit that hasn't been pushed by you in this session.**
   Create a new commit instead — amending throws away the previous content.
6. **Don't `git add -A` blindly.** Stage the specific files you intend to
   commit; `-A` sweeps in `.env`, build artifacts, and unrelated edits.

## Secrets

- Read secrets only from `.env` at the repo root or `~/.ashlr/`. Never
  `cat ~/.aws/credentials`, `~/.ssh/`, `~/Library/Keychains/`, `1Password`
  vault paths, or anything that looks like a credential store.
- Never echo a secret value into a prompt, log line, or commit message. If you
  need to confirm a key is set, check `[ -n "$VAR" ]` and report "set" /
  "unset" — never the value.
- If you discover a hard-coded secret in the codebase, stop, surface it, and
  ask whether to rotate or extract.

## Style — match the human

- **Concise. Direct. No filler.** Skip "I'll now…", "Great question!", "Let me
  know if you need anything else." Get to the answer.
- **Surface assumptions, risks, and unknowns proactively.** If a change has
  multiple valid approaches, name them with the tradeoff before picking one.
- **Don't gold-plate.** If the user asks for X, deliver X — don't bundle
  unrelated refactors. Mention adjacent improvements in a sentence at the end.
- **Match the code that's already there.** Look for existing utilities and
  conventions before writing new helpers.
- **No emojis** in code, commits, or PR descriptions unless explicitly asked.

## Investigation defaults

- Before any non-trivial task: `git status`, scan recent commits in the area,
  search for existing patterns. ~30 seconds of orientation saves an hour of
  rework.
- For tasks touching 3+ files: explore the dependency surface first. Don't
  jump straight to edits.
- Ask 1–3 strategic questions when the task is ambiguous — questions specific
  to what you found, not generic clarifiers.

## Verification

After making changes, prove they work:

```bash
# Workbench itself
./bin/aw help && ./bin/aw status && ./scripts/healthcheck.sh

# Per-language defaults (run whichever applies)
bun test                  # JS/TS projects with Bun
npm test                  # JS/TS projects with npm
pytest                    # Python projects
cargo test                # Rust projects
go test ./...             # Go projects
shellcheck <file>         # Shell scripts (if shellcheck is installed)
bash -n <file>            # Shell syntax check (always available)
```

If the project has a `Makefile`, `justfile`, or `package.json` `scripts`
block, prefer those — they encode the project's intended commands.

## Tool boundaries

- **Filesystem**: stay inside the user's project + `~/.ashlr/` + the workbench
  itself. Don't write outside the project root without asking.
- **Network**: HTTP fetches are fine; arbitrary outbound auth (sending data to
  a third-party API) needs the user's say-so.
- **Shell**: long-running background processes (`&`, `nohup`, daemons) should
  be tracked — capture the PID and tell the user how to kill it.
- **Git**: read freely (`git log`, `git diff`, `git blame`); write only as
  described in "Safety" above.

## When you're stuck

- Don't loop on the same approach. After two failed attempts at the same
  strategy, step back and consider a different one.
- If you don't know enough about the codebase, say so — ask for a pointer to
  the relevant file/function before guessing.
- Surfacing "I'm not sure, here are two options" beats picking wrong silently.

## Reference

- Mason's working style: `~/.claude/CLAUDE.md`
- Workbench overview + conventions: `./CLAUDE.md`
- Per-agent quirks: `./agents/<name>/README.md`
