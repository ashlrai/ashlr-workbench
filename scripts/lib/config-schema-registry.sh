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

  # Handle --migrate-all flag
  if [ "${1:-}" = "--migrate-all" ]; then
    target_ver="${2:-$SCHEMA_REGISTRY_VERSION}"
    printf "\n%sMigrating all agent configs → %s%s\n" "$C_BOLD" "$target_ver" "$C_RESET"
    for _agent in openhands goose aider ashlrcode; do
      _cfg="$(_sr_agent_config "$_agent")"
      config_migrate_auto "$_cfg" --target-version "$target_ver"
    done
  else
    config_registry_check_all
  fi

  printf "\n%sResult:%s %s%d passed%s, %s%d warnings%s, %s%d failed%s\n" \
    "$C_BOLD" "$C_RESET" \
    "$C_GREEN" "$PASS" "$C_RESET" \
    "$C_YELLOW" "$WARN" "$C_RESET" \
    "$C_RED" "$FAIL" "$C_RESET"

  [ "$FAIL" -eq 0 ]
fi
