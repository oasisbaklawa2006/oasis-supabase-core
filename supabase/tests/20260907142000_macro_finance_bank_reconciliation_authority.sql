-- Contract for migration 20260907142000_macro_finance_bank_reconciliation_authority.sql.

select plan(39);

select has_table('public', 'bank_settlement_import_batches', 'bank settlement import batches exist');
select has_table('public', 'bank_settlement_transactions', 'bank settlement transactions exist');
select has_table('public', 'bank_reconciliation_matches', 'bank reconciliation matches exist');
select has_table('public', 'bank_reconciliation_cases', 'bank reconciliation cases exist');
select has_table('public', 'bank_reconciliation_case_events', 'bank reconciliation case events exist');
select has_table('public', 'bank_reconciliation_idempotency', 'bank reconciliation idempotency exists');

select has_function('public', 'import_bank_settlement_batch_v1', array['text','text','jsonb','text','text','uuid'], 'import batch RPC exists');
select has_function('public', 'auto_match_bank_settlement_batch_v1', array['uuid','text','text','uuid'], 'auto match RPC exists');
select has_function('public', 'resolve_bank_reconciliation_case_v1', array['uuid','text','text','uuid','text','text','text','uuid'], 'resolve case RPC exists');
select has_function('public', 'get_bank_reconciliation_summary_v1', array['uuid'], 'reconciliation summary RPC exists');
select has_function('public', 'get_bank_reconciliation_tally_projection_v1', array['uuid'], 'tally projection RPC exists');

select ok(not has_table_privilege('authenticated', 'public.bank_settlement_transactions', 'INSERT'), 'no direct bank transaction insert');
select ok(not has_table_privilege('authenticated', 'public.bank_reconciliation_matches', 'INSERT'), 'no direct reconciliation match insert');
select ok(not has_table_privilege('service_role', 'public.bank_settlement_import_batches', 'INSERT'), 'service role cannot direct-write import batches');

select ok(pg_get_functiondef('public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'import requires Finance+AAL2');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'auto match requires Finance+AAL2');
select ok(pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'case resolution requires Finance+AAL2');
select ok(pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%BANK_RECONCILIATION_MAKER_CHECKER%', 'sensitive case resolution enforces maker-checker');

select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%ambiguous%', 'auto match opens ambiguous cases instead of forcing matches');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%order_payments%', 'auto match uses canonical order_payments truth');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%UTR_EXACT%', 'auto match supports UTR exact rule');
select ok(not has_function_privilege('service_role', 'public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)', 'EXECUTE'), 'service role cannot import bank batches');

select ok(pg_get_functiondef('public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)'::regprocedure) like '%BANK_SETTLEMENT_IMPORT_IDEMPOTENCY_CONFLICT%', 'import is idempotent');
select ok(pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%BANK_RECONCILIATION_MATCH_IDEMPOTENCY_CONFLICT%', 'auto match is idempotent');
select ok(pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%BANK_RECONCILIATION_CASE_TERMINAL%', 'terminal cases reject stale replay');

select ok(pg_get_functiondef('public.prevent_bank_reconciliation_mutation()'::regprocedure) like '%BANK_RECONCILIATION_APPEND_ONLY%', 'matches and case events are append-only');
select ok(pg_get_functiondef('public.get_bank_reconciliation_summary_v1(uuid)'::regprocedure) like '%BANK_RECONCILIATION_SUMMARY_INTERNAL_ONLY%', 'summary is internal-only');
select ok(pg_get_functiondef('public.get_bank_reconciliation_tally_projection_v1(uuid)'::regprocedure) like '%duplicate_gl%', 'tally projection declares no duplicate GL');
select ok(pg_get_functiondef('public.get_bank_reconciliation_tally_projection_v1(uuid)'::regprocedure) like '%tally_projection_only%', 'tally projection is facts-only');

select ok(has_function_privilege('authenticated', 'public.get_bank_reconciliation_summary_v1(uuid)', 'EXECUTE'), 'authenticated internal actor can read summary');
select ok(not has_function_privilege('service_role', 'public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)', 'EXECUTE'), 'service role cannot resolve reconciliation cases');

select ok(
  (select count(*) = 1 from pg_indexes where schemaname = 'public' and indexname = 'bank_reconciliation_matches_transaction_uidx'),
  'one match per transaction is enforced'
);
select ok(
  (select count(*) = 1 from pg_indexes where schemaname = 'public' and indexname = 'bank_reconciliation_matches_target_uidx'),
  'one match per canonical target is enforced'
);
select ok(
  pg_get_functiondef('public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)'::regprocedure) like '%ON CONFLICT (normalized_fingerprint)%',
  'import dedupes settlement transactions by normalized fingerprint'
);
select ok(
  pg_get_functiondef('public.import_bank_settlement_batch_v1(text,text,jsonb,text,text,uuid)'::regprocedure) like '%case_type = ''duplicate''%',
  'duplicate settlement replay opens governed duplicate case'
);
select ok(
  pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%company_id = v_tx.company_id%',
  'auto match constrains candidate lookup by company'
);
select ok(
  pg_get_functiondef('public.auto_match_bank_settlement_batch_v1(uuid,text,text,uuid)'::regprocedure) like '%v_tx.direction <> ''credit''%',
  'auto match rejects non-receipt lines from canonical payment matching'
);
select ok(
  pg_get_functiondef('public.resolve_bank_reconciliation_case_v1(uuid,text,text,uuid,text,text,text,uuid)'::regprocedure) like '%v_target_type text := lower(btrim(coalesce(p_match_target_type%',
  'manual match normalizes target type to lowercase'
);

select lives_ok($macro_bank$
DO $bank$
DECLARE
  v_staff uuid := '9f790000-0000-0000-0000-000000000001';
  v_staff2 uuid := '9f790000-0000-0000-0000-000000000002';
  v_company uuid := '9f790000-0000-0000-0000-000000000010';
  v_payment uuid := '9f790000-0000-0000-0000-000000000020';
  v_payment2 uuid := '9f790000-0000-0000-0000-000000000021';
  v_payment3 uuid := '9f790000-0000-0000-0000-000000000022';
  v_order uuid := '9f790000-0000-0000-0000-000000000030';
  v_batch uuid;
  v_batch2 uuid;
  v_batch3 uuid;
  v_tx uuid;
  v_case uuid;
  v_matched integer;
  v_imported integer;
  v_already boolean;
  v_rows jsonb := jsonb_build_array(jsonb_build_object(
    'transaction_date', current_date,
    'direction', 'credit',
    'amount', 5000,
    'currency', 'INR',
    'company_id', '9f790000-0000-0000-0000-000000000010',
    'utr', 'UTR-MF-BANK-1'
  ));
  v_rows2 jsonb := jsonb_build_array(jsonb_build_object(
    'transaction_date', current_date,
    'direction', 'credit',
    'amount', 5000,
    'currency', 'INR',
    'company_id', '9f790000-0000-0000-0000-000000000010',
    'utr', 'UTR-MF-BANK-2'
  ));
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES
    (v_staff, 'macro-bank-staff@test.invalid'),
    (v_staff2, 'macro-bank-staff2@test.invalid')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_staff, 'FINANCE_EXEC', 'Macro Bank Staff', true),
    (v_staff2, 'FINANCE_EXEC', 'Macro Bank Staff 2', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'Macro Bank Co', 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
  VALUES (v_order, v_company, 'BK-ORD-1', 'MANUAL', 'bk-ord-1-token', 50000, 15000, 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.order_payments(
    id, order_id, company_id, payment_type, amount, reference_no, created_by, status, currency
  ) VALUES (
    v_payment, v_order, v_company, 'advance', 5000, 'UTR-MF-BANK-1', v_staff, 'uploaded', 'INR'
  ) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.order_payments(
    id, order_id, company_id, payment_type, amount, reference_no, created_by, status, currency
  ) VALUES (
    v_payment2, v_order, v_company, 'advance', 5000, 'UTR-MF-BANK-2', v_staff, 'uploaded', 'INR'
  ) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.order_payments(
    id, order_id, company_id, payment_type, amount, reference_no, created_by, status, currency
  ) VALUES (
    v_payment3, v_order, v_company, 'advance', 5000, 'UTR-MF-BANK-3', v_staff, 'uploaded', 'INR'
  ) ON CONFLICT (id) DO NOTHING;
  set local session_replication_role = default;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  SELECT batch_id, imported_count, already_imported INTO v_batch, v_imported, v_already
    FROM public.import_bank_settlement_batch_v1('file', 'bank-fixture-1', v_rows, 'corr', 'bank-import-1', v_staff);
  IF v_imported <> 1 OR v_already THEN RAISE EXCEPTION 'BANK_IMPORT_FAILED'; END IF;
  SELECT matched_count INTO v_matched
    FROM public.auto_match_bank_settlement_batch_v1(v_batch, 'corr', 'bank-match-1', v_staff);
  IF v_matched <> 1 THEN RAISE EXCEPTION 'BANK_AUTO_MATCH_FAILED'; END IF;
  SELECT batch_id, imported_count INTO v_batch2, v_imported
    FROM public.import_bank_settlement_batch_v1('file', 'bank-fixture-3', v_rows2, 'corr', 'bank-import-3', v_staff);
  IF v_imported <> 1 THEN RAISE EXCEPTION 'BANK_SECOND_IMPORT_FAILED'; END IF;
  SELECT matched_count INTO v_matched
    FROM public.auto_match_bank_settlement_batch_v1(v_batch2, 'corr', 'bank-match-2', v_staff);
  IF v_matched <> 1 THEN RAISE EXCEPTION 'BANK_SECOND_AUTO_MATCH_FAILED'; END IF;
  SELECT batch_id, imported_count INTO v_batch3, v_imported
    FROM public.import_bank_settlement_batch_v1('file', 'bank-fixture-4', jsonb_build_array(jsonb_build_object(
      'transaction_date', current_date, 'direction', 'credit', 'amount', 5000, 'currency', 'INR',
      'company_id', v_company::text, 'utr', 'UTR-MF-BANK-3'
    )), 'corr', 'bank-import-4', v_staff);
  IF v_imported <> 1 THEN RAISE EXCEPTION 'BANK_THIRD_IMPORT_FAILED'; END IF;
  set local role postgres;
  SELECT id INTO v_tx
    FROM public.bank_settlement_transactions t
   WHERE t.batch_id = v_batch3
   ORDER BY t.created_at DESC
   LIMIT 1;
  IF v_tx IS NULL THEN RAISE EXCEPTION 'BANK_THIRD_TX_MISSING'; END IF;
  INSERT INTO public.bank_reconciliation_cases(
    transaction_id, company_id, case_type, status, amount_delta, reason,
    opened_by, opened_role, correlation_id, idempotency_key
  ) VALUES (
    v_tx, v_company, 'unmatched', 'open', NULL, 'Manual match normalization probe case',
    v_staff, 'FINANCE_EXEC', 'corr', 'bank-manual-case-seed'
  ) RETURNING id INTO v_case;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  PERFORM public.resolve_bank_reconciliation_case_v1(
    v_case, 'MATCH', 'ORDER_PAYMENT', v_payment3, 'manual match probe', 'corr', 'bank-resolve-1', v_staff2
  );
  set local role postgres;
  IF NOT EXISTS (
    SELECT 1 FROM public.bank_reconciliation_matches m
     WHERE m.transaction_id = v_tx AND m.match_target_id = v_payment3 AND m.match_target_type = 'order_payment'
  ) THEN
    RAISE EXCEPTION 'BANK_MANUAL_MATCH_FAILED';
  END IF;
END;
$bank$;
$macro_bank$, 'bank import dedupe, auto-match, and lowercase manual match behave correctly');

select * from finish();
