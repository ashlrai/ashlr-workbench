# Workflows

Six recipes for common tasks. Each one names an agent (or pair) and tells
you the exact commands. If you're unsure which agent to pick, the
workflows answer it for the task at hand.

---

## 1. Refactor a function across files

**Goal.** Rename a symbol, change a signature, extract a helper — an edit
that touches 2–10 files and you already know which.

**Agent choice.** **Aider** for the edits (strict diffs, reviewable),
**ashlrcode** for optional planning if the scope is unclear.

**Why.** Aider's search/replace edit format is the safest way to apply a
rename cleanly. If the scope is fuzzy ("where does `UserId` propagate?"),
ashlrcode with `ashlr__grep` in plan mode surveys first.

### Step-by-step

Scope unclear? Start with ashlrcode:

```bash
aw start ashlrcode
> /plan
> I want to rename UserId to AccountId throughout this repo. Don't make
  changes. List every file that contains "UserId", the line counts, and
  anything that looks like it might be a breaking change.
> /exit
```

Then Aider, with the file list in hand:

```bash
aw start aider ~/Desktop/<repo>
> /add src/auth/types.ts src/auth/session.ts src/api/users.ts test/auth/session.test.ts
> Rename UserId to AccountId everywhere. Keep a type alias `type UserId =
  AccountId` with a JSDoc @deprecated tag in types.ts for back-compat.
> /run bun test
```

Aider produces one diff per file, asks y/n on each. After you accept,
`/run` streams the test output. Iterate on failures inside the same
session.

### Expected output

- 3–7 file diffs, each a clean search/replace.
- One new type alias with @deprecated.
- Tests green (or Aider fixes until green if you tell it to).

### Variations

- **Big repo, unclear scope.** Skip the ashlrcode plan; use
  `aw start ashlrcode` with `ashlr__orient` first: "How is UserId used
  across auth?"
- **Thinking model for harder refactors.**
  `aw start aider . --model openai/qwen3-235b-a22b-thinking-2507`
  (requires LM Studio to have that model loaded).

---

## 2. Add a new feature

**Goal.** Ship a bounded feature end-to-end: plan, implement, test, commit.

**Agent choice.** **ashlrcode** for planning + orchestration. **Goose**
(or Aider) for the implementation. The choice between Goose and Aider
depends on how tool-heavy the implementation is.

**Why.** ashlrcode's `/plan` is explicitly read-only — good for
front-loading exploration. Goose's MCP toolbelt is helpful when the
feature involves SQL, HTTP, or logs. If it's pure code, Aider is tighter.

### Step-by-step

Plan:

```bash
aw start ashlrcode
> /plan
> Add a --json output mode to the ashlr__savings CLI. Requirements:
  1. Existing human-readable output stays as default.
  2. --json prints a single-line JSON object with {tokensSaved, dollarsSaved,
     lifetime, session}.
  3. Updates the docs in docs/commands/ashlr-savings.md.
  Survey the code, propose a plan with concrete file changes. Ask me
  questions if anything is ambiguous.
> (review plan; ask follow-ups; tweak)
> /exit
```

Implement with Goose (tool-heavy: needs to run tests, call CLI, read JSON
output):

```bash
aw start goose ~/Desktop/ashlr-plugin
> Apply the plan saved in ./plan.md. Run bun test between each file change.
  Use ashlr__bash_start to run `bun test --watch` in the background so
  we get fast feedback.
```

Or implement with Aider if it's pure code, no testing acrobatics:

```bash
aw start aider ~/Desktop/ashlr-plugin
> /add servers/efficiency-server.ts scripts/savings-dashboard.ts scripts/savings-status-line.ts docs/commands/ashlr-savings.md
> Apply the changes from plan.md: add --json mode to ashlr__savings.
```

Commit:

```bash
aw start ashlrcode --prompt "Stage all changes. Write a tight Conventional
Commits message. Commit. Do not push."
```

### Expected output

- `plan.md` in the project root (gitignore it).
- 2–4 files changed.
- Tests green.
- One or two commits with clean messages.

### Variations

- **Skip the plan** if the feature is 1–2 files. Go straight to Aider.
- **Parallel scaffold.** Run OpenHands on a sibling task (say, a
  matching feature in a second repo) while you interactively work on
  this one.

---

## 3. Fix a bug

**Goal.** Reproduce a bug, find the cause, fix it, land a test.

**Agent choice.** **Aider** with `/ask` for the diagnosis, then Aider
directly for the fix. Fall back to Goose if you need MCP tools
(`ashlr__logs`, `ashlr__sql`) to reproduce.

**Why.** Bugs usually land on 1–2 files. Aider's ergonomics shine.
`/ask` keeps Aider in read mode so it won't prematurely edit.

### Step-by-step

```bash
aw start aider ~/Desktop/<repo>
> /add <the file you suspect>
> /add <the test file>
> /ask The bug: passing a sessionId of `undefined` to
  createSession() returns a real session with id="undefined". Where
  is the guard missing?
```

Aider reads, thinks, explains — no edits. Iterate questions until you
understand.

Then:

```
> /code Add an input-validation check: throw TypeError if sessionId is
  not a non-empty string. Update the existing test to cover the new
  throw, and add a second test confirming valid IDs still work.
> /run bun test
```

If Aider can't reproduce from reading alone, switch to Goose with the
`ashlr__bash` and `ashlr__logs` tools:

```bash
aw start goose ~/Desktop/<repo>
> ashlr__bash_start { cmd: "bun run dev" }
> Hit the endpoint that triggers the bug via ashlr__http.
> ashlr__logs to read the error trace.
> Locate the emit site via ashlr__grep.
> Propose a fix. Do not apply yet.
```

### Expected output

- A small, targeted fix (often <20 LOC).
- A regression test.
- Green tests.

### Variations

- **Use `git bisect` to narrow in.** Before opening an agent, run bisect
  to find the introducing commit. Give the agent the commit diff with
  "this change broke X; why?"
- **Complex, multi-day bug.** Use ashlrcode `/plan` first to capture
  hypotheses; consolidate findings into the genome via
  `ashlr__genome_propose → knowledge/discoveries.md`.

---

## 4. Write a PR description

**Goal.** Take a branch with commits, produce a clean PR description.

**Agent choice.** **ashlrcode** one-shot. Short, cheap, usually good.

**Why.** This is a pure I/O task: read `git diff`, write prose. No MCP
needed; no plan needed; no deep reasoning needed. Fast models shine.

### Step-by-step

```bash
cd ~/Desktop/<repo>
git checkout <branch>

aw start ashlrcode --prompt "Read the git diff from main to HEAD and the
commit log. Write a PR description with:
- a Summary (1-3 bullets, why not what)
- a Test Plan (markdown checklist of how a reviewer verifies)
- if any risks / rollback notes apply, add a Risks section
80-char wrap. No emojis. Output markdown only, no preface."
```

Copy-paste the output into `gh pr create --body-file <(pbpaste)` or the
GitHub UI.

### Expected output

~15–30 line PR body. Usually needs one editorial pass to trim generic
phrasing.

### Variations

- **Fully autonomous.** Let ashlrcode open the PR:
  ```bash
  aw start ashlrcode --prompt "Write a PR description for current
  branch, then push the branch and open the PR with gh."
  ```
  The `git push` and `npm publish` hooks will pause and ask you to
  confirm — that's the safety net.
- **Use the genome.** If you've been proposing
  `knowledge/decisions.md` entries during the work, include
  "consult knowledge/decisions.md for relevant ADRs" in the prompt.

---

## 5. Review a PR

**Goal.** Read a teammate's PR, flag issues, surface questions.

**Agent choice.** **ashlrcode** with Claude (if you want nuance) or
**OpenHands** if you want it to actually check out + run tests.

**Why.** Reading is the work. Claude is the best reader. OpenHands earns
its keep when the review requires running code (breaks CI in a subtle
way, etc.).

### Step-by-step — static review

```bash
aw start ashlrcode
> /model claude-3-7-sonnet     # if configured; else current provider
> Use ashlr__pr to fetch PR 1234 in this repo. Review it. Flag:
  1. Any changes that look like they break the existing API.
  2. Tests missing for new code paths.
  3. Naming / style that diverges from knowledge/conventions.md.
  4. Security smells.
  Output as a markdown list I can paste into the PR as a review.
```

### Step-by-step — runtime review

```bash
aw start openhands
# In the UI:
Task: Check out PR 1234. Install deps, run tests. If anything fails,
explain why. Open a terminal, run the new feature against the example
in the PR description. Write up findings as a PR review comment draft.
Do not actually submit the review.
```

### Expected output

A review draft you edit lightly and submit.

### Variations

- **Two-pass review.** Static with ashlrcode + Claude first, runtime
  with OpenHands second. Cross-check findings.
- **Long PR.** Use `ashlr__orient` + `ashlr__diff` to chunk the diff
  by subsystem before you read.

---

## 6. Set up a new project

**Goal.** Take a blank dir, initialize it as a proper workbench-friendly
repo with a genome.

**Agent choice.** **ashlrcode** (or your shell) for the `aw genome init`
bootstrap, then **Goose** for scaffolding with MCP tools.

**Why.** Goose is the right daily driver once the genome is up. The
genome seeds faster conversations going forward. ashlrcode's permission
rules give a safe baseline while the project is small.

### Step-by-step

```bash
mkdir ~/Desktop/new-thing
cd ~/Desktop/new-thing
git init

# Workbench genome bootstrap:
aw genome init .
# Or via Claude Code:
# /ashlr:ashlr-genome-init
```

You now have `.ashlrcode/genome/` populated with empty shells: vision/,
knowledge/, strategies/, milestones/.

Fill in the essentials by hand or by agent:

```bash
aw start goose
> Use ashlr__tree to confirm the current layout.
> Help me fill in vision/north-star.md — I want to build a
  TypeScript SDK for X. Draft a 3-bullet north star, then put it in
  via ashlr__genome_propose.
> Do the same for vision/architecture.md: a 1-paragraph architecture
  overview. Propose it.
> Then ashlr__genome_consolidate to merge the proposals.
```

Scaffold the repo:

```bash
> Initialize a Bun project: bun init, then add:
  - @modelcontextprotocol/sdk
  - tsx
  Create src/index.ts with a placeholder export.
  Create test/index.test.ts with one passing test.
  Commit everything as "chore: scaffold project".
```

### Expected output

- `.ashlrcode/genome/` populated with real content in vision/.
- Standard Bun + TS project structure.
- Initial commit on main.

### Variations

- **Start from a template.** `git clone` the template first, then
  `aw genome init .` on top.
- **Team-shared genome.** Commit `.ashlrcode/genome/` (except
  `pending/` and `evolution/`, which you can gitignore if you want
  private mutation logs).
- **Monorepo.** Put the workspace genome at the repo root, and optional
  per-package genomes inside each `packages/*/`.

---

## Combining workflows

A real day might look like:

- 09:00 — **Plan** a feature via workflow #2 (ashlrcode).
- 09:30 — **Implement** via Aider (workflow #2 continuation).
- 11:00 — **Set up a new project** (workflow #6) for a spike.
- 13:00 — **Fix a bug** in the first project (workflow #3).
- 15:00 — **Write a PR** for the feature (workflow #4).
- 16:00 — **Review** a teammate's PR (workflow #5).
- EOD — `aw genome consolidate` to fold the day's proposals into the
  workspace genome.

## Cross-cutting tips

- **Use the genome.** Every workflow above gets better when the agents
  have genome context. Propose freely; consolidate weekly.
- **Don't mix agents in one repl.** Switch sessions; don't try to run
  Aider and Goose in the same terminal. The conceptual overhead isn't
  worth it.
- **Keep sessions short.** `/clear` or `/exit` + new session after a
  task is done. Long-running sessions accrete irrelevant context.
- **Watch `/cost`.** In ashlrcode with Grok or Claude, a session can
  quietly burn $1–5. Check `/cost` before you `/exit`.
- **Local first when in doubt.** If data sensitivity is unclear, use
  LM Studio Qwen. The cost is latency, not money.

## Related docs

- Per-agent deep dives: `docs/agents/`
- Model decision guide: `docs/models.md`
- Cheatsheet (printable): `docs/CHEATSHEET.md`
- Troubleshooting: `docs/troubleshooting.md`
