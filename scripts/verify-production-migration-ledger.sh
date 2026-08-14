#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
REPORT_FILE="${REPORT_FILE:-production-migration-ledger-report.txt}"
REMOTE_HISTORY_LEDGER="${REMOTE_HISTORY_LEDGER:-docs/reconciliation/production-migration-ledger-remote-history-2026-08-14.csv}"
CANONICAL_LINEAGE_LEDGER="${CANONICAL_LINEAGE_LEDGER:-docs/reconciliation/canonical-production-lineage-2026-08-14.csv}"

write_failure() {
  local reason="$1"
  shift || true
  {
    echo "Production migration ledger verification"
    echo "Generated at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Status: FAILURE"
    echo "Reason: $reason"
    if (($#)); then
      printf '%s\n' "$@"
    fi
  } | tee "$REPORT_FILE" >&2
  exit 1
}

if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  write_failure "Migration directory not found: $MIGRATIONS_DIR"
fi
if [[ ! -f "$REMOTE_HISTORY_LEDGER" ]]; then
  write_failure "Remote-history reconciliation ledger missing: $REMOTE_HISTORY_LEDGER"
fi
if [[ ! -f "$CANONICAL_LINEAGE_LEDGER" ]]; then
  write_failure "Canonical-lineage reconciliation ledger missing: $CANONICAL_LINEAGE_LEDGER"
fi

local_versions_file="$(mktemp)"
remote_versions_file="$(mktemp)"
pending_versions_file="$(mktemp)"
all_migrations_file="$(mktemp)"
malformed_file="$(mktemp)"
reconciliation_versions_file="$(mktemp)"
canonical_lineage_versions_file="$(mktemp)"
canonical_lineage_status_file="$(mktemp)"
trap 'rm -f "$local_versions_file" "$remote_versions_file" "$pending_versions_file" "$all_migrations_file" "$malformed_file" "$reconciliation_versions_file" "$canonical_lineage_versions_file" "$canonical_lineage_status_file"' EXIT

find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort > "$all_migrations_file"
awk '!/^[0-9]{14}_.+\.sql$/' "$all_migrations_file" > "$malformed_file"
if [[ -s "$malformed_file" ]]; then
  write_failure "Malformed migration filenames detected" "$(cat "$malformed_file")" "Required pattern: YYYYMMDDHHMMSS_description.sql"
fi

sed -nE 's/^([0-9]{14})_.+\.sql$/\1/p' "$all_migrations_file" | sort > "$local_versions_file"
if [[ ! -s "$local_versions_file" ]]; then
  write_failure "No canonical migration files found in $MIGRATIONS_DIR"
fi

duplicate_versions="$(uniq -d "$local_versions_file" || true)"
if [[ -n "$duplicate_versions" ]]; then
  write_failure "Duplicate local migration versions detected" "$duplicate_versions"
fi

tail -n +2 "$REMOTE_HISTORY_LEDGER" | cut -d, -f1 | sed '/^[[:space:]]*$/d' | sort -u > "$reconciliation_versions_file"
if [[ "$(wc -l < "$reconciliation_versions_file" | tr -d ' ')" != "32" ]]; then
  write_failure "Remote-history reconciliation ledger must contain exactly 32 unique versions"
fi

tail -n +2 "$CANONICAL_LINEAGE_LEDGER" | cut -d, -f1 | sed '/^[[:space:]]*$/d' | sort -u > "$canonical_lineage_versions_file"
if [[ "$(wc -l < "$canonical_lineage_versions_file" | tr -d ' ')" != "16" ]]; then
  write_failure "Canonical-lineage reconciliation ledger must contain exactly 16 unique versions"
fi
tail -n +2 "$CANONICAL_LINEAGE_LEDGER" | cut -d, -f1,2 | sort > "$canonical_lineage_status_file"

if ! psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 \
  -c "select version from supabase_migrations.schema_migrations order by version" \
  | sed '/^[[:space:]]*$/d' \
  | sort > "$remote_versions_file"; then
  write_failure "Unable to read production migration ledger"
fi

if ! remote_only="$(comm -13 "$local_versions_file" "$remote_versions_file")"; then
  write_failure "Unable to compare canonical and production migration ledgers"
fi
if ! unaccounted_remote="$(comm -23 <(printf '%s\n' "$remote_only" | sed '/^[[:space:]]*$/d' | sort) "$reconciliation_versions_file")"; then
  write_failure "Unable to compare remote-only versions with reconciliation ledger"
fi
if ! stale_reconciliation="$(comm -23 "$reconciliation_versions_file" "$remote_versions_file")"; then
  write_failure "Unable to compare reconciliation versions with production ledger"
fi
if [[ -n "$unaccounted_remote" || -n "$stale_reconciliation" ]]; then
  write_failure "Migration-ledger reconciliation mismatch" "Unaccounted remote-only versions:" "$unaccounted_remote" "Reconciliation entries absent from remote ledger:" "$stale_reconciliation"
fi

if ! local_missing_versions="$(comm -23 "$local_versions_file" "$remote_versions_file")"; then
  write_failure "Unable to compare canonical and production migration ledgers for local gaps"
fi
max_remote="$(tail -n 1 "$remote_versions_file" 2>/dev/null || true)"
historical_missing_file="$(mktemp)"
append_only_missing_file="$(mktemp)"
trap 'rm -f "$historical_missing_file" "$append_only_missing_file" "$canonical_lineage_status_file.tmp"' EXIT
if [[ -n "$max_remote" ]]; then
  if ! awk -v max="$max_remote" '$1 <= max {print}' <<< "$local_missing_versions" | sort > "$historical_missing_file"; then
    write_failure "Unable to classify historical canonical gaps"
  fi
  if ! awk -v max="$max_remote" '$1 > max {print}' <<< "$local_missing_versions" | sort > "$append_only_missing_file"; then
    write_failure "Unable to classify append-only pending migrations"
  fi
else
  cp "$local_missing_versions" "$append_only_missing_file"
  : > "$historical_missing_file"
fi
if ! unclassified_local="$(comm -23 "$historical_missing_file" "$canonical_lineage_versions_file")"; then
  write_failure "Unable to compare historical canonical gaps with canonical-lineage reconciliation"
fi
if [[ -n "$unclassified_local" ]]; then
  write_failure "Unreconciled canonical-local migration versions detected" "$unclassified_local"
fi
if ! comm -23 "$canonical_lineage_versions_file" "$local_missing_versions" > "$canonical_lineage_status_file.tmp"; then
  write_failure "Unable to verify canonical-lineage entries against local migrations"
fi
if [[ -s "$canonical_lineage_status_file.tmp" ]]; then
  write_failure "Canonical-lineage reconciliation contains versions not missing locally" "$(cat "$canonical_lineage_status_file.tmp")"
fi
pending_versions_file="$append_only_missing_file"
if [[ -n "$max_remote" ]]; then
  while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence; do
    case "$status" in
      represented_remote)
        [[ -z "$replacement_version" ]] || write_failure "Represented canonical version must not declare a replacement" "$canonical_version"
        ;;
      pending_forward)
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || write_failure "Pending canonical version lacks a valid forward replacement" "$canonical_version"
        [[ "$replacement_version" > "$max_remote" ]] || write_failure "Forward replacement must be append-only above latest production version" "$canonical_version" "$replacement_version" "$max_remote"
        compgen -G "$MIGRATIONS_DIR/${replacement_version}_*.sql" >/dev/null || write_failure "Forward replacement migration is missing from Core" "$replacement_version"
        grep -qx "$replacement_version" "$pending_versions_file" || write_failure "Forward replacement must be pending above production" "$canonical_version" "$replacement_version"
        ;;
      *) write_failure "Unknown canonical-lineage reconciliation status" "$canonical_version" "$status" ;;
    esac
  done < <(tail -n +2 "$CANONICAL_LINEAGE_LEDGER")
  non_append_pending="$(awk -v max="$max_remote" '$1 <= max {print}' "$pending_versions_file")"
  if [[ -n "$non_append_pending" ]]; then
    write_failure "Non-append-only local migrations detected; deployment is blocked" "$non_append_pending" "Pending migration versions must be greater than latest production version: $max_remote"
  fi
fi

{
  echo "Production migration ledger verification"
  echo "Generated at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Status: SUCCESS"
  echo "Local migration count: $(wc -l < "$local_versions_file" | tr -d ' ')"
  echo "Remote migration count: $(wc -l < "$remote_versions_file" | tr -d ' ')"
  echo "Remote-history reconciliation count: $(wc -l < "$reconciliation_versions_file" | tr -d ' ')"
  echo "Canonical-lineage reconciliation count: $(wc -l < "$canonical_lineage_versions_file" | tr -d ' ')"
  echo "Latest remote version: ${max_remote:-none}"
  echo "Pending append-only versions:"
  if [[ -s "$pending_versions_file" ]]; then
    cat "$pending_versions_file"
  else
    echo "none"
  fi
} | tee "$REPORT_FILE"
