#!/usr/bin/env bash
# config-audit.sh — Cross-agent config consistency auditor + auto-migration tool.
#
# Reads all 4 agent config files, validates them against agents/config-schema.json,
# and emits a human-readable audit report plus a CSV summary (config-audit.csv).
#
# Checks performed:
#   1. Model names match a known set (catches silent cloud-LLM fallbacks)
#   2. LLM endpoint URLs are in the known-good list
#   3. MCP server refs in each agent match the canonical server set
#   4. Deprecated keys detected + fix suggestion emitted
#   5. Env var refs like ${XAI_API_KEY} are exported in start-<agent>.sh or .env.example
#   6. Per-agent compliance score + cross-agent drift summary in CSV
#
# Flags:
#   --fix        Rewrite deprecated keys + standardize model refs in-place
#   --csv PATH   Override output CSV path (default: config-audit.csv)
#   --no-color   Disable ANSI color
#   --quiet      Suppress per-check detail lines; show summary only
#
# Exit codes:
#   0  All checks passed (clean)
#   1  One or more issues found
#
# Usage:
#   bash scripts/config-audit.sh
#   bash scripts/config-audit.sh --fix
#   bash scripts/config-audit.sh --csv /tmp/audit.csv
#
# Integration:
#   Called by .git/hooks/pre-commit when agent config files change.
#   Also callable directly or from healthcheck.sh.
#
# Design constraints:
#   - macOS bash 3.2 safe — no mapfile, no GNU-only flags, no associative arrays
#   - python3 required for TOML/YAML/JSON parsing (already used project-wide)
#   - Graceful degradation when python3 absent (structural checks skipped)

set -uo pipefail

# ─── Resolve repo root ────────────────────────────────────────────────────────
_AUDIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKBENCH="${WORKBENCH:-$(cd "$_AUDIT_SCRIPT_DIR/.." && pwd)}"

# ─── Color setup ──────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
fi

# ─── Parse flags ──────────────────────────────────────────────────────────────
FIX_MODE=0
QUIET=0
CSV_OUT="$WORKBENCH/config-audit.csv"

while [ $# -gt 0 ]; do
  case "$1" in
    --fix)      FIX_MODE=1 ;;
    --no-color) C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD="" ;;
    --quiet)    QUIET=1 ;;
    --csv)      shift; CSV_OUT="$1" ;;
    --help|-h)
      printf "Usage: %s [--fix] [--csv PATH] [--no-color] [--quiet]\n" \
        "$(basename "$0")"
      printf "\n  --fix        Auto-apply fixes for deprecated keys\n"
      printf "  --csv PATH   Override output CSV path\n"
      printf "  --no-color   Disable ANSI colors\n"
      printf "  --quiet      Show summary only\n"
      exit 0
      ;;
    *) printf "Unknown flag: %s\n" "$1" >&2; exit 1 ;;
  esac
  shift
done

# ─── Counters ─────────────────────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0

# Per-agent counters (parallel arrays — bash 3.2 safe)
_AGENTS="openhands goose aider ashlrcode"
_ag_pass_openhands=0; _ag_warn_openhands=0; _ag_fail_openhands=0
_ag_pass_goose=0;     _ag_warn_goose=0;     _ag_fail_goose=0
_ag_pass_aider=0;     _ag_warn_aider=0;     _ag_fail_aider=0
_ag_pass_ashlrcode=0; _ag_warn_ashlrcode=0; _ag_fail_ashlrcode=0

# ─── Output helpers ───────────────────────────────────────────────────────────
_ok() {
  TOTAL_PASS=$((TOTAL_PASS+1))
  [ "$QUIET" -eq 0 ] && printf "  %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"
}

_warn() {
  TOTAL_WARN=$((TOTAL_WARN+1))
  [ "$QUIET" -eq 0 ] && printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"
}

_bad() {
  TOTAL_FAIL=$((TOTAL_FAIL+1))
  printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$*"
}

_fix() {
  [ "$QUIET" -eq 0 ] && printf "  %s→%s %s\n" "$C_CYAN" "$C_RESET" "$*"
}

_section() {
  printf "\n%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"
}

_agent_ok()   { _ok "$@";   eval "_ag_pass_${_cur_agent}=\$((_ag_pass_${_cur_agent}+1))"; }
_agent_warn() { _warn "$@"; eval "_ag_warn_${_cur_agent}=\$((_ag_warn_${_cur_agent}+1))"; }
_agent_bad()  { _bad "$@";  eval "_ag_fail_${_cur_agent}=\$((_ag_fail_${_cur_agent}+1))"; }

# ─── Python3 availability ─────────────────────────────────────────────────────
_python3_available() { command -v python3 >/dev/null 2>&1; }

# ─── Run a python3 tempscript, capture output + rc ────────────────────────────
_run_py() {
  local script="$1"; shift
  python3 "$script" "$@" 2>&1
}

# ─── Paths ────────────────────────────────────────────────────────────────────
SCHEMA_FILE="$WORKBENCH/agents/config-schema.json"

OH_TOML="$WORKBENCH/agents/openhands/config.toml"
GOOSE_YAML="$WORKBENCH/agents/goose/config.yaml"
AIDER_YAML="$WORKBENCH/agents/aider/aider.conf.yml"
ASHLR_JSON="$WORKBENCH/agents/ashlrcode/settings.json"

# ─── Check schema file ────────────────────────────────────────────────────────
if [ ! -f "$SCHEMA_FILE" ]; then
  _bad "agents/config-schema.json missing — cannot run audit"
  exit 1
fi

if ! _python3_available; then
  _warn "python3 not available — structural checks will be skipped"
fi

# ─── Section 1: Model name validation ─────────────────────────────────────────
_section "1. Model Name Validation"

_check_models() {
  local agent="$1" config="$2" format="$3"
  _cur_agent="$agent"

  if [ ! -f "$config" ]; then
    _agent_bad "$agent: config file missing — $config"
    return
  fi

  if ! _python3_available; then
    _agent_warn "$agent: python3 unavailable — model check skipped"
    return
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/ca-model-XXXXXX.py)" || {
    _agent_warn "$agent: cannot create temp file"
    return
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, os

agent   = sys.argv[1]
config  = sys.argv[2]
fmt     = sys.argv[3]
schema_path = sys.argv[4]

try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("WARN: cannot read schema: %s" % e)
    sys.exit(0)

known_models = schema.get("known_models", [])

def extract_models_toml(path):
    """Return list of (section.key, value) model strings from TOML."""
    models = []
    try:
        import tomllib
        with open(path, 'rb') as fh:
            data = tomllib.load(fh)
        llm = data.get('llm', {})
        if 'model' in llm:
            models.append(('llm.model', llm['model']))
    except ImportError:
        try:
            import tomli
            with open(path, 'rb') as fh:
                data = tomli.load(fh)
            llm = data.get('llm', {})
            if 'model' in llm:
                models.append(('llm.model', llm['model']))
        except ImportError:
            # Fallback: grep for model = "..."
            with open(path) as fh:
                in_llm = False
                for line in fh:
                    s = line.strip()
                    if s == '[llm]':
                        in_llm = True
                        continue
                    if s.startswith('[') and s != '[llm]':
                        in_llm = False
                        continue
                    if in_llm and s.startswith('model'):
                        val = s.split('=', 1)[-1].strip().strip('"').strip("'")
                        models.append(('llm.model', val))
    return models

def extract_models_yaml(path):
    models = []
    try:
        import yaml
        data = yaml.safe_load(open(path))
        if isinstance(data, dict):
            for key in ('model', 'GOOSE_MODEL'):
                if key in data:
                    models.append((key, str(data[key])))
    except ImportError:
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                for key in ('model:', 'GOOSE_MODEL:'):
                    if s.startswith(key):
                        val = s.split(':', 1)[-1].strip().strip('"').strip("'")
                        models.append((key.rstrip(':'), val))
    return models

def extract_models_json(path):
    models = []
    try:
        data = json.load(open(path))
        providers = data.get('providers', {})
        primary = providers.get('primary', {})
        if 'model' in primary:
            models.append(('providers.primary.model', primary['model']))
        for fb in providers.get('fallbacks', []):
            if 'model' in fb:
                label = fb.get('label', fb.get('provider', 'fallback'))
                models.append(('providers.fallbacks[%s].model' % label, fb['model']))
    except Exception as e:
        print("ERROR: JSON parse error: %s" % e)
        sys.exit(1)
    return models

if fmt == 'toml':
    found = extract_models_toml(config)
elif fmt == 'yaml':
    found = extract_models_yaml(config)
elif fmt == 'json':
    found = extract_models_json(config)
else:
    print("WARN: unknown format %s" % fmt)
    sys.exit(0)

if not found:
    print("WARN: no model keys found in %s" % os.path.basename(config))
    sys.exit(0)

errors = 0
for key, val in found:
    if val in known_models:
        print("OK: %s = %s" % (key, val))
    else:
        # Partial match: value contains a known model fragment
        partial = any(m in val or val in m for m in known_models)
        if partial:
            print("WARN: %s = %s (not in exact known_models list — verify)" % (key, val))
        else:
            print("ERROR: %s = %s — not in known_models (may fall back to cloud LLM)" % (key, val))
            errors += 1

sys.exit(1 if errors else 0)
PYEOF

  result="$(_run_py "$tmpscript" "$agent" "$config" "$format" "$SCHEMA_FILE")"
  rc=$?
  rm -f "$tmpscript"

  while IFS= read -r line; do
    case "$line" in
      "OK:"*)    _agent_ok   "$agent: ${line#OK: }" ;;
      "WARN:"*)  _agent_warn "$agent: ${line#WARN: }" ;;
      "ERROR:"*) _agent_bad  "$agent: ${line#ERROR: }" ;;
      "")        ;;
      *)         [ -n "$line" ] && _agent_warn "$agent: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF
}

_check_models "openhands" "$OH_TOML"    "toml"
_check_models "goose"     "$GOOSE_YAML" "yaml"
_check_models "aider"     "$AIDER_YAML" "yaml"
_check_models "ashlrcode" "$ASHLR_JSON" "json"

# ─── Section 2: LLM URL validation ────────────────────────────────────────────
_section "2. LLM Endpoint URL Validation"

_check_urls() {
  local agent="$1" config="$2" format="$3"
  _cur_agent="$agent"

  if [ ! -f "$config" ]; then
    _agent_bad "$agent: config file missing — $config"
    return
  fi

  if ! _python3_available; then
    _agent_warn "$agent: python3 unavailable — URL check skipped"
    return
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/ca-url-XXXXXX.py)" || {
    _agent_warn "$agent: cannot create temp file"
    return
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, os

agent  = sys.argv[1]
config = sys.argv[2]
fmt    = sys.argv[3]
schema_path = sys.argv[4]

try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("WARN: cannot read schema: %s" % e)
    sys.exit(0)

known_urls = schema.get("known_llm_urls", [])

def extract_urls_toml(path):
    urls = []
    try:
        import tomllib
        with open(path, 'rb') as fh:
            data = tomllib.load(fh)
        llm = data.get('llm', {})
        for k in ('base_url', 'api_base', 'openai_base_url'):
            if k in llm:
                urls.append((k, llm[k]))
    except ImportError:
        try:
            import tomli
            with open(path, 'rb') as fh:
                data = tomli.load(fh)
            llm = data.get('llm', {})
            for k in ('base_url', 'api_base', 'openai_base_url'):
                if k in llm:
                    urls.append((k, llm[k]))
        except ImportError:
            with open(path) as fh:
                in_llm = False
                for line in fh:
                    s = line.strip()
                    if s == '[llm]':
                        in_llm = True
                        continue
                    if s.startswith('[') and s != '[llm]':
                        in_llm = False
                        continue
                    if in_llm and ('base_url' in s or 'api_base' in s):
                        parts = s.split('=', 1)
                        if len(parts) == 2:
                            val = parts[1].strip().strip('"').strip("'")
                            urls.append((parts[0].strip(), val))
    return urls

def extract_urls_yaml(path):
    urls = []
    try:
        import yaml
        data = yaml.safe_load(open(path))
        if isinstance(data, dict):
            for key in ('openai-api-base', 'OPENAI_HOST', 'OPENAI_BASE_URL'):
                if key in data:
                    urls.append((key, str(data[key])))
    except ImportError:
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                for key in ('openai-api-base:', 'OPENAI_HOST:', 'OPENAI_BASE_URL:'):
                    if s.startswith(key):
                        val = s.split(':', 1)[-1].strip().strip('"').strip("'")
                        urls.append((key.rstrip(':'), val))
    return urls

def extract_urls_json(path):
    urls = []
    try:
        data = json.load(open(path))
        providers = data.get('providers', {})
        primary = providers.get('primary', {})
        for k in ('baseURL', 'base_url', 'openai_base_url'):
            if k in primary:
                urls.append(('providers.primary.%s' % k, primary[k]))
        for fb in providers.get('fallbacks', []):
            for k in ('baseURL', 'base_url'):
                if k in fb:
                    label = fb.get('label', fb.get('provider', 'fallback'))
                    urls.append(('providers.fallbacks[%s].%s' % (label, k), fb[k]))
    except Exception as e:
        print("ERROR: JSON parse error: %s" % e)
        sys.exit(1)
    return urls

if fmt == 'toml':
    found = extract_urls_toml(config)
elif fmt == 'yaml':
    found = extract_urls_yaml(config)
elif fmt == 'json':
    found = extract_urls_json(config)
else:
    print("WARN: unknown format %s" % fmt)
    sys.exit(0)

if not found:
    print("WARN: no LLM URL keys found in %s" % os.path.basename(config))
    sys.exit(0)

errors = 0
for key, val in found:
    # Normalize: strip trailing slash for comparison
    norm = val.rstrip('/')
    norm_known = [u.rstrip('/') for u in known_urls]
    if norm in norm_known:
        print("OK: %s = %s" % (key, val))
    else:
        print("ERROR: %s = %s — not in known_llm_urls (unexpected endpoint; may hit cloud)" % (key, val))
        errors += 1

sys.exit(1 if errors else 0)
PYEOF

  result="$(_run_py "$tmpscript" "$agent" "$config" "$format" "$SCHEMA_FILE")"
  rc=$?
  rm -f "$tmpscript"

  while IFS= read -r line; do
    case "$line" in
      "OK:"*)    _agent_ok   "$agent: ${line#OK: }" ;;
      "WARN:"*)  _agent_warn "$agent: ${line#WARN: }" ;;
      "ERROR:"*) _agent_bad  "$agent: ${line#ERROR: }" ;;
      "")        ;;
      *)         [ -n "$line" ] && _agent_warn "$agent: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF
}

_check_urls "openhands" "$OH_TOML"    "toml"
_check_urls "goose"     "$GOOSE_YAML" "yaml"
_check_urls "aider"     "$AIDER_YAML" "yaml"
_check_urls "ashlrcode" "$ASHLR_JSON" "json"

# ─── Section 3: MCP server ref validation ─────────────────────────────────────
_section "3. MCP Server Reference Validation"

_check_mcp_refs() {
  local agent="$1" config="$2" format="$3"
  _cur_agent="$agent"

  if [ ! -f "$config" ]; then
    _agent_bad "$agent: config file missing — $config"
    return
  fi

  if ! _python3_available; then
    _agent_warn "$agent: python3 unavailable — MCP ref check skipped"
    return
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/ca-mcp-XXXXXX.py)" || {
    _agent_warn "$agent: cannot create temp file"
    return
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, os

agent  = sys.argv[1]
config = sys.argv[2]
fmt    = sys.argv[3]
schema_path = sys.argv[4]

try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("WARN: cannot read schema: %s" % e)
    sys.exit(0)

known_servers = schema.get("known_mcp_servers", [])

def extract_mcp_names_toml(path):
    # OpenHands has no direct mcp list in config.toml; check mcp.json instead
    mcp_json = os.path.join(os.path.dirname(path), 'mcp.json')
    if not os.path.exists(mcp_json):
        return []
    data = json.load(open(mcp_json))
    return [s.get('name', '') for s in data.get('stdio_servers', [])]

def extract_mcp_names_yaml(path):
    names = []
    try:
        import yaml
        data = yaml.safe_load(open(path))
        if isinstance(data, dict):
            exts = data.get('extensions', {})
            if isinstance(exts, dict):
                for name in exts.keys():
                    names.append(name)
    except ImportError:
        # Fallback: scan for "name: <server>" under extensions block
        in_ext = False
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                if s == 'extensions:':
                    in_ext = True
                    continue
                if in_ext and not line.startswith(' ') and not line.startswith('\t'):
                    in_ext = False
                if in_ext and s.startswith('name:'):
                    val = s.split(':', 1)[-1].strip().strip('"').strip("'")
                    names.append(val)
    return names

def extract_mcp_names_json(path):
    data = json.load(open(path))
    servers = data.get('mcpServers', {})
    return list(servers.keys())

if fmt == 'toml':
    found = extract_mcp_names_toml(config)
elif fmt == 'yaml':
    found = extract_mcp_names_yaml(config)
elif fmt == 'json':
    found = extract_mcp_names_json(config)
else:
    print("WARN: unknown format %s" % fmt)
    sys.exit(0)

if not found:
    print("WARN: no MCP server refs found in %s" % os.path.basename(config))
    sys.exit(0)

errors = 0
for name in found:
    if name in known_servers:
        print("OK: MCP server ref '%s' is in known_mcp_servers" % name)
    else:
        # Not in the canonical list — warn but don't fail (may be intentional extra)
        print("WARN: MCP server ref '%s' is not in known_mcp_servers (custom/extra server)" % name)

# Check that all canonical servers are present
missing = [s for s in known_servers if s not in found]
for m in missing:
    print("WARN: canonical MCP server '%s' is missing from config" % m)

sys.exit(0)
PYEOF

  result="$(_run_py "$tmpscript" "$agent" "$config" "$format" "$SCHEMA_FILE")"
  rc=$?
  rm -f "$tmpscript"

  while IFS= read -r line; do
    case "$line" in
      "OK:"*)    _agent_ok   "$agent: ${line#OK: }" ;;
      "WARN:"*)  _agent_warn "$agent: ${line#WARN: }" ;;
      "ERROR:"*) _agent_bad  "$agent: ${line#ERROR: }" ;;
      "")        ;;
      *)         [ -n "$line" ] && _agent_warn "$agent: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF
}

_check_mcp_refs "openhands" "$OH_TOML"    "toml"
_check_mcp_refs "goose"     "$GOOSE_YAML" "yaml"
_check_mcp_refs "aider"     "$AIDER_YAML" "yaml"
_check_mcp_refs "ashlrcode" "$ASHLR_JSON" "json"

# ─── Section 4: Deprecated key detection + fix suggestions ────────────────────
_section "4. Deprecated Key Detection"

# Global list of fixes to apply when --fix is passed
_FIX_ACTIONS=""

_check_deprecated() {
  local agent="$1" config="$2" format="$3"
  _cur_agent="$agent"

  if [ ! -f "$config" ]; then
    _agent_bad "$agent: config file missing — $config"
    return
  fi

  if ! _python3_available; then
    _agent_warn "$agent: python3 unavailable — deprecated key check skipped"
    return
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/ca-depr-XXXXXX.py)" || {
    _agent_warn "$agent: cannot create temp file"
    return
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, os, re

agent  = sys.argv[1]
config = sys.argv[2]
fmt    = sys.argv[3]
schema_path = sys.argv[4]
fix_mode = sys.argv[5] == '1'

try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("WARN: cannot read schema: %s" % e)
    sys.exit(0)

deprecated_map = schema.get("deprecated_keys", {})

# Build agent-format -> deprecated list mapping
format_to_depr_key = {
    'toml': 'openhands_config_toml',
    'yaml_goose': 'goose_config_yaml',
    'yaml_aider': 'aider_conf_yml',
    'json': 'ashlrcode_settings_json',
}

# Pick the right deprecated key list
if fmt == 'toml':
    depr_list = deprecated_map.get('openhands_config_toml', [])
elif fmt == 'yaml' and 'goose' in agent:
    depr_list = deprecated_map.get('goose_config_yaml', [])
elif fmt == 'yaml' and 'aider' in agent:
    depr_list = deprecated_map.get('aider_conf_yml', [])
elif fmt == 'json':
    depr_list = deprecated_map.get('ashlrcode_settings_json', [])
else:
    depr_list = []

if not depr_list:
    print("OK: no deprecated keys defined for %s" % agent)
    sys.exit(0)

raw = open(config).read()
fixes_needed = []

for entry in depr_list:
    key         = entry.get('key', '')
    replacement = entry.get('replacement', '')
    reason      = entry.get('reason', '')

    # For TOML: check "section.key" pattern (e.g. "llm.api_base")
    # For YAML: check top-level key pattern
    # For JSON: check top-level key in nested structure

    found_key = False

    if fmt == 'toml':
        # Match key = ... in the appropriate section
        section, _, bare_key = key.partition('.')
        # Look for bare_key = ... following [section] header
        pattern = r'^\s*' + re.escape(bare_key) + r'\s*='
        in_section = False
        for line in raw.splitlines():
            stripped = line.strip()
            if stripped == '[%s]' % section:
                in_section = True
                continue
            if stripped.startswith('[') and not stripped.startswith('[['):
                in_section = False
                continue
            if in_section and re.match(pattern, line):
                found_key = True
                break

    elif fmt == 'yaml':
        # Check for top-level key occurrence
        pattern = r'^' + re.escape(key) + r'\s*:'
        if re.search(pattern, raw, re.MULTILINE):
            found_key = True

    elif fmt == 'json':
        try:
            data = json.loads(raw)
            # Check in providers.primary and fallbacks
            def _find_key(obj, target):
                if isinstance(obj, dict):
                    if target in obj:
                        return True
                    for v in obj.values():
                        if _find_key(v, target):
                            return True
                elif isinstance(obj, list):
                    for item in obj:
                        if _find_key(item, target):
                            return True
                return False
            if _find_key(data, key):
                found_key = True
        except Exception:
            if key in raw:
                found_key = True

    if found_key:
        msg = "DEPRECATED: '%s' found in %s" % (key, os.path.basename(config))
        if replacement:
            msg += " — replace with '%s'" % replacement
        if reason:
            msg += " (%s)" % reason
        print("FIX_NEEDED:%s|%s|%s" % (key, replacement, reason))
        print("ERROR: " + msg)
        fixes_needed.append((key, replacement))
    else:
        print("OK: no deprecated key '%s' in %s" % (key, os.path.basename(config)))

if fix_mode and fixes_needed:
    # Apply in-place fixes
    content = raw
    for old_key, new_key in fixes_needed:
        if not new_key:
            continue
        if fmt == 'toml':
            section, _, bare_old = old_key.partition('.')
            _, _, bare_new = new_key.partition('.')
            # Replace "bare_old = " with "bare_new = " inside the section
            content = re.sub(
                r'((?:^|\n)\[%s\][^\[]*?)(\n\s*)%s(\s*=)' % (re.escape(section), re.escape(bare_old)),
                r'\1\2%s\3' % bare_new,
                content,
                flags=re.DOTALL
            )
        elif fmt == 'yaml':
            content = re.sub(
                r'^(%s)(\s*:)' % re.escape(old_key),
                '%s\\2' % new_key,
                content,
                flags=re.MULTILINE
            )
        elif fmt == 'json':
            # For JSON, we just report — structural JSON rewrites are risky in regex
            print("WARN: --fix for JSON key '%s' skipped (use manual edit)" % old_key)
            continue
    if content != raw:
        open(config, 'w').write(content)
        print("FIXED: deprecated keys rewritten in %s" % os.path.basename(config))

sys.exit(1 if fixes_needed else 0)
PYEOF

  result="$(_run_py "$tmpscript" "$agent" "$config" "$format" "$SCHEMA_FILE" "$FIX_MODE")"
  rc=$?
  rm -f "$tmpscript"

  while IFS= read -r line; do
    case "$line" in
      "FIX_NEEDED:"*)
        # Collect for summary — don't print as ok/bad
        local fix_detail="${line#FIX_NEEDED:}"
        _FIX_ACTIONS="${_FIX_ACTIONS}${agent}:${fix_detail}\n"
        ;;
      "FIXED:"*)  _fix "$agent: ${line#FIXED: }" ;;
      "OK:"*)     _agent_ok   "$agent: ${line#OK: }" ;;
      "WARN:"*)   _agent_warn "$agent: ${line#WARN: }" ;;
      "ERROR:"*)  _agent_bad  "$agent: ${line#ERROR: }" ;;
      "")         ;;
      *)          [ -n "$line" ] && _agent_warn "$agent: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF
}

_check_deprecated "openhands" "$OH_TOML"    "toml"
_check_deprecated "goose"     "$GOOSE_YAML" "yaml"
_check_deprecated "aider"     "$AIDER_YAML" "yaml"
_check_deprecated "ashlrcode" "$ASHLR_JSON" "json"

# ─── Section 5: Env var ref coverage ──────────────────────────────────────────
_section "5. Env Var Reference Coverage"

_check_env_refs() {
  local agent="$1" config="$2"
  _cur_agent="$agent"

  if [ ! -f "$config" ]; then
    _agent_bad "$agent: config file missing — $config"
    return
  fi

  if ! _python3_available; then
    _agent_warn "$agent: python3 unavailable — env var check skipped"
    return
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/ca-env-XXXXXX.py)" || {
    _agent_warn "$agent: cannot create temp file"
    return
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, re, os, glob

agent       = sys.argv[1]
config      = sys.argv[2]
schema_path = sys.argv[3]
workbench   = sys.argv[4]

try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("WARN: cannot read schema: %s" % e)
    sys.exit(0)

# Extract ${VAR} patterns from the config file
raw = open(config).read()
refs_in_config = set(re.findall(r'\$\{([A-Z_][A-Z0-9_]*)\}', raw))

if not refs_in_config:
    print("OK: no env var refs (${VAR}) found in %s" % os.path.basename(config))
    sys.exit(0)

# Build set of vars exported in start-<agent>.sh or .env.example
exported_vars = set()

# Check .env.example
env_example = os.path.join(workbench, '.env.example')
if os.path.exists(env_example):
    for line in open(env_example):
        s = line.strip()
        if s and not s.startswith('#') and '=' in s:
            exported_vars.add(s.split('=')[0].strip())

# Check start-<agent>.sh and all start-*.sh scripts
start_scripts = glob.glob(os.path.join(workbench, 'scripts', 'start-*.sh'))
for script in start_scripts:
    content = open(script).read()
    # Match: export VAR=, export VAR, VAR=, or "load_env_file" (which exports all .env)
    for m in re.findall(r'(?:^|\n)\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=', content):
        exported_vars.add(m)
    # Also mark any var that's sourced/loaded from .env
    if 'load_env_file' in content or '. "$WORKBENCH/.env"' in content:
        # These scripts load .env, so all .env.example vars are available
        if os.path.exists(env_example):
            for line in open(env_example):
                s = line.strip()
                if s and not s.startswith('#') and '=' in s:
                    exported_vars.add(s.split('=')[0].strip())

errors = 0
for var in sorted(refs_in_config):
    if var in exported_vars:
        print("OK: ${%s} is defined in start-<agent>.sh or .env.example" % var)
    else:
        print("ERROR: ${%s} referenced in %s but not found in any start-*.sh or .env.example" % (
            var, os.path.basename(config)))
        errors += 1

sys.exit(1 if errors else 0)
PYEOF

  result="$(_run_py "$tmpscript" "$agent" "$config" "$SCHEMA_FILE" "$WORKBENCH")"
  rc=$?
  rm -f "$tmpscript"

  while IFS= read -r line; do
    case "$line" in
      "OK:"*)    _agent_ok   "$agent: ${line#OK: }" ;;
      "WARN:"*)  _agent_warn "$agent: ${line#WARN: }" ;;
      "ERROR:"*) _agent_bad  "$agent: ${line#ERROR: }" ;;
      "")        ;;
      *)         [ -n "$line" ] && _agent_warn "$agent: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF
}

_check_env_refs "openhands" "$OH_TOML"
_check_env_refs "goose"     "$GOOSE_YAML"
_check_env_refs "aider"     "$AIDER_YAML"
_check_env_refs "ashlrcode" "$ASHLR_JSON"

# ─── Section 6: Cross-agent drift summary ─────────────────────────────────────
_section "6. Cross-Agent Model Consistency Check"

if _python3_available; then
  _DRIFT_TMPSCRIPT="$(mktemp /tmp/ca-drift-XXXXXX.py)"
  cat > "$_DRIFT_TMPSCRIPT" << 'PYEOF'
import sys, json, re, os

oh_toml     = sys.argv[1]
goose_yaml  = sys.argv[2]
aider_yaml  = sys.argv[3]
ashlr_json  = sys.argv[4]

def read_toml_model(path):
    try:
        import tomllib
        with open(path, 'rb') as fh:
            data = tomllib.load(fh)
        return data.get('llm', {}).get('model', None)
    except ImportError:
        try:
            import tomli
            with open(path, 'rb') as fh:
                data = tomli.load(fh)
            return data.get('llm', {}).get('model', None)
        except ImportError:
            with open(path) as fh:
                in_llm = False
                for line in fh:
                    s = line.strip()
                    if s == '[llm]':
                        in_llm = True
                        continue
                    if s.startswith('[') and s != '[llm]':
                        in_llm = False
                        continue
                    if in_llm and s.startswith('model'):
                        return s.split('=', 1)[-1].strip().strip('"').strip("'")
    return None

def read_yaml_model(path, key):
    try:
        import yaml
        data = yaml.safe_load(open(path))
        if isinstance(data, dict):
            return str(data.get(key, '')) or None
    except ImportError:
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                if s.startswith(key + ':'):
                    return s.split(':', 1)[-1].strip().strip('"').strip("'")
    return None

def read_json_model(path):
    try:
        data = json.load(open(path))
        return data.get('providers', {}).get('primary', {}).get('model', None)
    except Exception:
        return None

oh_model = read_toml_model(oh_toml) if os.path.exists(oh_toml) else None
go_model = read_yaml_model(goose_yaml, 'GOOSE_MODEL') if os.path.exists(goose_yaml) else None
ai_model = read_yaml_model(aider_yaml, 'model') if os.path.exists(aider_yaml) else None
ac_model = read_json_model(ashlr_json) if os.path.exists(ashlr_json) else None

models = {
    'openhands': oh_model,
    'goose':     go_model,
    'aider':     ai_model,
    'ashlrcode': ac_model,
}

# Normalize: strip routing prefixes (openai/, anthropic/, etc.) and
# vendor namespaces (qwen/, meta/, google/) for cross-agent comparison.
def norm(m):
    if m is None:
        return None
    # Strip known LiteLLM provider prefixes
    for prefix in ('openai/', 'anthropic/', 'ollama/', 'vertex_ai/'):
        if m.startswith(prefix):
            m = m[len(prefix):]
            break
    # Strip vendor model namespaces (e.g. "qwen/" in "qwen/qwen3-coder-30b")
    # Only if the result still contains the model name after the slash
    parts = m.split('/', 1)
    if len(parts) == 2 and parts[0].lower() in ('qwen', 'meta', 'google', 'mistral', 'deepseek'):
        m = parts[1]
    return m.strip()

norm_models = {k: norm(v) for k, v in models.items()}
unique_non_none = set(v for v in norm_models.values() if v)

print("DRIFT_TABLE")
for agent, model in models.items():
    print("  %-12s: %s" % (agent, model or '(not found)'))

if len(unique_non_none) <= 1:
    print("OK: all agents point to the same underlying model (no drift)")
else:
    # Check if ashlrcode uses a different model (xAI) — that's expected
    local_models = {k: norm_models[k] for k in ('openhands', 'goose', 'aider')}
    local_unique = set(v for v in local_models.values() if v)
    if len(local_unique) <= 1:
        print("OK: local agents (openhands/goose/aider) use the same model")
        if norm_models.get('ashlrcode') != list(local_unique)[0] if local_unique else True:
            print("WARN: ashlrcode uses a different model (expected — it uses cloud xAI)")
    else:
        print("ERROR: model drift detected across local agents — verify configs are aligned")
        for agent, model in models.items():
            print("  DRIFT: %s = %s" % (agent, model or '(not found)'))

sys.exit(0)
PYEOF

  _DRIFT_OUT="$(_run_py "$_DRIFT_TMPSCRIPT" "$OH_TOML" "$GOOSE_YAML" "$AIDER_YAML" "$ASHLR_JSON")"
  rm -f "$_DRIFT_TMPSCRIPT"

  _drift_in_table=0
  _cur_agent="openhands"  # default for counter purposes
  while IFS= read -r line; do
    case "$line" in
      "DRIFT_TABLE")
        _drift_in_table=1
        printf "  %-12s  %s\n" "Agent" "Model"
        printf "  %-12s  %s\n" "------------" "----------------------------"
        ;;
      "  "*)
        [ "$_drift_in_table" -eq 1 ] && printf "%s\n" "$line"
        ;;
      "OK:"*)    _ok   "${line#OK: }" ;;
      "WARN:"*)  _warn "${line#WARN: }" ;;
      "ERROR:"*) _bad  "${line#ERROR: }" ;;
      "") _drift_in_table=0 ;;
      *)  [ -n "$line" ] && _warn "$line" ;;
    esac
  done << LINEEOF
$_DRIFT_OUT
LINEEOF
else
  _warn "python3 unavailable — cross-agent drift check skipped"
fi

# ─── Generate CSV report ───────────────────────────────────────────────────────
_section "7. CSV Compliance Report"

_generate_csv() {
  local csv_path="$1"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S')"

  {
    printf "timestamp,agent,pass,warn,fail,compliance_pct,status\n"
    for ag in $_AGENTS; do
      local p w f total pct status
      eval "p=\${_ag_pass_${ag}:-0}"
      eval "w=\${_ag_warn_${ag}:-0}"
      eval "f=\${_ag_fail_${ag}:-0}"
      total=$((p + w + f))
      if [ "$total" -eq 0 ]; then
        pct=0
        status="no-checks"
      else
        pct=$(( (p * 100) / total ))
        if [ "$f" -gt 0 ]; then
          status="FAIL"
        elif [ "$w" -gt 0 ]; then
          status="WARN"
        else
          status="PASS"
        fi
      fi
      printf "%s,%s,%d,%d,%d,%d,%s\n" "$ts" "$ag" "$p" "$w" "$f" "$pct" "$status"
    done
    printf "%s,TOTAL,%d,%d,%d,,\n" "$ts" "$TOTAL_PASS" "$TOTAL_WARN" "$TOTAL_FAIL"
  } > "$csv_path"
}

_generate_csv "$CSV_OUT"
if [ -f "$CSV_OUT" ]; then
  _ok "CSV report written to $CSV_OUT"
  if [ "$QUIET" -eq 0 ]; then
    printf "\n"
    column -t -s',' "$CSV_OUT" 2>/dev/null || cat "$CSV_OUT"
  fi
else
  _warn "CSV report could not be written to $CSV_OUT"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "\n%sAudit Summary:%s  %s%d passed%s  %s%d warnings%s  %s%d failed%s\n" \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN" "$TOTAL_PASS" "$C_RESET" \
  "$C_YELLOW" "$TOTAL_WARN" "$C_RESET" \
  "$C_RED" "$TOTAL_FAIL" "$C_RESET"

if [ "$FIX_MODE" -eq 1 ] && [ -n "$_FIX_ACTIONS" ]; then
  printf "\n%sFixes applied.%s Re-run without --fix to verify.\n" "$C_CYAN" "$C_RESET"
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
  printf "%sConfig issues detected — see above.%s\n" "$C_RED" "$C_RESET"
  exit 1
fi

exit 0
