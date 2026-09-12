#!/usr/bin/env bash
# Two-session concurrency proof for Issue #285 Trace reprint atomic allocation.
#
# Proves public.trace_allocate_reprint_count_v1's per-(ref_type, ref_id)
# advisory lock genuinely serializes two OVERLAPPING database sessions racing
# distinct idempotency keys for the same label reference:
#
#   1. Session A allocates count 1, then holds its transaction open.
#   2. Session B starts while A is still open and must block on the ref lock.
#   3. We assert B is genuinely blocked via pg_locks before A commits.
#   4. A commits; B proceeds and receives count 2 (above threshold, blocked).
#   5. Final state: exactly two durable allocations with distinct counts.
#
# Mirrors scripts/test-catalogue-source-staging-two-session-race.sh.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "TRACE_REPRINT_TWO_SESSION_RACE_FAILURE: $*" >&2
  exit 1
}

percent_decode_uri_component() {
  local value="$1" out='' prefix hex rest decoded
  while [[ "$value" == *%* ]]; do
    prefix="${value%%\%*}"
    out+="$prefix"
    value="${value#*%}"
    [[ "$value" =~ ^([0-9A-Fa-f]{2})(.*)$ ]] \
      || fail 'DB_URL contains invalid percent-encoding'
    hex="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    printf -v decoded '%b' "\\x${hex}"
    [[ -n "$decoded" ]] || fail 'DB_URL contains a decoded NUL byte'
    out+="$decoded"
    value="$rest"
  done
  printf '%s%s' "$out" "$value"
}

is_loopback_host() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  host="${host#[}"
  host="${host%]}"
  case "$host" in
    localhost|::1) return 0 ;;
    /*) return 0 ;;
  esac
  [[ "$host" =~ ^127(\.[0-9]{1,3}){3}$ ]] && return 0
  return 1
}

is_loopback_hostaddr() {
  local addr="$1"
  [[ -n "$addr" ]] || return 1
  case "$addr" in
    ::1|0:0:0:0:0:0:0:1) return 0 ;;
  esac
  [[ "$addr" =~ ^127(\.[0-9]{1,3}){3}$ ]] && return 0
  return 1
}

assert_loopback_host_value() {
  local raw_value="$1" source="$2" decoded entry
  local -a entries
  decoded="$(percent_decode_uri_component "$raw_value")"
  IFS=',' read -r -a entries <<< "$decoded"
  [[ "${#entries[@]}" -gt 0 ]] || fail "DB_URL ${source} is empty"
  for entry in "${entries[@]}"; do
    is_loopback_host "$entry" \
      || fail "DB_URL ${source} host '${entry}' is not loopback-local; this harness mutates fixtures and DDL"
  done
}

assert_loopback_hostaddr_value() {
  local raw_value="$1" source="$2" decoded entry
  local -a entries
  decoded="$(percent_decode_uri_component "$raw_value")"
  IFS=',' read -r -a entries <<< "$decoded"
  [[ "${#entries[@]}" -gt 0 ]] || fail "DB_URL ${source} is empty"
  for entry in "${entries[@]}"; do
    is_loopback_hostaddr "$entry" \
      || fail "DB_URL ${source} hostaddr '${entry}' is not loopback-local; this harness mutates fixtures and DDL"
  done
}

assert_loopback_postgres_url() {
  local url="$1" authority hostspec hostport host query pair key value decoded_key
  local -a query_pairs hostports
  [[ "$url" =~ ^postgres(ql)?:// ]] || fail 'DB_URL is not a PostgreSQL URL'
  authority="${url#*://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%#*}"
  [[ -n "$authority" ]] || fail 'DB_URL has no authority'
  hostspec="${authority##*@}"
  [[ -n "$hostspec" ]] || fail 'DB_URL has no host'
  IFS=',' read -r -a hostports <<< "$hostspec"
  [[ "${#hostports[@]}" -gt 0 ]] || fail 'DB_URL authority hostspec is empty'
  for hostport in "${hostports[@]}"; do
    if [[ "$hostport" == \[*\]* ]]; then
      host="${hostport#\[}"
      host="${host%%\]*}"
    else
      host="${hostport%%:*}"
    fi
    is_loopback_host "$host" \
      || fail "DB_URL authority host '${host}' is not loopback-local; this harness mutates fixtures and DDL"
  done

  if [[ "$url" == *\?* ]]; then
    query="${url#*\?}"
    query="${query%%#*}"
    IFS='&' read -r -a query_pairs <<< "$query"
    for pair in "${query_pairs[@]}"; do
      [[ -n "$pair" ]] || continue
      key="${pair%%=*}"
      if [[ "$pair" == *=* ]]; then
        value="${pair#*=}"
      else
        value=''
      fi
      decoded_key="$(percent_decode_uri_component "$key")"
      case "${decoded_key,,}" in
        host)
          [[ -n "$value" ]] || fail 'DB_URL query parameter host is empty'
          assert_loopback_host_value "$value" 'query parameter host'
          ;;
        hostaddr)
          [[ -n "$value" ]] || fail 'DB_URL query parameter hostaddr is empty'
          assert_loopback_hostaddr_value "$value" 'query parameter hostaddr'
          ;;
      esac
    done
  fi
}

db_url="${DB_URL:-}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'
assert_loopback_postgres_url "$db_url"

command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_table="p285_two_session_race_coord_${BASHPID}_${RANDOM}"
coord_dir="$(mktemp -d /tmp/p285-two-session-race.XXXXXX)"
race_a_pid=''
race_b_pid=''

cleanup() {
  local pid
  for pid in "$race_a_pid" "$race_b_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "${db_url:-}" ]] && command -v psql >/dev/null 2>&1; then
    PGCONNECT_TIMEOUT=10 \
      PGOPTIONS='-c lock_timeout=5s -c statement_timeout=60s' \
      psql "$db_url" -X -q -v ON_ERROR_STOP=1 \
        -c "DROP TABLE IF EXISTS public.${coord_table};" >/dev/null 2>&1 || true
  fi
  rm -rf "$coord_dir"
}
trap cleanup EXIT

psql_cmd() {
  PGCONNECT_TIMEOUT=10 \
    PGOPTIONS='-c lock_timeout=5s -c statement_timeout=60s' \
    psql "$db_url" -X -v ON_ERROR_STOP=1 "$@"
}

# The two race sessions intentionally block on the per-reference advisory lock,
# so they must not inherit the short lock_timeout used by ordinary probes.
psql_race_cmd() {
  PGCONNECT_TIMEOUT=10 \
    PGOPTIONS='-c lock_timeout=0 -c statement_timeout=120s' \
    psql "$db_url" -X -v ON_ERROR_STOP=1 "$@"
}

actor_id='d2850000-0000-0000-0000-0000000000f1'
run_suffix="${RANDOM}${RANDOM}"
ref_id=''
idempotency_a=''
idempotency_b=''

init_fixtures() {
  ref_id="$(psql_cmd -Atq -c "SELECT gen_random_uuid();")"
  idempotency_a="p285-two-session-a-${run_suffix}"
  idempotency_b="p285-two-session-b-${run_suffix}"

  psql_cmd <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS public.${coord_table}(
  id integer PRIMARY KEY,
  signal boolean NOT NULL DEFAULT false
);
TRUNCATE public.${coord_table};
INSERT INTO public.${coord_table}(id, signal) VALUES (1, false);

INSERT INTO public.users (id, role, is_sales_executive) VALUES
  ('${actor_id}', 'PACKING_SUPERVISOR', false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.ols_print_logs(
  ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason
) VALUES (
  'carton', '${ref_id}', '${actor_id}', true, false, 0, 'p285 two-session fixture'
);
SQL
}

run_two_session_race() {
  local session_a_sql="$coord_dir/session_a.sql"
  local session_b_sql="$coord_dir/session_b.sql"
  local a_log="$coord_dir/session_a.log"
  local b_log="$coord_dir/session_b.log"
  local session_b_app_name="trace-reprint-race-b-${BASHPID}-${run_suffix}"
  local blocked_query="
    SELECT EXISTS (
      SELECT 1
      FROM pg_locks wl
      JOIN pg_stat_activity wsa ON wsa.pid = wl.pid
      WHERE wl.locktype = 'advisory'
        AND NOT wl.granted
        AND wsa.datname = current_database()
        AND wsa.application_name = '${session_b_app_name}'
        AND wsa.query ILIKE '%trace_allocate_reprint_count_v1%'
    );
  "

  cat >"$session_a_sql" <<SQL
\\set ON_ERROR_STOP 1
BEGIN;
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', '${actor_id}', 'role', 'authenticated')::text,
  true
);
SET LOCAL ROLE authenticated;
SELECT public.trace_allocate_reprint_count_v1(
  'carton', '${ref_id}', 'session-a race', '${idempotency_a}', null
);
RESET ROLE;
DO \$wait\$
BEGIN
  WHILE NOT (SELECT signal FROM public.${coord_table} WHERE id = 1) LOOP
    PERFORM pg_sleep(0.02);
  END LOOP;
END;
\$wait\$;
COMMIT;
SQL

  cat >"$session_b_sql" <<SQL
\\set ON_ERROR_STOP 1
SELECT set_config('application_name', '${session_b_app_name}', false);
BEGIN;
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', '${actor_id}', 'role', 'authenticated')::text,
  true
);
SET LOCAL ROLE authenticated;
SELECT public.trace_allocate_reprint_count_v1(
  'carton', '${ref_id}', 'session-b race', '${idempotency_b}', null
);
COMMIT;
SQL

  echo 'TRACE_REPRINT_TWO_SESSION_RACE: session A allocates count 1, then holds its transaction open'
  psql_race_cmd -Atq -f "$session_a_sql" >"$a_log" 2>&1 &
  race_a_pid=$!

  local a_waiting='f'
  for _ in $(seq 1 100); do
    a_waiting="$(psql_cmd -Atq -c "
      SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity asa
        WHERE asa.datname = current_database()
          AND asa.pid <> pg_backend_pid()
          AND asa.state = 'active'
          AND asa.query ILIKE '%${coord_table}%'
      );
    ")"
    [[ "$a_waiting" == 't' ]] && break
    sleep 0.05
  done
  [[ "$a_waiting" == 't' ]] || fail "session A did not reach the coordination wait boundary (pid=${race_a_pid}; log: $(cat "$a_log"))"

  echo 'TRACE_REPRINT_TWO_SESSION_RACE: session B starts while A still holds the ref advisory lock'
  psql_race_cmd -Atq -f "$session_b_sql" >"$b_log" 2>&1 &
  race_b_pid=$!

  local blocked='f'
  for _ in $(seq 1 100); do
    blocked="$(psql_cmd -Atq -c "$blocked_query")"
    [[ "$blocked" == 't' ]] && break
    sleep 0.05
  done
  [[ "$blocked" == 't' ]] \
    || fail "session B never blocked on the ref advisory lock (a_log: $(cat "$a_log"); b_log: $(cat "$b_log"))"
  echo 'TRACE_REPRINT_TWO_SESSION_RACE: session B is genuinely blocked on the advisory lock (pg_locks proof)'

  echo 'TRACE_REPRINT_TWO_SESSION_RACE: releasing session A; session B may now proceed'
  psql_cmd -c "UPDATE public.${coord_table} SET signal = true WHERE id = 1;" >/dev/null

  wait "$race_a_pid" || fail "session A failed (pid=${race_a_pid}; log: $(cat "$a_log"))"
  wait "$race_b_pid" || fail "session B failed (pid=${race_b_pid}; log: $(cat "$b_log"))"
  race_a_pid=''
  race_b_pid=''

  grep -q '"reprint_count": 1' "$a_log" \
    || fail "session A did not allocate reprint_count=1 (a_log: $(cat "$a_log"))"
  grep -q '"reprint_count": 2' "$b_log" \
    || fail "session B did not allocate reprint_count=2 after A committed (b_log: $(cat "$b_log"))"
  grep -q '"approval_required": true' "$b_log" \
    || fail "session B did not evaluate threshold authority on count 2 (b_log: $(cat "$b_log"))"

  local alloc_count distinct_counts
  alloc_count="$(psql_cmd -Atq -c "
    SELECT count(*) FROM public.ols_trace_reprint_allocations
    WHERE ref_id = '${ref_id}';
  ")"
  distinct_counts="$(psql_cmd -Atq -c "
    SELECT count(distinct reprint_count) FROM public.ols_trace_reprint_allocations
    WHERE ref_id = '${ref_id}';
  ")"

  [[ "$alloc_count" == '2' ]] \
    || fail "expected exactly two durable allocations, found ${alloc_count}"
  [[ "$distinct_counts" == '2' ]] \
    || fail "expected two distinct allocated counts, found ${distinct_counts}"

  echo "TRACE_REPRINT_TWO_SESSION_RACE: converged on alloc_count=${alloc_count} distinct_counts=${distinct_counts}"
}

init_fixtures
run_two_session_race

echo 'TRACE_REPRINT_TWO_SESSION_RACE: PASS'
