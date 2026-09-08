#!/usr/bin/env bash
# Two-session concurrency proof for Finance hold vs dispatch finalization (#260).
# Scenario A: finalizer session holds eligibility locks; hold session blocks, then
#   commits after release; subsequent finalization is fail-closed.
# Scenario B: hold session holds eligibility locks; finalizer blocks, hold commits,
#   finalizer revalidates under shared lock and rejects dispatch.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE_FAILURE: $*" >&2
  exit 1
}

db_url="${DB_URL:-}"
[[ -n "$db_url" ]] || fail 'DB_URL is required'

command -v psql >/dev/null 2>&1 || fail 'psql is not available'

coord_dir="$(mktemp -d /tmp/md0802-two-session-race.XXXXXX)"
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

evidence_table='md0802_two_session_race_evidence'
coord_table='md0802_two_session_race_coord'

seed_order_fixture() {
  local order_id="$1"
  local suffix="$2"
  local commercial_id="$3"
  local pi_id="$4"
  local dpl_id="$5"
  local invoice_id="$6"
  local clearance_id="$7"
  local proof_id="$8"
  local hold_key="$9"
  local pi_suffix="${10}"

  psql_cmd <<SQL >/dev/null
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
VALUES ('${order_id}', 'd8020000-0000-0000-0000-000000000010', 'MD0802-${suffix}', 'MANUAL', 'md0802-${suffix}', 100000, 30000, 'cleared_for_dispatch')
ON CONFLICT (id) DO UPDATE SET status = 'cleared_for_dispatch';

INSERT INTO public.sales_order_commercial_versions(
  id, order_id, version_number, source_channel, commercial_snapshot, snapshot_fingerprint,
  sales_order_value, advance_required, change_reason, correlation_id, idempotency_key, created_by
) VALUES (
  '${commercial_id}', '${order_id}', 1, 'MANUAL', '{}'::jsonb,
  'md0802-${suffix}-commercial', 100000, 30000, 'two-session fixture', 'md0802-${suffix}-commercial', 'md0802-${suffix}-commercial-key',
  'd8020000-0000-0000-0000-000000000002'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.sales_order_proforma_invoices(
  id, order_id, commercial_version_id, commercial_version_number, frozen_commercial_snapshot,
  frozen_snapshot_fingerprint, status, customer_visible_pi_number, reason, source, correlation_id, idempotency_key, created_by,
  issued_by, issued_at
) VALUES (
  '${pi_id}', '${order_id}', '${commercial_id}', 1, '{}'::jsonb,
  'md0802-${suffix}-pi', 'ISSUED', 'PI2026/09-${pi_suffix}', 'two-session fixture', 'MANUAL', 'md0802-${suffix}-pi', 'md0802-${suffix}-pi-key',
  'd8020000-0000-0000-0000-000000000002', 'd8020000-0000-0000-0000-000000000002', statement_timestamp()
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.finance_dpl_receipts(
  id, order_id, company_id, commercial_version_id, external_dpl_id, dpl_version, dpl_fingerprint,
  dpl_snapshot, finalized_at, received_by, received_role, source_channel, evidence_reference,
  correlation_id, idempotency_key
) VALUES (
  '${dpl_id}', '${order_id}', 'd8020000-0000-0000-0000-000000000010', '${commercial_id}', 'MD0802-${suffix}-DPL', 1,
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  jsonb_build_object('carton_ids', '[]'::jsonb), statement_timestamp(),
  'd8020000-0000-0000-0000-000000000002', 'FINANCE_EXEC', 'FINANCE', 'md0802-${suffix}-dpl-evidence', 'md0802-${suffix}-dpl', 'md0802-${suffix}-dpl-key'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.final_invoices(
  id, order_id, company_id, proforma_invoice_id, commercial_version_id, finance_dpl_receipt_id,
  invoice_number, invoice_date, taxable_total, tax_total, gross_total, status, document_reference,
  invoice_fingerprint, issued_by, issued_role, reason, correlation_id, idempotency_key
) VALUES (
  '${invoice_id}', '${order_id}', 'd8020000-0000-0000-0000-000000000010', '${pi_id}', '${commercial_id}', '${dpl_id}',
  'MD0802-${suffix}-INV', current_date, 84745.76, 15254.24, 100000, 'ISSUED', 'md0802-${suffix}-invoice-doc',
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'd8020000-0000-0000-0000-000000000002', 'FINANCE_EXEC',
  'two-session fixture', 'md0802-${suffix}-invoice', 'md0802-${suffix}-invoice-key'
) ON CONFLICT (id) DO NOTHING;

DELETE FROM public.finance_control_events
WHERE order_id = '${order_id}' OR idempotency_key = '${hold_key}';

DELETE FROM public.finance_control_idempotency
WHERE idempotency_key = '${hold_key}';

INSERT INTO public.finance_clearance_events(
  id, order_id, company_id, proforma_invoice_id, commercial_version_id, clearance_type, decision,
  commercial_value, required_advance, verified_payment_amount, wallet_applied_amount,
  approved_credit_amount, covered_amount, reason, evidence_reference, actor_id, actor_role,
  source_channel, source_reference, correlation_id, idempotency_key, facts_snapshot, created_at
) VALUES (
  '${clearance_id}', '${order_id}', 'd8020000-0000-0000-0000-000000000010', '${pi_id}', '${commercial_id}', 'DISPATCH', 'GRANTED',
  100000, 0, 100000, 0, 0, 100000, 'two-session active clearance', 'md0802-${suffix}-clearance', 'd8020000-0000-0000-0000-000000000002',
  'FINANCE_EXEC', 'FINANCE', '${invoice_id}'::text, 'md0802-${suffix}-clearance-grant', 'md0802-${suffix}-clearance-grant-key',
  '{}'::jsonb, statement_timestamp() - interval '2 hours'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO public.dispatch_proof_packets(
  id, order_id, final_invoice_id, finance_dpl_receipt_id, finance_dispatch_clearance_event_id,
  transport_snapshot, gate_decision_ids, evidence_references, dispatched_at, proof_fingerprint,
  recorded_by, recorded_role, correlation_id, idempotency_key
) VALUES (
  '${proof_id}', '${order_id}', '${invoice_id}', '${dpl_id}', '${clearance_id}',
  jsonb_build_object('transporter', 'BlueDart', 'lr_awb_bilty', 'AWB-${suffix}', 'tracking_reference', 'TRK-${suffix}'),
  '[]'::jsonb, '["md0802-${suffix}-evidence"]'::jsonb,
  statement_timestamp() - interval '90 minutes', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'd8020000-0000-0000-0000-000000000001', 'DISPATCH_MANAGER', 'md0802-${suffix}-proof', 'md0802-${suffix}-proof-key'
) ON CONFLICT (id) DO NOTHING;

SET LOCAL session_replication_role = DEFAULT;
COMMIT;
SQL
}

assert_finance_state() {
  local order_id="$1"
  local expect_hold="$2"
  local expect_status="$3"
  local blocking_hold_count clearance_decision audit_count

  blocking_hold_count="$(psql_cmd -Atq -c "
    SELECT count(*)::integer
    FROM public.finance_control_events h
    WHERE h.order_id = '${order_id}'
      AND h.control_kind = 'HOLD'
      AND h.decision = 'APPLIED'
      AND h.blocking
  ")"

  clearance_decision="$(psql_cmd -Atq -c "
    SELECT e.decision
    FROM public.finance_clearance_events e
    WHERE e.order_id = '${order_id}' AND e.clearance_type = 'DISPATCH'
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT 1
  ")"

  audit_count="$(psql_cmd -Atq -c "
    SELECT count(*)::integer
    FROM public.audit_logs
    WHERE entity_id = '${order_id}' AND action_type = 'ORDER_DISPATCHED'
  ")"

  order_status="$(psql_cmd -Atq -c "SELECT status FROM public.orders WHERE id = '${order_id}'")"

  [[ "$blocking_hold_count" == "$expect_hold" ]] \
    || fail "expected ${expect_hold} blocking hold(s) for ${order_id}, found ${blocking_hold_count}"
  [[ "$clearance_decision" == 'GRANTED' ]] \
    || fail "expected active GRANTED dispatch clearance for ${order_id}, found ${clearance_decision}"
  [[ "$order_status" == "$expect_status" ]] \
    || fail "expected order status ${expect_status} for ${order_id}, found ${order_status}"
  [[ "$audit_count" == '0' ]] \
    || fail "expected no ORDER_DISPATCHED audit for ${order_id}, found ${audit_count}"
}

run_finalizer_once() {
  local order_id="$1"
  local out_file="$2"
  psql_cmd -Atq -f - >"$out_file" <<SQL
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
SELECT public.release_order_to_dispatched_v1('${order_id}'::uuid)::text;
COMMIT;
SQL
}

record_evidence() {
  local scenario="$1"
  local peer_blocked="$2"
  local finalizer_json="$3"
  local order_id="$4"
  local blocking_hold_count clearance_decision order_status peer_sql

  blocking_hold_count="$(psql_cmd -Atq -c "
    SELECT count(*)::integer
    FROM public.finance_control_events h
    WHERE h.order_id = '${order_id}'
      AND h.control_kind = 'HOLD' AND h.decision = 'APPLIED' AND h.blocking
  ")"
  clearance_decision="$(psql_cmd -Atq -c "
    SELECT e.decision
    FROM public.finance_clearance_events e
    WHERE e.order_id = '${order_id}' AND e.clearance_type = 'DISPATCH'
    ORDER BY e.created_at DESC, e.id DESC LIMIT 1
  ")"
  order_status="$(psql_cmd -Atq -c "SELECT status FROM public.orders WHERE id = '${order_id}'")"
  peer_sql='false'
  [[ "$peer_blocked" == 't' ]] && peer_sql='true'

  psql_cmd <<SQL >/dev/null
INSERT INTO public.${evidence_table}(
  scenario, peer_blocked, finalizer_result, order_status, blocking_hold_count, clearance_decision
) VALUES (
  '${scenario}',
  ${peer_sql},
  '${finalizer_json}'::jsonb,
  '${order_status}',
  ${blocking_hold_count},
  '${clearance_decision}'
)
ON CONFLICT (scenario) DO UPDATE SET
  peer_blocked = EXCLUDED.peer_blocked,
  finalizer_result = EXCLUDED.finalizer_result,
  order_status = EXCLUDED.order_status,
  blocking_hold_count = EXCLUDED.blocking_hold_count,
  clearance_decision = EXCLUDED.clearance_decision,
  recorded_at = statement_timestamp();
SQL
}

init_coord_and_evidence() {
  psql_cmd <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS public.${coord_table}(
  id integer PRIMARY KEY,
  signal boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS public.${evidence_table}(
  scenario text PRIMARY KEY,
  peer_blocked boolean NOT NULL,
  finalizer_result jsonb NOT NULL,
  order_status text NOT NULL,
  blocking_hold_count integer NOT NULL,
  clearance_decision text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
TRUNCATE public.${coord_table};
TRUNCATE public.${evidence_table};
INSERT INTO public.${coord_table}(id, signal) VALUES
  (1, false),
  (2, false);
SQL
}

wait_for_peer_blocked() {
  local query="$1"
  local label="$2"
  local log_a="${3:-}"
  local log_b="${4:-}"
  local blocked='f'

  for _ in $(seq 1 100); do
    blocked="$(psql_cmd -Atq -c "$query")"
    [[ "$blocked" == 't' ]] && break
    sleep 0.05
  done
  [[ "$blocked" == 't' ]] || fail "${label} peer never blocked on eligibility lock (logs: ${log_a}; ${log_b})"
  echo "$blocked"
}

run_scenario_b_hold_first() {
  local order_id='d8020000-0000-0000-0000-000000000027'
  local hold_key='md0802-race-b-hold-key'
  local b_log="$coord_dir/scenario_b_hold.log"
  local a_log="$coord_dir/scenario_b_finalizer.log"
  local a_result="$coord_dir/scenario_b_result.json"
  local session_b_sql="$coord_dir/scenario_b_session_b.sql"
  local blocked_query="
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

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[B]: seeding fixture order ...0027'
  seed_order_fixture \
    "$order_id" 'TWO-SESSION-B' \
    'd8020000-0000-0000-0000-000000000037' \
    'd8020000-0000-0000-0000-000000000038' \
    'd8020000-0000-0000-0000-000000000039' \
    'd8020000-0000-0000-0000-00000000003a' \
    'd8020000-0000-0000-0000-00000000003b' \
    'd8020000-0000-0000-0000-00000000003c' \
    "$hold_key" \
    '027'

  psql_cmd -c "UPDATE public.${coord_table} SET signal = false WHERE id = 1;" >/dev/null

  cat >"$session_b_sql" <<SQL
\\set ON_ERROR_STOP 1
BEGIN;
SELECT public.lock_finance_dispatch_eligibility_v1('${order_id}'::uuid);
SELECT public.lock_finance_dispatch_eligibility_company_v1('d8020000-0000-0000-0000-000000000010'::uuid);
DO \$wait\$
BEGIN
  WHILE NOT (SELECT signal FROM public.${coord_table} WHERE id = 1) LOOP
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
  '${order_id}'::uuid,
  NULL,
  'ORDER',
  1000,
  'two-session B blocking hold during finalization',
  'md0802-race-b-hold-evidence',
  'md0802-race-b-hold-corr',
  '${hold_key}'
);
COMMIT;
SQL

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[B]: hold session acquires eligibility locks first'
  psql_cmd -f "$session_b_sql" >"$b_log" 2>&1 &
  local b_pid=$!

  local b_waiting='f'
  for _ in $(seq 1 100); do
    b_waiting="$(psql_cmd -Atq -c "
      SELECT EXISTS (
        SELECT 1 FROM pg_stat_activity bsa
        WHERE bsa.datname = current_database()
          AND bsa.pid <> pg_backend_pid()
          AND bsa.state = 'active'
          AND bsa.query ILIKE '%${coord_table}%'
      );
    ")"
    [[ "$b_waiting" == 't' ]] && break
    sleep 0.05
  done
  [[ "$b_waiting" == 't' ]] || fail "scenario B hold session did not reach eligibility wait boundary (log: $(cat "$b_log"))"

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[B]: finalizer session starts while hold holds locks'
  run_finalizer_once "$order_id" "$a_result" 2>"$a_log" &
  local a_pid=$!

  local peer_blocked
  peer_blocked="$(wait_for_peer_blocked "$blocked_query" 'scenario B finalizer' "$a_log" "$b_log")"

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[B]: finalizer blocked; hold commits blocking hold'
  psql_cmd -c "UPDATE public.${coord_table} SET signal = true WHERE id = 1;" >/dev/null

  wait "$b_pid" || fail "scenario B hold session failed (log: $(cat "$b_log"))"
  wait "$a_pid" || fail "scenario B finalizer session failed (log: $(cat "$a_log"))"
  [[ -s "$a_result" ]] || fail 'scenario B finalizer produced no result'

  local finalizer_json
  finalizer_json="$(tr -d '\n' <"$a_result" | sed -n 's/.*\({"ok".*\)/\1/p')"
  [[ -n "$finalizer_json" ]] || fail "scenario B finalizer result missing JSON payload: $(cat "$a_result")"
  echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE[B]: peer_blocked=${peer_blocked} result=${finalizer_json}"

  [[ "$finalizer_json" == *'"ok": false'* ]] || fail 'scenario B finalizer must reject dispatch'
  [[ "$finalizer_json" == *'FINANCE_BLOCKING_HOLD_ACTIVE'* ]] || fail 'scenario B must surface FINANCE_BLOCKING_HOLD_ACTIVE'

  assert_finance_state "$order_id" '1' 'cleared_for_dispatch'
  record_evidence 'hold_first' "$peer_blocked" "$finalizer_json" "$order_id"
  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[B]: PASS'
}

run_scenario_a_finalizer_holds_lock() {
  local order_id='d8020000-0000-0000-0000-000000000028'
  local hold_key='md0802-race-a-hold-key'
  local a_log="$coord_dir/scenario_a_finalizer.log"
  local b_log="$coord_dir/scenario_a_hold.log"
  local a_result="$coord_dir/scenario_a_result.json"
  local session_a_sql="$coord_dir/scenario_a_session_a.sql"
  local session_b_sql="$coord_dir/scenario_a_session_b.sql"
  local blocked_query="
    SELECT EXISTS (
      SELECT 1
      FROM pg_locks wl
      JOIN pg_stat_activity wsa ON wsa.pid = wl.pid
      WHERE wl.locktype = 'advisory'
        AND NOT wl.granted
        AND wsa.datname = current_database()
        AND wsa.query ILIKE '%apply_finance_hold_v1%'
    );
  "

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: seeding fixture order ...0028'
  seed_order_fixture \
    "$order_id" 'TWO-SESSION-A' \
    'd8020000-0000-0000-0000-000000000047' \
    'd8020000-0000-0000-0000-000000000048' \
    'd8020000-0000-0000-0000-000000000049' \
    'd8020000-0000-0000-0000-00000000004a' \
    'd8020000-0000-0000-0000-00000000004b' \
    'd8020000-0000-0000-0000-00000000004c' \
    "$hold_key" \
    '028'

  psql_cmd -c "UPDATE public.${coord_table} SET signal = false WHERE id = 2;" >/dev/null

  cat >"$session_a_sql" <<SQL
\\set ON_ERROR_STOP 1
BEGIN;
SELECT public.lock_finance_dispatch_eligibility_v1('${order_id}'::uuid);
SELECT public.lock_finance_dispatch_eligibility_company_v1('d8020000-0000-0000-0000-000000000010'::uuid);
DO \$wait\$
BEGIN
  WHILE NOT (SELECT signal FROM public.${coord_table} WHERE id = 2) LOOP
    PERFORM pg_sleep(0.02);
  END LOOP;
END;
\$wait\$;
ROLLBACK;
SQL

  cat >"$session_b_sql" <<SQL
\\set ON_ERROR_STOP 1
BEGIN;
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
  '${order_id}'::uuid,
  NULL,
  'ORDER',
  1000,
  'two-session A blocking hold while finalizer holds lock',
  'md0802-race-a-hold-evidence',
  'md0802-race-a-hold-corr',
  '${hold_key}'
);
COMMIT;
SQL

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: finalizer session holds eligibility locks'
  psql_cmd -f "$session_a_sql" >"$a_log" 2>&1 &
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
          AND asa.query ILIKE '%id = 2%'
      );
    ")"
    [[ "$a_waiting" == 't' ]] && break
    sleep 0.05
  done
  [[ "$a_waiting" == 't' ]] || fail "scenario A finalizer session did not reach eligibility wait boundary (log: $(cat "$a_log"))"

  assert_finance_state "$order_id" '0' 'cleared_for_dispatch'

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: hold session attempts commit while finalizer holds locks'
  psql_cmd -f "$session_b_sql" >"$b_log" 2>&1 &
  local b_pid=$!

  local peer_blocked
  peer_blocked="$(wait_for_peer_blocked "$blocked_query" 'scenario A hold' "$a_log" "$b_log")"

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: hold blocked; finalizer releases locks without dispatch'
  psql_cmd -c "UPDATE public.${coord_table} SET signal = true WHERE id = 2;" >/dev/null

  wait "$a_pid" || fail "scenario A finalizer session failed (log: $(cat "$a_log"))"
  wait "$b_pid" || fail "scenario A hold session failed (log: $(cat "$b_log"))"

  assert_finance_state "$order_id" '1' 'cleared_for_dispatch'

  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: post-hold finalization must fail closed'
  run_finalizer_once "$order_id" "$a_result"
  local finalizer_json
  finalizer_json="$(tr -d '\n' <"$a_result" | sed -n 's/.*\({"ok".*\)/\1/p')"
  [[ -n "$finalizer_json" ]] || fail "scenario A finalizer result missing JSON payload: $(cat "$a_result")"
  echo "DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: peer_blocked=${peer_blocked} result=${finalizer_json}"

  [[ "$finalizer_json" == *'"ok": false'* ]] || fail 'scenario A post-hold finalizer must reject dispatch'
  [[ "$finalizer_json" == *'FINANCE_BLOCKING_HOLD_ACTIVE'* ]] || fail 'scenario A must surface FINANCE_BLOCKING_HOLD_ACTIVE'

  assert_finance_state "$order_id" '1' 'cleared_for_dispatch'
  record_evidence 'finalizer_holds_lock' "$peer_blocked" "$finalizer_json" "$order_id"
  echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE[A]: PASS'
}

init_coord_and_evidence
run_scenario_b_hold_first
run_scenario_a_finalizer_holds_lock

echo 'DISPATCH_FINALIZATION_TWO_SESSION_RACE: PASS (scenarios A and B)'
