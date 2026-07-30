#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
REPORT_FILE="${REPORT_FILE:-production-migration-ledger-report.txt}"

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

local_versions_file="$(mktemp)"
remote_versions_file="$(mktemp)"
pending_versions_file="$(mktemp)"
all_migrations_file="$(mktemp)"
malformed_file="$(mktemp)"
trap 'rm -f "$local_versions_file" "$remote_versions_file" "$pending_versions_file" "$all_migrations_file" "$malformed_file"' EXIT

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

if ! psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 \
  -c "select version from supabase_migrations.schema_migrations order by version" \
  | sed '/^[[:space:]]*$/d' \
  | sort > "$remote_versions_file"; then
  write_failure "Unable to read production migration ledger"
fi

remote_only="$(comm -13 "$local_versions_file" "$remote_versions_file" || true)"
if [[ -n "$remote_only" ]]; then
  write_failure "Remote-only migration versions detected; deployment is blocked" "$remote_only" "Capture or reconcile these versions in Core; never repair history automatically."
fi

comm -23 "$local_versions_file" "$remote_versions_file" > "$pending_versions_file"
max_remote="$(tail -n 1 "$remote_versions_file" 2>/dev/null || true)"
if [[ -n "$max_remote" ]]; then
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
  echo "Latest remote version: ${max_remote:-none}"
  echo "Pending append-only versions:"
  if [[ -s "$pending_versions_file" ]]; then
    cat "$pending_versions_file"
  else
    echo "none"
  fi
} | tee "$REPORT_FILE"
