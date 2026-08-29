-- PF-6B contract coverage for migration 20260830100000_pre_factory_credit_wallet_authority:
-- canonical wallet, governed credit and factual exposure.

select plan(46);

select has_table('public', 'wallet_opening_balance_evidence', 'wallet opening evidence exists');
select has_table('public', 'wallet_authority_idempotency', 'wallet idempotency ledger exists');
select has_table('public', 'wallet_mutation_scopes', 'wallet mutation scopes exist');
select has_table('public', 'credit_request_mutation_scopes', 'credit request mutation scopes exist');
select has_table('public', 'credit_decision_audit', 'credit decision audit exists');
select has_table('public', 'credit_authority_idempotency', 'credit idempotency ledger exists');
select has_function('public', 'record_wallet_entry_v1', array['uuid','text','numeric','text','uuid','uuid','uuid','text','text','text','text','text','uuid'], 'wallet RPC exists');
select has_function('public', 'get_wallet_balance_v1', array['uuid'], 'wallet balance projection helper exists');
select has_function('public', 'request_credit_authority_v1', array['uuid','uuid','uuid','uuid','text','numeric','text','text','text','text','text','timestamp with time zone','uuid'], 'credit request RPC exists');
select has_function('public', 'decide_credit_request_v1', array['uuid','boolean','text','text','text','text','uuid'], 'credit decision RPC exists');
select has_function('public', 'get_credit_exposure_facts_v1', array['uuid','uuid','uuid'], 'factual exposure RPC exists');

select ok((select relrowsecurity from pg_class where oid = 'public.wallet_opening_balance_evidence'::regclass), 'opening evidence RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.wallet_authority_idempotency'::regclass), 'wallet idempotency RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.credit_requests'::regclass), 'credit request RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.credit_decision_audit'::regclass), 'credit audit RLS enabled');
select ok(not has_table_privilege('authenticated', 'public.wallet_transactions', 'INSERT'), 'authenticated cannot directly insert wallet ledger');
select ok(not has_table_privilege('authenticated', 'public.wallet_transactions', 'UPDATE'), 'authenticated cannot directly update wallet ledger');
select ok(not has_table_privilege('authenticated', 'public.credit_requests', 'INSERT'), 'authenticated cannot directly insert credit requests');
select ok(not has_table_privilege('authenticated', 'public.credit_requests', 'UPDATE'), 'authenticated cannot directly update credit requests');
select ok(not has_table_privilege('service_role', 'public.wallet_authority_idempotency', 'INSERT'), 'service_role cannot directly write wallet idempotency');
select ok(not has_table_privilege('service_role', 'public.credit_decision_audit', 'INSERT'), 'service_role cannot directly write credit audit');
select ok(has_function_privilege('authenticated', 'public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid)', 'EXECUTE'), 'authenticated wallet RPC grant');
select ok(has_function_privilege('authenticated', 'public.request_credit_authority_v1(uuid,uuid,uuid,uuid,text,numeric,text,text,text,text,text,timestamp with time zone,uuid)', 'EXECUTE'), 'authenticated credit request grant');
select ok(has_function_privilege('authenticated', 'public.decide_credit_request_v1(uuid,boolean,text,text,text,text,uuid)', 'EXECUTE'), 'authenticated credit decision grant');
select ok(not has_function_privilege('service_role', 'public.decide_credit_request_v1(uuid,boolean,text,text,text,text,uuid)', 'EXECUTE'), 'service_role cannot impersonate credit approver');

select ok(pg_get_functiondef('public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid)'::regprocedure) like '%pg_advisory_xact_lock%', 'wallet entry is serialized');
select ok(pg_get_functiondef('public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid)'::regprocedure) like '%WALLET_INSUFFICIENT_BALANCE%', 'wallet debit cannot overspend');
select ok(pg_get_functiondef('public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid)'::regprocedure) like '%WALLET_IDEMPOTENCY_CONFLICT%', 'wallet retry conflicts are actor/request bound');
select ok(pg_get_functiondef('public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid)'::regprocedure) like '%WALLET_SOURCE_DUPLICATE_CONFLICT%', 'duplicate wallet source events cannot create a second commitment');
select ok(pg_get_functiondef('public.prevent_wallet_transaction_mutation()'::regprocedure) like '%WALLET_LEDGER_APPEND_ONLY%', 'wallet ledger is append-only');
select ok(pg_get_functiondef('public.refresh_wallet_balance_projection()'::regprocedure) like '%WALLET_OPENING_BALANCE_UNRECONCILED%', 'wallet projection fails closed without opening evidence');
select ok(pg_get_functiondef('public.refresh_wallet_balance_projection()'::regprocedure) like '%wallet_balance + v_delta%', 'wallet projection is incremental and O(1)');
select ok(pg_get_functiondef('public.get_wallet_balance_v1(uuid)'::regprocedure) like '%WALLET_COMPANY_SCOPE_REQUIRED%', 'wallet balance helper enforces company scope');
select ok(pg_get_functiondef('public.request_credit_authority_v1(uuid,uuid,uuid,uuid,text,numeric,text,text,text,text,text,timestamp with time zone,uuid)'::regprocedure) like '%CREDIT_COMMERCIAL_BINDING_MISMATCH%', 'credit request binds exact SO version');
select ok(pg_get_functiondef('public.request_credit_authority_v1(uuid,uuid,uuid,uuid,text,numeric,text,text,text,text,text,timestamp with time zone,uuid)'::regprocedure) like '%CREDIT_REQUEST_EXCEEDS_REMAINING_SO_VALUE%', 'short-term request cannot exceed remaining SO value');
select ok(pg_get_functiondef('public.request_credit_authority_v1(uuid,uuid,uuid,uuid,text,numeric,text,text,text,text,text,timestamp with time zone,uuid)'::regprocedure) like '%CREDIT_SOURCE_DUPLICATE_CONFLICT%', 'duplicate credit source events cannot create a second request');
select ok(pg_get_functiondef('public.assert_credit_actor_v1(uuid,text)'::regprocedure) like '%CREDIT_AAL2_REQUIRED%', 'credit decisions require AAL2');
select ok(pg_get_functiondef('public.assert_credit_actor_v1(uuid,text)'::regprocedure) like '%CREDIT_MANAGEMENT_AUTHORITY_REQUIRED%', 'long-term decisions require established management roles');
select ok(pg_get_functiondef('public.decide_credit_request_v1(uuid,boolean,text,text,text,text,uuid)'::regprocedure) like '%assert_credit_actor_v1%', 'decision RPC delegates actor authority to the shared helper');
select ok(pg_get_functiondef('public.get_credit_exposure_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%get_order_payment_facts_v1%', 'exposure uses canonical PF-6A payment facts');
select ok(pg_get_functiondef('public.get_credit_exposure_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%frozen_commercial_snapshot%', 'exposure uses frozen PI commercial truth');
select ok(pg_get_functiondef('public.get_credit_exposure_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%exposure_facts_only%', 'exposure is facts-only and not clearance');
select ok(pg_get_functiondef('public.get_credit_exposure_facts_v1(uuid,uuid,uuid)'::regprocedure) not like '%finance_clear%', 'exposure does not grant Finance clearance');
select ok(pg_get_functiondef('public.get_credit_exposure_facts_v1(uuid,uuid,uuid)'::regprocedure) not like '%production%', 'PF-6B does not grant production authority');
select ok(pg_get_functiondef('public.prevent_credit_audit_mutation()'::regprocedure) like '%CREDIT_DECISION_AUDIT_IMMUTABLE%', 'credit decision history is append-only');

select lives_ok($pf6b_runtime$
DO $pf6b$
DECLARE
  v_actor uuid := '96000000-0000-0000-0000-000000000001';
  v_company uuid := '96000000-0000-0000-0000-000000000002';
  v_entry uuid;
  v_retry uuid;
  v_balance numeric;
  v_already boolean;
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES (v_actor, 'pf6b-wallet@test.invalid') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES (v_actor, 'FINANCE_EXEC', 'PF6B Finance', true)
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  set local session_replication_role = default;
  INSERT INTO public.companies(id, business_name, status, wallet_balance) VALUES (v_company, 'PF6B Wallet Co', 'active', 0)
    ON CONFLICT (id) DO NOTHING;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  SELECT entry_id, balance, already_applied INTO v_entry, v_balance, v_already
    FROM public.record_wallet_entry_v1(v_company, 'credit', 1000, 'INR', NULL, NULL, NULL, 'PF6B_TEST', 'runtime:wallet:1', 'test credit', 'pf6b:wallet:1', 'pf6b-wallet-1', v_actor);
  IF v_balance <> 1000 OR v_already THEN RAISE EXCEPTION 'PF6B_WALLET_CREDIT_FAILED'; END IF;
  SELECT entry_id, balance, already_applied INTO v_retry, v_balance, v_already
    FROM public.record_wallet_entry_v1(v_company, 'credit', 1000, 'INR', NULL, NULL, NULL, 'PF6B_TEST', 'runtime:wallet:1', 'test credit', 'pf6b:wallet:1', 'pf6b-wallet-retry', v_actor);
  IF v_retry IS DISTINCT FROM v_entry OR v_balance <> 1000 OR NOT v_already THEN RAISE EXCEPTION 'PF6B_WALLET_RETRY_FAILED'; END IF;
  SELECT balance INTO v_balance FROM public.record_wallet_entry_v1(v_company, 'debit', 400, 'INR', NULL, NULL, NULL, 'PF6B_TEST', 'runtime:wallet:2', 'test debit', 'pf6b:wallet:2', 'pf6b-wallet-2', v_actor);
  IF v_balance <> 600 THEN RAISE EXCEPTION 'PF6B_WALLET_PROJECTION_FAILED'; END IF;
  BEGIN
    PERFORM public.record_wallet_entry_v1(v_company, 'debit', 700, 'INR', NULL, NULL, NULL, 'PF6B_TEST', 'runtime:wallet:3', 'overspend', 'pf6b:wallet:3', 'pf6b-wallet-3', v_actor);
    RAISE EXCEPTION 'PF6B_WALLET_OVERSPEND_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '55000' THEN NULL;
  END;
  BEGIN
    UPDATE public.wallet_transactions SET amount = 999 WHERE id = v_entry;
    RAISE EXCEPTION 'PF6B_WALLET_UPDATE_NOT_REJECTED';
  EXCEPTION WHEN insufficient_privilege OR sqlstate '42501' THEN NULL;
  END;
  BEGIN
    DELETE FROM public.wallet_transactions WHERE id = v_entry;
    RAISE EXCEPTION 'PF6B_WALLET_DELETE_NOT_REJECTED';
  EXCEPTION WHEN insufficient_privilege OR sqlstate '42501' THEN NULL;
  END;
END;
$pf6b$;
$pf6b_runtime$, 'wallet credit, idempotent retry, projection and overspend rejection execute behaviorally');
