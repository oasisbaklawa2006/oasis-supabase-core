#!/usr/bin/env bash
# Concurrency proof for the Studio AI-copy budget reservation (APPVERSE-CORE-AI-BUDGET-01).
# Races many parallel database sessions for a company-day budget with room for exactly THREE
# maximum reservations and requires exactly three to succeed and the bucket to land on the cap.
# DISPOSABLE LOCAL DATABASES ONLY: the script refuses any non-local host and creates synthetic
# staff rows. Usage: DATABASE_URL=postgres://postgres@localhost:54322/postgres \
#   bash scripts/tests/verify-ai-copy-budget-concurrency.sh
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL to a disposable LOCAL database with the migration applied}"
case "$DATABASE_URL" in
  *localhost*|*127.0.0.1*|*host=/tmp*|*@/*|*\?host=/*) ;;
  *) echo "REFUSED: DATABASE_URL must be a local disposable database" >&2; exit 2 ;;
esac
SESSIONS="${SESSIONS:-12}"
ROOM_REQUESTS=3
MODEL='gpt-5.4-mini-2026-03-17'
psql_q() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -At "$@"; }

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

tmp="$(mktemp -d)"
for n in $(seq 1 "$SESSIONS"); do
  (
    actor="94790000-0000-0000-0000-$(printf '%012d' "$n")"
    psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -At <<SQL > "$tmp/$n.out" 2>&1
SET ROLE service_role;
WITH g AS (SELECT public.catalogue_ai_copy_budget_gate_v1('${actor}', '${MODEL}') AS id)
SELECT CASE WHEN g.id IS NULL THEN 'gate-denied'
            WHEN public.catalogue_ai_copy_budget_reserve_v1(g.id, '${actor}', '${MODEL}', 1000) THEN 'reserved'
            ELSE 'reserve-denied' END FROM g;
SQL
  ) &
done
wait

reserved="$(cat "$tmp"/*.out | grep -c '^reserved$' || true)"
denied="$(cat "$tmp"/*.out | grep -c 'reserve-denied' || true)"
errors="$(cat "$tmp"/*.out | grep -vc -E '^(reserved|reserve-denied|gate-denied)$' || true)"
final="$(psql_q -c "SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1 WHERE bucket='company_day' AND actor_id='00000000-0000-0000-0000-000000000000'")"
rows="$(psql_q -c "SELECT count(*) FROM public.catalogue_ai_copy_reservations_v1 WHERE status='reserved'")"
echo "sessions=${SESSIONS} reserved=${reserved} reserve-denied=${denied} errors=${errors} final_company_day_micro_usd=${final} reserved_rows=${rows}"
rm -rf "$tmp"
test "$errors" = "0" || { echo "CONCURRENCY FAIL: unexpected session output" >&2; exit 1; }
test "$reserved" = "$ROOM_REQUESTS" || { echo "CONCURRENCY FAIL: expected exactly ${ROOM_REQUESTS} reservations" >&2; exit 1; }
test "$rows" = "$ROOM_REQUESTS" || { echo "CONCURRENCY FAIL: ledger rows differ from grants" >&2; exit 1; }
test "$final" = "5000000" || { echo "CONCURRENCY FAIL: bucket did not land exactly on the cap" >&2; exit 1; }
echo "AI_COPY_BUDGET_CONCURRENCY_PASS"
