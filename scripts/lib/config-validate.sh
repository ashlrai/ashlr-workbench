#!/usr/bin/env bash
# config-validate.sh — Agent Config Validation Framework for ashlr-workbench.
#
# Provides typed assertion functions that validate agent config files against
# their schema baselines.  When a key is renamed or a section removed on an
# agent upgrade, validation catches it immediately with a precise error message
# that names the offending key and links to the upgrade docs.
#
# Public API:
#   validate_json_schema   file schema_file [label]
#   validate_yaml_keys     file required_keys_csv [label]
#   validate_toml_sections file sections_csv [label]
#   validate_toml_keys     file section keys_csv [label]
#   validate_json_keys     file keys_csv [label]
#   validate_all_agent_configs
#
# Design constraints:
#   - macOS bash 3.2 safe — no mapfile, no GNU-only flags, no associative arrays
#   - No external runtime required beyond python3 (already used elsewhere)
#   - Gracefully degrades to "skipped" warnings when python3 is absent
#   - ok / warn / bad helpers must be provided by the caller (healthcheck.sh
#     defines them; a lightweight fallback is included for standalone use)
#   - Python is invoked via temp script files to avoid heredoc-in-subshell
#     parse errors on bash 3.2 / macOS /bin/sh
#
# Integration:
#   Source this file from healthcheck.sh, then call validate_all_agent_configs.
#
# Usage (standalone):
#   bash scripts/lib/config-validate.sh

# Guard against double-sourcing.
if [ -n "${_ASHLR_CONFIG_VALIDATE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_CONFIG_VALIDATE_SOURCED=1

# ─── Fallback helpers (provided by healthcheck.sh in normal operation) ─────────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
fi

# WORKBENCH must be set by the caller; derive it from this script's location as
# a fallback so the library is usable in isolation.
if [ -z "${WORKBENCH:-}" ]; then
  _CV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  WORKBENCH="$(cd "$_CV_SCRIPT_DIR/../.." && pwd)"
fi

# ─── Internal helpers ──────────────────────────────────────────────────────────

# _cv_python3_available — return 0 if python3 is on PATH.
_cv_python3_available() { command -v python3 >/dev/null 2>&1; }

# _cv_label file [label] — return display label (path or explicit name).
_cv_label() {
  local file="$1" label="${2:-}"
  if [ -n "$label" ]; then
    printf '%s' "$label"
  else
    printf '%s' "${file#$WORKBENCH/}"
  fi
}

# _cv_run_python tmpscript [args...] — run a python3 temp script, capture output,
# return exit code.  Caller must create the temp script before calling this.
_cv_run_python() {
  local script="$1"; shift
  python3 "$script" "$@" 2>&1
}

# _cv_parse_output label result rc — walk structured output lines from a Python
# validator script and call ok/warn/bad accordingly.  Echoes the final rc.
_cv_parse_output() {
  local label="$1"
  local result="$2"
  local rc="$3"
  local any_error=0

  while IFS= read -r line; do
    case "$line" in
      "OK:"*)   ok   "$label: ${line#OK: }" ;;
      "OK")     ok   "$label: validation passed" ;;
      "ERROR:"*) bad  "$label: ${line#ERROR: }"; any_error=1 ;;
      "WARN:"*) warn "$label: ${line#WARN: }" ;;
      "")       ;;
      *)        [ -n "$line" ] && warn "$label: $line" ;;
    esac
  done <<LINEEOF
$result
LINEEOF

  if [ "$any_error" -gt 0 ] || [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─── validate_json_schema <file> <schema_file> [label] ─────────────────────────
# Validates a JSON config file against a JSON schema baseline.
# The schema_file encodes structural expectations for the config type.
#
# Supported schema types (keyed by top-level field in schema_file):
#   mcp_json       — OpenHands mcp.json (stdio_servers shape + required names)
#   settings_json  — ashlrcode settings.json (mcpServers + hooks shape)
validate_json_schema() {
  local file="$1"
  local schema_file="$2"
  local label
  label="$(_cv_label "$file" "${3:-}")"

  if [ ! -f "$file" ]; then
    bad "$label: file missing — $file"
    return 1
  fi
  if [ ! -f "$schema_file" ]; then
    warn "$label: schema file missing — $schema_file (schema drift detection skipped)"
    return 0
  fi
  if ! _cv_python3_available; then
    warn "$label: python3 not available — JSON schema validation skipped"
    return 0
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/cv-py-XXXXXX.py)" || { warn "$label: cannot create temp file"; return 0; }

  cat > "$tmpscript" << 'PYEOF'
import json, sys, os

config_path = sys.argv[1]
schema_path = sys.argv[2]

errors = []

try:
    config = json.load(open(config_path))
except Exception as e:
    print("ERROR: %s is not valid JSON: %s" % (os.path.basename(config_path), e))
    sys.exit(1)

try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("WARN: schema file is not valid JSON: %s" % e)
    sys.exit(0)

schema_version = schema.get("_version", "unknown")
upgrade_docs   = schema.get("_upgrade_docs", "")

def hint(version, docs):
    s = "expected from schema v%s" % version
    if docs:
        s += "  See: %s" % docs
    return s

# ── mcp.json validation ──────────────────────────────────────────────────────
if "mcp_json" in schema:
    spec = schema["mcp_json"]
    for key in spec.get("required_keys", []):
        if key not in config:
            errors.append("mcp.json: missing required key '%s' — %s" % (key, hint(schema_version, upgrade_docs)))
    if "stdio_servers" in config:
        srv_required_keys = spec.get("stdio_server_required_keys", [])
        present_names = []
        for i, srv in enumerate(config["stdio_servers"]):
            srv_name = srv.get("name", "<server[%d]>" % i)
            present_names.append(srv_name)
            for k in srv_required_keys:
                if k not in srv:
                    errors.append("mcp.json: stdio_servers['%s'] missing key '%s' — %s" % (srv_name, k, hint(schema_version, upgrade_docs)))
        for req_name in spec.get("required_server_names", []):
            if req_name not in present_names:
                errors.append("mcp.json: missing required stdio_server '%s' — %s" % (req_name, hint(schema_version, upgrade_docs)))

# ── settings.json validation ─────────────────────────────────────────────────
if "settings_json" in schema:
    spec = schema["settings_json"]
    for key in spec.get("required_keys", []):
        if key not in config:
            errors.append("settings.json: missing required key '%s' — %s" % (key, hint(schema_version, upgrade_docs)))
    if "mcpServers" in config:
        srv_required_keys = spec.get("mcp_server_required_keys", [])
        present_names = list(config["mcpServers"].keys())
        for srv_name, srv_cfg in config["mcpServers"].items():
            for k in srv_required_keys:
                if k not in srv_cfg:
                    errors.append("settings.json: mcpServers['%s'] missing key '%s' — %s" % (srv_name, k, hint(schema_version, upgrade_docs)))
        for req_name in spec.get("required_mcp_servers", []):
            if req_name not in present_names:
                errors.append("settings.json: missing required mcpServer '%s' — %s" % (req_name, hint(schema_version, upgrade_docs)))
    if "hooks" in config:
        for req_key in spec.get("hook_required_keys", []):
            if req_key not in config["hooks"]:
                errors.append("settings.json: hooks missing required key '%s' — %s" % (req_key, hint(schema_version, upgrade_docs)))

for e in errors:
    print("ERROR: %s" % e)
if not errors:
    ver = schema.get("_version", "?")
    print("OK: schema validation passed (v%s)" % ver)
sys.exit(1 if errors else 0)
PYEOF

  result="$(_cv_run_python "$tmpscript" "$file" "$schema_file")"
  rc=$?
  rm -f "$tmpscript"
  _cv_parse_output "$label" "$result" "$rc"
}

# ─── validate_yaml_keys <file> <required_keys_csv> [label] ────────────────────
# Check that all comma-separated required_keys are present as top-level keys in
# a YAML file.  Uses python3 + PyYAML when available; falls back to grep-based
# presence check when PyYAML is absent.
validate_yaml_keys() {
  local file="$1"
  local required_csv="$2"
  local label
  label="$(_cv_label "$file" "${3:-}")"

  if [ ! -f "$file" ]; then
    bad "$label: file missing — $file"
    return 1
  fi
  if ! _cv_python3_available; then
    warn "$label: python3 not available — YAML key validation skipped"
    return 0
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/cv-py-XXXXXX.py)" || { warn "$label: cannot create temp file"; return 0; }

  cat > "$tmpscript" << 'PYEOF'
import sys, os

config_path   = sys.argv[1]
required_keys = [k.strip() for k in sys.argv[2].split(',') if k.strip()]
errors = []

try:
    import yaml
    try:
        data = yaml.safe_load(open(config_path))
    except Exception as e:
        print("ERROR: %s YAML parse error: %s" % (os.path.basename(config_path), e))
        sys.exit(1)
    if not isinstance(data, dict):
        print("ERROR: %s YAML root must be a mapping, got %s" % (os.path.basename(config_path), type(data).__name__))
        sys.exit(1)
    present_keys = set(data.keys())
except ImportError:
    # No PyYAML — use line-level key detection (key: value at column 0).
    present_keys = set()
    with open(config_path) as fh:
        for line in fh:
            stripped = line.rstrip()
            if stripped and not stripped.startswith('#') and not stripped.startswith(' ') and ':' in stripped:
                k = stripped.split(':')[0].strip()
                if k:
                    present_keys.add(k)

for key in required_keys:
    if key not in present_keys:
        errors.append("missing required key '%s'" % key)

for e in errors:
    print("ERROR: %s" % e)
if not errors:
    print("OK: required YAML keys present")
sys.exit(1 if errors else 0)
PYEOF

  result="$(_cv_run_python "$tmpscript" "$file" "$required_csv")"
  rc=$?
  rm -f "$tmpscript"
  _cv_parse_output "$label" "$result" "$rc"
}

# ─── validate_toml_sections <file> <sections_csv> [label] ─────────────────────
# Confirm that all required top-level [sections] exist in a TOML file.
validate_toml_sections() {
  local file="$1"
  local sections_csv="$2"
  local label
  label="$(_cv_label "$file" "${3:-}")"

  if [ ! -f "$file" ]; then
    bad "$label: file missing — $file"
    return 1
  fi
  if ! _cv_python3_available; then
    warn "$label: python3 not available — TOML section validation skipped"
    return 0
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/cv-py-XXXXXX.py)" || { warn "$label: cannot create temp file"; return 0; }

  cat > "$tmpscript" << 'PYEOF'
import sys, os

config_path = sys.argv[1]
required    = [s.strip() for s in sys.argv[2].split(',') if s.strip()]
errors      = []

data = None
try:
    import tomllib
    with open(config_path, 'rb') as fh:
        data = tomllib.load(fh)
except ImportError:
    try:
        import tomli
        with open(config_path, 'rb') as fh:
            data = tomli.load(fh)
    except ImportError:
        # Fallback: scan for [section] header lines.
        present = set()
        with open(config_path) as fh:
            for line in fh:
                s = line.strip()
                if s.startswith('[') and s.endswith(']') and not s.startswith('[['):
                    present.add(s[1:-1].strip())
        for sec in required:
            if sec not in present:
                errors.append("missing required section [%s]" % sec)
        for e in errors:
            print("ERROR: %s" % e)
        if not errors:
            print("OK: required TOML sections present")
        sys.exit(1 if errors else 0)

if data is not None:
    for sec in required:
        if sec not in data:
            errors.append("missing required section [%s]" % sec)

for e in errors:
    print("ERROR: %s" % e)
if not errors:
    print("OK: required TOML sections present")
sys.exit(1 if errors else 0)
PYEOF

  result="$(_cv_run_python "$tmpscript" "$file" "$sections_csv")"
  rc=$?
  rm -f "$tmpscript"
  _cv_parse_output "$label" "$result" "$rc"
}

# ─── validate_toml_keys <file> <section> <keys_csv> [label] ───────────────────
# Check that specific keys exist within a named [section] of a TOML file.
# Emits a precise error like:
#   'config.toml: missing [sandbox].runtime_container_image — expected from OpenHands 1.6+ schema'
validate_toml_keys() {
  local file="$1"
  local section="$2"
  local keys_csv="$3"
  local label
  label="$(_cv_label "$file" "${4:-}")"

  if [ ! -f "$file" ]; then
    bad "$label: file missing — $file"
    return 1
  fi
  if ! _cv_python3_available; then
    warn "$label: python3 not available — TOML key validation skipped"
    return 0
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/cv-py-XXXXXX.py)" || { warn "$label: cannot create temp file"; return 0; }

  cat > "$tmpscript" << 'PYEOF'
import sys, os

config_path = sys.argv[1]
section     = sys.argv[2]
required    = [k.strip() for k in sys.argv[3].split(',') if k.strip()]
errors      = []

data = None
parse_failed = False

try:
    import tomllib
    with open(config_path, 'rb') as fh:
        data = tomllib.load(fh)
except ImportError:
    try:
        import tomli
        with open(config_path, 'rb') as fh:
            data = tomli.load(fh)
    except ImportError:
        parse_failed = True

if parse_failed:
    # Fallback: scan lines within the target section.
    in_section = False
    present_keys = set()
    raw = open(config_path).read()
    for line in raw.splitlines():
        s = line.strip()
        if s.startswith('[') and not s.startswith('[['):
            in_section = (s == '[%s]' % section)
            continue
        if in_section and '=' in s and not s.startswith('#'):
            k = s.split('=')[0].strip()
            present_keys.add(k)
    if '[%s]' % section not in raw:
        errors.append("section [%s] not found" % section)
    else:
        for key in required:
            if key not in present_keys:
                errors.append("missing [%s].%s" % (section, key))
    for e in errors:
        print("ERROR: %s" % e)
    if not errors:
        print("OK: TOML [%s] keys present" % section)
    sys.exit(1 if errors else 0)

if section not in data:
    print("ERROR: section [%s] missing from config" % section)
    sys.exit(1)

sec_data = data[section]
for key in required:
    if key not in sec_data:
        errors.append("missing [%s].%s" % (section, key))

for e in errors:
    print("ERROR: %s" % e)
if not errors:
    print("OK: TOML [%s] keys present" % section)
sys.exit(1 if errors else 0)
PYEOF

  result="$(_cv_run_python "$tmpscript" "$file" "$section" "$keys_csv")"
  rc=$?
  rm -f "$tmpscript"
  _cv_parse_output "$label" "$result" "$rc"
}

# ─── validate_json_keys <file> <keys_csv> [label] ─────────────────────────────
# Check that all comma-separated keys are present at the top level of a JSON
# file.  Used for quick structural checks without a full schema file.
validate_json_keys() {
  local file="$1"
  local keys_csv="$2"
  local label
  label="$(_cv_label "$file" "${3:-}")"

  if [ ! -f "$file" ]; then
    bad "$label: file missing — $file"
    return 1
  fi
  if ! _cv_python3_available; then
    warn "$label: python3 not available — JSON key validation skipped"
    return 0
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/cv-py-XXXXXX.py)" || { warn "$label: cannot create temp file"; return 0; }

  cat > "$tmpscript" << 'PYEOF'
import json, sys, os

config_path   = sys.argv[1]
required_keys = [k.strip() for k in sys.argv[2].split(',') if k.strip()]
errors        = []

try:
    data = json.load(open(config_path))
except Exception as e:
    print("ERROR: %s JSON parse error: %s" % (os.path.basename(config_path), e))
    sys.exit(1)

if not isinstance(data, dict):
    print("ERROR: expected JSON object at root, got %s" % type(data).__name__)
    sys.exit(1)

for key in required_keys:
    if key not in data:
        errors.append("missing required key '%s'" % key)

for e in errors:
    print("ERROR: %s" % e)
if not errors:
    print("OK: required JSON keys present")
sys.exit(1 if errors else 0)
PYEOF

  result="$(_cv_run_python "$tmpscript" "$file" "$keys_csv")"
  rc=$?
  rm -f "$tmpscript"
  _cv_parse_output "$label" "$result" "$rc"
}

# ─── validate_all_agent_configs ────────────────────────────────────────────────
# Run all schema-aware config validations for every agent in the workbench.
# Called by healthcheck.sh; also usable standalone.
#
# Checks performed:
#   OpenHands config.toml — sections + per-section required keys
#   OpenHands mcp.json    — top-level shape + stdio_servers contract
#   Aider aider.conf.yml  — required keys
#   Goose config.yaml     — required keys + extensions block
#   ashlrcode settings.json — required keys + mcpServers + hooks
validate_all_agent_configs() {
  local wb="${WORKBENCH:-}"
  if [ -z "$wb" ]; then
    _CV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    wb="$(cd "$_CV_SCRIPT_DIR/../.." && pwd)"
  fi

  # ── OpenHands config.toml ───────────────────────────────────────────────────
  local oh_toml="$wb/agents/openhands/config.toml"
  local oh_schema="$wb/agents/openhands/schema.json"

  validate_toml_sections "$oh_toml" "core,llm,sandbox,agent,security" \
    "openhands/config.toml"
  validate_toml_keys "$oh_toml" "core" \
    "workspace_base,file_store,max_iterations,run_as_openhands" \
    "openhands/config.toml"
  validate_toml_keys "$oh_toml" "llm" \
    "model,base_url,api_key,max_input_tokens,max_output_tokens,temperature" \
    "openhands/config.toml"
  validate_toml_keys "$oh_toml" "sandbox" \
    "runtime_container_image,timeout,use_host_network" \
    "openhands/config.toml"
  validate_toml_keys "$oh_toml" "agent" \
    "name,enable_mcp,mcp_config_path" \
    "openhands/config.toml"
  validate_toml_keys "$oh_toml" "security" \
    "confirmation_mode,security_analyzer" \
    "openhands/config.toml"

  # ── OpenHands mcp.json ──────────────────────────────────────────────────────
  validate_json_schema \
    "$wb/agents/openhands/mcp.json" \
    "$oh_schema" \
    "openhands/mcp.json"

  # ── Aider aider.conf.yml ────────────────────────────────────────────────────
  validate_yaml_keys \
    "$wb/agents/aider/aider.conf.yml" \
    "model,openai-api-base,openai-api-key,auto-commits,dirty-commits,map-tokens,stream,pretty" \
    "aider/aider.conf.yml"

  # ── Goose config.yaml ───────────────────────────────────────────────────────
  validate_yaml_keys \
    "$wb/agents/goose/config.yaml" \
    "GOOSE_PROVIDER,GOOSE_MODEL,OPENAI_HOST,GOOSE_MODE,GOOSE_TEMPERATURE,GOOSE_MAX_TOKENS,extensions" \
    "goose/config.yaml"

  # ── ashlrcode settings.json ─────────────────────────────────────────────────
  validate_json_schema \
    "$wb/agents/ashlrcode/settings.json" \
    "$wb/agents/ashlrcode/schema.json" \
    "ashlrcode/settings.json"
}

# ─── Standalone execution ──────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail

  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""
  else
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  fi

  PASS=0; WARN=0; FAIL=0

  ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; PASS=$((PASS+1)); }
  warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; WARN=$((WARN+1)); }
  bad()  { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*"; FAIL=$((FAIL+1)); }

  printf "%sAgent Config Validation%s\n" "$C_BOLD" "$C_RESET"
  validate_all_agent_configs

  printf "\n%sResult:%s %s%d passed%s, %s%d warnings%s, %s%d failed%s\n" \
    "$C_BOLD" "$C_RESET" \
    "$C_GREEN" "$PASS" "$C_RESET" \
    "$C_YELLOW" "$WARN" "$C_RESET" \
    "$C_RED" "$FAIL" "$C_RESET"

  [ "$FAIL" -eq 0 ]
fi
