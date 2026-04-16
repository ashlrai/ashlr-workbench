# Troubleshooting

Concrete problems, concrete fixes. Sorted by frequency.

## Cheatsheet

Run this first. It will tell you what is broken 80% of the time:

```bash
aw doctor
```

If `aw doctor` says "all clear" but something is still off, skim the
section for the agent you were running.

---

## LM Studio

### LM Studio endpoint not responding

Symptom (from `start-aider.sh`):

```
start-aider: LM Studio endpoint http://localhost:1234/v1 not responding.
  Start LM Studio and load qwen/qwen3-coder-30b, then retry.
```

Fix:

1. Open LM Studio (the GUI).
2. Developer tab → "Start Server" → confirm port `1234`.
3. If the toggle was already on, click Stop then Start. LM Studio
   occasionally stops binding the port silently after a sleep.
4. Confirm with `curl -fsS http://localhost:1234/v1/models`.

### Model not loaded

Symptom: `curl` returns `{"data":[]}` or a model ID that is not
`qwen/qwen3-coder-30b`.

Fix:

1. LM Studio → My Models → find `qwen/qwen3-coder-30b`.
2. Click Load. Wait for the memory bar to settle.
3. Check the terminal again.

### "Out of memory" when loading the model

Typical on a 32 GB Mac trying to load the Q6 quant.

Fix:

- Download a smaller quant of the same model: Q4_K_M fits in ~20 GB.
- Or unload any other loaded models (LM Studio stacks them in memory).
- Close Chrome. Seriously — Chrome with 30 tabs chews through 6 GB that
  would otherwise be available for weights.

### LM Studio is slow (<20 tok/s decode)

- Check Activity Monitor → Memory → Memory Pressure. If it's yellow or red,
  close tabs and other Electron apps.
- Confirm GPU acceleration is on: LM Studio → Settings → Hardware →
  should report Apple Metal, not CPU.
- Context length matters. A 32 K context Aider session decodes slower than
  an 8 K one. Drop `map-tokens` in `aider.conf.yml` if you don't need the
  full repo map.

---

## Ollama

### Ollama not running

Symptom: `aw health` shows `ollama: fail`. Ollama is optional — nothing
breaks unless you explicitly swap to it.

Fix:

```bash
ollama serve &              # launches on :11434
# or
brew services start ollama
```

Confirm: `curl http://localhost:11434/api/tags` returns a list.

### Model not pulled

```bash
ollama pull gemma4:26b
```

Takes 15–20 minutes on the first pull. Subsequent runs are instant.

---

## Aider

### `lm-studio` API key rejected

Symptom: `AuthenticationError: Error code: 401 - {"error":"Invalid API
key"}`. This means Aider is somehow hitting OpenAI, not LM Studio.

Fix: confirm the model prefix in your config is `openai/qwen3-coder-30b`,
NOT `qwen3-coder-30b`. The `openai/` prefix tells Aider to use the
OpenAI-compatible client, which then honors `openai-api-base`.

```yaml
# agents/aider/aider.conf.yml  (correct)
model: openai/qwen3-coder-30b
openai-api-base: http://localhost:1234/v1
openai-api-key: lm-studio
```

Yes, the API key value `lm-studio` is nonsense — LM Studio doesn't
validate it. But Aider refuses to make a call without any key set, hence
the dummy value.

### Edits keep failing to apply

Symptom: `SearchReplaceNoExactMatch` or "Failed to apply edit."

Cause: Qwen3-Coder-30B's edit format requires quoting the original text
verbatim. Long/complex files sometimes trip it up.

Fix:

- `/clear` the chat to drop stale context.
- `/drop` files you don't need.
- Re-`/add` the target file so Aider has a fresh copy.
- Try the thinking model: `--model openai/qwen3-235b-a22b-thinking-2507`
  (swap requires LM Studio to have that model loaded).
- Switch edit format: `--edit-format diff-fenced` or `--edit-format udiff`.

### Slow first response

Normal. Aider builds a repo map on first turn (10–30 s on a large repo).
Cache lives in `.aider.tags.cache.v3/` — don't delete it unless you
suspect corruption.

### Chat history leaking into commits

```bash
# In each project's .gitignore:
.aider.chat.history.md
.aider.input.history
.aider.tags.cache.v3/
```

---

## Goose

### Goose ignores the workbench config

Symptom: Goose starts with no ashlr tools available, uses some other model.

Cause: Goose read `~/.config/goose/config.yaml` instead of the workbench's.
Check `$GOOSE_PATH_ROOT`:

```bash
echo $GOOSE_PATH_ROOT
# Should be: /Users/masonwyatt/Desktop/ashlr-workbench/agents/goose
```

Fix: use `./scripts/start-goose.sh` (or `aw start goose`). Never run
`goose` directly for workbench sessions — the launcher sets env vars
and copies the canonical config.

### `ashlr-*` extension "failed to start"

Check the entrypoint is executable and the plugin has deps installed:

```bash
ls -l ~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh
cd ~/Desktop/ashlr-plugin && bun install
```

If the entrypoint isn't executable:

```bash
chmod +x ~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh
```

Try the server manually:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | bash ~/Desktop/ashlr-plugin/scripts/mcp-entrypoint.sh \
         servers/efficiency-server.ts
```

You should see a JSON-RPC response with `serverInfo` inside. If not, the
MCP server itself is broken — see `docs/integration/mcp-servers.md`.

### First tool call takes 1–3 seconds

Expected. Bun-based MCP servers warm up cold. After the first call,
latency drops to <100 ms. Don't tune this; it's not worth it.

### Goose keeps asking to approve each action

That is the default "review mode." To auto-approve in this session:

```
/mode            # toggle
```

Or edit `agents/goose/config.yaml` → set `GOOSE_MODE: smart_approve`
(smart) or `auto` (fully hands-off) and relaunch.

---

## OpenHands

### OpenHands won't start

Run through this in order:

1. **Docker running?** `docker info` — must succeed.
2. **Port 3000 free?** `lsof -iTCP:3000 -sTCP:LISTEN`. Kill whatever is
   bound. `aw stop openhands` before re-starting.
3. **Image pulled?** `docker images | grep openhands` — if missing,
   the start script will pull on next launch.
4. **Plugin mounted?** `start-openhands.sh` mounts
   `~/Desktop/ashlr-plugin` at `/host/ashlr-plugin`. The dir must exist.
5. **Linux bun staged?** Look for `~/.cache/ashlr-workbench/bun-linux-aarch64/`.
   `start-openhands.sh` downloads this automatically on first run — if
   the download fails, re-run when you have network.

Tail container logs:

```bash
aw logs openhands -f
# or:
docker logs -f ashlr-openhands
```

### Agent stalls mid-task

Usually LM Studio ran out of context or the model is thinking very slowly.

- In the OpenHands UI, open the event log. If the last event is a
  long-running LLM call, wait another 60 seconds.
- If stuck for >5 min, hit the red Stop button in the UI. The agent's
  prior state is preserved — say "continue from where you left off" to
  resume.

### MCP tools not available in OpenHands

1. Check `agents/openhands/mcp.json` got mounted at `/.openhands/mcp.json`.
   Inside the container:
   ```bash
   docker exec -it ashlr-openhands cat /.openhands/mcp.json | head
   ```
2. Confirm `enable_mcp = true` in `agents/openhands/config.toml`.
3. Check a server manually from inside the container:
   ```bash
   docker exec -it ashlr-openhands bash -c '
     cd /host/ashlr-plugin && /host/bun/bun run servers/efficiency-server.ts < /dev/null
   '
   ```
   (It will exit immediately — that's fine. If you get a missing-bun error,
   see next item.)

### `/host/bun: not found` inside the container

The staged bun binary didn't get mounted. Fix:

```bash
aw stop openhands
rm -rf ~/.cache/ashlr-workbench/bun-linux-aarch64/
aw start openhands   # re-downloads bun on start
```

### Container keeps restarting

```bash
docker inspect ashlr-openhands --format '{{.State.Status}} {{.State.Error}}'
```

If `Error` is non-empty, it's usually one of:

- Volume mount target inside the container is read-only but the agent
  tries to write there. Check `start-openhands.sh` for `:ro` flags.
- Out of disk. `docker system df` — prune if full.

Nuke state and try once more:

```bash
aw stop openhands && rm -rf ~/.openhands && aw start openhands
```

---

## ashlrcode

### `XAI_API_KEY` not set

The overlay embeds a key as fallback, but env wins:

```bash
export XAI_API_KEY="xai-..."
```

Or use a `.env` in `~/Desktop/ashlr-workbench/` and `source` it before
launch. Do NOT commit `.env`.

### MCP servers show "failed to start" in ashlrcode

Same fix as Goose — the plugin path or bun install is the usual culprit:

```bash
cd ~/Desktop/ashlr-plugin && git pull && bun install
```

If that is fine, inspect startup:

```bash
ashlrcode --verbose
```

Look for lines starting with `mcp:` for the spawn errors.

### Overlay not loading

ashlrcode < 2.1.0 ignores `ASHLRCODE_CONFIG_DIR`. Check:

```bash
ashlrcode --version
# If < 2.1.0, upgrade:
bun install -g ashlrcode@latest
```

### Want to skip MCP on startup

```bash
aw start ashlrcode -- --no-mcp
# or:
./scripts/start-ashlrcode.sh --no-mcp
```

---

## MCP (all agents)

### MCP server timeout

Symptom: agent prints "tool call timed out" or "mcp server unresponsive."

Causes in order of likelihood:

1. **Plugin deps missing.** `cd ~/Desktop/ashlr-plugin && bun install`.
2. **Bun not in PATH** for non-interactive shells. Test:
   ```bash
   bash -lc 'which bun'
   ```
   If empty, add `export PATH="$HOME/.bun/bin:$PATH"` to
   `~/.zshenv` (not just `~/.zshrc`).
3. **Server crashing on stdin.** Run the server by hand with an init
   message — see `docs/integration/mcp-servers.md` for the exact command.
4. **`.ashlrcode/genome/` is corrupt.** `ashlr__grep` falls back to
   ripgrep if genome retrieval fails, so this shows up as slowness, not
   crashes. `cat ~/Desktop/.ashlrcode/genome/manifest.json | jq .` — if
   it errors, regenerate: `aw genome init` inside the workspace dir.

### Tool invocation works but output is empty

Two likely causes:

- The genome is gated on a `pending/` queue that's full. Run
  `ashlr__genome_consolidate` or `aw genome consolidate`.
- `ashlr__http` against an HTTPS endpoint with a self-signed cert fails
  silently. Set `NODE_TLS_REJECT_UNAUTHORIZED=0` in the agent's env
  (only for local dev).

---

## Genome

### Genome missing / `ashlr__grep` slower than expected

Check:

```bash
ls ~/Desktop/.ashlrcode/genome/manifest.json
```

If missing:

```bash
cd ~/Desktop
aw genome init
# or from inside a project:
cd ~/Desktop/some-project && aw genome init .
```

### Stale genome sections

`ashlr__genome_status` shows counts. To refresh everything from scratch:

```bash
cd ~/Desktop
rm -rf .ashlrcode/genome
aw genome init
```

---

## Last resort

If absolutely nothing works:

```bash
# 1. Kill every agent
aw stop openhands
pkill -f 'aider|goose|ashlrcode'

# 2. Upgrade everything
cd ~/Desktop/ashlr-plugin && git pull && bun install
cd ~/Desktop/ashlr-workbench && git pull

# 3. Re-run health
aw doctor
```

Still stuck? Open an issue on the `ashlr-workbench` repo with:

- `aw doctor` output
- Which agent you were using
- The exact command that failed
- Relevant logs (LM Studio console, `docker logs ashlr-openhands`,
  or the agent's stderr)
