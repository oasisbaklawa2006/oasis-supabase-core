#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

script="$repo_root/scripts/verify-production-schema-semantic-drift.sh"
public_manifest_sql="$repo_root/scripts/sql/public-schema-semantic-manifest.sql"
platform_manifest_sql="$repo_root/scripts/sql/platform-schema-semantic-manifest.sql"

# Permanent invariants: the production checker may not reintroduce the
# connection-fan-out db-diff path, and the manifests must cover critical
# application-governed semantics that migration-ledger equality alone cannot prove.
if grep -q 'supabase[[:space:]]\+db[[:space:]]\+diff' "$script"; then
  echo 'semantic checker must not use supabase db diff' >&2
  exit 1
fi
if grep -Eq 'postgres(ql)?://[^[:space:]]*:[^[:space:]@]+@127\.0\.0\.1' "$script"; then
  echo 'semantic checker must derive local DB credentials instead of hardcoding them' >&2
  exit 1
fi
for required in \
  "'table'" "'column'" "'constraint'" "'index'" "'view'" \
  "'function'" "'trigger'" "'policy'" "'enum'" "'domain'" \
  "'sequence'" "'relation_grant'" "'routine_grant'" \
  "'publication'" "'publication_table'"; do
  grep -qF "$required" "$public_manifest_sql"
done
for required in \
  "'schema_owner'" "'schema_grant'" "'relation_owner'" "'routine_owner'" \
  "'type_owner'" "'column_grant'" "'default_acl'" "'storage_bucket'" \
  "'storage_policy'" "'storage_relation_grant'"; do
  grep -qF "$required" "$platform_manifest_sql"
done

grep -qF 'BEGIN READ ONLY;' "$public_manifest_sql"
grep -qF 'BEGIN READ ONLY;' "$platform_manifest_sql"

cat > "$test_root/bin/supabase" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_SUPABASE_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$MOCK_SUPABASE_CALL_LOG"
fi
case "${1:-}" in
  start)
    if [[ "${MOCK_SCENARIO:-}" == 'start_fail' ]]; then
      echo 'mock local Supabase startup failure' >&2
      exit 9
    fi
    exit 0
    ;;
  status)
    [[ "${2:-}" == '-o' && "${3:-}" == 'env' ]]
    printf 'DB_URL="%s"\n' "${MOCK_LOCAL_DB_URL:?}"
    exit 0
    ;;
  stop)
    exit 0
    ;;
  *)
    echo "unexpected supabase command: $*" >&2
    exit 97
    ;;
esac
MOCK
chmod +x "$test_root/bin/supabase"

cat > "$test_root/bin/psql" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="${1:-}"
scenario="${MOCK_SCENARIO:-identical}"
echo "$url $*" >> "${MOCK_CALL_LOG:?}"

is_local=0
[[ "$url" == *'127.0.0.1'* ]] && is_local=1
joined=" $* "
is_version_query=0
[[ "$joined" == *'SHOW server_version_num'* ]] && is_version_query=1

if [[ "$is_version_query" -eq 1 ]]; then
  if [[ "$is_local" -eq 0 ]]; then
    case "$scenario" in
      remote_capacity_fail)
        echo 'FATAL: (EMAXCONNSESSION) max clients reached in session mode - max clients are limited to pool_size: 15' >&2
        exit 1
        ;;
      remote_timeout_fail)
        echo 'psql: error: connection to server at "db.example.com" failed: timeout expired' >&2
        exit 1
        ;;
      version_mismatch)
        echo '160000'
        exit 0
        ;;
    esac
  fi
  echo '150000'
  exit 0
fi

# Manifest calls must execute BOTH semantic manifests inside this single psql
# process. Assert both files are present on every manifest capture.
[[ "$joined" == *'public-schema-semantic-manifest.sql'* ]]
[[ "$joined" == *'platform-schema-semantic-manifest.sql'* ]]

common() {
  cat <<'ROWS'
{"kind":"table","key":"public.orders","value":{"relkind":"r","rls_enabled":true}}
{"kind":"column","key":"public.orders.1:id","value":{"type":"uuid","not_null":true}}
{"kind":"policy","key":"public.orders:orders_read","value":{"command":"SELECT","roles":["authenticated"]}}
{"kind":"function","key":"public.order_total(uuid)","value":{"definition":"return canonical"}}
{"kind":"publication_table","key":"supabase_realtime:public.orders","value":{}}
{"kind":"schema_grant","key":"public:authenticated:USAGE","value":{"grantable":false}}
{"kind":"relation_owner","key":"public.orders","value":{"owner":"postgres","relkind":"r"}}
{"kind":"storage_bucket","key":"product-images","value":{"name":"product-images","public":true,"file_size_limit":5242880}}
{"kind":"storage_policy","key":"storage.objects:product_images_read","value":{"command":"SELECT","roles":["public"]}}
ROWS
}

case "$scenario" in
  identical|version_mismatch)
    common
    ;;
  column_drift)
    common | grep -v 'public.orders.1:id'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"column","key":"public.orders.1:id","value":{"type":"uuid","not_null":true}}'
    else
      echo '{"kind":"column","key":"public.orders.1:id","value":{"type":"text","not_null":true}}'
    fi
    ;;
  policy_drift)
    common | grep -v 'public.orders:orders_read'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"policy","key":"public.orders:orders_read","value":{"command":"SELECT","roles":["authenticated"]}}'
    else
      echo '{"kind":"policy","key":"public.orders:orders_read","value":{"command":"ALL","roles":["authenticated"]}}'
    fi
    ;;
  function_drift)
    common | grep -v 'public.order_total(uuid)'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"function","key":"public.order_total(uuid)","value":{"definition":"return canonical"}}'
    else
      echo '{"kind":"function","key":"public.order_total(uuid)","value":{"definition":"return unexpected"}}'
    fi
    ;;
  publication_drift)
    common | grep -v 'supabase_realtime:public.orders'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"publication_table","key":"supabase_realtime:public.orders","value":{}}'
    else
      echo '{"kind":"publication_table","key":"supabase_realtime:public.other_table","value":{}}'
    fi
    ;;
  storage_bucket_drift)
    common | grep -v '"kind":"storage_bucket"'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"storage_bucket","key":"product-images","value":{"name":"product-images","public":true,"file_size_limit":5242880}}'
    else
      echo '{"kind":"storage_bucket","key":"product-images","value":{"name":"product-images","public":true,"file_size_limit":10485760}}'
    fi
    ;;
  storage_policy_drift)
    common | grep -v '"kind":"storage_policy"'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"storage_policy","key":"storage.objects:product_images_read","value":{"command":"SELECT","roles":["public"]}}'
    else
      echo '{"kind":"storage_policy","key":"storage.objects:product_images_read","value":{"command":"ALL","roles":["public"]}}'
    fi
    ;;
  schema_grant_drift)
    common | grep -v '"kind":"schema_grant"'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"schema_grant","key":"public:authenticated:USAGE","value":{"grantable":false}}'
    else
      echo '{"kind":"schema_grant","key":"public:authenticated:CREATE","value":{"grantable":false}}'
    fi
    ;;
  owner_drift)
    common | grep -v '"kind":"relation_owner"'
    if [[ "$is_local" -eq 1 ]]; then
      echo '{"kind":"relation_owner","key":"public.orders","value":{"owner":"postgres","relkind":"r"}}'
    else
      echo '{"kind":"relation_owner","key":"public.orders","value":{"owner":"unexpected_owner","relkind":"r"}}'
    fi
    ;;
  remote_sql_fail)
    if [[ "$is_local" -eq 1 ]]; then
      common
    else
      echo 'ERROR: column pg_catalog.example_does_not_exist does not exist' >&2
      exit 1
    fi
    ;;
  remote_capacity_fail|remote_timeout_fail)
    if [[ "$is_local" -eq 1 ]]; then
      common
    else
      echo 'unexpected remote manifest call after production version connection failure' >&2
      exit 95
    fi
    ;;
  *)
    echo "unexpected MOCK_SCENARIO=$scenario" >&2
    exit 96
    ;;
esac
MOCK
chmod +x "$test_root/bin/psql"

run_case() {
  local scenario="$1"
  local case_root="$test_root/$scenario"
  mkdir -p "$case_root"
  : > "$case_root/calls.txt"
  : > "$case_root/supabase-calls.txt"
  MOCK_SCENARIO="$scenario" \
  MOCK_LOCAL_DB_URL='postgresql://postgres:test@127.0.0.1:54322/postgres' \
  MOCK_CALL_LOG="$case_root/calls.txt" \
  MOCK_SUPABASE_CALL_LOG="$case_root/supabase-calls.txt" \
  SCHEMA_CENSUS_RETRY_SLEEP_BASE_SECONDS=0 \
  SCHEMA_CENSUS_CONNECT_TIMEOUT_SECONDS=1 \
  SUPABASE_DB_URL='postgresql://readonly:test@production.invalid:5432/postgres' \
  PATH="$test_root/bin:$PATH" \
    bash "$script" \
      "$case_root/local.manifest" \
      "$case_root/remote.manifest" \
      "$case_root/diff.txt" \
      "$case_root/start.log"
}

# 1. Identical manifests pass. Calls are strictly sequential: local version,
# local manifest, production version, production manifest.
run_case identical >/dev/null
case_root="$test_root/identical"
test "$(cat "$case_root/diff.txt")" = 'none'
test "$(wc -l < "$case_root/calls.txt" | tr -d ' ')" -eq 4
sed -n '1p' "$case_root/calls.txt" | grep -q '127.0.0.1'
sed -n '2p' "$case_root/calls.txt" | grep -q '127.0.0.1'
sed -n '3p' "$case_root/calls.txt" | grep -q 'production.invalid'
sed -n '4p' "$case_root/calls.txt" | grep -q 'production.invalid'

# 2-9. Structural, authorization, Realtime, storage and ownership differences
# are real drift, never normalized away.
for scenario in \
  column_drift policy_drift function_drift publication_drift \
  storage_bucket_drift storage_policy_drift schema_grant_drift owner_drift; do
  set +e
  run_case "$scenario" >"$test_root/$scenario.out" 2>"$test_root/$scenario.err"
  status=$?
  set -e
  test "$status" -eq 1
  grep -q '^ACTUAL_SCHEMA_DRIFT:' "$test_root/$scenario.err"
  test -s "$test_root/$scenario/diff.txt"
  test "$(wc -l < "$test_root/$scenario/calls.txt" | tr -d ' ')" -eq 4
done

grep -q '"type":"text"' "$test_root/column_drift/diff.txt"
grep -q '"command":"ALL"' "$test_root/policy_drift/diff.txt"
grep -q 'return unexpected' "$test_root/function_drift/diff.txt"
grep -q 'public.other_table' "$test_root/publication_drift/diff.txt"
grep -q '10485760' "$test_root/storage_bucket_drift/diff.txt"
grep -q 'storage.objects:product_images_read' "$test_root/storage_policy_drift/diff.txt"
grep -q 'authenticated:CREATE' "$test_root/schema_grant_drift/diff.txt"
grep -q 'unexpected_owner' "$test_root/owner_drift/diff.txt"

# 10. Production session-cap exhaustion is an infrastructure failure, never
# misreported as ACTUAL_SCHEMA_DRIFT. Retries remain sequential and bounded:
# local version + local manifest + exactly three production version attempts.
set +e
run_case remote_capacity_fail >"$test_root/capacity.out" 2>"$test_root/capacity.err"
status=$?
set -e
test "$status" -eq 2
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE:' "$test_root/capacity.err"
if grep -q '^ACTUAL_SCHEMA_DRIFT:' "$test_root/capacity.err"; then
  echo 'capacity failure was incorrectly classified as schema drift' >&2
  exit 1
fi
test "$(wc -l < "$test_root/remote_capacity_fail/calls.txt" | tr -d ' ')" -eq 5

# 11. libpq timeout-expired failures receive the same bounded transient
# classification rather than hanging indefinitely or being called schema drift.
set +e
run_case remote_timeout_fail >"$test_root/timeout.out" 2>"$test_root/timeout.err"
status=$?
set -e
test "$status" -eq 2
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE:' "$test_root/timeout.err"
grep -q 'bounded connection-capacity retries' "$test_root/timeout.err"
test "$(wc -l < "$test_root/remote_timeout_fail/calls.txt" | tr -d ' ')" -eq 5

# 12. Catalog/SQL failures occur only after PostgreSQL version parity succeeds;
# they fail immediately and are not retried as pool-pressure events.
set +e
run_case remote_sql_fail >"$test_root/sql.out" 2>"$test_root/sql.err"
status=$?
set -e
test "$status" -eq 2
grep -q 'SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE:' "$test_root/sql.err"
test "$(wc -l < "$test_root/remote_sql_fail/calls.txt" | tr -d ' ')" -eq 4

# 13. PostgreSQL major mismatch is infrastructure incompatibility, not drift,
# and stops before a production manifest query is attempted.
set +e
run_case version_mismatch >"$test_root/version.out" 2>"$test_root/version.err"
status=$?
set -e
test "$status" -eq 2
grep -q 'PostgreSQL major-version mismatch' "$test_root/version.err"
test "$(wc -l < "$test_root/version_mismatch/calls.txt" | tr -d ' ')" -eq 3

# 14. Local replay/bootstrap failure is distinct from drift and never opens a
# production connection.
set +e
run_case start_fail >"$test_root/start.out" 2>"$test_root/start.err"
status=$?
set -e
test "$status" -eq 2
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE:' "$test_root/start.err"
test ! -s "$test_root/start_fail/calls.txt"

# 15. Missing production connection evidence is a classified hard failure
# before local Supabase startup or any psql call, with isolated output paths.
missing_root="$test_root/missing-url"
mkdir -p "$missing_root"
: > "$missing_root/calls.txt"
: > "$missing_root/supabase-calls.txt"
set +e
MOCK_SCENARIO=identical \
MOCK_LOCAL_DB_URL='postgresql://postgres:test@127.0.0.1:54322/postgres' \
MOCK_CALL_LOG="$missing_root/calls.txt" \
MOCK_SUPABASE_CALL_LOG="$missing_root/supabase-calls.txt" \
PATH="$test_root/bin:$PATH" \
SUPABASE_DB_URL='' \
  bash "$script" \
    "$missing_root/local.manifest" \
    "$missing_root/remote.manifest" \
    "$missing_root/diff.txt" \
    "$missing_root/start.log" \
    >/dev/null 2>"$missing_root/err"
status=$?
set -e
test "$status" -eq 2
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE:' "$missing_root/err"
test ! -s "$missing_root/calls.txt"
test ! -s "$missing_root/supabase-calls.txt"

# 16. Loopback text in userinfo must never make a remote authority look local.
spoof_root="$test_root/local-url-spoof"
mkdir -p "$spoof_root"
: > "$spoof_root/calls.txt"
: > "$spoof_root/supabase-calls.txt"
set +e
MOCK_SCENARIO=identical \
MOCK_LOCAL_DB_URL='postgresql://user:localhost@db.example.com:5432/postgres' \
MOCK_CALL_LOG="$spoof_root/calls.txt" \
MOCK_SUPABASE_CALL_LOG="$spoof_root/supabase-calls.txt" \
SCHEMA_CENSUS_RETRY_SLEEP_BASE_SECONDS=0 \
SCHEMA_CENSUS_CONNECT_TIMEOUT_SECONDS=1 \
SUPABASE_DB_URL='postgresql://readonly:test@production.invalid:5432/postgres' \
PATH="$test_root/bin:$PATH" \
  bash "$script" \
    "$spoof_root/local.manifest" \
    "$spoof_root/remote.manifest" \
    "$spoof_root/diff.txt" \
    "$spoof_root/start.log" \
    >"$spoof_root/out" 2>"$spoof_root/err"
status=$?
set -e
test "$status" -eq 2
grep -q 'authority host is not loopback-local' "$spoof_root/err"
test ! -s "$spoof_root/calls.txt"

# 17. The production checker must remain read-only by construction.
if grep -Eq 'supabase[[:space:]]+(db[[:space:]]+push|migration[[:space:]]+(up|repair))|psql.*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)' "$script"; then
  echo 'semantic census script contains a production-capable write path' >&2
  exit 1
fi

echo 'verify-production-schema-semantic-drift.sh: all cases passed'
