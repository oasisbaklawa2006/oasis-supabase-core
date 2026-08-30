-- PF-6C contract coverage for canonical Finance Operations Clearance.

select plan(28);

select has_table('public','finance_clearance_events','Finance clearance event ledger exists');
select has_table('public','finance_clearance_idempotency','Finance clearance idempotency ledger exists');
select has_function('public','assert_finance_clearance_actor_v1',array['uuid'],'Finance clearance actor helper exists');
select has_function('public','get_finance_operations_clearance_facts_v1',array['uuid','uuid','uuid'],'Finance operations facts RPC exists');
select has_function('public','decide_finance_operations_clearance_v1',array['uuid','uuid','uuid','text','text','text','text','text','text','text','uuid'],'Finance operations decision RPC exists');
select has_view('public','finance_operations_clearance_authority_v1','Finance operations authority projection exists');

select ok((select relrowsecurity from pg_class where oid='public.finance_clearance_events'::regclass),'Finance clearance events have RLS');
select ok((select relrowsecurity from pg_class where oid='public.finance_clearance_idempotency'::regclass),'Finance clearance idempotency has RLS');
select ok(not has_table_privilege('authenticated','public.finance_clearance_events','INSERT'),'authenticated cannot directly insert clearance');
select ok(not has_table_privilege('authenticated','public.finance_clearance_events','UPDATE'),'authenticated cannot directly update clearance');
select ok(not has_table_privilege('authenticated','public.finance_clearance_events','DELETE'),'authenticated cannot directly delete clearance');
select ok(not has_table_privilege('service_role','public.finance_clearance_events','INSERT'),'service role cannot impersonate Finance decision');
select ok(has_function_privilege('authenticated','public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)','EXECUTE'),'authenticated internal actor can call facts RPC');
select ok(has_function_privilege('authenticated','public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)','EXECUTE'),'authenticated Finance actor can call decision RPC');
select ok(not has_function_privilege('service_role','public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)','EXECUTE'),'service role cannot call Finance decision RPC');

select ok(pg_get_functiondef('public.assert_finance_clearance_actor_v1(uuid)'::regprocedure) like '%assert_order_transition_role(''finance_review'')%','Finance clearance reuses canonical Finance role authority');
select ok(pg_get_functiondef('public.assert_finance_clearance_actor_v1(uuid)'::regprocedure) like '%has_step_up_auth()%','Finance clearance requires step-up authentication');
select ok(pg_get_functiondef('public.assert_finance_clearance_actor_v1(uuid)'::regprocedure) like '%FINANCE_CLEARANCE_AAL2_REQUIRED%','AAL2 fails closed');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%assert_order_payment_binding_v1%','clearance facts bind exact SO/PI/commercial version');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%get_order_payment_facts_v1%','clearance consumes canonical verified payment facts');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%round((v_value * 0.30) / 500) * 500%','advance is 30 percent rounded to nearest INR 500');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%w.direction = ''debit''%','wallet counts only when actually applied as governed debit');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%c.status = ''approved''%','only approved credit contributes to clearance');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%eligible_for_operations_clearance%','facts expose eligibility separately from decision');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_OPERATIONS_CLEARANCE_NOT_FUNDED%','grant fails closed when required advance is not covered');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%pg_advisory_xact_lock%','clearance decisions are serialized per order');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) not like '%UPDATE public.orders%','Finance clearance does not mutate order operational state');
select ok(pg_get_functiondef('public.prevent_finance_clearance_event_mutation()'::regprocedure) like '%FINANCE_CLEARANCE_EVENTS_APPEND_ONLY%','Finance clearance decision history is append-only');

select * from finish();
