-- Contract for migration 20260830143900_commercial_closure_financial_projection.sql.

select plan(14);

select has_table('public','commercial_closures','commercial closure ledger exists');
select has_function('public','get_customer_financial_360_v1',array['uuid'],'customer financial 360 exists');
select has_function('public','close_order_commercially_v1',array['uuid','text','text','text','uuid'],'commercial closure RPC exists');
select has_function('public','get_tally_finance_export_v1',array['date','date'],'Tally projection RPC exists');
select has_view('public','commercial_closure_authority_v1','commercial closure authority view exists');
select ok((select relrowsecurity from pg_class where oid='public.commercial_closures'::regclass),'commercial closures have RLS');
select ok(not has_table_privilege('authenticated','public.commercial_closures','INSERT'),'authenticated cannot directly insert commercial closure');
select ok(not has_table_privilege('authenticated','public.commercial_closures','UPDATE'),'authenticated cannot mutate commercial closure');
select ok(pg_get_functiondef('public.close_order_commercially_v1(uuid,text,text,text,uuid)'::regprocedure) like '%COMPLAINT_WINDOW_STILL_OPEN%','commercial closure fails while complaint window is open');
select ok(pg_get_functiondef('public.close_order_commercially_v1(uuid,text,text,text,uuid)'::regprocedure) like '%COMPLAINT_RESOLUTION_PENDING%','commercial closure fails with unresolved complaint');
select ok(pg_get_functiondef('public.close_order_commercially_v1(uuid,text,text,text,uuid)'::regprocedure) like '%closure_fingerprint%','commercial closure freezes fingerprinted lineage');
select ok(pg_get_functiondef('public.get_tally_finance_export_v1(date,date)'::regprocedure) like '%FINAL_INVOICE%','Tally projection includes canonical final invoices');
select ok(pg_get_functiondef('public.get_tally_finance_export_v1(date,date)'::regprocedure) like '%COMMERCIAL_ADJUSTMENT%','Tally projection includes governed adjustments');
select ok(pg_get_functiondef('public.get_customer_financial_360_v1(uuid)'::regprocedure) like '%commercially_closed%','Finance 360 exposes terminal closure status');

select * from finish();
