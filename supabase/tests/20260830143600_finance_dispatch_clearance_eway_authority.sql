-- Contract for migration 20260830143600_finance_dispatch_clearance_eway_authority.sql.

select plan(23);

select has_table('public','eway_bill_evidence','E-way evidence ledger exists');
select has_function('public','record_eway_bill_evidence_v1',array['uuid','text','text','text','text','timestamp with time zone','timestamp with time zone','text','text','uuid'],'E-way evidence RPC exists');
select has_function('public','decide_finance_dispatch_clearance_v1',array['uuid','text','text','text','text','text','uuid'],'Finance dispatch clearance RPC exists');
select has_function('public','assert_active_dispatch_clearance_v1',array['uuid'],'active dispatch clearance guard exists');
select has_view('public','finance_dispatch_clearance_authority_v1','dispatch clearance projection exists');
select ok((select relrowsecurity from pg_class where oid='public.eway_bill_evidence'::regclass),'E-way evidence RLS enabled');
select ok(not has_table_privilege('authenticated','public.eway_bill_evidence','INSERT'),'no direct E-way evidence writes');
select ok(not has_function_privilege('service_role','public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)','EXECUTE'),'service role cannot impersonate E-way decision');
select ok(not has_function_privilege('service_role','public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid)','EXECUTE'),'service role cannot impersonate Finance dispatch clearance');
select ok(pg_get_functiondef('public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%','E-way evidence requires Finance+AAL2');
select ok(pg_get_functiondef('public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,uuid)'::regprocedure) like '%VALIDATED%NOT_REQUIRED%','E-way evidence is validated or explicitly not required');
select ok(pg_get_functiondef('public.prevent_eway_bill_evidence_mutation()'::regprocedure) like '%EWAY_BILL_EVIDENCE_IMMUTABLE%','E-way evidence immutable');
select ok(pg_get_functiondef('public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid)'::regprocedure) like '%get_final_settlement_facts_v1%','dispatch clearance consumes settlement facts');
select ok(pg_get_functiondef('public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DISPATCH_CLEARANCE_BALANCE_OUTSTANDING%','outstanding balance blocks dispatch');
select ok(pg_get_functiondef('public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DISPATCH_CLEARANCE_EWAY_REQUIRED%','missing/expired E-way decision blocks dispatch');
select ok(pg_get_functiondef('public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid)'::regprocedure) like '%assert_active_operations_clearance_v1%','dispatch clearance preserves operations-clearance lineage');
select ok(pg_get_functiondef('public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid)'::regprocedure) not like '%UPDATE public.orders%','Finance dispatch clearance itself does not mutate operational status');
select ok(pg_get_functiondef('public.assert_active_dispatch_clearance_v1(uuid)'::regprocedure) like '%FINANCE_DISPATCH_CLEARANCE_REQUIRED%','dispatch guard fails closed');
select ok(pg_get_functiondef('public.clear_order_for_dispatch_v1(uuid)'::regprocedure) like '%assert_active_dispatch_clearance_v1%','operational dispatch transition requires Finance dispatch clearance');
select ok(pg_get_functiondef('public.clear_order_for_dispatch_v1(uuid)'::regprocedure) not like '%final_invoice_url%','legacy invoice URL no longer authorizes dispatch');
select ok(pg_get_functiondef('public.clear_order_for_dispatch_v1(uuid)'::regprocedure) not like '%payment_cleared%','legacy payment boolean no longer authorizes dispatch');
select ok(pg_get_functiondef('public.clear_order_for_dispatch_v1(uuid)'::regprocedure) like '%finance_dispatch_clearance_event_id%','dispatch transition audit stores clearance lineage');
select ok((select definition from pg_views where schemaname='public' and viewname='finance_dispatch_clearance_authority_v1') like '%DISPATCH%','projection is scoped only to Finance Dispatch Clearance');

select * from finish();
