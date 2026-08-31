#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  echo 'SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: SUPABASE_DB_URL is required' >&2
  exit 2
fi

public_manifest_sql="${PUBLIC_SCHEMA_MANIFEST_SQL:-scripts/sql/public-schema-semantic-manifest.sql}"
platform_manifest_sql="${PLATFORM_SCHEMA_MANIFEST_SQL:-scripts/sql/platform-schema-semantic-manifest.sql}"
normalizer="${SCHEMA_SEMANTIC_NORMALIZER:-scripts/normalize-schema-semantic-manifest.py}"
local_manifest="${1:-production-schema-semantic-local.manifest}"
remote_manifest="${2:-production-schema-semantic-remote.manifest}"
diff_file="${3:-production-schema-semantic-diff.txt}"
local_start_log="${4:-production-schema-local-start.log}"
local_start_sanitized="${local_start_log%.log}-sanitized.log"
retry_sleep_base="${SCHEMA_CENSUS_RETRY_SLEEP_BASE_SECONDS:-5}"
connect_timeout="${SCHEMA_CENSUS_CONNECT_TIMEOUT_SECONDS:-10}"
[[ "$retry_sleep_base" =~ ^[0-9]+$ ]] || { echo 'SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: retry sleep base must be a non-negative integer' >&2; exit 2; }
[[ "$connect_timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: connection timeout must be a positive integer' >&2; exit 2; }

fail_infra() {
  echo "SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: $*" >&2
  exit 2
}

[[ -f "$public_manifest_sql" ]] || fail_infra "public semantic manifest SQL is missing: $public_manifest_sql"
[[ -f "$platform_manifest_sql" ]] || fail_infra "platform semantic manifest SQL is missing: $platform_manifest_sql"
[[ -f "$normalizer" ]] || fail_infra "semantic manifest normalizer is missing: $normalizer"
command -v supabase >/dev/null 2>&1 || fail_infra "supabase CLI is not available"
command -v psql >/dev/null 2>&1 || fail_infra "psql is not available"
command -v python3 >/dev/null 2>&1 || fail_infra "python3 is not available"

local_started=0
local_stderr_raw="${local_manifest}.stderr.raw.txt"
local_stderr="${local_manifest}.stderr.txt"
remote_stderr_raw="${remote_manifest}.stderr.raw.txt"
remote_stderr="${remote_manifest}.stderr.txt"
local_version_stderr_raw="${local_manifest}.version.stderr.raw.txt"
remote_version_stderr_raw="${remote_manifest}.version.stderr.raw.txt"
cleanup() {
  rm -f \
    "$local_stderr_raw" "$remote_stderr_raw" \
    "$local_version_stderr_raw" "$remote_version_stderr_raw" \
    "${local_manifest}.raw" "${remote_manifest}.raw"
  if [[ "$local_started" -eq 1 ]]; then
    supabase stop --no-backup >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

sanitize_log() {
  local source="$1" target="$2"
  sed -E \
    -e 's|(postgres(ql)?://[^:[:space:]]+:)[^@[:space:]]+@|\1[REDACTED]@|g' \
    -e 's/(key|token|password|secret|jwt)[^[:space:]]*[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/gi' \
    "$source" > "$target" 2>/dev/null || true
}

assert_loopback_postgres_url() {
  local url="$1" authority hostport host
  [[ "$url" =~ ^postgres(ql)?:// ]] || fail_infra "Supabase local DB_URL is not a PostgreSQL URL"
  authority="${url#*://}"
  authority="${authority%%/*}"
  [[ -n "$authority" ]] || fail_infra "Supabase local DB_URL has no authority"
  hostport="${authority##*@}"
  [[ -n "$hostport" ]] || fail_infra "Supabase local DB_URL has no host"
  if [[ "$hostport" == \[*\]* ]]; then
    host="${hostport#\[}"
    host="${host%%\]*}"
  else
    host="${hostport%%:*}"
  fi
  case "$host" in
    127.0.0.1|localhost|::1) ;;
    *) fail_infra "Supabase local DB_URL authority host is not loopback-local" ;;
  esac
}

is_transient_connection_failure() {
  local file="$1"
  grep -Eqi '(EMAXCONNSESSION|max clients reached|too many clients|remaining connection slots|could not connect|connection[^[:space:]]* (failed|timed out)|connection to server .* failed:.*timeout expired|timeout expired|server closed the connection)' "$file"
}

capture_server_version_num() {
  local db_url="$1" stderr_file="$2"
  PGAPPNAME='oasis-schema-census-version' \
  PGCONNECT_TIMEOUT="$connect_timeout" \
    psql "$db_url" -X -A -t -q -v ON_ERROR_STOP=1 \
      -c 'SHOW server_version_num' 2>"$stderr_file" \
      | tr -d '[:space:]'
}

capture_manifest() {
  local db_url="$1" output="$2" stderr_file="$3"
  if ! PGAPPNAME='oasis-schema-census' \
      PGCONNECT_TIMEOUT="$connect_timeout" \
      psql "$db_url" -X -A -t -q -v ON_ERROR_STOP=1 \
        -f "$public_manifest_sql" \
        -f "$platform_manifest_sql" \
        >"${output}.raw" 2>"$stderr_file"; then
    return 1
  fi
  LC_ALL=C sort -u "${output}.raw" > "$output"
  rm -f "${output}.raw"
}

if ! supabase start >"$local_start_log" 2>&1; then
  sanitize_log "$local_start_log" "$local_start_sanitized"
  cat "$local_start_sanitized" >&2 || true
  fail_infra "canonical local Supabase stack could not start/replay"
fi
local_started=1
sanitize_log "$local_start_log" "$local_start_sanitized"

status_env_raw="$(supabase status -o env 2>/dev/null)" || fail_infra "could not read local Supabase status"
local_db_url="$(printf '%s\n' "$status_env_raw" | awk -F= '$1 == "DB_URL" { sub(/^DB_URL=/, ""); print; exit }')"
local_db_url="${local_db_url#\"}"
local_db_url="${local_db_url%\"}"
[[ -n "$local_db_url" ]] || fail_infra "Supabase status did not provide DB_URL"
assert_loopback_postgres_url "$local_db_url"
unset status_env_raw

local_version_num="$(capture_server_version_num "$local_db_url" "$local_version_stderr_raw")" || {
  sanitize_log "$local_version_stderr_raw" "$local_stderr"
  cat "$local_stderr" >&2 || true
  fail_infra "could not read canonical local PostgreSQL version"
}
[[ "$local_version_num" =~ ^[0-9]+$ ]] || fail_infra "canonical local PostgreSQL server_version_num is malformed"
local_major=$((local_version_num / 10000))
rm -f "$local_version_stderr_raw"

if ! capture_manifest "$local_db_url" "$local_manifest" "$local_stderr_raw"; then
  sanitize_log "$local_stderr_raw" "$local_stderr"
  cat "$local_stderr" >&2 || true
  fail_infra "canonical local schema manifest query failed"
fi
sanitize_log "$local_stderr_raw" "$local_stderr"
rm -f "$local_stderr_raw"
unset local_db_url

remote_version_num=''
remote_version_failure_kind='query'
for attempt in 1 2 3; do
  if remote_version_num="$(capture_server_version_num "$SUPABASE_DB_URL" "$remote_version_stderr_raw")"; then
    rm -f "$remote_version_stderr_raw"
    break
  fi
  sanitize_log "$remote_version_stderr_raw" "$remote_stderr"
  transient=0
  if is_transient_connection_failure "$remote_version_stderr_raw"; then transient=1; fi
  rm -f "$remote_version_stderr_raw"
  if [[ "$transient" -eq 1 && "$attempt" -lt 3 ]]; then
    remote_version_failure_kind='capacity'
    sleep_seconds=$((attempt * retry_sleep_base))
    echo "Transient production version-check connection failure; retrying sequentially after ${sleep_seconds}s (attempt $attempt/3)." >&2
    sleep "$sleep_seconds"
    continue
  fi
  [[ "$transient" -eq 1 ]] && remote_version_failure_kind='capacity'
  remote_version_num=''
  break
done

if [[ -z "$remote_version_num" ]]; then
  cat "$remote_stderr" >&2 || true
  if [[ "$remote_version_failure_kind" == 'capacity' ]]; then
    fail_infra "production PostgreSQL version check exhausted bounded connection-capacity retries"
  fi
  fail_infra "production PostgreSQL version check failed"
fi
[[ "$remote_version_num" =~ ^[0-9]+$ ]] || fail_infra "production PostgreSQL server_version_num is malformed"
remote_major=$((remote_version_num / 10000))
if [[ "$local_major" -ne "$remote_major" ]]; then
  fail_infra "PostgreSQL major-version mismatch: canonical local=$local_major production=$remote_major"
fi

remote_ok=0
remote_failure_kind='query'
for attempt in 1 2 3; do
  if capture_manifest "$SUPABASE_DB_URL" "$remote_manifest" "$remote_stderr_raw"; then
    sanitize_log "$remote_stderr_raw" "$remote_stderr"
    rm -f "$remote_stderr_raw"
    remote_ok=1
    break
  fi
  sanitize_log "$remote_stderr_raw" "$remote_stderr"
  transient=0
  if is_transient_connection_failure "$remote_stderr_raw"; then transient=1; fi
  rm -f "$remote_stderr_raw"
  if [[ "$transient" -eq 1 && "$attempt" -lt 3 ]]; then
    remote_failure_kind='capacity'
    sleep_seconds=$((attempt * retry_sleep_base))
    echo "Transient production census connection failure; retrying sequentially after ${sleep_seconds}s (attempt $attempt/3)." >&2
    sleep "$sleep_seconds"
    continue
  fi
  [[ "$transient" -eq 1 ]] && remote_failure_kind='capacity'
  break
done

if [[ "$remote_ok" -ne 1 ]]; then
  cat "$remote_stderr" >&2 || true
  if [[ "$remote_failure_kind" == 'capacity' ]]; then
    fail_infra "production schema manifest query exhausted bounded connection-capacity retries"
  fi
  fail_infra "production schema manifest query failed"
fi

# Normalize only non-semantic source formatting and non-portable hosted/local
# bootstrap ACL materialization. RLS policies, owners, schema grants, storage,
# executable properties and every structural object remain drift-sensitive.
if ! python3 "$normalizer" "$local_manifest" "$remote_manifest"; then
  fail_infra "semantic manifest normalization failed"
fi

if diff -u "$local_manifest" "$remote_manifest" > "$diff_file"; then
  echo 'none' > "$diff_file"
  echo "OK: production app-governed schema semantic manifest matches canonical Core migration replay (PostgreSQL major $local_major)."
  exit 0
fi

echo 'ACTUAL_SCHEMA_DRIFT: production app-governed schema semantic manifest differs from canonical Core migration replay.' >&2
echo "Diff evidence: $diff_file" >&2
cat "$diff_file" >&2
exit 1
