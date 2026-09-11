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

assert_loopback_postgres_url() {
  local url="$1" authority hostport host
  [[ "$url" =~ ^postgres(ql)?:// ]] || fail 'DB_URL is not a PostgreSQL URL'
  authority="${url#*://}"
  authority="${authority%%/*}"
  [[ -n "$authority" ]] || fail 'DB_URL has no authority'
  hostport="${authority##*@}"
  [[ -n "$hostport" ]] || fail 'DB_URL has no host'
  if [[ "$hostport" == \[*\]* ]]; then
    host="${hostport#\[}"
    host="${host%%\]*}"
  else
    host="${hostport%%:*}"
  fi
  case "$host" in
    127.0.0.1|localhost|::1) ;;
    *) fail 'DB_URL authority host is not loopback-local; this harness mutates fixtures and DDL' ;;
  esac
}

db_url="${DB_URL:-}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'
assert_loopback_postgres_url "$db_url"

command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_dir="$(mktemp -d /tmp/p285-two-session-race.XXXXXX)"
cleanup() {
  rm -rf "$coord_dir"
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
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

coord_table='p285_two_session_race_coord'
actor_id='d2850000-0000-0000-0000-0000000000f1'
ref_id='d2850000-0000-0000-0000-00000000c0f1'

init_fixtures() {
  psql_cmd <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS public.${coord_table}(
  id integer PRIMARY KEY,
  signal boolean NOT NULL DEFAULT false
);
TRUNCATE public.${coord_table};
INSERT INTO public.${coord_table}(id, signal) VALUES (1, false);

INSERT INTO public.users (id, role) VALUES
  ('${actor_id}', 'PACKING_SUPERVISOR')
ON CONFLICT (id) DO NOTHING;

DELETE FROM public.ols_trace_mutation_receipts
  WHERE idempotency_key LIKE 'p285-two-session-%';
DELETE FROM public.ols_audit_logs
  WHERE idempotency_key LIKE 'p285-two-session-%';
DELETE FROM public.ols_trace_reprint_allocations
  WHERE ref_id = '${ref_id}';
DELETE FROM public.ols_trace_reprint_counters
  WHERE ref_id = '${ref_id}';
DELETE FROM public.ols_print_logs
  WHERE ref_id = '${ref_id}';

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
  local blocked_query="
    SELECT EXISTS (
      SELECT 1
      FROM pg_locks wl
      JOIN pg_stat_activity wsa ON wsa.pid = wl.pid
      WHERE wl.locktype = 'advisory'
        AND NOT wl.granted
        AND wsa.datname = current_database()
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
  'carton', '${ref_id}', 'session-a race', 'p285-two-session-a', null
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
BEGIN;
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', '${actor_id}', 'role', 'authenticated')::text,
  true
);
SET LOCAL ROLE authenticated;
SELECT public.trace_allocate_reprint_count_v1(
  'carton', '${ref_id}', 'session-b race', 'p285-two-session-b', null
);
COMMIT;
SQL

  echo 'TRACE_REPRINT_TWO_SESSION_RACE: session A allocates count 1, then holds its transaction open'
  psql_race_cmd -Atq -f "$session_a_sql" >"$a_log" 2>&1 &
  local a_pid=$!

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
  [[ "$a_waiting" == 't' ]] || fail "session A did not reach the coordination wait boundary (log: $(cat "$a_log"))"

  echo 'TRACE_REPRINT_TWO_SESSION_RACE: session B starts while A still holds the ref advisory lock'
  psql_race_cmd -Atq -f "$session_b_sql" >"$b_log" 2>&1 &
  local b_pid=$!

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

  wait "$a_pid" || fail "session A failed (log: $(cat "$a_log"))"
  wait "$b_pid" || fail "session B failed (log: $(cat "$b_log"))"

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

psql_cmd -c "DROP TABLE IF EXISTS public.${coord_table};" >/dev/null

echo 'TRACE_REPRINT_TWO_SESSION_RACE: PASS'
