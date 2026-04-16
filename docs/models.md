# Models

Which model for which agent for which task. This is a decision guide, not
an exhaustive benchmark. All numbers are rough estimates on an M-series Mac
with 48–64 GB unified memory; your mileage will vary.

## The four slots

Every agent in this workbench eventually calls one of these four model
families. Pick based on the axis that matters to the current task:
privacy, latency, quality, or cost.

```
                         privacy
                            │
         local-only ────────┼──────── cloud-only
                            │
          Qwen3-Coder-30B   │   Claude 3.5 / 3.7 Sonnet
          gemma4:26b        │   xAI Grok
                            │
                            ▼
                          cost
                    $0   │   $$$
          latency  ──────┼────── quality
                    slow │   fast/great
```

## Model-by-model

### Qwen3-Coder-30B (LM Studio, default)

**Where it runs.** LM Studio, `http://localhost:1234/v1`, API key `lm-studio`.
Apple Silicon native (MLX format if you picked that quant, otherwise GGUF
through `llama.cpp`).

**Strengths.**

- Tuned for code. Handles the standard Aider search/replace edit format
  reliably on files up to ~800 LOC.
- ~32 K context window. Enough for a repo-map-scoped Aider session or a
  short Goose task.
- Zero egress. Every token stays on-box. Safe for client code, private keys
  in `.env` you forgot to redact, etc.
- Fast prefill on Apple Silicon (100–300 tok/s prefill, 30–80 tok/s decode
  depending on quant and context length).

**Weaknesses.**

- Reasoning-lite. Struggles with deeply layered tasks like "refactor this
  inheritance hierarchy into composition across 6 files." Use the thinking
  variant (`qwen/qwen3-235b-a22b-thinking-2507`) or Claude instead.
- Context window is a ceiling, not a comfort zone. Past ~24 K it starts
  to miss details. Rely on `ashlr__grep` (genome-aware) to keep prompts
  short.
- No tool-use fine-tuning as strong as Claude's. MCP tool calls work but
  the model occasionally describes a tool call instead of emitting one —
  mostly harmless, but it shows up in long Goose sessions.

**Use it for.** Default for everything unless you have a reason otherwise.
Aider edits, Goose short tasks, OpenHands autonomous loops when you want
privacy, ashlrcode local fallback.

**Avoid for.** Long-context reasoning (>24 K), complex cross-file refactors,
anything that needs a strong planner.

**Typical invocation.**

```yaml
# aider.conf.yml
model: openai/qwen3-coder-30b
openai-api-base: http://localhost:1234/v1
openai-api-key: lm-studio
```

### Claude 3.5 / 3.7 Sonnet (Anthropic API)

**Where it runs.** `https://api.anthropic.com/v1`. Requires `ANTHROPIC_API_KEY`.

**Strengths.**

- Best-in-class reasoning and long-context work (200 K context).
- Best tool-use behavior of any model in this lineup. Paired with MCP, it
  is noticeably more likely to pick the right tool on the first try.
- Prompt caching makes multi-turn sessions cheap on repeat content (you
  pay 10% for cached tokens on reads). Good fit for Claude Code + MCP.

**Weaknesses.**

- Not local. You send code and context to Anthropic.
- Costs money. Typical Claude Code session on a feature runs $1–$5.
- Rate-limited. If you run OpenHands unattended on Claude for hours, you
  will hit org limits.

**Use it for.** Complex multi-step refactors, PR reviews where you want
nuance, anything where Qwen is demonstrably failing and you have already
spent 15 minutes trying to unstick it locally.

**Avoid for.** Routine edits, anything with data that should not leave
your laptop.

**Typical invocation.**

```json
// ashlrcode settings.json
"providers": {
  "primary": {
    "provider": "anthropic",
    "apiKeyEnvVar": "ANTHROPIC_API_KEY",
    "model": "claude-3-7-sonnet-20250219"
  }
}
```

Or for ashlrcode one-shot:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
ashlrcode --provider anthropic --model claude-3-7-sonnet-20250219 \
  "review the staged diff"
```

### gemma4:26b (Ollama)

**Where it runs.** Ollama, `http://localhost:11434`. Pull with
`ollama pull gemma4:26b`.

**Strengths.**

- Good general language model. Strong at summarization and rewriting prose.
- Local, free, no API key.
- Plays well with Ollama's quantized variants. On a 48 GB Mac, `gemma4:26b`
  runs in Q4_K_M at ~15 tok/s.

**Weaknesses.**

- Not a coding-specialist. Noticeably worse than Qwen3-Coder-30B on raw
  code generation and edits.
- Slower than Qwen3-Coder on the same hardware for code tasks (gemma
  wastes tokens on chatter).
- Ollama's OpenAI-compat endpoint is on a different port (`:11434/v1`),
  so switching providers requires a config edit, not just a model swap.

**Use it for.** Summarization fallbacks when LM Studio is busy serving
Qwen on another session. Writing documentation bodies. Quick "explain
this log" one-shots.

**Avoid for.** Primary coding model. Seriously — use Qwen.

**Typical invocation.**

```bash
# One-shot summarization via ashlr__http fallback:
OLLAMA_BASE=http://localhost:11434/v1 \
  ashlrcode --model gemma4:26b "summarize the top 5 discussions in this log"
```

### xAI Grok (ashlrcode default)

**Where it runs.** `https://api.x.ai/v1`. Requires `XAI_API_KEY`.

**Strengths.**

- Fast. Grok's `grok-4-1-fast-reasoning` is noticeably quicker than Claude
  for short turns.
- Good general reasoning — between Qwen-30B and Claude Sonnet on most
  everyday tasks.
- Cheaper per token than Claude (current pricing; verify before relying on it).

**Weaknesses.**

- Cloud-only. Same privacy caveat as Claude.
- Tool-use behavior is decent but inconsistent — sometimes it narrates
  a tool call rather than emitting one. Less frequent than Qwen, more
  frequent than Claude.
- Less deep reasoning headroom than Claude Sonnet on hard refactors.

**Use it for.** ashlrcode default; fast iterative sessions where quality
matters more than cost but Claude's premium is not worth it. Quick Q&A
about a repo.

**Avoid for.** Privacy-sensitive code. Very long-context synthesis
(Claude is better).

**Typical invocation.** Already wired as ashlrcode primary in
`agents/ashlrcode/settings.json`. Override per-session with `/model`.

## Agent × model matrix

Default pairings in the workbench. Rows are agents, columns are providers.

| Agent       | Default         | Fallback         | Why                                             |
|-------------|-----------------|------------------|-------------------------------------------------|
| Aider       | Qwen3-Coder-30B | (manual `--model`) | Aider's edit format benefits from a coding-specialist; local is cheap |
| Goose       | Qwen3-Coder-30B | — (no auto)      | MCP tool calls are short; Qwen is fast enough  |
| OpenHands   | Qwen3-Coder-30B | Claude via env   | Long-horizon runs stay on-box; escalate to Claude for reasoning hardship |
| ashlrcode   | xAI Grok        | LM Studio (Qwen) | Grok primary for speed; `/model lmstudio-local` to go local |

## "Which model should I pick right now"

Shortest useful decision table:

| You want to...                                     | Pick this                    |
|----------------------------------------------------|------------------------------|
| Edit 1–3 files you already know                    | Qwen3-Coder-30B via Aider    |
| Explore a repo you don't know                      | Qwen3-Coder-30B via Goose + ashlr__orient |
| Refactor across 6+ files with tricky types         | Claude 3.7 Sonnet via ashlrcode (`/plan` first) |
| Run a 20-min autonomous task on laptop            | Qwen3-Coder-30B via OpenHands |
| Same task but you hit a reasoning wall             | Swap OpenHands to Claude via LLM settings in UI |
| Summarize a 10 K-token log file                    | gemma4:26b via Ollama        |
| Review a PR line-by-line                           | Claude 3.7 Sonnet            |
| Draft a PR description from a diff                 | Grok (fast, cheap, good enough) |
| Work on proprietary / NDA code                     | Qwen3-Coder-30B (local only) |

## Tradeoff axes

Pick the one you care most about right now and that tells you which model.

**Latency.** Grok fast path < local Qwen < Claude < gemma4 (slow).

**Quality on code.** Claude ≥ Qwen3-Coder-30B > Grok > gemma4. For hard
reasoning: Claude >> everything else.

**Privacy.** Local (Qwen, gemma) >> cloud (Grok, Claude). If the repo
has credentials you haven't rotated, assume "local only."

**Cost per 1M tokens** (order-of-magnitude, check current pricing):

| Model                      | Input    | Output   |
|---------------------------|----------|----------|
| Qwen3-Coder-30B (local)   | $0       | $0       |
| gemma4:26b (local)        | $0       | $0       |
| xAI Grok                  | ~$3      | ~$15     |
| Claude 3.7 Sonnet         | ~$3      | ~$15     |

"Free" for local = electricity + wear-and-tear on your laptop. A long
OpenHands run on local Qwen keeps the GPU pegged for hours; treat it like
a background compile.

## Swapping models safely

- **Aider.** `./scripts/start-aider.sh . --model openai/qwen3-235b-a22b-thinking-2507`
  — first positional arg is the project dir, everything after is forwarded.
- **Goose.** Edit the `provider:` block in `agents/goose/config.yaml` and
  re-run `./scripts/start-goose.sh` (the script copies the canonical config
  on every launch).
- **OpenHands.** LLM settings live in the web UI under Settings → LLM.
  These are persisted in `~/.openhands/`.
- **ashlrcode.** `/model lmstudio-local` in the REPL, or edit
  `agents/ashlrcode/settings.json` primary/fallback blocks and re-launch.

If you add a brand-new provider (say, Google Vertex), you update the agent's
config — `aw` itself does not need to know about models.
