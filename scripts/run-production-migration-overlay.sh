#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

REMOTE_HISTORY_LEDGER="${REMOTE_HISTORY_LEDGER:-docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv}"
CANONICAL_LINEAGE_LEDGER="${CANONICAL_LINEAGE_LEDGER:-docs/reconciliation/canonical-production-lineage-2026-08-18.csv}"
PREVIEW_MIGRATION_LEDGER_COMPAT_FILE="${PREVIEW_MIGRATION_LEDGER_COMPAT_FILE:-supabase/preview-migration-ledger-compat.txt}"

fail() {
  echo "PRODUCTION MIGRATION OVERLAY FAILED: $*" >&2
  exit 1
}

mode="${1:-}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"
case "$mode" in
  --dry-run) push_flags=(--db-url "$SUPABASE_DB_URL" --dry-run) ;;
  --apply) push_flags=(--db-url "$SUPABASE_DB_URL") ;;
  *) fail "usage: $0 --dry-run|--apply" ;;
esac

[[ -f "$REMOTE_HISTORY_LEDGER" ]] || fail "remote-history ledger missing: $REMOTE_HISTORY_LEDGER"
[[ -f "$CANONICAL_LINEAGE_LEDGER" ]] || fail "canonical-lineage ledger missing: $CANONICAL_LINEAGE_LEDGER"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
[[ -d "$MIGRATIONS_DIR" ]] || fail "migration directory missing: $MIGRATIONS_DIR"
link_state='supabase/.temp/project-ref'
[[ -f "$link_state" ]] || fail "linked project state is missing: $link_state"

overlay_root="$(mktemp -d)"
cleanup() {
  rm -rf "$overlay_root"
}
trap cleanup EXIT

mkdir -p "$overlay_root/supabase/.temp"
cp supabase/config.toml "$overlay_root/supabase/config.toml"
cp "$link_state" "$overlay_root/supabase/.temp/project-ref"
cp -a "$MIGRATIONS_DIR" "$overlay_root/supabase/migrations"

overlay_migrations="$overlay_root/supabase/migrations"
remote_stub_count=0
while IFS=, read -r version name classification evidence || [[ -n "${version:-}" ]]; do
  [[ "$version" == version ]] && continue
  version="${version//$'\r'/}"
  name="${name//$'\r'/}"
  classification="${classification//$'\r'/}"
  evidence="${evidence//$'\r'/}"
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" == 33 ]] || fail "remote-history ledger must contain exactly 33 rows; found $remote_stub_count"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  canonical_version="${canonical_version//$'\r'/}"
  status="${status//$'\r'/}"
  replacement_version="${replacement_version//$'\r'/}"
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" == 13 ]] || fail "canonical-lineage ledger must contain exactly 13 represented_remote rows; found $represented_count"
[[ "$pending_count" == 13 ]] || fail "canonical-lineage ledger must contain exactly 13 pending_forward rows; found $pending_count"

if [[ "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE" == '..' || "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE" == ../* || "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE" == */../* || "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE" == */.. ]]; then
  fail "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE must be repository-relative without '..': $PREVIEW_MIGRATION_LEDGER_COMPAT_FILE"
fi
if [[ "$MIGRATIONS_DIR" = 'supabase/migrations' && "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE" = /* ]]; then
  fail "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE must be repository-relative without '..': $PREVIEW_MIGRATION_LEDGER_COMPAT_FILE"
fi

validate_preview_compat_stub_content() {
  local content="$1" path="$2" version="$3"
  local executable_sql

  if ! grep -Fq 'Preview ledger compatibility' <<<"$content"; then
    fail "preview ledger compatibility migration $path version $version must contain 'Preview ledger compatibility' marker comment"
  fi

  executable_sql="$(printf '%s\n' "$content" \
    | sed -E 's/--.*$//' \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [[ "$executable_sql" != 'select 1;' ]]; then
    fail "preview ledger compatibility migration $path version $version must be an exact no-op stub (comments plus select 1;): $executable_sql"
  fi
}

preview_compat_hidden_count=0
preview_compat_preserved_remote_count=0
declare -A preview_ledger_compat_versions=()
if [[ -f "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE" ]]; then
  while IFS= read -r compat_line || [[ -n "$compat_line" ]]; do
    [[ -z "$compat_line" || "$compat_line" =~ ^[[:space:]]*# ]] && continue
    compat_version="${compat_line%%#*}"
    compat_version="$(printf '%s' "$compat_version" | tr -d '[:space:]')"
    [[ -z "$compat_version" ]] && continue
    if [[ ! "$compat_version" =~ ^[0-9]{14}$ ]]; then
      fail "preview ledger compatibility entry must be exactly 14 digits: $compat_line"
    fi
    if [[ -n "${preview_ledger_compat_versions[$compat_version]:-}" ]]; then
      fail "duplicate preview ledger compatibility version: $compat_version"
    fi
    preview_ledger_compat_versions["$compat_version"]=1
  done < "$PREVIEW_MIGRATION_LEDGER_COMPAT_FILE"
fi

# Validate every inventory-listed compatibility migration before consulting remote state.
# Only exact inert stubs may participate in this compatibility mechanism.
for compat_version in "${!preview_ledger_compat_versions[@]}"; do
  matches=("$overlay_migrations/${compat_version}_"*.sql)
  [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "preview ledger compatibility version lacks a matching migration file: $compat_version"
  validate_preview_compat_stub_content "$(<"${matches[0]}")" "${matches[0]}" "$compat_version"
done

# The production ledger is authoritative for whether a validated compatibility row must
# remain visible to Supabase CLI. Hiding an already-applied remote version makes the CLI
# report "Remote migration versions not found in local migrations directory" and can
# tempt unsafe history repair. Fail closed if remote-applied status cannot be determined.
declare -A remote_applied_versions=()
if (( ${#preview_ledger_compat_versions[@]} > 0 )); then
  remote_migration_list=''
  if ! remote_migration_list="$(supabase migration list --db-url "$SUPABASE_DB_URL" 2>&1)"; then
    fail "unable to determine remote-applied migration versions from production ledger"
  fi

  while IFS='|' read -r _local remote _rest; do
    remote="$(printf '%s' "${remote:-}" | tr -d '`[:space:]')"
    if [[ "$remote" =~ ^[0-9]{14}$ ]]; then
      remote_applied_versions["$remote"]=1
    fi
  done < <(printf '%s\n' "$remote_migration_list" | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g')

  if (( ${#remote_applied_versions[@]} == 0 )); then
    fail "unable to determine remote-applied migration versions from production ledger"
  fi
fi

for compat_version in "${!preview_ledger_compat_versions[@]}"; do
  matches=("$overlay_migrations/${compat_version}_"*.sql)
  if [[ -n "${remote_applied_versions[$compat_version]:-}" ]]; then
    preview_compat_preserved_remote_count=$((preview_compat_preserved_remote_count + 1))
    continue
  fi

  rm -- "${matches[0]}"
  preview_compat_hidden_count=$((preview_compat_hidden_count + 1))
done

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Preserved remote-applied preview ledger compatibility stubs: $preview_compat_preserved_remote_count"
echo "Hidden preview-only ledger compatibility stubs: $preview_compat_hidden_count"
echo "Pending forward replacements: $pending_count"

SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
