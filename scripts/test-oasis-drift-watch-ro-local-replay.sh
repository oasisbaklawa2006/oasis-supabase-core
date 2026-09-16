#!/usr/bin/env bash
# Prove oasis_drift_watch_ro can execute Drift Watch manifest and ledger queries
# against the canonical local replay catalog without public schema USAGE.
set -euo pipefail

db_url="${DB_URL:-${SUPABASE_DB_URL:-}}"
public_manifest_sql="${PUBLIC_SCHEMA_MANIFEST_SQL:-scripts/sql/public-schema-semantic-manifest.sql}"
platform_manifest_sql="${PLATFORM_SCHEMA_MANIFEST_SQL:-scripts/sql/platform-schema-semantic-manifest.sql}"

fail() {
  echo "OASIS DRIFT WATCH LOCAL REPLAY TEST FAILED: $*" >&2
  exit 1
}

[[ -n "$db_url" ]] || fail 'DB_URL or SUPABASE_DB_URL is required'
[[ -f "$public_manifest_sql" ]] || fail "missing $public_manifest_sql"
[[ -f "$platform_manifest_sql" ]] || fail "missing $platform_manifest_sql"
command -v psql >/dev/null 2>&1 || fail 'psql is required'

role_probe="$(PGCONNECT_TIMEOUT=10 psql "$db_url" -X -A -t -v ON_ERROR_STOP=1 -c "
select exists (select 1 from pg_roles where rolname = 'oasis_drift_watch_ro');
")"
[[ "$role_probe" == 't' ]] || fail 'oasis_drift_watch_ro is missing from replayed catalog'

manifest_output="$(mktemp)"
ledger_output="$(mktemp)"
trap 'rm -f "$manifest_output" "$ledger_output"' EXIT

if ! PGCONNECT_TIMEOUT=10 PGOPTIONS='-c role=oasis_drift_watch_ro' \
  psql "$db_url" -X -A -t -q -v ON_ERROR_STOP=1 \
    -f "$public_manifest_sql" \
    -f "$platform_manifest_sql" \
    >"$manifest_output"; then
  fail 'semantic manifest SQL failed as oasis_drift_watch_ro'
fi
[[ -s "$manifest_output" ]] || fail 'semantic manifest returned no rows as oasis_drift_watch_ro'
grep -Eq '"kind"[[:space:]]*:[[:space:]]*"table"' "$manifest_output" \
  || fail 'semantic manifest missing public table metadata rows'
grep -Eq '"kind"[[:space:]]*:[[:space:]]*"storage_bucket"' "$manifest_output" \
  || fail 'semantic manifest missing storage bucket rows'

if ! PGCONNECT_TIMEOUT=10 PGOPTIONS='-c role=oasis_drift_watch_ro' \
  psql "$db_url" -X -A -t -q -v ON_ERROR_STOP=1 \
    -c "select version from supabase_migrations.schema_migrations order by version" \
    >"$ledger_output"; then
  fail 'migration ledger query failed as oasis_drift_watch_ro'
fi
[[ -s "$ledger_output" ]] || fail 'migration ledger query returned no rows as oasis_drift_watch_ro'

if ! SUPABASE_DB_URL="$db_url" PGOPTIONS='-c role=oasis_drift_watch_ro' \
  bash scripts/certify-production-drift-watch-credential.sh >/dev/null; then
  fail 'drift-watch credential certification failed against local replay role session'
fi

echo "OASIS DRIFT WATCH LOCAL REPLAY TEST: semantic rows=$(wc -l < "$manifest_output" | tr -d ' ') ledger_rows=$(wc -l < "$ledger_output" | tr -d ' ')"
