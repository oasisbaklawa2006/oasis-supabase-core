#!/usr/bin/env bash
# Two-session concurrency proof for Finance hold vs dispatch finalization (#260).
# Session B holds the canonical eligibility locks at the mutation boundary while
# session A blocks on release_order_to_dispatched_v1, then B commits a blocking
# hold and A revalidates under the shared lock and rejects dispatch.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE_FAILURE: $*" >&2
  exit 1
}

db_url="${1:-${DB_URL:-}}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'

command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_dir="$(mktemp -d /tmp/md0802-two-session-race.XXXXXX)"
cleanup() {
  rm -rf "$coord_dir"
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

b_ready="$coord_dir/b_ready"
a_result="$coord_dir/a_result.json"
b_log="$coord_dir/b.log"
a_log="$coord_dir/a.log"

seed_sql="$coord_dir/seed.sql"
session_b_sql="$coord_dir/session_b.sql"
session_a_sql="$coord_dir/session_a.sql"

cat >"$seed_sql" <<'SQL'
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL session_replication_role = replica;

INSERT INTO auth.users(id, email) VALUES
  ('d8020000-0000-0000-0000-000000000001', 'md0802-dispatch@test.invalid'),
  ('d8020000-0000-0000-0000-000000000002', 'md0802-finance@test.invalid')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users(id, role, name, is_active) VALUES
  ('d8020000-0000-0000-0000-000000000001', 'DISPATCH_MANAGER', 'MD0802 Dispatch', true),
  ('d8020000-0000-0000-0000-000000000002', 'FINANCE_EXEC', 'MD0802 Finance', true)
ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;

INSERT INTO public.companies(id, business_name, status)
VALUES ('d8020000-0000-0000-0000-000000000010', 'MD0802 Two Session Co', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
VALUES ('d8020000-0000-0000-0000-000000000027', 'd8020000-0000-0000-0000-000000000010', 'MD0802-TWO-SESSION', 'MANUAL', 'md0802-two-session', 100000, 30000, 'cleared_for_dispatch')
ON CONFLICT (id) DO UPDATE SET status = 'cleared_for_dispatch';

INSERT INTO public.sales_order_commercial_versions(
  id, order_id, version_number, source_channel, commercial_snapshot, snapshot_fingerprint,
  sales_order_value, advance_required, change_reason, correlation_id, idempotency_key, created_by
) VALUES (
  'd8020000-0000-0000-0000-000000000037', 'd8020000-0000-0000-0000-000000000027', 1, 'MANUAL', '{}'::jsonb,
  'md0802-two-session-commercial', 100000, 30000, 'two-session fixture', 'md0802-two-session-commercial', 'md0802-two-session-commercial-key',
  'd8020000-0000-0000-0000-000000000002'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.sales_order_proforma_invoices(
  id, order_id, commercial_version_id, commercial_version_number, frozen_commercial_snapshot,
  frozen_snapshot_fingerprint, status, customer_visible_pi_number, reason, source, correlation_id, idempotency_key, created_by,
  issued_by, issued_at
) VALUES (
  'd8020000-0000-0000-0000-000000000038', 'd8020000-0000-0000-0000-000000000027', 'd8020000-0000-0000-0000-000000000037', 1, '{}'::jsonb,
  'md0802-two-session-pi', 'ISSUED', 'PI2026/09-027', 'two-session fixture', 'MANUAL', 'md0802-two-session-pi', 'md0802-two-session-pi-key',
  'd8020000-0000-0000-0000-000000000002', 'd8020000-0000-0000-0000-000000000002', statement_timestamp()
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.finance_dpl_receipts(
  id, order_id, company_id, commercial_version_id, external_dpl_id, dpl_version, dpl_fingerprint,
  dpl_snapshot, finalized_at, received_by, received_role, source_channel, evidence_reference,
  correlation_id, idempotency_key
) VALUES (
  'd8020000-0000-0000-0000-000000000039', 'd8020000-0000-0000-0000-000000000027', 'd8020000-0000-0000-0000-000000000010',
  'd8020000-0000-0000-0000-000000000037', 'MD0802-TWO-SESSION-DPL', 1,
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  jsonb_build_object('carton_ids', '[]'::jsonb), statement_timestamp(),
  'd8020000-0000-0000-0000-000000000002', 'FINANCE_EXEC', 'FINANCE', 'md0802-two-session-dpl-evidence', 'md0802-two-session-dpl', 'md0802-two-session-dpl-key'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.final_invoices(
  id, order_id, company_id, proforma_invoice_id, commercial_version_id, finance_dpl_receipt_id,
  invoice_number, invoice_date, taxable_total, tax_total, gross_total, status, document_reference,
  invoice_fingerprint, issued_by, issued_role, reason, correlation_id, idempotency_key
) VALUES (
  'd8020000-0000-0000-0000-00000000003a', 'd8020000-0000-0000-0000-000000000027', 'd8020000-0000-0000-0000-000000000010',
  'd8020000-0000-0000-0000-000000000038', 'd8020000-0000-0000-0000-000000000037', 'd8020000-0000-0000-0000-000000000039',
  'MD0802-TWO-SESSION-INV', current_date, 84745.76, 15254.24, 100000, 'ISSUED', 'md0802-two-session-invoice-doc',
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'd8020000-0000-0000-0000-000000000002', 'FINANCE_EXEC',
  'two-session fixture', 'md0802-two-session-invoice', 'md0802-two-session-invoice-key'
) ON CONFLICT (id) DO NOTHING;

DELETE FROM public.finance_control_events
WHERE order_id = 'd8020000-0000-0000-0000-000000000027'
   OR idempotency_key IN ('md0802-race-hold-key', 'md0802-race-hold-key-applied');

DELETE FROM public.finance_control_idempotency
WHERE idempotency_key IN ('md0802-race-hold-key', 'md0802-race-hold-key-applied');

INSERT INTO public.finance_clearance_events(
  id, order_id, company_id, proforma_invoice_id, commercial_version_id, clearance_type, decision,
  commercial_value, required_advance, verified_payment_amount, wallet_applied_amount,
  approved_credit_amount, covered_amount, reason, evidence_reference, actor_id, actor_role,
  source_channel, source_reference, correlation_id, idempotency_key, facts_snapshot, created_at
) VALUES (
  'd8020000-0000-0000-0000-00000000003b', 'd8020000-0000-0000-0000-000000000027', 'd8020000-0000-0000-0000-000000000010',
  'd8020000-0000-0000-0000-000000000038', 'd8020000-0000-0000-0000-000000000037', 'DISPATCH', 'GRANTED',
  100000, 0, 100000, 0, 0, 100000, 'two-session active clearance', 'md0802-two-session-clearance', 'd8020000-0000-0000-0000-000000000002',
  'FINANCE_EXEC', 'FINANCE', 'd8020000-0000-0000-0000-00000000003a'::text, 'md0802-two-session-clearance-grant', 'md0802-two-session-clearance-grant-key',
  '{}'::jsonb, statement_timestamp() - interval '2 hours'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.dispatch_proof_packets(
  id, order_id, final_invoice_id, finance_dpl_receipt_id, finance_dispatch_clearance_event_id,
  transport_snapshot, gate_decision_ids, evidence_references, dispatched_at, proof_fingerprint,
  recorded_by, recorded_role, correlation_id, idempotency_key
) VALUES (
  'd8020000-0000-0000-0000-00000000003c', 'd8020000-0000-0000-0000-000000000027', 'd8020000-0000-0000-0000-00000000003a',
  'd8020000-0000-0000-0000-000000000039', 'd8020000-0000-0000-0000-00000000003b',
  jsonb_build_object('transporter', 'BlueDart', 'lr_awb_bilty', 'AWB-TWO-SESSION', 'tracking_reference', 'TRK-TWO-SESSION'),
  '[]'::jsonb, '["md0802-two-session-evidence"]'::jsonb,
  statement_timestamp() - interval '90 minutes', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'd8020000-0000-0000-0000-000000000001', 'DISPATCH_MANAGER', 'md0802-two-session-proof', 'md0802-two-session-proof-key'
) ON CONFLICT (id) DO NOTHING;

SET LOCAL session_replication_role = DEFAULT;
COMMIT;
SQL

coord_table='md0802_two_session_race_coord'

psql "$db_url" -X -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS public.${coord_table}(
  id integer PRIMARY KEY,
  session_a_go boolean NOT NULL DEFAULT false
);
INSERT INTO public.${coord_table}(id, session_a_go) VALUES (1, false)
ON CONFLICT (id) DO UPDATE SET session_a_go = false;
SQL

cat >"$session_b_sql" <<SQL
\\set ON_ERROR_STOP 1
BEGIN;
SELECT public.lock_finance_dispatch_eligibility_v1('d8020000-0000-0000-0000-000000000027'::uuid);
SELECT public.lock_finance_dispatch_eligibility_company_v1('d8020000-0000-0000-0000-000000000010'::uuid);
DO \$wait\$
BEGIN
  WHILE NOT (
    SELECT session_a_go FROM public.${coord_table} WHERE id = 1
  ) LOOP
    PERFORM pg_sleep(0.02);
  END LOOP;
END;
\$wait\$;
SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'd8020000-0000-0000-0000-000000000002',
    'role', 'authenticated',
    'aal', 'aal2'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
SELECT public.apply_finance_hold_v1(
  'd8020000-0000-0000-0000-000000000010'::uuid,
  'd8020000-0000-0000-0000-000000000027'::uuid,
  NULL,
  'ORDER',
  1000,
  'two-session blocking hold during finalization',
  'md0802-race-hold-evidence',
  'md0802-race-hold-corr',
  'md0802-race-hold-key'
);
COMMIT;
SQL

cat >"$session_a_sql" <<SQL
\\set ON_ERROR_STOP 1
\\pset format unaligned
\\pset tuples_only on
BEGIN;
SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'd8020000-0000-0000-0000-000000000001',
    'role', 'authenticated'
  )::text,
  true
);
SET LOCAL ROLE authenticated;
\\o '$a_result'
SELECT public.release_order_to_dispatched_v1('d8020000-0000-0000-0000-000000000027'::uuid)::text;
\\o
COMMIT;
SQL

blocked_query="
SELECT EXISTS (
  SELECT 1
  FROM pg_locks wl
  JOIN pg_stat_activity wsa ON wsa.pid = wl.pid
  WHERE wl.locktype = 'advisory'
    AND NOT wl.granted
    AND wsa.datname = current_database()
    AND wsa.query ILIKE '%release_order_to_dispatched_v1%'
);
"

echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE: seeding fixture order d802...0027'
psql "$db_url" -X -v ON_ERROR_STOP=1 -f "$seed_sql" >/dev/null

echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE: starting session B (eligibility lock holder)'
psql "$db_url" -X -v ON_ERROR_STOP=1 -f "$session_b_sql" >"$b_log" 2>&1 &
b_pid=$!

b_holding='f'
for _ in $(seq 1 100); do
  b_holding="$(psql "$db_url" -X -Atq -v ON_ERROR_STOP=1 -c "
    SELECT EXISTS (
      SELECT 1
      FROM pg_stat_activity bsa
      WHERE bsa.datname = current_database()
        AND bsa.state = 'active'
        AND bsa.query ILIKE '%${coord_table}%'
    );
  ")"
  [[ "$b_holding" == 't' ]] && break
  sleep 0.05
done
[[ "$b_holding" == 't' ]] || fail "session B did not reach eligibility lock wait boundary (log: $(cat "$b_log"))"
touch "$b_ready"

echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE: starting session A (dispatch finalizer)'
psql "$db_url" -X -v ON_ERROR_STOP=1 -f "$session_a_sql" >"$a_log" 2>&1 &
a_pid=$!

blocked_before_hold='f'
for _ in $(seq 1 100); do
  blocked_before_hold="$(psql "$db_url" -X -Atq -v ON_ERROR_STOP=1 -c "$blocked_query")"
  [[ "$blocked_before_hold" == 't' ]] && break
  sleep 0.05
done
[[ "$blocked_before_hold" == 't' ]] || fail "session A never blocked on eligibility lock (a_log: $(cat "$a_log"); b_log: $(cat "$b_log"))"

echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE: session A blocked; session B committing blocking hold'
psql "$db_url" -X -v ON_ERROR_STOP=1 -c "UPDATE public.${coord_table} SET session_a_go = true WHERE id = 1;" >/dev/null

wait "$b_pid" || fail "session B failed (log: $(cat "$b_log"))"

wait "$a_pid" || fail "session A failed (log: $(cat "$a_log"))"
[[ -s "$a_result" ]] || fail "session A did not produce a finalizer result"

finalizer_json="$(tr -d '\n' <"$a_result" | sed -n '1p')"
order_status="$(psql "$db_url" -X -Atq -v ON_ERROR_STOP=1 -c "SELECT status FROM public.orders WHERE id = 'd8020000-0000-0000-0000-000000000027'")"
blocked_sql='false'
[[ "$blocked_before_hold" == 't' ]] && blocked_sql='true'

echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE: blocked_before_hold=$blocked_before_hold"
echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE: finalizer_result=$finalizer_json"
echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE: order_status=$order_status"

[[ "$finalizer_json" == *'"ok": false'* ]] \
  || fail "session A should reject dispatch after concurrent hold commit"
[[ "$finalizer_json" == *'finance_dispatch_clearance_required'* ]] \
  || fail "session A should report finance_dispatch_clearance_required"
[[ "$finalizer_json" == *'FINANCE_BLOCKING_HOLD_ACTIVE'* ]] \
  || fail "session A should surface FINANCE_BLOCKING_HOLD_ACTIVE"
[[ "$order_status" == 'cleared_for_dispatch' ]] \
  || fail "order must remain cleared_for_dispatch after rejected finalization"

evidence_table='md0802_two_session_race_evidence'
psql "$db_url" -X -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS public.${evidence_table}(
  run_id text PRIMARY KEY,
  blocked_before_hold boolean NOT NULL,
  finalizer_result jsonb NOT NULL,
  order_status text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
INSERT INTO public.${evidence_table}(run_id, blocked_before_hold, finalizer_result, order_status)
VALUES (
  'md0802-two-session-race',
  ${blocked_sql},
  '${finalizer_json}'::jsonb,
  '${order_status}'
)
ON CONFLICT (run_id) DO UPDATE SET
  blocked_before_hold = EXCLUDED.blocked_before_hold,
  finalizer_result = EXCLUDED.finalizer_result,
  order_status = EXCLUDED.order_status,
  recorded_at = statement_timestamp();
DROP TABLE IF EXISTS public.${coord_table};
SQL

echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE: PASS'
