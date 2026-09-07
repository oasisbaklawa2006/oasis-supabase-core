-- Contract for migration 20260907141000_macro_finance_payment_gateway_authority.sql.

select plan(37);

select has_table('public', 'payment_gateway_payable_intents', 'gateway payable intents exist');
select has_table('public', 'payment_gateway_provider_events', 'gateway provider events exist');
select has_table('public', 'payment_gateway_idempotency', 'gateway idempotency ledger exists');

select has_function('public', 'derive_payment_gateway_canonical_amount_v1', array['uuid','uuid','uuid','text'], 'canonical amount derivation exists');
select has_function('public', 'create_payment_gateway_payable_intent_v1', array['uuid','uuid','uuid','text','text','text','text','uuid'], 'create payable intent RPC exists');
select has_function('public', 'get_payment_gateway_payable_status_v1', array['uuid'], 'buyer status RPC exists');
select has_function('public', 'record_payment_gateway_provider_event_v1', array['uuid','text','text','text','numeric','text','jsonb','text','boolean','text','text'], 'provider event RPC exists');
select has_function('public', 'settle_payment_gateway_intent_v1', array['uuid','uuid','text','text'], 'gateway settlement RPC exists');
select has_function('public', 'get_payment_gateway_finance_facts_v1', array['uuid','uuid'], 'gateway finance facts RPC exists');
select has_function('public', 'get_finance_dispatch_clearance_facts_v1', array['uuid'], 'dispatch clearance facts RPC exists');

select ok(not has_table_privilege('authenticated', 'public.payment_gateway_payable_intents', 'INSERT'), 'no direct gateway intent insert');
select ok(not has_table_privilege('authenticated', 'public.payment_gateway_provider_events', 'INSERT'), 'no direct provider event insert');
select ok(not has_table_privilege('service_role', 'public.payment_gateway_payable_intents', 'INSERT'), 'service role cannot direct-write intents');

select ok(has_function_privilege('authenticated', 'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'buyer can create payable intent');
select ok(not has_function_privilege('authenticated', 'public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text)', 'EXECUTE'), 'buyer cannot ingest provider events');
select ok(has_function_privilege('service_role', 'public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text)', 'EXECUTE'), 'service role can ingest provider events');
select ok(not has_function_privilege('authenticated', 'public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)', 'EXECUTE'), 'buyer cannot settle gateway intents');
select ok(has_function_privilege('service_role', 'public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)', 'EXECUTE'), 'service role can settle gateway intents');

select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%derive_payment_gateway_canonical_amount_v1%', 'intent creation derives server-side amount');
select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) not like '%p_submitted_amount%', 'intent creation never accepts client amount');
select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED%', 'intent creation enforces company scope');
select ok(pg_get_functiondef('public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text)'::regprocedure) like '%PAYMENT_GATEWAY_SIGNATURE_INVALID%', 'unsigned provider events fail closed');
select ok(pg_get_functiondef('public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text)'::regprocedure) like '%PAYMENT_GATEWAY_AMOUNT_BINDING_MISMATCH%', 'provider amount must bind to canonical intent');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%order_payment_authority_scopes%', 'settlement maps into canonical order_payments');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%PAYMENT_GATEWAY%', 'settlement tags canonical payment source channel');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%verification_required%', 'gateway settlement remains uploaded-only pending Finance verify');
select ok(pg_get_functiondef('public.get_payment_gateway_finance_facts_v1(uuid,uuid)'::regprocedure) like '%PAYMENT_GATEWAY_FINANCE_FACTS_INTERNAL_ONLY%', 'finance facts are internal-only');
select ok(pg_get_functiondef('public.get_finance_dispatch_clearance_facts_v1(uuid)'::regprocedure) like '%finance_dispatch_clearance_authority_v1%', 'dispatch facts reuse clearance projection');
select ok(pg_get_functiondef('public.get_finance_dispatch_clearance_facts_v1(uuid)'::regprocedure) like '%finance_control_authority_v1%', 'dispatch facts include blocking hold state');

select ok(pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure) like '%PAYMENT_GATEWAY_IDEMPOTENCY_CONFLICT%', 'intent creation is idempotent');
select ok(pg_get_functiondef('public.settle_payment_gateway_intent_v1(uuid,uuid,text,text)'::regprocedure) like '%PAYMENT_GATEWAY_SETTLE_IDEMPOTENCY_CONFLICT%', 'settlement is idempotent');
select ok(pg_get_functiondef('public.prevent_payment_gateway_mutation()'::regprocedure) like '%PAYMENT_GATEWAY_APPEND_ONLY%', 'provider events are append-only');

select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) like '%required_advance%', 'advance derivation mirrors canonical advance policy');
select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) like '%get_credit_exposure_facts_v1%', 'balance derivation reuses credit exposure facts');
select ok(pg_get_functiondef('public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure) like '%PAYMENT_GATEWAY_NO_PAYABLE_BALANCE%', 'zero payable balance fails closed');

select ok(pg_get_functiondef('public.get_payment_gateway_payable_status_v1(uuid)'::regprocedure) like '%buyer_status_only%', 'buyer status projection is bounded');
select ok(not has_function_privilege('service_role', 'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'service role cannot impersonate buyer intent creation');

select * from finish();
