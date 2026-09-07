-- Contract for migration 20260907140000_macro_finance_runtime_authority.sql.

select plan(71);

-- Tables and views
select has_table('public', 'ledger_dispute_events', 'ledger dispute event ledger exists');
select has_table('public', 'ledger_dispute_mutation_scopes', 'ledger dispute mutation scopes exist');
select has_table('public', 'finance_control_events', 'finance control event ledger exists');
select has_table('public', 'finance_control_idempotency', 'finance control idempotency ledger exists');
select has_view('public', 'ledger_dispute_authority_v1', 'ledger dispute authority projection exists');
select has_view('public', 'finance_control_authority_v1', 'finance control authority projection exists');

-- RPC existence
select has_function('public', 'finance_ageing_bucket_v1', array['integer'], 'ageing bucket helper exists');
select has_function('public', 'raise_ledger_dispute_v1', array['uuid','text','jsonb','text','text','text','uuid'], 'raise ledger dispute RPC exists');
select has_function('public', 'transition_ledger_dispute_v1', array['uuid','text','text','jsonb','text','text','uuid'], 'transition ledger dispute RPC exists');
select has_function('public', 'apply_finance_hold_v1', array['uuid','uuid','uuid','text','numeric','text','text','text','text','uuid'], 'apply finance hold RPC exists');
select has_function('public', 'release_finance_hold_v1', array['uuid','text','text','text','text','uuid'], 'release finance hold RPC exists');
select has_function('public', 'reverse_finance_control_v1', array['uuid','text','text','text','text','uuid'], 'reverse finance control RPC exists');
select has_function('public', 'decide_finance_second_approval_v1', array['uuid','boolean','text','text','text','text','uuid'], 'second approval RPC exists');
select has_function('public', 'assert_no_blocking_finance_hold_v1', array['uuid'], 'blocking hold guard exists');
select has_function('public', 'apply_finance_adjustment_v1', array['uuid','text','numeric','text','text','text','text','text','text','uuid'], 'finance adjustment RPC exists');
select has_function('public', 'get_company_ar_ageing_facts_v1', array['uuid'], 'company AR ageing facts RPC exists');
select has_function('public', 'get_portfolio_exposure_facts_v1', array['uuid'], 'portfolio exposure facts RPC exists');
select has_function('public', 'get_finance_control_projection_v1', array['uuid','uuid'], 'finance control projection RPC exists');

-- Direct-write denial
select ok(not has_table_privilege('authenticated', 'public.ledger_disputes', 'INSERT'), 'authenticated cannot directly insert ledger disputes');
select ok(not has_table_privilege('authenticated', 'public.ledger_disputes', 'UPDATE'), 'authenticated cannot directly update ledger disputes');
select ok(not has_table_privilege('authenticated', 'public.commercial_adjustments', 'INSERT'), 'authenticated cannot directly insert commercial adjustments');
select ok(not has_table_privilege('authenticated', 'public.finance_control_events', 'INSERT'), 'authenticated cannot directly insert finance control events');
select ok(not has_table_privilege('service_role', 'public.finance_control_events', 'INSERT'), 'service role cannot impersonate finance control writes');

-- Authorization / AAL2 / maker-checker
select ok(pg_get_functiondef('public.apply_finance_hold_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'finance hold requires Finance+AAL2');
select ok(pg_get_functiondef('public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'finance adjustment requires Finance+AAL2');
select ok(pg_get_functiondef('public.transition_ledger_dispute_v1(uuid,text,text,jsonb,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'terminal ledger dispute transition requires Finance+AAL2');
select ok(pg_get_functiondef('public.decide_finance_second_approval_v1(uuid,boolean,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_SECOND_APPROVAL_MAKER_CHECKER%', 'second approval enforces maker-checker');
select ok(pg_get_functiondef('public.decide_finance_second_approval_v1(uuid,boolean,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%', 'second approval requires Finance+AAL2');

-- Company isolation
select ok(pg_get_functiondef('public.get_company_ar_ageing_facts_v1(uuid)'::regprocedure) like '%AR_AGEING_COMPANY_SCOPE_REQUIRED%', 'AR ageing enforces company scope');
select ok(pg_get_functiondef('public.get_portfolio_exposure_facts_v1(uuid)'::regprocedure) like '%PORTFOLIO_EXPOSURE_INTERNAL_ONLY%', 'portfolio exposure is internal-only');
select ok(pg_get_functiondef('public.get_finance_control_projection_v1(uuid,uuid)'::regprocedure) like '%FINANCE_CONTROL_PROJECTION_INTERNAL_ONLY%', 'finance projection is internal-only');
select ok(pg_get_functiondef('public.raise_ledger_dispute_v1(uuid,text,jsonb,text,text,text,uuid)'::regprocedure) like '%LEDGER_DISPUTE_COMPANY_SCOPE_REQUIRED%', 'ledger dispute raise enforces company scope');

-- Amount arithmetic / ageing boundaries
select is(public.finance_ageing_bucket_v1(0), 'CURRENT', 'age 0 is CURRENT');
select is(public.finance_ageing_bucket_v1(-3), 'CURRENT', 'negative age is CURRENT');
select is(public.finance_ageing_bucket_v1(15), '1-30', 'age 15 is 1-30 bucket');
select is(public.finance_ageing_bucket_v1(45), '31-60', 'age 45 is 31-60 bucket');
select is(public.finance_ageing_bucket_v1(75), '61-90', 'age 75 is 61-90 bucket');
select is(public.finance_ageing_bucket_v1(120), '90+', 'age 120 is 90+ bucket');
select ok(pg_get_functiondef('public.get_company_ar_ageing_facts_v1(uuid)'::regprocedure) like '%get_final_settlement_facts_v1%', 'AR ageing derives from settlement facts');
select ok(pg_get_functiondef('public.get_company_ar_ageing_facts_v1(uuid)'::regprocedure) like '%commercial_adjustments%', 'AR ageing includes adjustment arithmetic');
select ok(pg_get_functiondef('public.get_company_ar_ageing_facts_v1(uuid)'::regprocedure) like '%ar_ageing_facts_only%', 'AR ageing is facts-only');

-- Idempotency
select ok(pg_get_functiondef('public.raise_ledger_dispute_v1(uuid,text,jsonb,text,text,text,uuid)'::regprocedure) like '%LEDGER_DISPUTE_IDEMPOTENCY_CONFLICT%', 'ledger dispute raise is idempotent');
select ok(pg_get_functiondef('public.apply_finance_hold_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_HOLD_IDEMPOTENCY_CONFLICT%', 'finance hold is idempotent');
select ok(pg_get_functiondef('public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_ADJUSTMENT_IDEMPOTENCY_CONFLICT%', 'finance adjustment is idempotent');

-- Stale / terminal transitions
select ok(pg_get_functiondef('public.transition_ledger_dispute_v1(uuid,text,text,jsonb,text,text,uuid)'::regprocedure) like '%LEDGER_DISPUTE_TERMINAL_STATE%', 'ledger dispute rejects terminal replay');
select ok(pg_get_functiondef('public.release_finance_hold_v1(uuid,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_HOLD_ALREADY_RELEASED%', 'finance hold release rejects stale replay');
select ok(pg_get_functiondef('public.reverse_finance_control_v1(uuid,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_CONTROL_ALREADY_REVERSED%', 'finance control reversal rejects stale replay');

-- Adjustment reuse (no duplicate tables)
select ok(pg_get_functiondef('public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%commercial_adjustments%', 'finance adjustment reuses commercial_adjustments');
select ok(pg_get_functiondef('public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DIRECT%', 'finance adjustment tags non-complaint source');
select ok(pg_get_functiondef('public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) not like '%resolve_commercial_complaint_v1%', 'finance adjustment is separate from complaint remedy');

-- Dispatch-hold integration
select ok(pg_get_functiondef('public.assert_active_dispatch_clearance_v1(uuid)'::regprocedure) like '%assert_no_blocking_finance_hold_v1%', 'dispatch clearance guard checks blocking finance holds');
select ok(pg_get_functiondef('public.assert_no_blocking_finance_hold_v1(uuid)'::regprocedure) like '%FINANCE_BLOCKING_HOLD_ACTIVE%', 'blocking hold guard fails closed');
select ok((select definition from pg_views where schemaname='public' and viewname='finance_control_authority_v1') like '%finance_control_event_has_active_neutralizer_v1%', 'finance control projection excludes released holds');

-- Portfolio exposure reuse
select ok(pg_get_functiondef('public.get_portfolio_exposure_facts_v1(uuid)'::regprocedure) like '%get_company_ar_ageing_facts_v1%', 'portfolio exposure aggregates AR ageing');
select ok(pg_get_functiondef('public.get_portfolio_exposure_facts_v1(uuid)'::regprocedure) like '%get_wallet_balance_v1%', 'portfolio exposure includes wallet facts');
select ok(pg_get_functiondef('public.get_portfolio_exposure_facts_v1(uuid)'::regprocedure) like '%credit_requests%', 'portfolio exposure includes approved credit');
select ok(pg_get_functiondef('public.get_portfolio_exposure_facts_v1(uuid)'::regprocedure) like '%exposure_facts_only%', 'portfolio exposure is facts-only');
select ok(pg_get_functiondef('public.get_portfolio_exposure_facts_v1(uuid)'::regprocedure) like '%clearance_decision%', 'portfolio exposure does not grant clearance');

-- Append-only guards
select ok(pg_get_functiondef('public.prevent_ledger_dispute_direct_write()'::regprocedure) like '%LEDGER_DISPUTE_GOVERNED_WRITE_REQUIRED%', 'ledger disputes require governed writes');
select ok(pg_get_functiondef('public.prevent_finance_control_event_mutation()'::regprocedure) like '%FINANCE_CONTROL_EVENTS_APPEND_ONLY%', 'finance control events are append-only');

-- Privilege hardening
select ok(not has_function_privilege('service_role', 'public.apply_finance_hold_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,uuid)', 'EXECUTE'), 'service role cannot apply finance holds');
select ok(not has_function_privilege('service_role', 'public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)', 'EXECUTE'), 'service role cannot apply finance adjustments');
select ok(has_function_privilege('authenticated', 'public.get_company_ar_ageing_facts_v1(uuid)', 'EXECUTE'), 'authenticated can read AR ageing facts');

-- RLS readability for dispute event chain
select ok(
  (select count(*) >= 2 from pg_policies where schemaname = 'public' and tablename = 'ledger_dispute_events'),
  'ledger_dispute_events has buyer and staff read policies'
);
select ok(
  (select count(*) >= 2 from pg_policies where schemaname = 'public' and tablename = 'ledger_disputes' and cmd = 'SELECT'),
  'ledger_disputes has explicit staff and buyer read policies'
);
select ok(
  pg_get_functiondef('public.finance_control_event_has_active_neutralizer_v1(uuid,integer)'::regprocedure) like '%REVERSAL%',
  'finance hold neutralizer resolves release and reversal chains'
);
select ok(
  pg_get_functiondef('public.get_company_ar_ageing_facts_v1(uuid)'::regprocedure) like '%+ v_refunds%',
  'AR ageing adds refunds to open receivable arithmetic'
);
select ok(
  pg_get_functiondef('public.get_company_ar_ageing_facts_v1(uuid)'::regprocedure) like '%bi_monthly_ledgers%',
  'ledger dispute state is scoped to invoice ledger period'
);
select ok(
  pg_get_functiondef('public.apply_finance_hold_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_HOLD_ORDER_COMPANY_MISMATCH%',
  'finance hold validates order tenant binding'
);
select ok(
  pg_get_functiondef('public.transition_ledger_dispute_v1(uuid,text,text,jsonb,text,text,uuid)'::regprocedure) like '%FOR UPDATE%',
  'ledger dispute transition locks dispute row'
);

select lives_ok($macro_finance_runtime$
DO $macro$
DECLARE
  v_staff uuid := '9f770000-0000-0000-0000-000000000001';
  v_staff2 uuid := '9f770000-0000-0000-0000-000000000002';
  v_company uuid := '9f770000-0000-0000-0000-000000000010';
  v_order uuid := '9f770000-0000-0000-0000-000000000020';
  v_bad_order uuid := '9f770000-0000-0000-0000-000000000021';
  v_ledger uuid := '9f770000-0000-0000-0000-000000000030';
  v_hold uuid;
  v_applied uuid;
  v_release uuid;
  v_reversal uuid;
  v_status text;
BEGIN
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES
    (v_staff, 'macro-finance-staff@test.invalid'),
    (v_staff2, 'macro-finance-staff2@test.invalid')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES
    (v_staff, 'FINANCE_EXEC', 'Macro Finance Staff', true),
    (v_staff2, 'FINANCE_EXEC', 'Macro Finance Staff 2', true)
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'Macro Finance Co', 'active')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
  VALUES (v_order, v_company, 'MF-ORD-1', 'MANUAL', 'mf-ord-1-token', 100000, 30000, 'active')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
  VALUES (v_bad_order, v_company, 'MF-ORD-2', 'MANUAL', 'mf-ord-2-token', 50000, 15000, 'active')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.bi_monthly_ledgers(id, company_id, period_start, period_end, total_amount, order_count, status)
  VALUES (v_ledger, v_company, current_date - 15, current_date + 15, 100000, 1, 'sent')
  ON CONFLICT (id) DO NOTHING;
  set local session_replication_role = default;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  BEGIN
    PERFORM public.apply_finance_hold_v1('9f770000-0000-0000-0000-000000000099', v_order, NULL, 'ORDER', 1000, 'tenant mismatch probe', 'evidence', 'corr', 'mf-hold-bad', v_staff);
    RAISE EXCEPTION 'MF_HOLD_TENANT_MISMATCH_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '42501' THEN NULL;
  END;
  SELECT control_event_id INTO v_hold
    FROM public.apply_finance_hold_v1(v_company, v_order, NULL, 'ORDER', 150000, 'large hold probe', 'evidence', 'corr', 'mf-hold-pending', v_staff);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  SELECT control_event_id INTO v_applied
    FROM public.decide_finance_second_approval_v1(v_hold, true, 'approve large hold', 'evidence', 'corr', 'mf-hold-approve', v_staff2);
  PERFORM public.reverse_finance_control_v1(v_hold, 'reverse pending hold chain', 'evidence', 'corr', 'mf-hold-reverse', v_staff2);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  IF EXISTS (
    SELECT 1 FROM public.finance_control_authority_v1 f
     WHERE f.order_id = v_order AND f.active_blocking_hold
  ) THEN
    RAISE EXCEPTION 'MF_HOLD_CHAIN_NOT_CLEARED';
  END IF;
  SELECT control_event_id INTO v_hold
    FROM public.apply_finance_hold_v1(v_company, v_order, NULL, 'ORDER', 1000, 'release chain probe', 'evidence', 'corr', 'mf-hold-release', v_staff);
  SELECT control_event_id INTO v_release
    FROM public.release_finance_hold_v1(v_hold, 'release hold', 'evidence', 'corr', 'mf-hold-release-event', v_staff);
  IF EXISTS (
    SELECT 1 FROM public.finance_control_authority_v1 f WHERE f.control_event_id = v_hold AND f.active_blocking_hold
  ) THEN
    RAISE EXCEPTION 'MF_HOLD_RELEASE_NOT_CLEARED';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff2::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  SELECT control_event_id INTO v_reversal
    FROM public.reverse_finance_control_v1(v_release, 'reverse release', 'evidence', 'corr', 'mf-release-reverse', v_staff2);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  IF NOT EXISTS (
    SELECT 1 FROM public.finance_control_authority_v1 f WHERE f.control_event_id = v_hold AND f.active_blocking_hold
  ) THEN
    RAISE EXCEPTION 'MF_RELEASE_REVERSAL_DID_NOT_REACTIVATE_HOLD';
  END IF;
  SELECT current_status INTO v_status
    FROM public.raise_ledger_dispute_v1(v_ledger, 'Initial dispute probe', '["evidence"]'::jsonb, 'finance', 'corr', 'mf-dispute-1', v_staff);
  IF v_status <> 'OPEN' THEN RAISE EXCEPTION 'MF_DISPUTE_RAISE_STATUS'; END IF;
  SELECT current_status INTO v_status
    FROM public.raise_ledger_dispute_v1(v_ledger, 'Initial dispute probe', '["evidence"]'::jsonb, 'finance', 'corr', 'mf-dispute-1', v_staff);
  IF v_status <> 'OPEN' THEN RAISE EXCEPTION 'MF_DISPUTE_IDEMPOTENT_STATUS'; END IF;
  SELECT current_status INTO v_status
    FROM public.transition_ledger_dispute_v1(
      (SELECT dispute_id FROM public.ledger_dispute_authority_v1 WHERE idempotency_key = 'mf-dispute-1'),
      'INVESTIGATING', 'Investigating probe', '["evidence"]'::jsonb, 'corr', 'mf-dispute-inv', v_staff
    );
  IF v_status <> 'INVESTIGATING' THEN RAISE EXCEPTION 'MF_DISPUTE_TRANSITION_STATUS'; END IF;
END;
$macro$;
$macro_finance_runtime$, 'finance hold chain, tenant binding, and dispute idempotent status behave correctly');

select * from finish();
