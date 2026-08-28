#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"

out_file="${1:-production-schema-semantic-diff.sql}"
err_file="${2:-production-schema-semantic-diff.stderr.txt}"
raw_file="${out_file}.raw"

cleanup() {
  rm -f "$raw_file"
}
trap cleanup EXIT

# `supabase db diff --db-url` is read-only against the target database. It
# creates a disposable shadow database from the canonical Core migrations and
# compares that migration-derived schema to production. No -f flag is used, so
# it cannot create or mutate a migration file. No linked reset/push/repair path
# is involved.
#
# We intentionally scope the hard fail to the application-owned `public`
# schema. Supabase documents known db-diff limitations for publications,
# storage bucket data and some view attributes; those are governed separately
# rather than being silently ignored here.
set +e
supabase db diff \
  --db-url "$SUPABASE_DB_URL" \
  --schema public \
  --use-pg-schema \
  >"$raw_file" 2>"$err_file"
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  cat "$err_file" >&2 || true
  echo "SEMANTIC SCHEMA DRIFT CHECK FAILED: supabase db diff exited $status" >&2
  exit "$status"
fi

# Ignore whitespace-only output. Any actual SQL emitted by db diff is an
# unexplained semantic difference between a zero-state replay of Core and the
# production public schema and therefore fails closed.
sed -e '/^[[:space:]]*$/d' "$raw_file" > "$out_file"

if [[ -s "$out_file" ]]; then
  echo 'ACTUAL_SCHEMA_DRIFT: production public schema differs from canonical Core migration replay.' >&2
  echo 'Diff follows:' >&2
  cat "$out_file" >&2
  exit 1
fi

echo 'none' > "$out_file"
echo 'OK: production public schema is semantically identical to canonical Core migration replay.'
