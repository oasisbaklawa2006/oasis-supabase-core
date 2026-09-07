-- Contract for migration 20260907141000_macro_finance_payment_gateway_authority.sql.

select plan(42);

select has_table('public', 'payment_gateway_payable_intents', 'gateway payable intents exist');
select has_table('public', 'payment_gateway_provider_events', 'gateway provider events exist');
select has_table('public', 'payment_gateway_idempotency', 'gateway idempotency ledger exists');

select has_function('public', 'derive_payment_gateway_canonical_amount_v1', array['uuid','uuid','uuid','text'], 'canonical amount derivation exists');
select has_function('public', 'create_payment_gateway_payable_intent_v1', array['uuid','uuid','uuid','text','text','text','text','uuid'], 'create payable intent RPC exists');
select has_function('public', 'get_payment_gateway_payable_status_v1', array['uuid'], 'buyer status RPC exists');
select has_function('public', 'record_payment_gateway_provider_event_v1', array['uuid','text','text','text','numeric','text','jsonb','text','boolean','text','text','text'], 'provider event RPC exists');
select has_function('public', 'settle_payment_gateway_intent_v1', array['uuid','uuid','text','text'], 'gateway settlement RPC exists');
select has_function('public', 'get_payment_gateway_finance_facts_v1', array['uuid','uuid'], 'gateway finance facts RPC exists');
select has_function('public', 'get_finance_dispatch_clearance_facts_v1', array['uuid'], 'dispatch clearance facts RPC exists');

select ok(not has_table_privilege('authenticated', 'public.payment_gateway_payable_intents', 'INSERT'), 'no direct gateway intent insert');
select ok(not has_table_privilege('authenticated', 'public.payment_gateway_provider_events', 'INSERT'), 'no direct provider event insert');
select ok(not has_table_privilege('service_role', 'public.payment_gateway_payable_intents', 'INSERT'), 'service role cannot direct-write intents');

select ok(has_function_privilege('authenticated', 'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'buyer can create payable intent');
select ok(not has_function_privilege('authenticated', 'public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text)', 'EXECUTE'), 'buyer cannot ingest provider events');
select ok(has_function_privilege('service_role', 'public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text)', 'EXECUTE'), 'service role can ingest provider events');
select ok(not has_function_privilege('authenticated', 'public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)', 'EXECUTE'), 'buyer cannot settle gateway intents');
select ok(has_function_privilege('service_role', 'public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)', 'EXECUTE'), 'service role can settle gateway intents');

select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%derive_payment_gateway_canonical_amount_v1%', 'intent creation derives server-side amount');
select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) not like '%p_submitted_amount%', 'intent creation never accepts client amount');
select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED%', 'intent creation enforces company scope');
select ok(pg_get_functiondef('public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text)'::regprocedure) like '%PAYMENT_GATEWAY_SIGNATURE_INVALID%', 'unsigned provider events fail closed');
select ok(pg_get_functiondef('public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text)'::regprocedure) like '%PAYMENT_GATEWAY_AMOUNT_BINDING_MISMATCH%', 'provider amount must bind to canonical intent');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%order_payment_authority_scopes%', 'settlement maps into canonical order_payments');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%PAYMENT_GATEWAY%', 'settlement tags canonical payment source channel');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%verification_required%', 'gateway settlement remains uploaded-only pending Finance verify');
select ok(pg_get_functiondef('public.get_payment_gateway_finance_facts_v1(uuid,uuid)'::regprocedure) like '%PAYMENT_GATEWAY_FINANCE_FACTS_INTERNAL_ONLY%', 'finance facts are internal-only');
select ok(pg_get_functiondef('public.get_finance_dispatch_clearance_facts_v1(uuid)'::regprocedure) like '%finance_dispatch_clearance_authority_v1%', 'dispatch facts reuse clearance projection');
select ok(pg_get_functiondef('public.get_finance_dispatch_clearance_facts_v1(uuid)'::regprocedure) like '%finance_control_authority_v1%', 'dispatch facts include blocking hold state');

select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%PAYMENT_GATEWAY_IDEMPOTENCY_CONFLICT%', 'intent creation is idempotent');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%PAYMENT_GATEWAY_SETTLE_IDEMPOTENCY_CONFLICT%', 'settlement is idempotent');
select ok(pg_get_functiondef('public.prevent_payment_gateway_mutation()'::regprocedure) like '%PAYMENT_GATEWAY_APPEND_ONLY%', 'provider events are append-only');

select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) like '%advance_required%', 'advance derivation uses frozen advance_required authority');
select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) not like '%0.30%', 'advance derivation does not recompute policy locally');
select ok(pg_get_functiondef('public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text)'::regprocedure) like '%p_provider_order_id%', 'provider order id is stored separately from payment id');
select ok(pg_get_functiondef('public.get_finance_dispatch_clearance_facts_v1(uuid)'::regprocedure) like '%f.scope = ''COMPANY''%', 'dispatch facts honor company-scoped blocking holds');
select ok(not has_function_privilege('service_role', 'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'service role cannot impersonate buyer intent creation');

select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) like '%get_credit_exposure_facts_v1%', 'balance derivation reuses credit exposure facts');
select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) like '%PAYMENT_GATEWAY_NO_PAYABLE_BALANCE%', 'zero payable balance fails closed');
select ok(pg_get_functiondef('public.get_payment_gateway_payable_status_v1(uuid)'::regprocedure) like '%buyer_status_only%', 'buyer status projection is bounded');
select ok(not has_function_privilege('service_role', 'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'service role cannot impersonate buyer intent creation');

select lives_ok($macro_gateway$
DO $gw$
DECLARE
  v_staff uuid := '9f780000-0000-0000-0000-000000000001';
  v_company uuid := '9f780000-0000-0000-0000-000000000010';
  v_order uuid := '9f780000-0000-0000-0000-000000000020';
  v_pi uuid := '9f780000-0000-0000-0000-000000000030';
  v_version uuid := '9f780000-0000-0000-0000-000000000040';
  v_intent uuid := '9f780000-0000-0000-0000-000000000050';
  v_event uuid;
  v_payment uuid;
  v_payload jsonb := '{"status":"paid"}'::jsonb;
  v_hash text;
  v_already boolean;
  v_count integer;
  v_snapshot jsonb;
  v_snapshot_fp text;
BEGIN
  v_snapshot := jsonb_build_object('order_id', v_order::text, 'lines', jsonb_build_array(jsonb_build_object('quantity', 1)));
  v_snapshot_fp := md5(v_snapshot::text);
  set local session_replication_role = replica;
  INSERT INTO auth.users(id, email) VALUES (v_staff, 'macro-gateway@test.invalid') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users(id, role, name, is_active) VALUES (v_staff, 'FINANCE_EXEC', 'Macro Gateway Staff', true)
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, is_active = true;
  INSERT INTO public.companies(id, business_name, status) VALUES (v_company, 'Macro Gateway Co', 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.orders(id, company_id, order_number, order_origin, tracking_token, sales_order_value, advance_required, status)
  VALUES (v_order, v_company, 'GW-ORD-1', 'MANUAL', 'gw-ord-1-token', 100000, 30000, 'active') ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.sales_order_commercial_versions(
    id, order_id, version_number, source_channel, commercial_snapshot, snapshot_fingerprint,
    sales_order_value, advance_required, change_reason, correlation_id, idempotency_key
  ) VALUES (
    v_version, v_order, 1, 'TEST', v_snapshot, v_snapshot_fp,
    100000, 30000, 'gateway fixture', 'corr', 'gw-version-1'
  ) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.sales_order_proforma_invoices(
    id, order_id, commercial_version_id, commercial_version_number, frozen_commercial_snapshot,
    frozen_snapshot_fingerprint, status, reason, source, correlation_id, idempotency_key
  ) VALUES (
    v_pi, v_order, v_version, 1, v_snapshot, v_snapshot_fp, 'READY_FOR_ISSUE',
    'gateway fixture', 'TEST', 'corr', 'gw-pi-1'
  ) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.payment_gateway_payable_intents(
    id, order_id, company_id, proforma_invoice_id, commercial_version_id, payment_purpose, provider_code,
    canonical_amount, currency, status, facts_snapshot, expires_at, correlation_id, idempotency_key,
    created_by, created_role
  ) VALUES (
    v_intent, v_order, v_company, v_pi, v_version, 'advance', 'razorpay',
    30000, 'INR', 'created', '{}'::jsonb, statement_timestamp() + interval '30 minutes',
    'corr', 'gw-intent-fixture', v_staff, 'FINANCE_EXEC'
  ) ON CONFLICT (id) DO NOTHING;
  set local session_replication_role = default;
  v_hash := encode(digest(v_payload::text, 'sha256'), 'hex');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'service_role', 'aal', 'aal2')::text, true);
  set local role service_role;
  BEGIN
    PERFORM public.record_payment_gateway_provider_event_v1(
      v_intent, 'payment_success', 'evt-1', 'pay-1', 29999.00, 'INR', v_payload, v_hash, true, 'corr', 'gw-event-bad', NULL
    );
    RAISE EXCEPTION 'GW_AMOUNT_MISMATCH_NOT_REJECTED';
  EXCEPTION WHEN sqlstate '40001' THEN NULL;
  END;
  SELECT provider_event_id INTO v_event
    FROM public.record_payment_gateway_provider_event_v1(
      v_intent, 'order_created', 'evt-order', 'pay-1', 30000, 'INR', v_payload, v_hash, true, 'corr', 'gw-event-order', 'order-abc'
    );
  IF NOT EXISTS (
    SELECT 1 FROM public.payment_gateway_payable_intents i
     WHERE i.id = v_intent AND i.provider_order_id = 'order-abc'
  ) THEN
    RAISE EXCEPTION 'GW_PROVIDER_ORDER_ID_NOT_STORED';
  END IF;
  SELECT provider_event_id INTO v_event
    FROM public.record_payment_gateway_provider_event_v1(
      v_intent, 'payment_success', 'evt-success', 'pay-1', 30000, 'INR', v_payload, v_hash, true, 'corr', 'gw-event-success', NULL
    );
  SELECT order_payment_id, already_settled INTO v_payment, v_already
    FROM public.settle_payment_gateway_intent_v1(v_intent, v_event, 'corr', 'gw-settle-1');
  IF v_payment IS NULL OR v_already THEN RAISE EXCEPTION 'GW_FIRST_SETTLE_FAILED'; END IF;
  SELECT order_payment_id, already_settled INTO v_payment, v_already
    FROM public.settle_payment_gateway_intent_v1(v_intent, v_event, 'corr', 'gw-settle-1');
  IF NOT v_already THEN RAISE EXCEPTION 'GW_SETTLE_RETRY_NOT_IDEMPOTENT'; END IF;
  SELECT count(*) INTO v_count FROM public.order_payments p WHERE p.id = v_payment;
  IF v_count <> 1 THEN RAISE EXCEPTION 'GW_SETTLE_DUPLICATE_PAYMENT'; END IF;
END;
$gw$;
$macro_gateway$, 'gateway amount binding, provider order id, and settlement idempotency behave correctly');

select * from finish();
