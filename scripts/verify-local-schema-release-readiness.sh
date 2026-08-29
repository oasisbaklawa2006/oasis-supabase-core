#!/usr/bin/env bash
# Canonical local release-readiness gate shared by PR CI and production
# preflight. It proves the exact checked-out Core commit can rebuild from zero,
# that both semantic manifest queries compile against the real replayed catalog,
# that pgTAP contracts pass, and that database lint is clean. This script never
# accepts or uses a production database URL.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

public_manifest_sql="${PUBLIC_SCHEMA_MANIFEST_SQL:-scripts/sql/public-schema-semantic-manifest.sql}"
platform_manifest_sql="${PLATFORM_SCHEMA_MANIFEST_SQL:-scripts/sql/platform-schema-semantic-manifest.sql}"
start_log="${LOCAL_SCHEMA_START_LOG:-/tmp/supabase-start.log}"
start_sanitized_log="${LOCAL_SCHEMA_START_SANITIZED_LOG:-/tmp/supabase-start-sanitized.log}"
manifest_output="${LOCAL_SCHEMA_MANIFEST_OUTPUT:-/tmp/canonical-schema-semantic.manifest}"
test_log="${LOCAL_SCHEMA_TEST_LOG:-/tmp/supabase-test.log}"
lint_log="${LOCAL_SCHEMA_LINT_LOG:-/tmp/supabase-lint.log}"

fail() {
  echo "LOCAL_SCHEMA_RELEASE_READINESS_FAILURE: $*" >&2
  exit 1
}

command -v supabase >/dev/null 2>&1 || fail 'supabase CLI is not available'
command -v psql >/dev/null 2>&1 || fail 'psql is not available'
[[ -f "$public_manifest_sql" ]] || fail "public semantic manifest SQL is missing: $public_manifest_sql"
[[ -f "$platform_manifest_sql" ]] || fail "platform semantic manifest SQL is missing: $platform_manifest_sql"

sanitize_log() {
  local source="$1" target="$2"
  sed -E \
    -e 's|(postgres(ql)?://[^:[:space:]]+:)[^@[:space:]]+@|\1[REDACTED]@|g' \
    -e 's/(key|token|password|secret|jwt)[^[:space:]]*[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/gi' \
    "$source" > "$target" 2>/dev/null || true
}

assert_loopback_postgres_url() {
  local url="$1" authority hostport host
  [[ "$url" =~ ^postgres(ql)?:// ]] || fail 'local DB_URL is not a PostgreSQL URL'
  authority="${url#*://}"
  authority="${authority%%/*}"
  [[ -n "$authority" ]] || fail 'local DB_URL has no authority'
  hostport="${authority##*@}"
  [[ -n "$hostport" ]] || fail 'local DB_URL has no host'
  if [[ "$hostport" == \[*\]* ]]; then
    host="${hostport#\[}"
    host="${host%%\]*}"
  else
    host="${hostport%%:*}"
  fi
  case "$host" in
    127.0.0.1|localhost|::1) ;;
    *) fail 'local DB_URL authority host is not loopback-local' ;;
  esac
}

local_started=0
cleanup() {
  if [[ "$local_started" -eq 1 ]]; then
    supabase stop --no-backup >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

: > "$start_log"
: > "$start_sanitized_log"
: > "$manifest_output"
: > "$test_log"
: > "$lint_log"

# supabase start performs an initial migration replay while bringing up the
# pinned local stack. A second explicit reset below proves clean replay again
# after all services are available.
if ! supabase start >"$start_log" 2>&1; then
  sanitize_log "$start_log" "$start_sanitized_log"
  cat "$start_sanitized_log" >&2 || true
  fail 'local Supabase stack could not start/replay'
fi
local_started=1
sanitize_log "$start_log" "$start_sanitized_log"

echo 'LOCAL_SCHEMA_RELEASE_READINESS: local stack started.'

if ! supabase db reset --local; then
  fail 'zero-state migration replay failed'
fi

echo 'LOCAL_SCHEMA_RELEASE_READINESS: zero-state replay passed.'

status_env_raw="$(supabase status -o env 2>/dev/null)" || fail 'could not read local Supabase status'
local_db_url="$(printf '%s\n' "$status_env_raw" | awk -F= '$1 == "DB_URL" { sub(/^DB_URL=/, ""); print; exit }')"
local_db_url="${local_db_url#\"}"
local_db_url="${local_db_url%\"}"
[[ -n "$local_db_url" ]] || fail 'Supabase status did not provide DB_URL'
assert_loopback_postgres_url "$local_db_url"
unset status_env_raw

if ! PGCONNECT_TIMEOUT=10 PGAPPNAME='oasis-local-release-readiness' \
  psql "$local_db_url" -X -A -t -q -v ON_ERROR_STOP=1 \
    -f "$public_manifest_sql" \
    -f "$platform_manifest_sql" \
    > "$manifest_output"; then
  unset local_db_url
  fail 'semantic manifest SQL failed against real replayed catalog'
fi
unset local_db_url

[[ -s "$manifest_output" ]] || fail 'semantic manifest execution returned no rows'
grep -Eq '"kind"[[:space:]]*:[[:space:]]*"table"' "$manifest_output" \
  || fail 'semantic manifest is missing public table rows'
grep -Eq '"kind"[[:space:]]*:[[:space:]]*"storage_bucket"' "$manifest_output" \
  || fail 'semantic manifest is missing governed storage bucket rows'

echo "LOCAL_SCHEMA_RELEASE_READINESS: semantic manifests compiled ($(wc -l < "$manifest_output") rows)."

set +e
set -o pipefail
supabase test db 2>&1 | tee "$test_log"
test_status=${PIPESTATUS[0]}
set +o pipefail
set -e
[[ "$test_status" -eq 0 ]] || fail 'database contract tests failed'

echo 'LOCAL_SCHEMA_RELEASE_READINESS: pgTAP contracts passed.'

set +e
set -o pipefail
supabase db lint --local --level warning 2>&1 | tee "$lint_log"
lint_status=${PIPESTATUS[0]}
set +o pipefail
set -e
[[ "$lint_status" -eq 0 ]] || fail 'database lint failed'

echo 'LOCAL_SCHEMA_RELEASE_READINESS: database lint passed.'
echo 'LOCAL_SCHEMA_RELEASE_READINESS: SUCCESS'
