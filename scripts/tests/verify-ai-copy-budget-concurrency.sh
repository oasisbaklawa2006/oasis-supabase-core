#!/usr/bin/env bash
# Concurrency proof for the Studio AI-copy budget reservation (APPVERSE-CORE-AI-BUDGET-01).
#
# Phase 1 commits one gate per worker, sequentially, so the gate transaction lock cannot hide a race.
# Phase 2 launches every RESERVE call at the same instant, each in its own session and transaction,
# against company-day room for exactly THREE maximum reservations. Exactly three must be granted, the
# rest denied, every worker must report, and the bucket must land exactly on the cap.
#
# DISPOSABLE DATABASES ONLY. The script destroys budget rows and clears the emergency latch, so it
# refuses to run unless the target is explicitly marked disposable:
#   * the connection comes ONLY from PGHOST/PGPORT/PGUSER/PGDATABASE (no URL, no service files);
#   * PGHOST must be localhost, 127.0.0.1 or a local socket directory;
#   * PGDATABASE must look like disposable_*, scratch_* or test_*;
#   * the database must carry the comment AI_COPY_BUDGET_DISPOSABLE_TEST, set by its creator with
#       COMMENT ON DATABASE <name> IS 'AI_COPY_BUDGET_DISPOSABLE_TEST';
# Optional: SESSIONS (default 12), NEGATIVE_CONTROL_SQL (path to a migration copy used only by CI/devs).
set -euo pipefail

: "${PGHOST:?set PGHOST (localhost, 127.0.0.1 or a socket directory)}"
: "${PGUSER:?set PGUSER}"
: "${PGDATABASE:?set PGDATABASE (disposable_*, scratch_* or test_*)}"
PGPORT="${PGPORT:-5432}"
export PGHOST PGPORT PGUSER PGDATABASE
# Anything that can redirect libpq elsewhere is refused outright.
for var in PGHOSTADDR PGSERVICE PGSERVICEFILE PGSYSCONFDIR DATABASE_URL; do
  if [ -n "${!var:-}" ]; then echo "REFUSED: $var must not be set" >&2; exit 2; fi
done
case "$PGHOST" in
  localhost|127.0.0.1|/*) ;;
  *) echo "REFUSED: PGHOST must be localhost, 127.0.0.1 or a local socket directory" >&2; exit 2 ;;
esac
[[ "$PGPORT" =~ ^[0-9]{2,5}$ ]] || { echo "REFUSED: invalid PGPORT" >&2; exit 2; }
[[ "$PGDATABASE" =~ ^(disposable|scratch|test)_[a-z0-9_]+$ ]] || { echo "REFUSED: PGDATABASE must match (disposable|scratch|test)_*" >&2; exit 2; }

SESSIONS="${SESSIONS:-12}"
[[ "$SESSIONS" =~ ^[0-9]{1,3}$ ]] && [ "$SESSIONS" -ge 6 ] || { echo "REFUSED: SESSIONS must be an integer >= 6" >&2; exit 2; }
ROOM_REQUESTS=3
MODEL='gpt-5.4-mini-2026-03-17'
psql_q() { psql -X -q -v ON_ERROR_STOP=1 -At "$@"; }

marker="$(psql_q -c "SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = current_database()")"
[ "$marker" = "AI_COPY_BUDGET_DISPOSABLE_TEST" ] || { echo "REFUSED: database is not marked AI_COPY_BUDGET_DISPOSABLE_TEST" >&2; exit 2; }

psql_q <<SQL
DELETE FROM public.catalogue_ai_copy_usage_v1;
DELETE FROM public.catalogue_ai_copy_reservations_v1;
UPDATE public.catalogue_ai_copy_budget_policy_v1 SET enabled = true, emergency_disabled_at = NULL, emergency_reason = NULL WHERE singleton;
INSERT INTO public.users(id, email, role, is_active, invite_status)
SELECT ('94790000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'qa-conc-' || n || '@example.invalid', 'SUPER_ADMIN', true, 'active'
  FROM generate_series(1, ${SESSIONS}) n ON CONFLICT (id) DO NOTHING;
-- company day has room for exactly ${ROOM_REQUESTS} more maximum reservations
INSERT INTO public.catalogue_ai_copy_usage_v1 (bucket, bucket_start, actor_id, requests, micro_usd)
VALUES ('company_day', ((now() AT TIME ZONE 'UTC')::date)::timestamp AT TIME ZONE 'UTC',
        '00000000-0000-0000-0000-000000000000', 0, 5000000 - ${ROOM_REQUESTS} * 15000);
SQL

# ---- Phase 1: one committed gate per worker (sequential; each its own transaction)
declare -a ACTORS GATES
for n in $(seq 1 "$SESSIONS"); do
  actor="94790000-0000-0000-0000-$(printf '%012d' "$n")"
  gate="$(psql_q -c "SET ROLE service_role; SELECT public.catalogue_ai_copy_budget_gate_v1('${actor}', '${MODEL}')" | tail -1)"
  [[ "$gate" =~ ^[0-9a-f-]{36}$ ]] || { echo "CONCURRENCY FAIL: gate for worker $n was denied or malformed ('${gate}')" >&2; exit 1; }
  ACTORS[$n]="$actor"; GATES[$n]="$gate"
done

# ---- Phase 2: every reserve starts at the same instant (barrier on a shared start time)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
start_at="$(python3 -c 'import time; print(time.time() + 3.0)')"
declare -a PIDS
for n in $(seq 1 "$SESSIONS"); do
  (
    python3 -c "import time,sys; d=float(sys.argv[1])-time.time(); time.sleep(d if d>0 else 0)" "$start_at"
    psql_q -c "SET ROLE service_role; SELECT CASE WHEN public.catalogue_ai_copy_budget_reserve_v1('${GATES[$n]}', '${ACTORS[$n]}', '${MODEL}', 1000) THEN 'reserved' ELSE 'reserve-denied' END" | tail -1
  ) > "$tmp/$n.out" 2> "$tmp/$n.err" &
  PIDS[$n]=$!
done

failed=0
for n in $(seq 1 "$SESSIONS"); do
  if ! wait "${PIDS[$n]}"; then
    echo "worker $n exited non-zero:" >&2; cat "$tmp/$n.err" "$tmp/$n.out" >&2; failed=1
  fi
done
[ "$failed" = "0" ] || { echo "CONCURRENCY FAIL: a worker failed" >&2; exit 1; }

reserved=0; denied=0
for n in $(seq 1 "$SESSIONS"); do
  result="$(cat "$tmp/$n.out")"
  case "$result" in
    reserved) reserved=$((reserved + 1)) ;;
    reserve-denied) denied=$((denied + 1)) ;;
    *) echo "worker $n produced no valid result: '${result}'" >&2; cat "$tmp/$n.err" >&2; exit 1 ;;
  esac
done
final="$(psql_q -c "SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket='company_day' AND actor_id='00000000-0000-0000-0000-000000000000'")"
rows="$(psql_q -c "SELECT count(*) FROM public.catalogue_ai_copy_reservations_v1 WHERE status='reserved'")"
echo "sessions=${SESSIONS} reserved=${reserved} reserve-denied=${denied} final_company_day_micro_usd=${final} reserved_rows=${rows}"
[ $((reserved + denied)) -eq "$SESSIONS" ] || { echo "CONCURRENCY FAIL: not every worker reported" >&2; exit 1; }
[ "$reserved" -eq "$ROOM_REQUESTS" ] || { echo "CONCURRENCY FAIL: expected exactly ${ROOM_REQUESTS} reservations" >&2; exit 1; }
[ "$rows" -eq "$ROOM_REQUESTS" ] || { echo "CONCURRENCY FAIL: ledger rows differ from grants" >&2; exit 1; }
[ "$final" -eq 5000000 ] || { echo "CONCURRENCY FAIL: bucket did not land exactly on the cap" >&2; exit 1; }
echo "AI_COPY_BUDGET_CONCURRENCY_PASS"
