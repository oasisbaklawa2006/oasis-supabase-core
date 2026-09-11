#!/usr/bin/env bash
# Two-session concurrency proof for Issue #282 catalogue-source atomic staging.
#
# Proves public.stage_catalogue_source_entry's pg_advisory_xact_lock genuinely
# serializes two OVERLAPPING database sessions racing the identical governed
# staging identity (same dedupe_key + same source_entry_key + identical
# content), not merely two sequential calls in one session:
#
#   1. Session A calls the RPC, then holds its transaction open (does not
#      commit) so the advisory lock acquired inside the function stays held.
#   2. Session B starts while A is still open and calls the RPC with the
#      SAME dedupe_key/entry_key. B must block INSIDE the function, at the
#      pg_advisory_xact_lock call, before it can even read the batch row.
#   3. We assert B is genuinely blocked (pg_locks: an ungranted advisory
#      lock held by a session running this exact function) before letting
#      A commit. If the advisory lock were removed or bypassed, B would
#      never appear as blocked here and this harness would fail with
#      "peer never blocked" -- the PASS path requires witnessing the block,
#      it is not inferred from final state alone.
#   4. A commits, releasing the lock; B then proceeds, discovers the batch
#      and entry A already created, and reports an exact idempotent replay.
#   5. Final state: exactly one durable batch, exactly one durable entry,
#      exactly one audit row (from A; B's replay is a true no-op and must
#      not append a second one) -- both callers converged correctly.
#
# Mirrors scripts/test-dispatch-finalization-two-session-race.sh's technique
# (coordination table polled inside a DO block; pg_locks/pg_stat_activity
# for blocking proof) rather than inventing a new mechanism.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE_FAILURE: $*" >&2
  exit 1
}

db_url="${DB_URL:-}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'

command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_dir="$(mktemp -d /tmp/p282-two-session-race.XXXXXX)"
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

coord_table='p282_two_session_race_coord'
actor_id='d2820000-0000-0000-0000-0000000000f1'
dedupe_key='p282-two-session-race'
entry_key='race-entry'

init_fixtures() {
  psql_cmd <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS public.${coord_table}(
  id integer PRIMARY KEY,
  signal boolean NOT NULL DEFAULT false
);
TRUNCATE public.${coord_table};
INSERT INTO public.${coord_table}(id, signal) VALUES (1, false);

INSERT INTO public.roles (id, role_key, role_name, is_active) VALUES
  ('d2820000-0000-0000-0000-00000000a0f1', 'catalogue_manager', 'Catalogue manager', true)
ON CONFLICT (role_key) DO UPDATE SET is_active = true;

INSERT INTO public.users (id, role) VALUES
  ('${actor_id}', 'CATALOGUE_MANAGER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_role_map (user_id, role_id)
SELECT '${actor_id}', id FROM public.roles WHERE role_key = 'catalogue_manager'
ON CONFLICT (user_id, role_id) DO NOTHING;

DELETE FROM public.catalogue_source_audit_log
  WHERE batch_id IN (SELECT id FROM public.catalogue_source_batches WHERE dedupe_key = '${dedupe_key}');
DELETE FROM public.catalogue_source_entries
  WHERE batch_id IN (SELECT id FROM public.catalogue_source_batches WHERE dedupe_key = '${dedupe_key}');
DELETE FROM public.catalogue_source_batches WHERE dedupe_key = '${dedupe_key}';
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
        AND wsa.query ILIKE '%stage_catalogue_source_entry%'
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
SELECT * FROM public.stage_catalogue_source_entry(
  '${dedupe_key}', 'P282RaceProvider', 'P282 Race Document', '${entry_key}',
  NULL, NULL, NULL, '{}'::jsonb,
  NULL, NULL, NULL, NULL, '{"raw":"race"}'::jsonb, '{}'::jsonb, NULL
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
SELECT * FROM public.stage_catalogue_source_entry(
  '${dedupe_key}', 'P282RaceProvider', 'P282 Race Document', '${entry_key}',
  NULL, NULL, NULL, '{}'::jsonb,
  NULL, NULL, NULL, NULL, '{"raw":"race"}'::jsonb, '{}'::jsonb, NULL
);
COMMIT;
SQL

  echo 'CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE: session A stages the entry, then holds its transaction open'
  psql_cmd -Atq -f "$session_a_sql" >"$a_log" 2>&1 &
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

  echo 'CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE: session B starts while A still holds the advisory lock'
  psql_cmd -Atq -f "$session_b_sql" >"$b_log" 2>&1 &
  local b_pid=$!

  local blocked='f'
  for _ in $(seq 1 100); do
    blocked="$(psql_cmd -Atq -c "$blocked_query")"
    [[ "$blocked" == 't' ]] && break
    sleep 0.05
  done
  [[ "$blocked" == 't' ]] \
    || fail "session B never blocked on the dedupe_key advisory lock (a_log: $(cat "$a_log"); b_log: $(cat "$b_log"))"
  echo 'CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE: session B is genuinely blocked on the advisory lock (pg_locks proof)'

  echo 'CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE: releasing session A; session B may now proceed'
  psql_cmd -c "UPDATE public.${coord_table} SET signal = true WHERE id = 1;" >/dev/null

  wait "$a_pid" || fail "session A failed (log: $(cat "$a_log"))"
  wait "$b_pid" || fail "session B failed (log: $(cat "$b_log"))"

  # session B ran only after A committed, so it must observe A's durable
  # state and report an exact idempotent replay -- not a fresh insert.
  # Result row shape: batch_id|batch_status|batch_dedupe_key|entry_id|entry_status|entry_was_replayed|audit_id
  awk -F'|' 'NF == 7 && $6 == "t" { found=1 } END { exit !found }' "$b_log" \
    || fail "session B did not report entry_was_replayed=true after A committed (b_log: $(cat "$b_log"))"

  local batch_count entry_count audit_count
  batch_count="$(psql_cmd -Atq -c "SELECT count(*) FROM public.catalogue_source_batches WHERE dedupe_key = '${dedupe_key}';")"
  entry_count="$(psql_cmd -Atq -c "
    SELECT count(*) FROM public.catalogue_source_entries e
    JOIN public.catalogue_source_batches b ON b.id = e.batch_id
    WHERE b.dedupe_key = '${dedupe_key}' AND e.source_entry_key = '${entry_key}';
  ")"
  audit_count="$(psql_cmd -Atq -c "
    SELECT count(*) FROM public.catalogue_source_audit_log al
    JOIN public.catalogue_source_batches b ON b.id = al.batch_id
    WHERE b.dedupe_key = '${dedupe_key}';
  ")"

  [[ "$batch_count" == '1' ]] \
    || fail "expected exactly one canonical batch for ${dedupe_key}, found ${batch_count}"
  [[ "$entry_count" == '1' ]] \
    || fail "expected exactly one canonical entry for ${entry_key}, found ${entry_count}"
  [[ "$audit_count" == '1' ]] \
    || fail "expected exactly one audit row (B's replay must not duplicate it), found ${audit_count}"

  echo "CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE: converged on batch_count=${batch_count} entry_count=${entry_count} audit_count=${audit_count}"
}

init_fixtures
run_two_session_race

psql_cmd -c "DROP TABLE IF EXISTS public.${coord_table};" >/dev/null

echo 'CATALOGUE_SOURCE_STAGING_TWO_SESSION_RACE: PASS'
