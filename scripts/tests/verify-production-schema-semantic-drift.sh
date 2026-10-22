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
# Record whether production credentials leaked into the local CLI environment.
if [[ -n "${MOCK_SUPABASE_ENV_LOG:-}" ]]; then
  printf '%s db_url=%s token=%s\n' "${1:-}" "${SUPABASE_DB_URL:+LEAKED}" "${SUPABASE_ACCESS_TOKEN:+LEAKED}" >> "$MOCK_SUPABASE_ENV_LOG"
fi
case "${1:-}" in
  start)
    if [[ -n "${MOCK_START_PLAN:-}" ]]; then
      state="${MOCK_START_STATE:?}"
      n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$state"
      if (( n > 20 )); then
        : > "${MOCK_START_STATE}.runaway"
        exit 125
      fi
      read -r -a plan <<< "$MOCK_START_PLAN"
      idx=$((n - 1))
      (( idx < ${#plan[@]} )) || idx=$(( ${#plan[@]} - 1 ))
      case "${plan[$idx]}" in
        ok) exit 0 ;;
        throttle)
          echo 'failed to pull docker image from all registries: ghcr.io/supabase/edge-runtime:v1.74.2 attempt 1: Error response from daemon: toomanyrequests: retry-after: 405.43us, allowed: 44000/minute' >&2
          exit 1 ;;
        port)
          echo 'failed to bind host port 0.0.0.0:54322/tcp: address already in use' >&2
          exit 1 ;;
        other)
          echo 'mock migration failure: ERROR: syntax error at or near "BOOM" (SQLSTATE 42601)' >&2
          exit 9 ;;
        *) echo "bad MOCK_START_PLAN token ${plan[$idx]}" >&2; exit 98 ;;
      esac
    fi
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

cat > "$test_root/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${MOCK_SLEEP_LOG:-}" ]]; then printf '%s\n' "$*" >> "$MOCK_SLEEP_LOG"; fi
exit 0
MOCK
chmod +x "$test_root/bin/sleep"

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

# ---------------------------------------------------------------------------------------------------------------
# 18-27. Bounded local stack start: registry throttling, port collisions, invalid configuration, cleanup after a
# partial start, and production-credential isolation. The CLI and sleep are mocked, so nothing waits or pulls.
# ---------------------------------------------------------------------------------------------------------------
PROD_SECRET='prod-secret'
PROD_TOKEN='sbp_prod_token_value'

# run_start_case <name> <start plan> <delays|__unset__> [scenario] [helper override]
run_start_case() {
  local name="$1" plan="$2" delays="$3" scenario="${4:-identical}" helper="${5:-}"
  start_dir="$test_root/start-$name"
  mkdir -p "$start_dir"
  : > "$start_dir/calls.txt"; : > "$start_dir/supabase-calls.txt"
  : > "$start_dir/supabase-env.txt"; : > "$start_dir/sleeps.txt"
  rm -f "$start_dir/start-n" "$start_dir/start-n.runaway"
  local -a envargs=(
    MOCK_SCENARIO="$scenario" MOCK_START_PLAN="$plan" MOCK_START_STATE="$start_dir/start-n"
    MOCK_LOCAL_DB_URL='postgresql://postgres:test@127.0.0.1:54322/postgres'
    MOCK_CALL_LOG="$start_dir/calls.txt" MOCK_SUPABASE_CALL_LOG="$start_dir/supabase-calls.txt"
    MOCK_SUPABASE_ENV_LOG="$start_dir/supabase-env.txt" MOCK_SLEEP_LOG="$start_dir/sleeps.txt"
    SCHEMA_CENSUS_RETRY_SLEEP_BASE_SECONDS=0 SCHEMA_CENSUS_CONNECT_TIMEOUT_SECONDS=1
    SUPABASE_DB_URL="postgresql://readonly:${PROD_SECRET}@production.invalid:5432/postgres"
    SUPABASE_ACCESS_TOKEN="$PROD_TOKEN"
    SUPABASE_INTERNAL_IMAGE_REGISTRY=ghcr.io
    PATH="$test_root/bin:$PATH"
  )
  if [[ "$delays" != '__unset__' ]]; then envargs+=(LOCAL_SCHEMA_PULL_RETRY_DELAYS="$delays"); fi
  if [[ -n "$helper" ]]; then envargs+=(LOCAL_SUPABASE_START_HELPER="$helper"); fi
  set +e
  env -u LOCAL_SCHEMA_PULL_RETRY_DELAYS -u LOCAL_SCHEMA_PIN_IMAGE_REGISTRY "${envargs[@]}" \
    timeout 60 bash "$script" \
      "$start_dir/local.manifest" "$start_dir/remote.manifest" "$start_dir/diff.txt" "$start_dir/start.log" \
      >"$start_dir/out" 2>"$start_dir/err"
  start_status=$?
  if [[ -e "$start_dir/start-n.runaway" ]]; then
    echo "start loop was not bounded in case $name" >&2
    exit 1
  fi
}
count_calls() { grep -c "^$2" "$1/supabase-calls.txt" || true; }
count_psql() { wc -l < "$1/calls.txt" | tr -d ' '; }
expect_eq() { # <what> <expected> <actual>
  if [[ "$2" != "$3" ]]; then echo "FAIL $1: expected '$2', got '$3'" >&2; exit 1; fi
}
no_drift_label() { if grep -q '^ACTUAL_SCHEMA_DRIFT:' "$1/err"; then echo "infrastructure failure misclassified as drift in $1" >&2; exit 1; fi; }

# 18. Healthy startup: one start, no pause, one cleanup stop, a full comparison.
run_start_case healthy 'ok' '__unset__'
expect_eq 'healthy status' 0 "$start_status"
expect_eq 'healthy starts' 1 "$(count_calls "$start_dir" start)"
expect_eq 'healthy sleeps' '' "$(paste -sd' ' "$start_dir/sleeps.txt")"
expect_eq 'healthy stops' 1 "$(count_calls "$start_dir" stop)"
expect_eq 'healthy psql calls' 4 "$(count_psql "$start_dir")"
grep -q '^OK: production app-governed schema semantic manifest matches' "$start_dir/out"

# 19. Registry throttling is retried with bounded pauses and then succeeds. Each retry cleans the half-started stack.
run_start_case throttle-recovers 'throttle throttle ok' '1 2'
expect_eq 'throttle-recovers status' 0 "$start_status"
expect_eq 'throttle-recovers starts' 3 "$(count_calls "$start_dir" start)"
expect_eq 'throttle-recovers sleeps' '1 2' "$(paste -sd' ' "$start_dir/sleeps.txt")"
expect_eq 'throttle-recovers stops' 3 "$(count_calls "$start_dir" stop)"
expect_eq 'throttle-recovers psql calls' 4 "$(count_psql "$start_dir")"

# 20. Persistent throttling fails closed as infrastructure: bounded attempts, no census, never drift, and the
# partially started stack is stopped on exit.
run_start_case throttle-persistent 'throttle' '1 2'
expect_eq 'throttle-persistent status' 2 "$start_status"
expect_eq 'throttle-persistent starts' 3 "$(count_calls "$start_dir" start)"
expect_eq 'throttle-persistent sleeps' '1 2' "$(paste -sd' ' "$start_dir/sleeps.txt")"
expect_eq 'throttle-persistent psql calls' 0 "$(count_psql "$start_dir")"
expect_eq 'throttle-persistent status calls' 0 "$(count_calls "$start_dir" status)"
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: canonical local Supabase stack could not start: container registry throttling persisted after 2 bounded retries' "$start_dir/err"
no_drift_label "$start_dir"
case "$(tail -n 1 "$start_dir/supabase-calls.txt")" in stop*) ;; *) echo 'partial stack was not stopped after failed startup' >&2; exit 1 ;; esac
# An empty schedule disables the throttling retry entirely: one attempt, no pause.
run_start_case throttle-disabled 'throttle' ''
expect_eq 'throttle-disabled status' 2 "$start_status"
expect_eq 'throttle-disabled starts' 1 "$(count_calls "$start_dir" start)"
expect_eq 'throttle-disabled sleeps' '' "$(paste -sd' ' "$start_dir/sleeps.txt")"

# 21. A genuine local replay/migration failure is never retried, even when it follows a throttled attempt.
run_start_case genuine-failure 'other' '1 2'
expect_eq 'genuine-failure status' 2 "$start_status"
expect_eq 'genuine-failure starts' 1 "$(count_calls "$start_dir" start)"
expect_eq 'genuine-failure sleeps' '' "$(paste -sd' ' "$start_dir/sleeps.txt")"
expect_eq 'genuine-failure psql calls' 0 "$(count_psql "$start_dir")"
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: canonical local Supabase stack could not start/replay' "$start_dir/err"
no_drift_label "$start_dir"
run_start_case throttle-then-genuine 'throttle other' '1 2'
expect_eq 'throttle-then-genuine status' 2 "$start_status"
expect_eq 'throttle-then-genuine starts' 2 "$(count_calls "$start_dir" start)"
expect_eq 'throttle-then-genuine sleeps' '1' "$(paste -sd' ' "$start_dir/sleeps.txt")"

# 22. Host-port collisions stay bounded to a single retry with no registry pause.
run_start_case port-recovers 'port ok' '1 2'
expect_eq 'port-recovers status' 0 "$start_status"
expect_eq 'port-recovers starts' 2 "$(count_calls "$start_dir" start)"
expect_eq 'port-recovers sleeps' '' "$(paste -sd' ' "$start_dir/sleeps.txt")"
run_start_case port-persistent 'port' '1 2'
expect_eq 'port-persistent status' 2 "$start_status"
expect_eq 'port-persistent starts' 2 "$(count_calls "$start_dir" start)"
grep -q 'after one port-collision retry' "$start_dir/err"
no_drift_label "$start_dir"

# 23. Invalid retry configuration fails before any start, any stop and any database connection. Leading zeros
# cannot slip past the 300 s cap through octal evaluation, and a stack this run never started is never stopped.
for bad in 'abc' '301' '0400' '-1' '1 2 3 4 5 6' '1.5'; do
  run_start_case "bad-delay-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '_')" 'ok' "$bad"
  expect_eq "bad delay '$bad' status" 2 "$start_status"
  expect_eq "bad delay '$bad' starts" 0 "$(count_calls "$start_dir" start)"
  expect_eq "bad delay '$bad' stops (no unrelated stack destroyed)" 0 "$(count_calls "$start_dir" stop)"
  expect_eq "bad delay '$bad' psql calls" 0 "$(count_psql "$start_dir")"
  grep -q 'LOCAL_SCHEMA_PULL_RETRY_DELAYS' "$start_dir/err"
  no_drift_label "$start_dir"
done

# 24. A missing helper is an infrastructure failure (exit 2). An unguarded `source` would exit 1, the code reserved
# for ACTUAL_SCHEMA_DRIFT.
run_start_case helper-missing 'ok' '__unset__' identical "$test_root/does-not-exist.sh"
expect_eq 'helper-missing status' 2 "$start_status"
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: bounded local Supabase start helper is missing' "$start_dir/err"
expect_eq 'helper-missing supabase calls' 0 "$(wc -l < "$start_dir/supabase-calls.txt" | tr -d ' ')"
expect_eq 'helper-missing psql calls' 0 "$(count_psql "$start_dir")"
no_drift_label "$start_dir"

# 25. Production credentials never reach the local stack: no supabase invocation (start, status, stop) sees them in
# its environment or arguments, they appear in no output, and production is only ever queried read-only.
for case_name in healthy throttle-recovers throttle-persistent genuine-failure; do
  d="$test_root/start-$case_name"
  if grep -q 'LEAKED' "$d/supabase-env.txt"; then echo "production credentials leaked into the supabase CLI environment in $case_name" >&2; exit 1; fi
  if grep -q -e 'production.invalid' -e "$PROD_SECRET" -e "$PROD_TOKEN" "$d/supabase-calls.txt" "$d/out" "$d/err"; then
    echo "production credential or host appeared in CLI arguments or output in $case_name" >&2; exit 1
  fi
done
run_start_case credentials-check 'ok' '__unset__'
grep -q '^start db_url= token=$' "$start_dir/supabase-env.txt"
grep -q '^stop db_url= token=$' "$start_dir/supabase-env.txt"
grep -q '^status db_url= token=$' "$start_dir/supabase-env.txt"
while IFS= read -r line; do
  if [[ "$line" == *'production.invalid'* ]]; then
    [[ "$line" == *'SHOW server_version_num'* || ( "$line" == *'public-schema-semantic-manifest.sql'* && "$line" == *'platform-schema-semantic-manifest.sql'* ) ]]
    if printf '%s' "$line" | grep -Eqi '(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)[[:space:]]'; then
      echo 'production connection carried a write-capable statement' >&2; exit 1
    fi
  else
    [[ "$line" == *'127.0.0.1'* ]]
  fi
done < "$start_dir/calls.txt"

# 26. A real difference is still ACTUAL_SCHEMA_DRIFT (exit 1) after a throttled-then-recovered start: retries must
# never mask or convert a genuine finding.
run_start_case drift-after-throttle 'throttle ok' '1 2' column_drift
expect_eq 'drift-after-throttle status' 1 "$start_status"
grep -q '^ACTUAL_SCHEMA_DRIFT:' "$start_dir/err"
grep -q '"type":"text"' "$start_dir/diff.txt"
expect_eq 'drift-after-throttle starts' 2 "$(count_calls "$start_dir" start)"

# 27. Missing production credentials still fail closed before any start, stop or database call (case 15 above),
# and the unset production variables do not leak back into later children.
set +e
MOCK_SCENARIO=identical MOCK_START_PLAN=ok MOCK_START_STATE="$test_root/no-url-n" \
MOCK_LOCAL_DB_URL='postgresql://postgres:test@127.0.0.1:54322/postgres' \
MOCK_CALL_LOG="$test_root/no-url-psql.txt" MOCK_SUPABASE_CALL_LOG="$test_root/no-url-supabase.txt" \
PATH="$test_root/bin:$PATH" SUPABASE_DB_URL='' \
  bash "$script" "$test_root/nu.local" "$test_root/nu.remote" "$test_root/nu.diff" "$test_root/nu.start.log" >/dev/null 2>"$test_root/no-url.err"
no_url_status=$?
set -e
expect_eq 'missing production URL status' 2 "$no_url_status"
grep -q '^SCHEMA_CENSUS_INFRASTRUCTURE_FAILURE: SUPABASE_DB_URL is required' "$test_root/no-url.err"
test ! -e "$test_root/no-url-supabase.txt" || test ! -s "$test_root/no-url-supabase.txt"

# 17. The production checker must remain read-only by construction.
if grep -Eq 'supabase[[:space:]]+(db[[:space:]]+push|migration[[:space:]]+(up|repair))|psql.*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)' "$script"; then
  echo 'semantic census script contains a production-capable write path' >&2
  exit 1
fi

echo 'verify-production-schema-semantic-drift.sh: all cases passed'
