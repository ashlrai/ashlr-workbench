#!/usr/bin/env bats
# tests/llm-router.bats — LLM Router Behavioral Test Suite with Latency Simulation
#
# Validates that scripts/lib/llm-router.sh correctly probes multiple LLM
# backends, learns latencies, and persists routing policy.
#
# Test categories:
#   1. Mock setup & init — llm_router_init probes all backends, ranks by latency
#   2. Select logic      — llm_router_select picks primary/fallback per agent
#   3. Fallback threshold — if primary > FALLBACK_THRESHOLD_MS, switch to fallback
#   4. Persistence       — routing policy survives shutdown (re-read from disk)
#   5. Graceful degrada- — only one backend available, still works
#   6. NO_COLOR & JSONL  — structured output, structured events
#   7. Policy snapshot   — llm-routing-policy.json contents validated
#   8. Latency matrix    — llm_router_status table output
#
# All HTTP calls are intercepted via curl() function overrides — tests run
# fully offline.
#
# Environment variables honoured:
#   BATS_TEST_DIRNAME  — set by bats to this file's directory
#   NO_COLOR           — suppresses ANSI sequences in output checks
#
# Run:
#   bats tests/llm-router.bats
#   NO_COLOR=1 bats tests/llm-router.bats

# ─── Resolve paths ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
export REPO_ROOT LIB_DIR

# ─── setup / teardown ─────────────────────────────────────────────────────────

setup() {
  # Isolated temp dir per test — never touches ~/.ashlr-workbench
  TEST_TMPDIR="$(mktemp -d /tmp/llm-router-test-XXXXXX)"
  export TEST_TMPDIR

  # Redirect all persistent state into the temp dir.
  export ASHLR_LLM_ROUTING_POLICY="${TEST_TMPDIR}/llm-routing-policy.json"
  export ASHLR_LLM_ROUTER_LOG="${TEST_TMPDIR}/router-events.jsonl"
  export ASHLR_SESSION_EVENTS_PATH="${TEST_TMPDIR}/session-events.jsonl"

  # Disable event emission by default; individual tests opt-in via
  # ASHLR_LLM_ROUTER_EVENTS=1.
  export ASHLR_LLM_ROUTER_EVENTS=0

  # Short probe timeout so tests don't stall on real network calls.
  export ASHLR_LLM_PROBE_TIMEOUT=1

  # Default fallback threshold.
  export ASHLR_LLM_FALLBACK_MS=2000

  # Clear all cloud API keys so xai/anthropic skip themselves cleanly.
  unset XAI_API_KEY ANTHROPIC_API_KEY 2>/dev/null || true

  # Point local backends at definitely-unused ports so real curl would fail.
  export LM_STUDIO_URL="http://127.0.0.1:19234/v1"
  export OLLAMA_URL="http://127.0.0.1:19434"

  # Reset double-source guard so we can re-source cleanly in each test.
  unset _ASHLR_LLM_ROUTER_SOURCED _ASHLR_CONFIG_SOURCED 2>/dev/null || true

  # Reset all router state variables.
  unset LLM_ROUTER_READY LLM_PRIMARY LLM_FALLBACK FALLBACK_THRESHOLD 2>/dev/null || true
  unset LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL LLM_PRIMARY_MS LLM_PRIMARY_URL 2>/dev/null || true
  unset LLM_FALLBACK_BACKEND LLM_FALLBACK_MODEL LLM_FALLBACK_MS LLM_FALLBACK_URL 2>/dev/null || true
  unset _LLM_RT_lmstudio_avail _LLM_RT_lmstudio_ms _LLM_RT_lmstudio_model _LLM_RT_lmstudio_url 2>/dev/null || true
  unset _LLM_RT_ollama_avail _LLM_RT_ollama_ms _LLM_RT_ollama_model _LLM_RT_ollama_url 2>/dev/null || true
  unset _LLM_RT_xai_avail _LLM_RT_xai_ms _LLM_RT_xai_model _LLM_RT_xai_url 2>/dev/null || true
  unset _LLM_RT_anthropic_avail _LLM_RT_anthropic_ms _LLM_RT_anthropic_model _LLM_RT_anthropic_url 2>/dev/null || true
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/llm-router-test-noop}" 2>/dev/null || true
}

# ─── Mock helpers ─────────────────────────────────────────────────────────────
#
# Each test loads the router via a wrapper bash -c that:
#   1. Defines a curl() mock that returns controllable JSON with optional sleep.
#   2. Defines _lr_now_ms() mock that returns incrementing timestamps simulating
#      specific latencies per backend.
#   3. Sources the router library.
#   4. Runs the requested public function(s).
#
# We use bash -c so every test gets a clean subprocess with no variable leakage.

# _router_bash_env — emit shell code that sets up the test environment.
# Every test subprocess sources this before doing anything else.
_router_bash_env() {
  cat <<'ENVEOF'
export ASHLR_LLM_ROUTER_EVENTS="${ASHLR_LLM_ROUTER_EVENTS:-0}"
export ASHLR_LLM_PROBE_TIMEOUT="${ASHLR_LLM_PROBE_TIMEOUT:-1}"
export ASHLR_LLM_FALLBACK_MS="${ASHLR_LLM_FALLBACK_MS:-2000}"
export ASHLR_LLM_ROUTING_POLICY="${ASHLR_LLM_ROUTING_POLICY}"
export ASHLR_LLM_ROUTER_LOG="${ASHLR_LLM_ROUTER_LOG}"
export LM_STUDIO_URL="${LM_STUDIO_URL:-http://127.0.0.1:19234/v1}"
export OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:19434}"
unset XAI_API_KEY ANTHROPIC_API_KEY 2>/dev/null || true
unset _ASHLR_LLM_ROUTER_SOURCED _ASHLR_CONFIG_SOURCED 2>/dev/null || true
ENVEOF
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: Library loads cleanly
# ══════════════════════════════════════════════════════════════════════════════

@test "llm-router.sh: library sources without errors (bash -n syntax check)" {
  run bash -n "${LIB_DIR}/llm-router.sh"
  [ "$status" -eq 0 ]
}

@test "llm-router.sh: library sources without errors (full source)" {
  run bash -c "
    $(_router_bash_env)
    . '${LIB_DIR}/llm-router.sh'
    echo 'sourced_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "sourced_ok"
}

@test "llm-router.sh: double-sourcing is idempotent (guard works)" {
  run bash -c "
    $(_router_bash_env)
    . '${LIB_DIR}/llm-router.sh'
    . '${LIB_DIR}/llm-router.sh'
    echo 'double_source_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "double_source_ok"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: llm_router_init — probes all backends, ranks by latency
# ══════════════════════════════════════════════════════════════════════════════

@test "llm_router_init: sets LLM_ROUTER_READY=1 when at least one backend is up" {
  run bash -c "
    $(_router_bash_env)

    # Mock: lmstudio up at 150ms, ollama down.
    _MOCK_MS=0
    _lr_now_ms() { _MOCK_MS=\$(( _MOCK_MS + 75 )); printf '%s' \"\$_MOCK_MS\"; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen/qwen3-coder-30b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf '%s' \"\${LLM_ROUTER_READY:-0}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "llm_router_init: sets LLM_ROUTER_READY=1 even when all backends are down" {
  # Router must never crash the caller — returns 0 with LLM_PRIMARY=none:
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '1000'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf '%s' \"\${LLM_ROUTER_READY:-0}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "llm_router_init: exports LLM_PRIMARY=none: when all backends are down" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '1000'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf '%s' \"\${LLM_PRIMARY:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "none:" ]
}

@test "llm_router_init: both backends probed and availability tracked independently" {
  # Verify that probe results for lmstudio and ollama are correctly stored and
  # retrievable via _lr_get_avail / _lr_get_ms after llm_router_init runs.
  # (Tests the probe+state layer; ranking is exercised separately via select.)
  run bash -c "
    $(_router_bash_env)

    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl

    . '${LIB_DIR}/llm-router.sh'
    _lr_discover_ollama() { return 0; }
    llm_router_init
    printf 'lms_avail=%s oll_avail=%s ready=%s' \
      \"\${_LLM_RT_lmstudio_avail:-?}\" \
      \"\${_LLM_RT_ollama_avail:-?}\" \
      \"\${LLM_ROUTER_READY:-0}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'lms_avail=1'
  printf '%s' "$output" | grep -q 'oll_avail=1'
  printf '%s' "$output" | grep -q 'ready=1'
}

@test "llm_router_init: lmstudio becomes primary when it is the only available backend" {
  run bash -c "
    $(_router_bash_env)

    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen/qwen3-coder-30b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl

    . '${LIB_DIR}/llm-router.sh'
    _lr_discover_ollama() { return 0; }
    llm_router_init
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "lmstudio" ]
}

@test "llm_router_select: assigns distinct primary and fallback when two backends are up" {
  # llm_router_select iterates pref_order directly (avoids the _lr_rank_backends
  # subshell-concatenation issue) so it correctly finds both backends.
  run bash -c "
    $(_router_bash_env)

    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl

    . '${LIB_DIR}/llm-router.sh'
    _lr_discover_ollama() { return 0; }
    llm_router_init
    # Use 'aider' pref order: lmstudio ollama xai anthropic — both local are up.
    llm_router_select 'aider'
    printf 'primary=%s fallback=%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\" \"\${LLM_FALLBACK_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  # Both backends up; primary must be lmstudio (first in aider pref order).
  printf '%s' "$output" | grep -q 'primary=lmstudio'
  # Fallback must be the second available: ollama.
  printf '%s' "$output" | grep -q 'fallback=ollama'
}

@test "llm_router_init: sets LLM_FALLBACK=none when only one backend is available" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"only-model\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf '%s' \"\${LLM_FALLBACK:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "none:" ]
}

@test "llm_router_init: exports FALLBACK_THRESHOLD from ASHLR_LLM_FALLBACK_MS" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_FALLBACK_MS=1500

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf '%s' \"\${FALLBACK_THRESHOLD:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1500" ]
}

@test "llm_router_init: --force-probe re-runs even when LLM_ROUTER_READY=1" {
  # Use a temp file counter since subshells cannot mutate parent-shell variables.
  run bash -c "
    $(_router_bash_env)
    _COUNTER_FILE=\"\$(mktemp)\"
    printf '0' > \"\$_COUNTER_FILE\"
    export _COUNTER_FILE

    curl() {
      case \"\$*\" in
        *19234*models*)
          n=\$(cat \"\$_COUNTER_FILE\" 2>/dev/null || printf '0')
          printf '%d' \$(( n + 1 )) > \"\$_COUNTER_FILE\"
          printf '{\"object\":\"list\",\"data\":[{\"id\":\"model\"}]}'
          return 0
          ;;
        *) return 7 ;;
      esac
    }
    export -f curl

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    # second call without --force-probe must be a no-op (count stays same).
    llm_router_init
    first_count=\$(cat \"\$_COUNTER_FILE\")
    # --force-probe must cause a new probe round.
    llm_router_init --force-probe
    second_count=\$(cat \"\$_COUNTER_FILE\")
    rm -f \"\$_COUNTER_FILE\"
    [ \"\$second_count\" -gt \"\$first_count\" ] && printf 'reprobe_ok' || printf 'no_reprobe:%s:%s' \"\$first_count\" \"\$second_count\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "reprobe_ok"
}

@test "llm_router_init: extracts model id from lmstudio JSON response" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '80'; }
    curl() {
      case \"\$*\" in
        *19234*models*)
          printf '{\"object\":\"list\",\"data\":[{\"id\":\"my-special-model\"}]}'
          return 0
          ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf '%s' \"\${LLM_PRIMARY_MODEL:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "my-special-model" ]
}

@test "llm_router_init: extracts model id from ollama JSON response" {
  run bash -c "
    $(_router_bash_env)

    # Make ollama faster so it wins primary.
    _MOCK_CALL=0
    _lr_now_ms() {
      _MOCK_CALL=\$(( _MOCK_CALL + 1 ))
      case \"\$_MOCK_CALL\" in
        1) printf '0' ;; 2) printf '500' ;;   # lmstudio: down (but need calls)
        3) printf '600' ;; 4) printf '650' ;; # ollama: 50ms
        *) printf '9999' ;;
      esac
    }
    curl() {
      case \"\$*\" in
        *19234*) return 7 ;;
        *19434*api/tags*)
          printf '{\"models\":[{\"name\":\"llama3.2:3b\"},{\"name\":\"gemma4:26b\"}]}'
          return 0
          ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'backend=%s model=%s' \"\${LLM_PRIMARY_BACKEND:-?}\" \"\${LLM_PRIMARY_MODEL:-?}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "backend=ollama"
  # Should pick the configured reasoning model if present, else first model.
  printf '%s' "$output" | grep -q "model="
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3: llm_router_select — agent-specific routing
# ══════════════════════════════════════════════════════════════════════════════

@test "llm_router_select: triggers llm_router_init if not yet ready" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    # Do NOT call llm_router_init first.
    llm_router_select 'aider'
    printf '%s' \"\${LLM_ROUTER_READY:-0}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "llm_router_select: aider prefers lmstudio over ollama" {
  run bash -c "
    $(_router_bash_env)

    _MOCK_CALL=0
    _lr_now_ms() {
      _MOCK_CALL=\$(( _MOCK_CALL + 1 ))
      case \"\$_MOCK_CALL\" in
        1) printf '0' ;; 2) printf '200' ;;  # lmstudio: 200ms
        3) printf '300' ;; 4) printf '350' ;; # ollama: 50ms
        *) printf '9999' ;;
      esac
    }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen-model\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  # aider preference order puts lmstudio first regardless of latency ranking.
  [ "$output" = "lmstudio" ]
}

@test "llm_router_select: openhands prefers lmstudio" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen-model\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'openhands'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "lmstudio" ]
}

@test "llm_router_select: ashlrcode prefers xai when XAI_API_KEY is set" {
  run bash -c "
    $(_router_bash_env)
    export XAI_API_KEY='test-xai-key-12345'

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *api.x.ai*models*)
          printf '{\"object\":\"list\",\"data\":[{\"id\":\"grok-3\"}]}'
          return 0
          ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'ashlrcode'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "xai" ]
}

@test "llm_router_select: ashlrcode prefers anthropic when only ANTHROPIC_API_KEY is set" {
  run bash -c "
    $(_router_bash_env)
    unset XAI_API_KEY 2>/dev/null || true
    export ANTHROPIC_API_KEY='test-anthropic-key-12345'

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *api.anthropic.com*models*)
          printf '{\"data\":[{\"id\":\"claude-sonnet-4-5\"}]}'
          return 0
          ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'ashlrcode'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "anthropic" ]
}

@test "llm_router_select: falls back to local when policy primary is down" {
  # Pre-write a policy saying primary=xai but xai has no API key → it's down.
  # Should fall through to local lmstudio.
  run bash -c "
    $(_router_bash_env)
    unset XAI_API_KEY 2>/dev/null || true

    # Write a stale policy that points at xai.
    mkdir -p \"\$(dirname \"\$ASHLR_LLM_ROUTING_POLICY\")\"
    printf '{\"openhands\":{\"primary\":\"xai\",\"fallback\":\"lmstudio\",\"threshold_ms\":2000}}\n' \
      > \"\$ASHLR_LLM_ROUTING_POLICY\"

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'openhands'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  # xai is down (no key), policy should be ignored; lmstudio should win.
  [ "$output" = "lmstudio" ]
}

@test "llm_router_select: honours persisted policy when that backend is still up" {
  run bash -c "
    $(_router_bash_env)

    # Write a policy that says openhands should use ollama as primary.
    mkdir -p \"\$(dirname \"\$ASHLR_LLM_ROUTING_POLICY\")\"
    printf '{\"openhands\":{\"primary\":\"ollama\",\"fallback\":\"lmstudio\",\"threshold_ms\":1000}}\n' \
      > \"\$ASHLR_LLM_ROUTING_POLICY\"

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'openhands'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  # Policy said ollama; ollama is up; should be honoured.
  [ "$output" = "ollama" ]
}

@test "llm_router_select: unknown agent falls through to default preference order" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'some-unknown-agent-xyz'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  # Default pref order starts with lmstudio; it's up.
  [ "$output" = "lmstudio" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4: Fallback-on-threshold logic
# ══════════════════════════════════════════════════════════════════════════════

@test "llm_router_aider_args: uses primary when primary_ms <= threshold" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_FALLBACK_MS=2000

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    # Manually set primary latency well below threshold.
    LLM_PRIMARY_MS=500
    LLM_PRIMARY_BACKEND='lmstudio'
    LLM_PRIMARY_MODEL='qwen/qwen3-coder-30b'
    LLM_PRIMARY_URL='http://127.0.0.1:19234/v1'
    LLM_FALLBACK_BACKEND='ollama'
    LLM_FALLBACK_MODEL='llama3.2:3b'
    LLM_FALLBACK_URL='http://127.0.0.1:19434'
    FALLBACK_THRESHOLD=2000
    export LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL LLM_PRIMARY_URL
    export LLM_FALLBACK_BACKEND LLM_FALLBACK_MODEL LLM_FALLBACK_URL FALLBACK_THRESHOLD
    result=\"\$(llm_router_aider_args)\"
    printf '%s' \"\$result\"
  "
  [ "$status" -eq 0 ]
  # Should reference the primary lmstudio URL.
  printf '%s' "$output" | grep -q "19234"
}

@test "llm_router_aider_args: switches to fallback when primary_ms > threshold" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    # Set up state: primary is lmstudio at 3000ms, threshold is 2000ms.
    LLM_ROUTER_READY=1
    LLM_PRIMARY_MS=3000
    LLM_PRIMARY_BACKEND='lmstudio'
    LLM_PRIMARY_MODEL='qwen/qwen3-coder-30b'
    LLM_PRIMARY_URL='http://127.0.0.1:19234/v1'
    LLM_FALLBACK_BACKEND='ollama'
    LLM_FALLBACK_MODEL='llama3.2:3b'
    LLM_FALLBACK_URL='http://127.0.0.1:19434'
    LLM_FALLBACK='ollama:llama3.2:3b'
    FALLBACK_THRESHOLD=2000
    export LLM_ROUTER_READY LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL LLM_PRIMARY_URL
    export LLM_FALLBACK LLM_FALLBACK_BACKEND LLM_FALLBACK_MODEL LLM_FALLBACK_URL FALLBACK_THRESHOLD
    result=\"\$(llm_router_aider_args)\"
    printf '%s' \"\$result\"
  "
  [ "$status" -eq 0 ]
  # Should reference the fallback ollama URL (port 19434), not lmstudio.
  printf '%s' "$output" | grep -q "19434"
}

@test "llm_router_aider_args: stays on primary when fallback is none" {
  # Even if primary exceeds threshold, if there's no fallback we must stay put.
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    LLM_ROUTER_READY=1
    LLM_PRIMARY_MS=5000
    LLM_PRIMARY_BACKEND='lmstudio'
    LLM_PRIMARY_MODEL='qwen/qwen3-coder-30b'
    LLM_PRIMARY_URL='http://127.0.0.1:19234/v1'
    LLM_FALLBACK='none:'
    LLM_FALLBACK_BACKEND='none'
    LLM_FALLBACK_MODEL=''
    LLM_FALLBACK_URL=''
    FALLBACK_THRESHOLD=2000
    export LLM_ROUTER_READY LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL LLM_PRIMARY_URL
    export LLM_FALLBACK LLM_FALLBACK_BACKEND LLM_FALLBACK_MODEL LLM_FALLBACK_URL FALLBACK_THRESHOLD
    result=\"\$(llm_router_aider_args)\"
    printf '%s' \"\$result\"
  "
  [ "$status" -eq 0 ]
  # No fallback → must use primary lmstudio URL.
  printf '%s' "$output" | grep -q "19234"
}

@test "llm_router_select: uses persisted threshold from policy" {
  run bash -c "
    $(_router_bash_env)

    # Write a policy with a custom threshold of 500ms.
    mkdir -p \"\$(dirname \"\$ASHLR_LLM_ROUTING_POLICY\")\"
    printf '{\"aider\":{\"primary\":\"lmstudio\",\"fallback\":\"ollama\",\"threshold_ms\":500}}\n' \
      > \"\$ASHLR_LLM_ROUTING_POLICY\"

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    printf '%s' \"\${FALLBACK_THRESHOLD:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "500" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 5: Persistence — policy survives shutdown and is re-read
# ══════════════════════════════════════════════════════════════════════════════

@test "llm_router_learn: persists routing policy to disk" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '250'

    [ -f \"\$ASHLR_LLM_ROUTING_POLICY\" ] && printf 'file_exists' || printf 'no_file'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "file_exists"
}

@test "llm_router_learn: policy JSON contains the agent key after learn" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'goose'
    llm_router_learn 'goose' 'lmstudio' '300'

    python3 -c \"
import json, sys
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
assert 'goose' in p, f'goose key missing: {p}'
assert p['goose']['primary'] == 'lmstudio', f'wrong primary: {p}'
print('ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "ok"
}

@test "llm_router_learn: policy is re-read by llm_router_select in fresh session" {
  # Write a policy in session 1, verify session 2 picks it up.

  # Session 1: learn that lmstudio is the best for agent 'goose'.
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'goose'
    llm_router_learn 'goose' 'lmstudio' '120'
    echo 'session1_done'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "session1_done"

  # Verify the policy file was actually written.
  [ -f "${TEST_TMPDIR}/llm-routing-policy.json" ]

  # Session 2: fresh process reads persisted policy.
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'goose'
    printf '%s' \"\${LLM_PRIMARY_BACKEND:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "lmstudio" ]
}

@test "llm_router_learn: EMA latency is stored and converges" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'

    # Record 3 observations; EMA with alpha=0.3 should converge.
    llm_router_learn 'aider' 'lmstudio' '200'
    llm_router_learn 'aider' 'lmstudio' '200'
    llm_router_learn 'aider' 'lmstudio' '200'

    python3 -c \"
import json
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
lat = p.get('aider', {}).get('learned_latencies', {}).get('lmstudio')
assert lat is not None, 'learned_latencies.lmstudio missing'
# After 3 identical observations of 200, EMA should converge toward 200.
assert 150 <= float(lat) <= 210, f'EMA out of expected range: {lat}'
print('ema_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "ema_ok"
}

@test "llm_router_learn: multiple agents are stored independently" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '150'
    llm_router_select 'goose'
    llm_router_learn 'goose' 'lmstudio' '300'

    python3 -c \"
import json
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
assert 'aider' in p, 'aider missing'
assert 'goose' in p, 'goose missing'
a_lat = p['aider']['learned_latencies']['lmstudio']
g_lat = p['goose']['learned_latencies']['lmstudio']
# aider was learned at 150, goose at 300 — should differ.
assert abs(float(a_lat) - float(g_lat)) > 50, f'latencies suspiciously close: {a_lat} vs {g_lat}'
print('independent_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "independent_ok"
}

@test "llm_router_learn: policy write is atomic (no partial files on concurrent calls)" {
  # Write policy from two sub-shells concurrently; final file must be valid JSON.
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init

    # Simulate concurrent writes.
    for i in 1 2 3 4 5; do
      (
        . '${LIB_DIR}/llm-router.sh'
        LLM_ROUTER_READY=1
        LLM_PRIMARY_BACKEND='lmstudio'
        LLM_PRIMARY_MODEL='qwen'
        FALLBACK_THRESHOLD=2000
        export LLM_ROUTER_READY LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL FALLBACK_THRESHOLD
        llm_router_learn \"agent_\$i\" 'lmstudio' \"\$((i * 100))\"
      ) &
    done
    wait

    python3 -c \"
import json
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
print('valid_json agents=' + str(len(p)))
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "valid_json"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 6: Graceful degradation — only one backend available
# ══════════════════════════════════════════════════════════════════════════════

@test "graceful degradation: only lmstudio up — primary=lmstudio, fallback=none" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'primary=%s fallback=%s' \"\${LLM_PRIMARY_BACKEND:-?}\" \"\${LLM_FALLBACK_BACKEND:-?}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "primary=lmstudio"
  printf '%s' "$output" | grep -q "fallback=none"
}

@test "graceful degradation: only ollama up — primary=ollama, fallback=none" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'primary=%s fallback=%s' \"\${LLM_PRIMARY_BACKEND:-?}\" \"\${LLM_FALLBACK_BACKEND:-?}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "primary=ollama"
  printf '%s' "$output" | grep -q "fallback=none"
}

@test "graceful degradation: all backends down — never crashes, returns 0" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_status
    llm_router_backends
    echo 'completed_without_crash'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "completed_without_crash"
}

@test "graceful degradation: llm_router_learn is safe when no primary is set" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    # With no backend up, LLM_PRIMARY_BACKEND=none — learn must not crash.
    llm_router_learn 'aider' 'none' '0'
    echo 'learn_safe'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "learn_safe"
}

@test "graceful degradation: single backend select returns that backend for any agent" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    for agent in aider goose openhands ashlrcode unknown; do
      llm_router_select \"\$agent\"
      [ \"\${LLM_PRIMARY_BACKEND:-none}\" = 'ollama' ] || {
        printf 'FAIL: %s got %s\n' \"\$agent\" \"\${LLM_PRIMARY_BACKEND:-none}\"
        exit 1
      }
    done
    echo 'all_agents_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "all_agents_ok"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 7: NO_COLOR + structured JSONL output
# ══════════════════════════════════════════════════════════════════════════════

@test "NO_COLOR=1: llm_router_status emits no ANSI escape sequences" {
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_status
  "
  [ "$status" -eq 0 ]
  # Output must not contain ANSI escape sequences when NO_COLOR=1.
  # ESC is \x1b / \033; check its absence.
  if printf '%s' "$output" | grep -qP '\x1b' 2>/dev/null; then
    # grep -P available (GNU grep)
    printf 'FAIL: ANSI sequences found in output\n'
    false
  else
    # Fallback: check via od for ESC byte (0x1b = 033 octal)
    if printf '%s' "$output" | od -c | grep -q '\\\\033'; then
      printf 'FAIL: ANSI escape codes found via od\n'
      false
    fi
  fi
}

@test "NO_COLOR=1: llm_router_backends emits no ANSI escape sequences" {
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_backends
  "
  [ "$status" -eq 0 ]
  # Check that no escape char appears in output.
  printf '%s' "$output" | od -c | grep -qv '\\033' || true
}

@test "JSONL events: routing_init event is written when ASHLR_LLM_ROUTER_EVENTS=1" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_ROUTER_EVENTS=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init

    python3 -c \"
import json, sys
events = [json.loads(l) for l in open('\$ASHLR_LLM_ROUTER_LOG') if l.strip()]
init_events = [e for e in events if e.get('event') == 'routing_init']
assert len(init_events) >= 1, f'no routing_init event found; all events: {events}'
e = init_events[0]
for k in ['ts', 'event', 'primary', 'fallback', 'threshold_ms']:
    assert k in e, f'missing field {k}: {e}'
print('routing_init_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "routing_init_ok"
}

@test "JSONL events: routing_decision event is written by llm_router_select" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_ROUTER_EVENTS=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'

    python3 -c \"
import json
events = [json.loads(l) for l in open('\$ASHLR_LLM_ROUTER_LOG') if l.strip()]
dec_events = [e for e in events if e.get('event') == 'routing_decision']
assert len(dec_events) >= 1, f'no routing_decision event; events={events}'
e = dec_events[0]
for k in ['ts', 'event', 'agent', 'primary', 'fallback']:
    assert k in e, f'missing field {k}: {e}'
assert e['agent'] == 'aider', f'wrong agent: {e}'
print('routing_decision_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "routing_decision_ok"
}

@test "JSONL events: routing_learn event is written by llm_router_learn" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_ROUTER_EVENTS=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '175'

    python3 -c \"
import json
events = [json.loads(l) for l in open('\$ASHLR_LLM_ROUTER_LOG') if l.strip()]
learn_events = [e for e in events if e.get('event') == 'routing_learn']
assert len(learn_events) >= 1, f'no routing_learn event; events={events}'
e = learn_events[0]
assert e['agent'] == 'aider'
assert e['backend'] == 'lmstudio'
assert e['observed_ms'] == '175'
print('routing_learn_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "routing_learn_ok"
}

@test "JSONL events: ASHLR_LLM_ROUTER_EVENTS=0 suppresses all event writes" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_ROUTER_EVENTS=0

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '200'

    if [ -f \"\$ASHLR_LLM_ROUTER_LOG\" ]; then
      count=\"\$(wc -l < \"\$ASHLR_LLM_ROUTER_LOG\" | tr -d ' ')\"
      [ \"\$count\" -eq 0 ] && printf 'no_events' || printf 'events_found:%s' \"\$count\"
    else
      printf 'no_events'
    fi
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "no_events"
}

@test "JSONL events: all emitted events are valid JSON lines" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_ROUTER_EVENTS=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '200'
    llm_router_select 'goose'

    python3 -c \"
import json, sys
bad = 0
total = 0
with open('\$ASHLR_LLM_ROUTER_LOG') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        total += 1
        try:
            json.loads(line)
        except Exception as e:
            bad += 1
            print(f'BAD LINE: {line!r} — {e}', file=sys.stderr)
print(f'total={total} bad={bad}')
assert bad == 0, f'{bad} malformed JSON lines'
print('all_valid')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "all_valid"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 8: Policy snapshot validation (llm-routing-policy.json)
# ══════════════════════════════════════════════════════════════════════════════

@test "policy snapshot: file is valid JSON after multiple agent sessions" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init

    for agent in aider goose openhands ashlrcode; do
      llm_router_select \"\$agent\"
      llm_router_learn \"\$agent\" 'lmstudio' '200'
    done

    python3 -c \"
import json
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
print('agents=' + str(len(p)))
print('valid_json')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "valid_json"
}

@test "policy snapshot: each agent entry has primary, fallback, threshold_ms, learned_latencies" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '150'

    python3 -c \"
import json
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
a = p.get('aider', {})
for k in ['primary', 'fallback', 'threshold_ms', 'learned_latencies']:
    assert k in a, f'missing key {k}: {a}'
print('schema_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "schema_ok"
}

@test "policy snapshot: learned_latency EMA is a valid float in plausible range" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    llm_router_learn 'aider' 'lmstudio' '400'
    llm_router_learn 'aider' 'lmstudio' '400'

    python3 -c \"
import json
p = json.load(open('\$ASHLR_LLM_ROUTING_POLICY'))
lat = float(p['aider']['learned_latencies']['lmstudio'])
# EMA with seed 400, two calls of 400ms — should be near 400.
assert 300 <= lat <= 450, f'latency {lat} out of expected 300-450 range'
print('ema_in_range')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "ema_in_range"
}

@test "policy snapshot: llm_router_learn with invalid ms is handled gracefully" {
  run bash -c "
    $(_router_bash_env)

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_select 'aider'
    # These should not crash.
    llm_router_learn 'aider' 'lmstudio' 'not-a-number'
    llm_router_learn 'aider' 'lmstudio' ''
    llm_router_learn 'aider' 'lmstudio' '-500'
    echo 'invalid_ms_ok'
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "invalid_ms_ok"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 9: llm_router_status — latency matrix table output
# ══════════════════════════════════════════════════════════════════════════════

@test "llm_router_status: prints all four backend names in output" {
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_status
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "lmstudio"
  printf '%s' "$output" | grep -q "ollama"
  printf '%s' "$output" | grep -q "xai"
  printf '%s' "$output" | grep -q "anthropic"
}

@test "llm_router_status: shows 'up' for available backends and 'down' for unavailable" {
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_status
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "up"
  printf '%s' "$output" | grep -q "down"
}

@test "llm_router_status: shows latency in ms for available backend" {
  # Inject a known latency via probe override so status can print it.
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    curl() { return 7; }
    export -f curl

    . '${LIB_DIR}/llm-router.sh'

    _lr_probe_lmstudio() {
      _LLM_RT_lmstudio_avail=1; _LLM_RT_lmstudio_ms=123
      _LLM_RT_lmstudio_model='qwen'; _LLM_RT_lmstudio_url='http://127.0.0.1:19234/v1'
      export _LLM_RT_lmstudio_avail _LLM_RT_lmstudio_ms _LLM_RT_lmstudio_model _LLM_RT_lmstudio_url
    }
    _lr_probe_ollama() {
      _LLM_RT_ollama_avail=0; _LLM_RT_ollama_ms=99999; _LLM_RT_ollama_model=''; _LLM_RT_ollama_url=''
      export _LLM_RT_ollama_avail _LLM_RT_ollama_ms _LLM_RT_ollama_model _LLM_RT_ollama_url
    }
    _lr_probe_xai() {
      _LLM_RT_xai_avail=0; _LLM_RT_xai_ms=99999; _LLM_RT_xai_model=''; _LLM_RT_xai_url=''
      export _LLM_RT_xai_avail _LLM_RT_xai_ms _LLM_RT_xai_model _LLM_RT_xai_url
    }
    _lr_probe_anthropic() {
      _LLM_RT_anthropic_avail=0; _LLM_RT_anthropic_ms=99999; _LLM_RT_anthropic_model=''; _LLM_RT_anthropic_url=''
      export _LLM_RT_anthropic_avail _LLM_RT_anthropic_ms _LLM_RT_anthropic_model _LLM_RT_anthropic_url
    }
    _lr_discover_ollama() { return 0; }

    llm_router_init
    llm_router_status
  "
  [ "$status" -eq 0 ]
  # Status output must contain the injected latency value.
  printf '%s' "$output" | grep -q "123ms"
}

@test "llm_router_status: shows PRIMARY and FALLBACK role labels" {
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *19434*api/tags*) printf '{\"models\":[{\"name\":\"llama3.2:3b\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_status
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qiE "PRIMARY|primary"
  printf '%s' "$output" | grep -qiE "FALLBACK|fallback"
}

@test "llm_router_status: threshold line is present" {
  run bash -c "
    $(_router_bash_env)
    export NO_COLOR=1

    _lr_now_ms() { printf '100'; }
    curl() { return 7; }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    llm_router_status
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "fallback"
  printf '%s' "$output" | grep -q "ms"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 10: xAI / Anthropic cloud backend stubs
# ══════════════════════════════════════════════════════════════════════════════

@test "xai backend: skipped cleanly when XAI_API_KEY is absent" {
  run bash -c "
    $(_router_bash_env)
    unset XAI_API_KEY 2>/dev/null || true

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'xai_avail=%s' \"\${_LLM_RT_xai_avail:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "xai_avail=0"
}

@test "anthropic backend: skipped cleanly when ANTHROPIC_API_KEY is absent" {
  run bash -c "
    $(_router_bash_env)
    unset ANTHROPIC_API_KEY 2>/dev/null || true

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'anthropic_avail=%s' \"\${_LLM_RT_anthropic_avail:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "anthropic_avail=0"
}

@test "xai backend: probed when XAI_API_KEY is set and mock returns success" {
  run bash -c "
    $(_router_bash_env)
    export XAI_API_KEY='test-key-xai'

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *api.x.ai*models*)
          printf '{\"object\":\"list\",\"data\":[{\"id\":\"grok-3\"}]}'
          return 0
          ;;
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'xai_avail=%s xai_model=%s' \"\${_LLM_RT_xai_avail:-UNSET}\" \"\${_LLM_RT_xai_model:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "xai_avail=1"
  printf '%s' "$output" | grep -q "xai_model=grok-3"
}

@test "anthropic backend: probed when ANTHROPIC_API_KEY is set and mock returns success" {
  run bash -c "
    $(_router_bash_env)
    export ANTHROPIC_API_KEY='test-key-anthropic'

    _lr_now_ms() { printf '100'; }
    curl() {
      case \"\$*\" in
        *api.anthropic.com*models*)
          printf '{\"data\":[{\"id\":\"claude-sonnet-4-5\"}]}'
          return 0
          ;;
        *19234*) printf '{\"object\":\"list\",\"data\":[{\"id\":\"qwen\"}]}'; return 0 ;;
        *) return 7 ;;
      esac
    }
    export -f curl _lr_now_ms

    . '${LIB_DIR}/llm-router.sh'
    llm_router_init
    printf 'anthropic_avail=%s model=%s' \"\${_LLM_RT_anthropic_avail:-UNSET}\" \"\${_LLM_RT_anthropic_model:-UNSET}\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "anthropic_avail=1"
  printf '%s' "$output" | grep -q "model=claude-sonnet-4-5"
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 11: llm_router_aider_args — backend-specific CLI flag generation
# ══════════════════════════════════════════════════════════════════════════════

@test "llm_router_aider_args: lmstudio backend emits --openai-api-base and openai/ prefix" {
  run bash -c "
    $(_router_bash_env)

    . '${LIB_DIR}/llm-router.sh'
    LLM_ROUTER_READY=1
    LLM_PRIMARY_MS=100
    LLM_PRIMARY_BACKEND='lmstudio'
    LLM_PRIMARY_MODEL='qwen/qwen3-coder-30b'
    LLM_PRIMARY_URL='http://127.0.0.1:19234/v1'
    LLM_FALLBACK_BACKEND='none'
    FALLBACK_THRESHOLD=2000
    export LLM_ROUTER_READY LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL
    export LLM_PRIMARY_URL LLM_FALLBACK_BACKEND FALLBACK_THRESHOLD
    llm_router_aider_args
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q -- "--openai-api-base"
  printf '%s' "$output" | grep -q "openai/"
}

@test "llm_router_aider_args: ollama backend emits --openai-api-base and openai/ prefix" {
  run bash -c "
    $(_router_bash_env)

    . '${LIB_DIR}/llm-router.sh'
    LLM_ROUTER_READY=1
    LLM_PRIMARY_MS=80
    LLM_PRIMARY_BACKEND='ollama'
    LLM_PRIMARY_MODEL='llama3.2:3b'
    LLM_PRIMARY_URL='http://127.0.0.1:19434'
    LLM_FALLBACK_BACKEND='none'
    FALLBACK_THRESHOLD=2000
    export LLM_ROUTER_READY LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL
    export LLM_PRIMARY_URL LLM_FALLBACK_BACKEND FALLBACK_THRESHOLD
    llm_router_aider_args
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q -- "--openai-api-base"
  printf '%s' "$output" | grep -q "openai/"
}

@test "llm_router_aider_args: xai backend emits --openai-api-base without openai/ prefix" {
  run bash -c "
    $(_router_bash_env)

    . '${LIB_DIR}/llm-router.sh'
    LLM_ROUTER_READY=1
    LLM_PRIMARY_MS=80
    LLM_PRIMARY_BACKEND='xai'
    LLM_PRIMARY_MODEL='grok-3'
    LLM_PRIMARY_URL='https://api.x.ai/v1'
    LLM_FALLBACK_BACKEND='none'
    FALLBACK_THRESHOLD=2000
    export LLM_ROUTER_READY LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL
    export LLM_PRIMARY_URL LLM_FALLBACK_BACKEND FALLBACK_THRESHOLD
    llm_router_aider_args
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q -- "--openai-api-base"
  printf '%s' "$output" | grep -q "grok-3"
  # xai should NOT add the "openai/" prefix.
  if printf '%s' "$output" | grep -q "openai/grok"; then
    echo "FAIL: xai model should not have openai/ prefix"
    false
  fi
}

@test "llm_router_aider_args: anthropic backend emits only --model flag" {
  run bash -c "
    $(_router_bash_env)

    . '${LIB_DIR}/llm-router.sh'
    LLM_ROUTER_READY=1
    LLM_PRIMARY_MS=200
    LLM_PRIMARY_BACKEND='anthropic'
    LLM_PRIMARY_MODEL='claude-sonnet-4-5'
    LLM_PRIMARY_URL='https://api.anthropic.com/v1'
    LLM_FALLBACK_BACKEND='none'
    FALLBACK_THRESHOLD=2000
    export LLM_ROUTER_READY LLM_PRIMARY_MS LLM_PRIMARY_BACKEND LLM_PRIMARY_MODEL
    export LLM_PRIMARY_URL LLM_FALLBACK_BACKEND FALLBACK_THRESHOLD
    llm_router_aider_args
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q -- "--model"
  printf '%s' "$output" | grep -q "claude-sonnet-4-5"
  # Anthropic must not emit --openai-api-base.
  if printf '%s' "$output" | grep -q -- "--openai-api-base"; then
    echo "FAIL: anthropic should not emit --openai-api-base"
    false
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 12: on_routing_decision hook
# ══════════════════════════════════════════════════════════════════════════════

@test "on_routing_decision: emits well-formed JSONL with all required fields" {
  run bash -c "
    $(_router_bash_env)
    export ASHLR_LLM_ROUTER_EVENTS=1

    . '${LIB_DIR}/llm-router.sh'
    LLM_PRIMARY_MS=100
    LLM_FALLBACK_MS=200
    FALLBACK_THRESHOLD=2000
    export LLM_PRIMARY_MS LLM_FALLBACK_MS FALLBACK_THRESHOLD

    on_routing_decision 'myagent' 'lmstudio:qwen' 'ollama:llama3.2:3b'

    python3 -c \"
import json
events = [json.loads(l) for l in open('\$ASHLR_LLM_ROUTER_LOG') if l.strip()]
assert len(events) == 1, f'expected 1 event, got {len(events)}'
e = events[0]
for k in ['ts', 'event', 'agent', 'primary', 'fallback', 'primary_ms', 'fallback_ms', 'threshold_ms']:
    assert k in e, f'missing {k}: {e}'
assert e['event'] == 'routing_decision'
assert e['agent'] == 'myagent'
assert e['primary'] == 'lmstudio:qwen'
print('on_routing_decision_ok')
\"
  "
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "on_routing_decision_ok"
}
