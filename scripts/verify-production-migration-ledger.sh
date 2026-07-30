#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
REPORT_FILE="${REPORT_FILE:-production-migration-ledger-report.txt}"

if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "Migration directory not found: $MIGRATIONS_DIR" >&2
  exit 1
fi

local_versions_file="$(mktemp)"
remote_versions_file="$(mktemp)"
pending_versions_file="$(mktemp)"
trap 'rm -f "$local_versions_file" "$remote_versions_file" "$pending_versions_file"' EXIT

find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' \
  | sed -nE 's/^([0-9]{14})_.+\.sql$/\1/p' \
  | sort > "$local_versions_file"

if [[ ! -s "$local_versions_file" ]]; then
  echo "No canonical migration files found in $MIGRATIONS_DIR" >&2
  exit 1
fi

duplicate_versions="$(uniq -d "$local_versions_file" || true)"
if [[ -n "$duplicate_versions" ]]; then
  echo "Duplicate local migration versions detected:" >&2
  echo "$duplicate_versions" >&2
  exit 1
fi

psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 \
  -c "select version from supabase_migrations.schema_migrations order by version" \
  | sed '/^[[:space:]]*$/d' \
  | sort > "$remote_versions_file"

remote_only="$(comm -13 "$local_versions_file" "$remote_versions_file" || true)"
if [[ -n "$remote_only" ]]; then
  echo "REMOTE-ONLY MIGRATION VERSIONS DETECTED. Deployment is blocked." >&2
  echo "$remote_only" >&2
  echo "Capture or reconcile these versions in Core; never repair history automatically." >&2
  exit 1
fi

comm -23 "$local_versions_file" "$remote_versions_file" > "$pending_versions_file"

max_remote="$(tail -n 1 "$remote_versions_file" 2>/dev/null || true)"
if [[ -n "$max_remote" ]]; then
  non_append_pending="$(awk -v max="$max_remote" '$1 <= max {print}' "$pending_versions_file")"
  if [[ -n "$non_append_pending" ]]; then
    echo "NON-APPEND-ONLY LOCAL MIGRATIONS DETECTED. Deployment is blocked." >&2
    echo "$non_append_pending" >&2
    echo "Pending migration versions must be greater than the latest production version: $max_remote" >&2
    exit 1
  fi
fi

{
  echo "Production migration ledger verification"
  echo "Generated at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
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
