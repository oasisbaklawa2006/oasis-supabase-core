-- Contract for migration 20260830143500_final_invoice_settlement_authority.sql.

select plan(22);

select has_table('public','final_invoices','Final invoice header exists');
select has_table('public','final_invoice_lines','Final invoice lines exist');
select has_table('public','final_invoice_idempotency','Final invoice idempotency exists');
select has_function('public','issue_final_invoice_v1',array['uuid','uuid','uuid','uuid','text','date','text','text','text','text','uuid'],'Final invoice RPC exists');
select has_function('public','get_final_settlement_facts_v1',array['uuid'],'Final settlement facts RPC exists');
select ok((select relrowsecurity from pg_class where oid='public.final_invoices'::regclass),'Final invoice RLS enabled');
select ok(not has_table_privilege('authenticated','public.final_invoices','INSERT'),'No direct final invoice insert');
select ok(not has_table_privilege('authenticated','public.final_invoice_lines','INSERT'),'No direct final invoice line insert');
select ok(not has_function_privilege('service_role','public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)','EXECUTE'),'service role cannot impersonate invoice issuer');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%','Final invoice requires Finance+AAL2');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) like '%finance_dpl_receipts%','Invoice consumes frozen Finance DPL receipt');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) like '%sales_order_commercial_versions%','Invoice consumes frozen commercial version');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) like '%actual_dispatch_qty%','Invoice uses actual DPL dispatch quantity');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) like '%FINAL_INVOICE_NON_LINE_CHARGE_TAX_AUTHORITY_REQUIRED%','Unknown charge tax treatment fails closed');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) like '%FINAL_INVOICE_ALREADY_ISSUED%','Only one active final invoice is issued per order');
select ok(pg_get_functiondef('public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)'::regprocedure) not like '%UPDATE public.orders%','Final invoice does not write legacy order URL/status authority');
select ok(pg_get_functiondef('public.prevent_final_invoice_mutation()'::regprocedure) like '%FINAL_INVOICE_IMMUTABLE_USE_COMPENSATING_DOCUMENT%','Invoice history is immutable');
select ok(pg_get_functiondef('public.get_final_settlement_facts_v1(uuid)'::regprocedure) like '%get_order_payment_facts_v1%','Settlement uses canonical verified payments');
select ok(pg_get_functiondef('public.get_final_settlement_facts_v1(uuid)'::regprocedure) like '%wallet_transactions%','Settlement includes governed applied wallet debits');
select ok(pg_get_functiondef('public.get_final_settlement_facts_v1(uuid)'::regprocedure) like '%credit_requests%','Settlement includes approved bound credit');
select ok(pg_get_functiondef('public.get_final_settlement_facts_v1(uuid)'::regprocedure) like '%settled_for_dispatch%','Settlement exposes dispatch readiness as a fact');
select ok(pg_get_functiondef('public.get_final_settlement_facts_v1(uuid)'::regprocedure) not like '%finance_clearance_events%','Settlement facts do not grant Finance clearance');

select * from finish();
