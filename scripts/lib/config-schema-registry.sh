#!/usr/bin/env bash
# config-schema-registry.sh — Centralized config schema registry with versioning
# and auto-migration for ashlr-workbench agent configs.
#
# This library is the single source of truth for:
#   - The canonical schema version ($SCHEMA_REGISTRY_VERSION = "v1.0")
#   - Per-agent config migration rules (loaded from agents/<name>/config-migrations.json)
#   - config_validate_strict  <config-file>                — schema + migration check
#   - config_migrate_auto     <config-file> --target-version v1.0  — apply migrations
#   - config_registry_check_all  — validate all known agents, emit warn/bad lines
#
# Design:
#   - macOS bash 3.2 safe — no mapfile, no associative arrays, no GNU-only flags
#   - Requires python3 (used project-wide; gracefully degrades when absent)
#   - Follows the ok/warn/bad convention from healthcheck.sh
#   - Double-source guard via _ASHLR_SCHEMA_REGISTRY_SOURCED
#
# Integration:
#   . scripts/lib/config-schema-registry.sh
#   config_registry_check_all        # called by healthcheck.sh
#   config_validate_strict  agents/aider/aider.conf.yml
#   config_migrate_auto     agents/openhands/config.toml --target-version v1.0
#
# Usage (standalone):
#   bash scripts/lib/config-schema-registry.sh

if [ -n "${_ASHLR_SCHEMA_REGISTRY_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ASHLR_SCHEMA_REGISTRY_SOURCED=1

# ─── Canonical schema version ─────────────────────────────────────────────────
SCHEMA_REGISTRY_VERSION="v1.0"
SCHEMA_REGISTRY_DATE="2026-06-29"

# ─── Resolve WORKBENCH ────────────────────────────────────────────────────────
if [ -z "${WORKBENCH:-}" ]; then
  _SR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  WORKBENCH="$(cd "$_SR_SCRIPT_DIR/../.." && pwd)"
fi

# ─── Fallback helpers (provided by healthcheck.sh in normal use) ──────────────
if ! declare -f ok >/dev/null 2>&1; then
  ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
  warn() { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
  bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
fi

# ─── Internal helpers ─────────────────────────────────────────────────────────

_sr_python3_available() { command -v python3 >/dev/null 2>&1; }

# _sr_agent_format <agent-name> — map agent name to config format string
_sr_agent_format() {
  case "$1" in
    openhands) printf 'toml'  ;;
    goose)     printf 'yaml'  ;;
    aider)     printf 'yaml'  ;;
    ashlrcode) printf 'json'  ;;
    *)         printf 'unknown' ;;
  esac
}

# _sr_agent_config <agent-name> — path to the agent's primary config file
_sr_agent_config() {
  case "$1" in
    openhands) printf '%s/agents/openhands/config.toml'       "$WORKBENCH" ;;
    goose)     printf '%s/agents/goose/config.yaml'            "$WORKBENCH" ;;
    aider)     printf '%s/agents/aider/aider.conf.yml'         "$WORKBENCH" ;;
    ashlrcode) printf '%s/agents/ashlrcode/settings.json'      "$WORKBENCH" ;;
    *)         printf '' ;;
  esac
}

# _sr_agent_migrations <agent-name> — path to the agent's migrations file
_sr_agent_migrations() {
  printf '%s/agents/%s/config-migrations.json' "$WORKBENCH" "$1"
}

# ─── config_validate_strict <config-file> [agent-name] ────────────────────────
# Validates the given config file against agents/config-schema.json AND reports
# on any known migration rules that haven't been applied (deprecated keys still
# present, missing version annotation, etc.).
#
# Emits lines via ok/warn/bad.
# Returns 0 if clean, 1 if any errors found.
config_validate_strict() {
  local config_file="$1"
  local agent="${2:-}"
  local label="${config_file#$WORKBENCH/}"

  if [ ! -f "$config_file" ]; then
    bad "config-schema-registry: $label — file not found"
    return 1
  fi

  if ! _sr_python3_available; then
    warn "config-schema-registry: python3 unavailable — strict validation of $label skipped"
    return 0
  fi

  # Auto-detect agent name from path if not provided
  if [ -z "$agent" ]; then
    case "$config_file" in
      */openhands/*) agent="openhands" ;;
      */goose/*)     agent="goose"     ;;
      */aider/*)     agent="aider"     ;;
      */ashlrcode/*) agent="ashlrcode" ;;
      *)             agent="unknown"   ;;
    esac
  fi

  local schema_file="$WORKBENCH/agents/config-schema.json"
  local migrations_file
  migrations_file="$(_sr_agent_migrations "$agent")"
  local format
  format="$(_sr_agent_format "$agent")"

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/sr-validate-XXXXXX.py)" || {
    warn "config-schema-registry: cannot create temp file for strict validation"
    return 0
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, os, re

config_path      = sys.argv[1]
schema_path      = sys.argv[2]
migrations_path  = sys.argv[3]
agent            = sys.argv[4]
fmt              = sys.argv[5]
registry_version = sys.argv[6]

errors   = []
warnings = []

# ── Load config ───────────────────────────────────────────────────────────────
try:
    raw = open(config_path).read()
except Exception as e:
    print("ERROR: cannot read %s: %s" % (os.path.basename(config_path), e))
    sys.exit(1)

# ── Load canonical schema ─────────────────────────────────────────────────────
schema = {}
if os.path.exists(schema_path):
    try:
        schema = json.load(open(schema_path))
    except Exception as e:
        warnings.append("cannot parse config-schema.json: %s" % e)

# ── Load per-agent migrations ─────────────────────────────────────────────────
migrations = []
if os.path.exists(migrations_path):
    try:
        mdata = json.load(open(migrations_path))
        migrations = mdata.get("migrations", [])
    except Exception as e:
        warnings.append("cannot parse config-migrations.json: %s" % e)

# ── Schema version annotation check ──────────────────────────────────────────
# For JSON configs we check for a "$schema" key; for YAML/TOML we look for a
# comment annotation like "# ashlr-config/v1.0".
has_version_annotation = False
if fmt == "json":
    try:
        cfg_data = json.loads(raw)
        if isinstance(cfg_data, dict) and "$schema" in cfg_data:
            sv = cfg_data["$schema"]
            if "ashlr-config" in str(sv):
                has_version_annotation = True
    except Exception:
        pass
else:
    if "ashlr-config/%s" % registry_version in raw or "ashlr-config/v" in raw:
        has_version_annotation = True

if not has_version_annotation:
    warnings.append(
        "no schema version annotation found — "
        "add '# ashlr-config/%s' comment (YAML/TOML) or "
        "'\"$schema\": \"ashlr-config/%s\"' (JSON)" % (registry_version, registry_version)
    )

# ── Check deprecated keys from canonical schema ───────────────────────────────
deprecated_map = schema.get("deprecated_keys", {})

agent_depr_key_map = {
    "openhands": "openhands_config_toml",
    "goose":     "goose_config_yaml",
    "aider":     "aider_conf_yml",
    "ashlrcode": "ashlrcode_settings_json",
}
depr_section = agent_depr_key_map.get(agent, "")
depr_list    = deprecated_map.get(depr_section, [])

for entry in depr_list:
    key         = entry.get("key", "")
    replacement = entry.get("replacement", "")
    reason      = entry.get("reason", "")
    if not key:
        continue

    found = False
    if fmt == "toml":
        section, _, bare_key = key.partition(".")
        in_section = False
        for line in raw.splitlines():
            s = line.strip()
            if s == "[%s]" % section:
                in_section = True
                continue
            if s.startswith("[") and not s.startswith("[["):
                in_section = False
                continue
            if in_section and re.match(r"^\s*" + re.escape(bare_key) + r"\s*=", line):
                found = True
                break
    elif fmt == "yaml":
        if re.search(r"^" + re.escape(key) + r"\s*:", raw, re.MULTILINE):
            found = True
    elif fmt == "json":
        try:
            cfg_data = json.loads(raw)
            def _find(obj, k):
                if isinstance(obj, dict):
                    if k in obj: return True
                    return any(_find(v, k) for v in obj.values())
                if isinstance(obj, list):
                    return any(_find(i, k) for i in obj)
                return False
            found = _find(cfg_data, key)
        except Exception:
            found = key in raw

    if found:
        msg = "deprecated key '%s' still present" % key
        if replacement:
            msg += " — migrate to '%s'" % replacement
        if reason:
            msg += " (%s)" % reason
        errors.append(msg)

# ── Check per-agent migrations not yet applied ────────────────────────────────
unapplied = []
for mig in migrations:
    old_key     = mig.get("old_key", "")
    new_key     = mig.get("new_key", "")
    version_str = mig.get("version", "")
    description = mig.get("description", "")
    root_only   = mig.get("root_only", False)

    if not old_key:
        continue

    old_found = False
    if fmt == "toml":
        section, _, bare = old_key.partition(".")
        if bare:
            in_sec = False
            for line in raw.splitlines():
                s = line.strip()
                if s == "[%s]" % section:
                    in_sec = True
                    continue
                if s.startswith("[") and not s.startswith("[["):
                    in_sec = False
                    continue
                if in_sec and re.match(r"^\s*" + re.escape(bare) + r"\s*=", line):
                    old_found = True
                    break
        else:
            if re.search(r"^" + re.escape(old_key) + r"\s*=", raw, re.MULTILINE):
                old_found = True
    elif fmt == "yaml":
        if re.search(r"^" + re.escape(old_key) + r"\s*:", raw, re.MULTILINE):
            old_found = True
    elif fmt == "json":
        try:
            cfg_data = json.loads(raw)
            if root_only:
                old_found = isinstance(cfg_data, dict) and old_key in cfg_data
            else:
                def _find2(obj, k):
                    if isinstance(obj, dict):
                        if k in obj: return True
                        return any(_find2(v, k) for v in obj.values())
                    if isinstance(obj, list):
                        return any(_find2(i, k) for i in obj)
                    return False
                old_found = _find2(cfg_data, old_key)
        except Exception:
            old_found = old_key in raw

    if old_found:
        msg = "unapplied migration (%s): '%s' → '%s'" % (version_str, old_key, new_key)
        if description:
            msg += " — %s" % description
        unapplied.append(msg)

for m in unapplied:
    errors.append(m)

# ── Output ────────────────────────────────────────────────────────────────────
for w in warnings:
    print("WARN: %s" % w)

if errors:
    for e in errors:
        print("ERROR: %s" % e)
    sys.exit(1)
else:
    print("OK: %s passes strict schema registry validation (%s)" % (
        os.path.basename(config_path), registry_version))
    sys.exit(0)
PYEOF

  result="$(python3 "$tmpscript" \
    "$config_file" "$schema_file" "$migrations_file" \
    "$agent" "$format" "$SCHEMA_REGISTRY_VERSION" 2>&1)"
  rc=$?
  rm -f "$tmpscript"

  local any_error=0
  while IFS= read -r line; do
    case "$line" in
      "OK:"*)    ok   "$label: ${line#OK: }" ;;
      "WARN:"*)  warn "$label: ${line#WARN: }" ;;
      "ERROR:"*) bad  "$label: ${line#ERROR: }"; any_error=1 ;;
      "")        ;;
      *)         [ -n "$line" ] && warn "$label: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF

  if [ "$any_error" -gt 0 ] || [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─── config_migrate_auto <config-file> --target-version <ver> ─────────────────
# Apply all migrations from agents/<name>/config-migrations.json that are
# applicable to the given config file, writing the result back in-place.
# A migration log is written alongside the config as <config-file>.migration-log.
#
# Options:
#   --target-version <ver>   Required. E.g. "v1.0"
#   --agent <name>           Override agent detection (useful for temp file paths)
#   --dry-run                Print what would change without modifying files
#   --log-path <path>        Override log output path
#
# Returns 0 on success, 1 if migrations failed or no migrations were applicable.
config_migrate_auto() {
  local config_file=""
  local target_version=""
  local dry_run=0
  local log_path=""
  local agent_override=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --target-version) shift; target_version="$1" ;;
      --dry-run)        dry_run=1 ;;
      --log-path)       shift; log_path="$1" ;;
      --agent)          shift; agent_override="$1" ;;
      -*)               warn "config_migrate_auto: unknown option $1" ;;
      *)
        if [ -z "$config_file" ]; then
          config_file="$1"
        fi
        ;;
    esac
    shift
  done

  if [ -z "$config_file" ]; then
    bad "config_migrate_auto: no config file specified"
    return 1
  fi
  if [ -z "$target_version" ]; then
    bad "config_migrate_auto: --target-version required"
    return 1
  fi

  local label="${config_file#$WORKBENCH/}"

  if [ ! -f "$config_file" ]; then
    bad "config_migrate_auto: $label — file not found"
    return 1
  fi

  if ! _sr_python3_available; then
    warn "config_migrate_auto: python3 unavailable — migration of $label skipped"
    return 0
  fi

  # Auto-detect agent from path (--agent override takes precedence)
  local agent
  if [ -n "$agent_override" ]; then
    agent="$agent_override"
  else
    case "$config_file" in
      */openhands/*) agent="openhands" ;;
      */goose/*)     agent="goose"     ;;
      */aider/*)     agent="aider"     ;;
      */ashlrcode/*) agent="ashlrcode" ;;
      *)             agent="unknown"   ;;
    esac
  fi

  local migrations_file
  migrations_file="$(_sr_agent_migrations "$agent")"
  local format
  format="$(_sr_agent_format "$agent")"

  if [ -z "$log_path" ]; then
    log_path="${config_file}.migration-log"
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/sr-migrate-XXXXXX.py)" || {
    warn "config_migrate_auto: cannot create temp file"
    return 1
  }

  cat > "$tmpscript" << 'PYEOF'
import sys, json, os, re, datetime

config_path     = sys.argv[1]
migrations_path = sys.argv[2]
agent           = sys.argv[3]
fmt             = sys.argv[4]
target_version  = sys.argv[5]
dry_run         = sys.argv[6] == "1"
log_path        = sys.argv[7]

# ── Load config ───────────────────────────────────────────────────────────────
try:
    raw = open(config_path).read()
except Exception as e:
    print("ERROR: cannot read config: %s" % e)
    sys.exit(1)

# ── Load migrations ───────────────────────────────────────────────────────────
if not os.path.exists(migrations_path):
    print("WARN: no migrations file at %s — nothing to migrate" % migrations_path)
    sys.exit(0)

try:
    mdata      = json.load(open(migrations_path))
    migrations = mdata.get("migrations", [])
    agent_name = mdata.get("agent", agent)
    from_ver   = mdata.get("from_version", "unknown")
    to_ver     = mdata.get("to_version", target_version)
except Exception as e:
    print("ERROR: cannot parse migrations file: %s" % e)
    sys.exit(1)

if not migrations:
    print("OK: no migrations defined in %s" % os.path.basename(migrations_path))
    sys.exit(0)

# ── Apply migrations in sequence ──────────────────────────────────────────────
content      = raw
applied      = []
skipped      = []
failed       = []

for mig in migrations:
    old_key     = mig.get("old_key", "")
    new_key     = mig.get("new_key", "")
    version_str = mig.get("version", "")
    description = mig.get("description", "")
    transform   = mig.get("transform", "rename")
    new_value   = mig.get("new_value", None)
    root_only   = mig.get("root_only", False)

    if not old_key:
        skipped.append({"migration": mig, "reason": "missing old_key"})
        continue

    # Check if old_key is present in current content
    old_present = False
    if fmt == "toml":
        section, _, bare = old_key.partition(".")
        if bare:
            in_sec = False
            for line in content.splitlines():
                s = line.strip()
                if s == "[%s]" % section:
                    in_sec = True
                    continue
                if s.startswith("[") and not s.startswith("[["):
                    in_sec = False
                    continue
                if in_sec and re.match(r"^\s*" + re.escape(bare) + r"\s*=", line):
                    old_present = True
                    break
        else:
            old_present = bool(re.search(r"^" + re.escape(old_key) + r"\s*=", content, re.MULTILINE))
    elif fmt == "yaml":
        old_present = bool(re.search(r"^" + re.escape(old_key) + r"\s*:", content, re.MULTILINE))
    elif fmt == "json":
        try:
            cfg_data = json.loads(content)
            if root_only:
                old_present = isinstance(cfg_data, dict) and old_key in cfg_data
            else:
                def _find(obj, k):
                    if isinstance(obj, dict):
                        if k in obj: return True
                        return any(_find(v, k) for v in obj.values())
                    if isinstance(obj, list):
                        return any(_find(i, k) for i in obj)
                    return False
                old_present = _find(cfg_data, old_key)
        except Exception:
            old_present = old_key in content

    if not old_present:
        skipped.append({
            "migration": mig,
            "reason": "old_key '%s' not present — already migrated or not applicable" % old_key
        })
        continue

    # Apply the transform
    new_content = content
    try:
        if transform == "rename":
            if fmt == "toml" and new_key:
                section, _, bare_old = old_key.partition(".")
                _, _, bare_new       = new_key.partition(".")
                new_content = re.sub(
                    r'((?:^|\n)\[%s\][^\[]*?)(\n[ \t]*)%s(\s*=)' % (
                        re.escape(section), re.escape(bare_old)),
                    r'\1\2%s\3' % bare_new,
                    content,
                    flags=re.DOTALL
                )
            elif fmt == "yaml" and new_key:
                new_content = re.sub(
                    r'^(%s)(\s*:)' % re.escape(old_key),
                    '%s\\2' % new_key,
                    content,
                    flags=re.MULTILINE
                )
            elif fmt == "json":
                try:
                    cfg_data = json.loads(content)
                    def _rename(obj, ok, nk):
                        if isinstance(obj, dict):
                            result = {}
                            for k, v in obj.items():
                                use_k = nk if k == ok else k
                                result[use_k] = _rename(v, ok, nk)
                            return result
                        if isinstance(obj, list):
                            return [_rename(i, ok, nk) for i in obj]
                        return obj
                    cfg_data = _rename(cfg_data, old_key, new_key)
                    new_content = json.dumps(cfg_data, indent=2) + "\n"
                except Exception as e:
                    failed.append({"migration": mig, "reason": "JSON rename failed: %s" % e})
                    continue
        elif transform == "delete":
            if fmt == "yaml":
                new_content = re.sub(
                    r'^%s\s*:.*\n?' % re.escape(old_key),
                    '',
                    content,
                    flags=re.MULTILINE
                )
            elif fmt == "json":
                try:
                    cfg_data = json.loads(content)
                    def _delete(obj, k):
                        if isinstance(obj, dict):
                            return {ck: _delete(cv, k) for ck, cv in obj.items() if ck != k}
                        if isinstance(obj, list):
                            return [_delete(i, k) for i in obj]
                        return obj
                    cfg_data = _delete(cfg_data, old_key)
                    new_content = json.dumps(cfg_data, indent=2) + "\n"
                except Exception as e:
                    failed.append({"migration": mig, "reason": "JSON delete failed: %s" % e})
                    continue
        elif transform == "set_value" and new_value is not None:
            if fmt == "toml":
                section, _, bare = old_key.partition(".")
                if bare:
                    new_content = re.sub(
                        r'((?:^|\n)\[%s\][^\[]*?)(\n[ \t]*)(%s\s*=\s*)(.*)' % (
                            re.escape(section), re.escape(bare)),
                        r'\1\2\g<3>"%s"' % new_value,
                        content,
                        flags=re.DOTALL
                    )
            elif fmt == "yaml":
                new_content = re.sub(
                    r'^(%s\s*:)\s*.*$' % re.escape(old_key),
                    r'\1 %s' % new_value,
                    content,
                    flags=re.MULTILINE
                )
        else:
            skipped.append({"migration": mig, "reason": "unsupported transform '%s'" % transform})
            continue

        if new_content != content:
            content = new_content
            applied.append(mig)
            print("MIGRATED: %s → %s (%s)" % (old_key, new_key or "[%s]" % transform, version_str))
        else:
            skipped.append({"migration": mig, "reason": "no change after transform"})

    except Exception as e:
        failed.append({"migration": mig, "reason": "transform exception: %s" % e})

# ── Write results ─────────────────────────────────────────────────────────────
if dry_run:
    print("DRY_RUN: %d migrations would be applied, %d skipped, %d failed" % (
        len(applied), len(skipped), len(failed)))
    if applied:
        for m in applied:
            print("  WOULD_APPLY: %s → %s (%s)" % (
                m.get("old_key"), m.get("new_key", ""), m.get("version", "")))
else:
    if applied and content != raw:
        try:
            open(config_path, "w").write(content)
            print("WRITTEN: %d migration(s) applied to %s" % (
                len(applied), os.path.basename(config_path)))
        except Exception as e:
            print("ERROR: could not write config: %s" % e)
            sys.exit(1)
    elif not applied:
        print("OK: no applicable migrations for %s (all up to date or already migrated)" % (
            os.path.basename(config_path)))

# ── Write migration log ───────────────────────────────────────────────────────
if not dry_run:
    try:
        log = {
            "timestamp":      datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "agent":          agent_name,
            "config_file":    os.path.basename(config_path),
            "from_version":   from_ver,
            "to_version":     to_ver,
            "target_version": target_version,
            "applied":        applied,
            "skipped":        [{"old_key": s["migration"].get("old_key"),
                                "reason": s["reason"]} for s in skipped],
            "failed":         [{"old_key": f["migration"].get("old_key"),
                                "reason": f["reason"]} for f in failed],
        }
        open(log_path, "w").write(json.dumps(log, indent=2) + "\n")
        print("LOG: migration log written to %s" % os.path.basename(log_path))
    except Exception as e:
        print("WARN: could not write migration log: %s" % e)

if failed:
    print("ERROR: %d migration(s) failed — check log for details" % len(failed))
    sys.exit(1)

sys.exit(0)
PYEOF

  local dry_run_str="0"
  [ "$dry_run" -eq 1 ] && dry_run_str="1"

  result="$(python3 "$tmpscript" \
    "$config_file" "$migrations_file" \
    "$agent" "$format" "$target_version" \
    "$dry_run_str" "$log_path" 2>&1)"
  rc=$?
  rm -f "$tmpscript"

  local any_error=0
  while IFS= read -r line; do
    case "$line" in
      "OK:"*)        ok   "$label: ${line#OK: }" ;;
      "MIGRATED:"*)  ok   "$label: ${line#MIGRATED: }" ;;
      "WRITTEN:"*)   ok   "$label: ${line#WRITTEN: }" ;;
      "LOG:"*)       ok   "$label: ${line#LOG: }" ;;
      "DRY_RUN:"*)   warn "$label: DRY RUN — ${line#DRY_RUN: }" ;;
      "WOULD_APPLY:"*) warn "$label: ${line#WOULD_APPLY: }" ;;
      "WARN:"*)      warn "$label: ${line#WARN: }" ;;
      "ERROR:"*)     bad  "$label: ${line#ERROR: }"; any_error=1 ;;
      "")            ;;
      *)             [ -n "$line" ] && warn "$label: $line" ;;
    esac
  done << LINEEOF
$result
LINEEOF

  if [ "$any_error" -gt 0 ] || [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─── MCP server config validation ────────────────────────────────────────────
#
# mcp_validate_agent_config <agent-name> [--diff-report-path <path>]
#   Validates the MCP server config for the given agent against its
#   agents/<name>/mcp-schema.json.  Checks:
#     - All required servers are present
#     - Each server has the required fields (command/cmd, args, name where needed)
#     - Known breaking-change signatures are absent (e.g. old arg flags)
#     - Known deprecated server names / entrypoints are absent
#     - For ashlrcode/openhands: 3rd-party server env vars are referenced
#
#   Emits ok/warn/bad lines and returns 0 if clean, 1 if errors found.
#
#   With --diff-report-path <path>: also writes a human-readable diff report to
#   the given path (JSON format) so callers can show what changed.
#
# mcp_validate_all_agents [--diff-report-path <path>]
#   Runs mcp_validate_agent_config for all four agents.
#
# mcp_generate_diff_report <agent-name> <report-path>
#   Standalone: writes the JSON diff report for an agent to a file.

_sr_mcp_schema() {
  printf '%s/agents/%s/mcp-schema.json' "$WORKBENCH" "$1"
}

# _sr_mcp_config_file <agent> — path to the agent's MCP config file
# (may differ from the main config for openhands which has a separate mcp.json)
_sr_mcp_config_file() {
  case "$1" in
    ashlrcode) printf '%s/agents/ashlrcode/settings.json' "$WORKBENCH" ;;
    aider)     printf '%s/agents/aider/aider.conf.yml'    "$WORKBENCH" ;;
    openhands) printf '%s/agents/openhands/mcp.json'      "$WORKBENCH" ;;
    goose)     printf '%s/agents/goose/config.yaml'       "$WORKBENCH" ;;
    *)         printf '' ;;
  esac
}

mcp_validate_agent_config() {
  local agent="$1"
  local diff_report_path=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --diff-report-path) shift; diff_report_path="$1" ;;
      *) warn "mcp_validate_agent_config: unknown option $1" ;;
    esac
    shift
  done

  local schema_file config_file label
  schema_file="$(_sr_mcp_schema "$agent")"
  config_file="$(_sr_mcp_config_file "$agent")"
  label="agents/${agent}/mcp"

  if [ ! -f "$schema_file" ]; then
    warn "mcp-schema-registry: $agent — mcp-schema.json not found at ${schema_file#$WORKBENCH/}"
    return 0
  fi

  if [ ! -f "$config_file" ]; then
    bad "mcp-schema-registry: $agent — config file not found at ${config_file#$WORKBENCH/}"
    return 1
  fi

  if ! _sr_python3_available; then
    warn "mcp-schema-registry: python3 unavailable — MCP validation of $agent skipped"
    return 0
  fi

  local tmpscript rc result
  tmpscript="$(mktemp /tmp/sr-mcp-validate-XXXXXX.py)" || {
    warn "mcp-schema-registry: cannot create temp file for MCP validation"
    return 0
  }

  cat > "$tmpscript" << 'MCP_PYEOF'
import sys, json, os, re
try:
    from datetime import datetime, timezone
    _utcnow = lambda: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
except Exception:
    import datetime as _dt
    _utcnow = lambda: _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

agent            = sys.argv[1]
config_path      = sys.argv[2]
schema_path      = sys.argv[3]
diff_report_path = sys.argv[4]   # "/dev/null" = no report

errors   = []
warnings = []
diff_items = []

# ── Load schema ───────────────────────────────────────────────────────────────
try:
    schema = json.load(open(schema_path))
except Exception as e:
    print("ERROR: cannot parse mcp-schema.json: %s" % e)
    sys.exit(1)

# ── Load config ───────────────────────────────────────────────────────────────
try:
    raw = open(config_path).read()
except Exception as e:
    print("ERROR: cannot read config %s: %s" % (os.path.basename(config_path), e))
    sys.exit(1)

fmt        = schema.get("config_format", "json")
config_key = schema.get("mcp_config_key", "mcpServers")
# bridge_mode: agent wires MCP servers via an external bridge script (e.g. aider),
# not via a native config block — skip native block checks for required_servers /
# server fields, but still run migration/breaking-change checks on the raw file.
bridge_mode = schema.get("mcp_integration_mode", "") == "bridge"

# ── Parse config by format ────────────────────────────────────────────────────
cfg_data  = {}
mcp_block = None   # dict or list

if fmt == "json":
    try:
        cfg_data = json.loads(raw)
    except Exception as e:
        print("ERROR: invalid JSON in %s: %s" % (os.path.basename(config_path), e))
        sys.exit(1)
    mcp_block = cfg_data.get(config_key)
elif fmt in ("yaml", "toml"):
    mcp_block = {}  # populated below via regex

# ── Build present_servers set ─────────────────────────────────────────────────
present_servers = set()

if not bridge_mode:
    if fmt == "json" and isinstance(mcp_block, dict):
        present_servers = set(mcp_block.keys())
    elif fmt == "json" and isinstance(mcp_block, list):
        for entry in mcp_block:
            if isinstance(entry, dict) and "name" in entry:
                present_servers.add(entry["name"])
    elif fmt == "yaml":
        in_block = False
        for line in raw.splitlines():
            if re.match(r'^' + re.escape(config_key) + r'\s*:', line):
                in_block = True
                continue
            if in_block:
                if re.match(r'^\S', line) and not re.match(r'^-', line):
                    in_block = False
                    continue
                m = re.match(r'^  ([a-zA-Z0-9_-]+)\s*:', line)
                if m:
                    present_servers.add(m.group(1))

# ── Check required servers (skip for bridge-mode agents) ──────────────────────
required_servers = schema.get("required_servers", [])
if not bridge_mode:
    for srv in required_servers:
        if srv not in present_servers:
            errors.append("required MCP server '%s' is missing from %s" % (
                srv, config_key))
            diff_items.append({"type": "missing_required_server", "server": srv})

# ── Check server fields (JSON only; skip for bridge-mode) ────────────────────
server_schema    = schema.get("server_schema", {})
required_fields  = server_schema.get("required_fields", [])
args_must_be_arr = server_schema.get("args_must_be_array", True)

if not bridge_mode:
    if fmt == "json" and isinstance(mcp_block, dict):
        for srv_name, srv_cfg in mcp_block.items():
            if not isinstance(srv_cfg, dict):
                errors.append("MCP server '%s': config must be an object, got %s" % (
                    srv_name, type(srv_cfg).__name__))
                continue
            for field in required_fields:
                if field not in srv_cfg:
                    errors.append("MCP server '%s': missing required field '%s'" % (srv_name, field))
                    diff_items.append({"type": "missing_field", "server": srv_name, "field": field})
            if args_must_be_arr and "args" in srv_cfg and not isinstance(srv_cfg["args"], list):
                errors.append("MCP server '%s': 'args' must be an array" % srv_name)

    elif fmt == "json" and isinstance(mcp_block, list):
        for entry in mcp_block:
            if not isinstance(entry, dict):
                continue
            srv_name = entry.get("name", "<unnamed>")
            for field in required_fields:
                if field not in entry:
                    errors.append("MCP server '%s': missing required field '%s'" % (srv_name, field))
                    diff_items.append({"type": "missing_field", "server": srv_name, "field": field})
            if args_must_be_arr and "args" in entry and not isinstance(entry["args"], list):
                errors.append("MCP server '%s': 'args' must be an array" % srv_name)

# ── Check ashlr-plugin entrypoint pattern (skip for bridge-mode) ──────────────
plugin_schema           = schema.get("ashlr_plugin_servers", {})
entrypoint_must_contain = plugin_schema.get("required_arg_contains", [])

if not bridge_mode:
    if fmt == "json" and isinstance(mcp_block, dict):
        for srv_name, srv_cfg in mcp_block.items():
            if not srv_name.startswith("ashlr-") or not isinstance(srv_cfg, dict):
                continue
            args_str = " ".join(str(a) for a in srv_cfg.get("args", []))
            for must_contain in entrypoint_must_contain:
                if must_contain not in args_str:
                    errors.append(
                        "ashlr MCP server '%s': args should contain '%s' "
                        "(entrypoint path may be stale)" % (srv_name, must_contain))
                    diff_items.append({
                        "type": "stale_entrypoint", "server": srv_name, "expected": must_contain
                    })
    elif fmt == "json" and isinstance(mcp_block, list):
        for entry in mcp_block:
            if not isinstance(entry, dict):
                continue
            srv_name = entry.get("name", "")
            if not srv_name.startswith("ashlr-"):
                continue
            args_str = " ".join(str(a) for a in entry.get("args", []))
            for must_contain in entrypoint_must_contain:
                if must_contain not in args_str:
                    errors.append(
                        "ashlr MCP server '%s': args should contain '%s' "
                        "(entrypoint path may be stale)" % (srv_name, must_contain))

# ── Check breaking changes in 3rd-party servers ───────────────────────────────
third_party = schema.get("third_party_servers", {})

for tp_name, tp_schema_entry in third_party.items():
    if tp_name not in present_servers:
        continue
    breaking = tp_schema_entry.get("breaking_changes", [])
    for bc in breaking:
        old_arg = bc.get("old_arg", "")
        new_arg = bc.get("new_arg", "")
        version = bc.get("version", "")
        description = bc.get("description", "")
        if not old_arg:
            continue
        if old_arg in raw:
            msg = "3rd-party server '%s': deprecated arg '%s'" % (tp_name, old_arg)
            if new_arg:
                msg += " — migrate to '%s'" % new_arg
            if version:
                msg += " (since %s)" % version
            if description:
                msg += " — %s" % description
            errors.append(msg)
            diff_items.append({
                "type": "breaking_change", "server": tp_name,
                "old_arg": old_arg, "new_arg": new_arg
            })

# ── Check schema-level migrations (deprecated server names / entrypoints) ─────
# For JSON format, we check actual parsed keys to avoid matching comment strings.
schema_migrations = schema.get("migrations", [])
for mig in schema_migrations:
    old_srv = mig.get("old_server_name", "")
    old_ep  = mig.get("old_entrypoint", "") or mig.get("old_server_path", "")
    old_key = mig.get("old_config_key", "")

    if old_srv and old_srv in present_servers:
        errors.append(
            "deprecated MCP server name '%s' found — "
            "rename to '%s' (%s)" % (
                old_srv,
                mig.get("new_server_name", "?"),
                mig.get("description", "")))
        diff_items.append({
            "type": "deprecated_server_name",
            "old": old_srv, "new": mig.get("new_server_name", "")
        })

    if old_ep and old_ep in raw:
        errors.append(
            "deprecated entrypoint '%s' still referenced — "
            "update to current path (%s)" % (old_ep, mig.get("description", "")))
        diff_items.append({
            "type": "stale_entrypoint_path", "old": old_ep,
            "description": mig.get("description", "")
        })

    if old_key:
        # For JSON: check actual top-level keys in the parsed object (not raw string)
        # to avoid false positives from comment fields.
        old_key_found = False
        if fmt == "json" and isinstance(cfg_data, dict):
            old_key_found = old_key in cfg_data
        elif fmt in ("yaml", "toml"):
            # YAML/TOML: regex match at start of line (not inside comment values)
            old_key_found = bool(re.search(
                r'^' + re.escape(old_key) + r'\s*[=:]', raw, re.MULTILINE))
        if old_key_found:
            errors.append(
                "deprecated MCP config key '%s' — "
                "migrate to '%s' (%s)" % (
                    old_key,
                    mig.get("new_config_key", "?"),
                    mig.get("description", "")))
            diff_items.append({
                "type": "deprecated_config_key",
                "old": old_key, "new": mig.get("new_config_key", "")
            })

# ── Check 3rd-party server env var references ─────────────────────────────────
if fmt == "json" and isinstance(mcp_block, dict):
    for tp_name, tp_schema_entry in third_party.items():
        if tp_name not in mcp_block:
            continue
        srv_cfg = mcp_block[tp_name]
        if not isinstance(srv_cfg, dict):
            continue
        required_env = tp_schema_entry.get("required_env_vars", [])
        combined = json.dumps(srv_cfg.get("args", [])) + " " + json.dumps(srv_cfg.get("env", {}))
        for ev in required_env:
            if ev not in combined:
                warnings.append(
                    "3rd-party server '%s': env var '%s' not referenced in args or env block "
                    "(agent startup may fail if not set)" % (tp_name, ev))

# ── Write diff report ─────────────────────────────────────────────────────────
if diff_report_path and diff_report_path != "/dev/null":
    try:
        report = {
            "timestamp":      _utcnow(),
            "agent":          agent,
            "config_file":    os.path.basename(config_path),
            "schema_version": schema.get("_version", "v1.0"),
            "errors":         errors,
            "warnings":       warnings,
            "diff_items":     diff_items,
            "status":         "clean" if not errors else "errors",
        }
        open(diff_report_path, "w").write(json.dumps(report, indent=2) + "\n")
        print("REPORT: diff report written to %s" % os.path.basename(diff_report_path))
    except Exception as e:
        print("WARN: could not write diff report: %s" % e)

# ── Output ────────────────────────────────────────────────────────────────────
for w in warnings:
    print("WARN: %s" % w)

if errors:
    for e in errors:
        print("ERROR: %s" % e)
    sys.exit(1)

bridge_note = " (bridge-mode: servers provided via aider-mcp-bridge)" if bridge_mode else ""
print("OK: %s MCP config passes schema validation (%d servers, %d required present)%s" % (
    agent,
    len(present_servers),
    len([s for s in required_servers if s in present_servers]),
    bridge_note
))
sys.exit(0)
MCP_PYEOF

  local diff_path_arg="${diff_report_path:-}"
  [ -z "$diff_path_arg" ] && diff_path_arg="/dev/null"

  result="$(python3 "$tmpscript" \
    "$agent" "$config_file" "$schema_file" "$diff_path_arg" 2>&1)"
  rc=$?
  rm -f "$tmpscript"

  local any_error=0
  while IFS= read -r line; do
    case "$line" in
      "OK:"*)      ok   "$label: ${line#OK: }" ;;
      "REPORT:"*)  ok   "$label: ${line#REPORT: }" ;;
      "WARN:"*)    warn "$label: ${line#WARN: }" ;;
      "ERROR:"*)   bad  "$label: ${line#ERROR: }"; any_error=1 ;;
      "")          ;;
      *)           [ -n "$line" ] && warn "$label: $line" ;;
    esac
  done << MCPLINEEOF
$result
MCPLINEEOF

  if [ "$any_error" -gt 0 ] || [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# mcp_validate_all_agents [--diff-report-path <path>] [--diff-report-dir <dir>]
# Validate MCP config for all four agents.
# --diff-report-dir <dir>: write per-agent reports as <dir>/<agent>-mcp-diff.json
mcp_validate_all_agents() {
  local diff_report_dir=""
  local diff_report_path_flag=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --diff-report-dir)  shift; diff_report_dir="$1" ;;
      --diff-report-path) shift; diff_report_path_flag="$1" ;;
      *) warn "mcp_validate_all_agents: unknown option $1" ;;
    esac
    shift
  done

  local agents="ashlrcode aider openhands goose"
  local any_issues=0

  for agent in $agents; do
    local report_path=""
    if [ -n "$diff_report_dir" ]; then
      mkdir -p "$diff_report_dir"
      report_path="${diff_report_dir}/${agent}-mcp-diff.json"
    elif [ -n "$diff_report_path_flag" ]; then
      report_path="$diff_report_path_flag"
    fi

    if [ -n "$report_path" ]; then
      mcp_validate_agent_config "$agent" --diff-report-path "$report_path" || any_issues=1
    else
      mcp_validate_agent_config "$agent" || any_issues=1
    fi
  done

  return "$any_issues"
}

# mcp_generate_diff_report <agent-name> <report-path>
# Write a JSON diff report for a single agent's MCP config without printing
# ok/warn/bad output to stdout.  Returns 0 on success.
mcp_generate_diff_report() {
  local agent="$1"
  local report_path="$2"

  if [ -z "$agent" ] || [ -z "$report_path" ]; then
    bad "mcp_generate_diff_report: usage: mcp_generate_diff_report <agent> <report-path>"
    return 1
  fi

  # Redirect output to /dev/null for the display; the report is written as a side effect.
  local _dummy
  _dummy="$(mcp_validate_agent_config "$agent" --diff-report-path "$report_path" 2>&1)" || true
  [ -f "$report_path" ]
}

# mcp_prelaunch_gate <agent-name> [--abort-on-error] [--diff-report-path <path>]
# Pre-launch validation gate called by start-{agent}.sh scripts before launching
# the agent.  Validates the agent's MCP config and prints a summary.
#
# By default (no --abort-on-error) it warns but does NOT abort, so a misconfigured
# MCP server doesn't block the agent from starting.
# With --abort-on-error it exits 1 if validation fails (used in strict CI mode).
#
# Emits a compact one-line summary: "[mcp-gate] agentname: N servers OK / M errors"
mcp_prelaunch_gate() {
  local agent="$1"
  local abort_on_error=0
  local diff_report_path=""
  shift

  while [ $# -gt 0 ]; do
    case "$1" in
      --abort-on-error)   abort_on_error=1 ;;
      --diff-report-path) shift; diff_report_path="$1" ;;
      *) ;;
    esac
    shift
  done

  local schema_file config_file
  schema_file="$(_sr_mcp_schema "$agent")"
  config_file="$(_sr_mcp_config_file "$agent")"

  # Silently skip if schema not present (feature not yet set up for this agent)
  if [ ! -f "$schema_file" ]; then
    return 0
  fi

  if [ ! -f "$config_file" ]; then
    warn "[mcp-gate] $agent: config file not found — ${config_file#$WORKBENCH/}"
    [ "$abort_on_error" -eq 1 ] && return 1
    return 0
  fi

  # Run validation; capture pass/fail
  local gate_rc=0
  if [ -n "$diff_report_path" ]; then
    mcp_validate_agent_config "$agent" --diff-report-path "$diff_report_path" || gate_rc=$?
  else
    mcp_validate_agent_config "$agent" || gate_rc=$?
  fi

  if [ "$gate_rc" -ne 0 ]; then
    warn "[mcp-gate] $agent: MCP config validation found errors — agent will start but some MCP servers may fail"
    [ "$abort_on_error" -eq 1 ] && return 1
  fi

  return 0
}

# ─── config_registry_check_all ────────────────────────────────────────────────
# Run strict schema registry validation for all four known agents.
# Called by healthcheck.sh to warn when any agent config is out of date.
# Emits ok/warn/bad lines consistent with the healthcheck section format.
config_registry_check_all() {
  local agents="openhands goose aider ashlrcode"
  local any_issues=0

  for agent in $agents; do
    local config_file
    config_file="$(_sr_agent_config "$agent")"

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
      warn "config-schema-registry: $agent — config not found at $config_file"
      any_issues=1
      continue
    fi

    local migrations_file
    migrations_file="$(_sr_agent_migrations "$agent")"
    if [ ! -f "$migrations_file" ]; then
      warn "config-schema-registry: $agent — no config-migrations.json (${migrations_file#$WORKBENCH/})"
      any_issues=1
    fi

    config_validate_strict "$config_file" "$agent" || any_issues=1

    # Also validate MCP config for this agent
    mcp_validate_agent_config "$agent" || any_issues=1
  done

  return "$any_issues"
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

  printf "%sConfig Schema Registry%s (version %s)\n" \
    "$C_BOLD" "$C_RESET" "$SCHEMA_REGISTRY_VERSION"

  # Handle flags
  case "${1:-}" in
    --migrate-all)
      target_ver="${2:-$SCHEMA_REGISTRY_VERSION}"
      printf "\n%sMigrating all agent configs → %s%s\n" "$C_BOLD" "$target_ver" "$C_RESET"
      for _agent in openhands goose aider ashlrcode; do
        _cfg="$(_sr_agent_config "$_agent")"
        config_migrate_auto "$_cfg" --target-version "$target_ver"
      done
      ;;
    --mcp-validate-all)
      printf "\n%sMCP Config Validation (all agents)%s\n" "$C_BOLD" "$C_RESET"
      _diff_dir="${2:-}"
      if [ -n "$_diff_dir" ]; then
        mcp_validate_all_agents --diff-report-dir "$_diff_dir"
      else
        mcp_validate_all_agents
      fi
      ;;
    --mcp-validate)
      _mcp_agent="${2:-}"
      _mcp_report="${3:-}"
      if [ -z "$_mcp_agent" ]; then
        bad "usage: config-schema-registry.sh --mcp-validate <agent> [diff-report-path]"
        exit 1
      fi
      printf "\n%sMCP Config Validation: %s%s\n" "$C_BOLD" "$_mcp_agent" "$C_RESET"
      if [ -n "$_mcp_report" ]; then
        mcp_validate_agent_config "$_mcp_agent" --diff-report-path "$_mcp_report"
      else
        mcp_validate_agent_config "$_mcp_agent"
      fi
      ;;
    *)
      config_registry_check_all
      ;;
  esac

  printf "\n%sResult:%s %s%d passed%s, %s%d warnings%s, %s%d failed%s\n" \
    "$C_BOLD" "$C_RESET" \
    "$C_GREEN" "$PASS" "$C_RESET" \
    "$C_YELLOW" "$WARN" "$C_RESET" \
    "$C_RED" "$FAIL" "$C_RESET"

  [ "$FAIL" -eq 0 ]
fi
