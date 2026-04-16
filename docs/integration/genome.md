# The genome

Shared, versioned memory for every agent in the workbench. A genome is a
directory of markdown files plus a manifest. Agents read it for
orientation and propose updates as they learn.

## What a genome is

A filesystem layout:

```
.ashlrcode/
  genome/
    manifest.json             ← index: tags, summary, tokens per section
    vision/
      north-star.md
      architecture.md
      principles.md
      anti-patterns.md
    knowledge/
      architecture.md
      conventions.md
      decisions.md
      dependencies.md
      discoveries.md
      workspace.md            (auto: discovered repos + projects)
    strategies/
      active.md
      experiments.md
      graveyard.md
    milestones/
      current.md
      backlog.md
      completed/
    evolution/
      (append-only mutation log, one file per consolidation)
    pending/
      (transient: proposed mutations before consolidation)
```

Two defining properties:

1. **Content-addressable by tag and section.** Every section has a
   `title`, `summary`, `tags[]`, and `tokens` count in `manifest.json`.
   Agents retrieve by tag overlap, not by blind grep.
2. **Append-mostly lifecycle.** Proposals land in `pending/`. Consolidation
   merges them in place and records the diff in `evolution/`. You can
   always walk back through `evolution/`.

Example `manifest.json` entry:

```json
{
  "path": "knowledge/conventions.md",
  "title": "Coding Conventions",
  "summary": "Style, lint, and naming rules that apply to this workspace",
  "tags": ["knowledge", "conventions", "style", "lint"],
  "tokens": 82,
  "updatedAt": "2026-04-16T04:22:05.054Z"
}
```

## Where genomes live in this workbench

Two levels, by design:

### Workspace-level genome

At `~/Desktop/.ashlrcode/genome/`. Shared across every repo in
`~/Desktop/`. Populated automatically on first `aw genome init` —
discovers repos + CLAUDE.md files and seeds `knowledge/workspace.md`.

This is the one Mason uses in daily work. Vision, principles, and
active strategies cross projects; it makes sense for them to live here.

### Per-project genome (optional)

At `<project>/.ashlrcode/genome/`. Scoped to a single repo. When present,
`ashlr__grep` and `ashlr__orient` prefer it.

When to create one:

- The project has strong domain knowledge that doesn't generalize to
  your workspace (e.g. a Roblox game with Luau-specific conventions).
- You collaborate with others on this repo and want the genome in
  source control (it's just markdown + JSON — checks in cleanly).
- You're running long autonomous OpenHands sessions in it and want
  the genome to trap "lessons learned" over time.

Initialize with:

```bash
cd <project>
aw genome init .
```

## How agents read the genome

`ashlr__grep` (in `ashlr-efficiency` server) detects
`.ashlrcode/genome/` and routes through `retrieveSectionsV2`:

```
  agent: ashlr__grep("how does the session store work")
         │
         ▼
  look for .ashlrcode/genome/ from CWD upward
         │
   ┌─────┴───────┐
   │             │
   found?        not found
   │             │
   ▼             ▼
  retrieveSectionsV2        ripgrep fallback
   └───── rank sections ────────┘
          by tag overlap + term match
                 │
                 ▼
          return top K with bodies
```

Benefits over raw ripgrep:

- **~80% token savings** on orientation queries (per ashlr-plugin's
  benchmark, `docs/benchmarks.json`).
- **More relevant results.** The manifest knows a section's intent; a
  pattern match does not.
- **Deterministic** — same query, same order, same sections.

If you want to bypass genome and force ripgrep (e.g. when grepping
code strings, not concepts), the agent can set `bypassSummary: true`
on the tool call, or you can call `ashlr__grep` with a regex that
obviously targets code (in which case retrieveSectionsV2 will still
try, but fall back when tag overlap is zero).

`ashlr__orient` uses the same retrieval under the hood, wrapped with
file reads and LLM synthesis.

## How agents update the genome

Three tools from `ashlr-genome`:

### `ashlr__genome_propose`

Queue a proposed change. Writes to `pending/<uuid>.json`.

```
ashlr__genome_propose {
  section: "knowledge/decisions.md",
  title: "ADR-0007: Prefer Zustand over Redux for session store",
  content: "Decision + rationale + consequences, 3 short paragraphs",
  tags: ["knowledge", "decisions", "state-management"]
}
```

Proposals are **cheap and non-binding** — agents should propose
liberally. The consolidation step is where quality gates happen.

### `ashlr__genome_consolidate`

Merge `pending/*` into the genome. Two modes:

- **Direct merge.** Append proposed content to the target section file,
  update manifest token count, write an evolution log entry. Default.
- **LLM-merged.** Send pending proposals + current section to a local
  LLM with a dedupe / rewrite prompt, write the LLM output back. Opt-in
  via `endpointOverride` or the agent's config.

Either mode produces an entry in `evolution/<timestamp>.json` with
before/after hashes and the proposal IDs merged.

Cadence: manually (`aw genome consolidate`) or on a timer. Mason tends
to consolidate at end-of-day.

### `ashlr__genome_status`

Quick report:

```
Pending proposals: 3
  - knowledge/decisions.md (ADR-0007)
  - strategies/active.md (switch from Zod to Valibot)
  - vision/architecture.md (introduce event bus)
Last consolidation: 2026-04-14T18:30:00Z (5 proposals → 3 sections)
Current generation: 1
```

## The workflow

End-to-end:

```
┌───────────────────────────────────────────────────────────────────┐
│ 1. agent calls ashlr__grep or ashlr__orient for a query            │
│    → genome retrieval returns top sections → 80% fewer tokens in   │
│      prompt                                                        │
└───────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────────────┐
│ 2. agent does work, observes a fact worth remembering               │
│    → ashlr__genome_propose writes a pending/*.json                  │
└───────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────────────┐
│ 3. periodically: ashlr__genome_consolidate                          │
│    → pending → section files                                        │
│    → evolution/<ts>.json records the merge                          │
│    → manifest.json updated with new token counts + summaries        │
└───────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────────────┐
│ 4. next session (maybe a different agent) starts                    │
│    → ashlr__grep retrieves the newly-consolidated knowledge         │
│    → feedback loop closed                                           │
└───────────────────────────────────────────────────────────────────┘
```

## Multi-agent genome safety

The propose / consolidate separation is what makes concurrent agents
safe:

- Goose + ashlrcode + OpenHands can all be in flight proposing to the
  same section. Each proposal is a fresh file in `pending/`.
- Consolidation is single-threaded (runs on demand or via hook). It
  sees all pending at once and merges coherently.
- Evolution log means nothing is lost, even if consolidation decides
  to drop a proposal.

## What to put in which section

Rule of thumb:

| Section                       | For                                                    |
|-------------------------------|--------------------------------------------------------|
| `vision/north-star.md`        | The end-state you're working toward                    |
| `vision/architecture.md`      | System-wide design; not per-feature                    |
| `vision/principles.md`        | "We prefer X over Y" rules                             |
| `vision/anti-patterns.md`     | "Never do this, here's why"                            |
| `knowledge/architecture.md`   | Actual current architecture (as built, not as dreamed) |
| `knowledge/conventions.md`    | Code style, naming, lint                               |
| `knowledge/decisions.md`      | ADRs — one per significant decision                    |
| `knowledge/dependencies.md`   | Why specific libs (not just `package.json` contents)   |
| `knowledge/discoveries.md`    | "Huh, turns out X" — small but useful facts            |
| `knowledge/workspace.md`      | Auto-populated; list of repos and their purpose        |
| `strategies/active.md`        | Ongoing approaches you're testing                      |
| `strategies/experiments.md`   | Started but inconclusive                               |
| `strategies/graveyard.md`     | Tried and abandoned, with reason                       |
| `milestones/current.md`       | Current release / milestone goals                      |
| `milestones/backlog.md`       | Future                                                 |
| `milestones/completed/`       | Archive                                                |
| `evolution/`                  | (auto) mutation log — don't hand-edit                  |
| `pending/`                    | (auto) proposal inbox — don't hand-edit                |

## Hand-editing the genome

Totally fine. Edit the markdown directly, then run:

```bash
aw genome reindex         # recompute manifest.json token counts + summaries
```

If you change structural things (add a new section), also update the
manifest's `sections[]` array. The `aw genome init` command regenerates
the manifest from scratch (destructive — nukes stale entries).

## Backups and portability

Because a genome is just files, it ships with your workspace:

- Commit per-project genomes to git if they're team-shared.
- Keep the workspace genome in a personal cloud sync (iCloud, Syncthing).
- To migrate to a new machine, copy the directory.

## When NOT to use a genome

- **Throwaway experiments.** If the project is a scratch dir you'll
  delete tomorrow, skip the genome. It's pure overhead for 1-day work.
- **Very small repos.** Under ~500 LOC there's not enough material to
  retrieve. Ripgrep is fine.
- **Public / generated docs.** Don't duplicate what's already in
  README.md. The genome should capture the stuff that isn't written
  anywhere else.

## Related docs

- `docs/integration/ashlr-plugins.md` → `ashlr-genome` and `ashlr-efficiency`
  servers.
- `docs/architecture.md` → genome in the data-flow diagram.
- `~/Desktop/ashlr-plugin/servers/genome-server.ts` → the implementation.
