begin;
-- Contract coverage for 20260805140000_phase4_inventory_completion.sql.
select plan(18);

select has_view('public','b2b_gate_store_reconciliation','gate-to-store reconciliation view exists');
select is((select 'security_invoker=true'=any(coalesce(reloptions,'{}')) from pg_class where oid='public.b2b_gate_store_reconciliation'::regclass),true,'reconciliation view uses security invoker');
select is((select has_table_privilege('anon','public.b2b_gate_store_reconciliation','select')),false,'anonymous cannot read reconciliation view');
select is((select has_table_privilege('authenticated','public.b2b_gate_store_reconciliation','select')),true,'authenticated staff can enter the RLS-governed view');
select has_function('public','resolve_b2b_supplier_discrepancy',array['uuid','text','text'],'discrepancy resolution RPC exists');
select has_function('public','reverse_b2b_inventory_grn',array['uuid','text','text','text'],'GRN reversal RPC exists');
select col_is_null('public','b2b_inventory_grns','stock_posted_at','stock posting timestamp is nullable until finalisation');
select is((select has_function_privilege('anon','public.finalise_b2b_inventory_grn(uuid,text,text)','execute')),false,'anonymous cannot finalise GRNs');
select is((select has_function_privilege('anon','public.reverse_b2b_inventory_grn(uuid,text,text,text)','execute')),false,'anonymous cannot reverse GRNs');
select is((select has_function_privilege('anon','public.resolve_b2b_supplier_discrepancy(uuid,text,text)','execute')),false,'anonymous cannot resolve discrepancies');
select is((select has_function_privilege('authenticated','public.finalise_b2b_inventory_grn(uuid,text,text)','execute')),true,'authenticated role can enter governed finalisation RPC');
select is((select has_function_privilege('authenticated','public.reverse_b2b_inventory_grn(uuid,text,text,text)','execute')),true,'authenticated role can enter governed reversal RPC');
select is((select has_function_privilege('authenticated','public.resolve_b2b_supplier_discrepancy(uuid,text,text)','execute')),true,'authenticated role can enter governed discrepancy RPC');
select is((select has_table_privilege('authenticated','public.b2b_inventory_grns','update')),false,'authenticated users cannot directly mutate GRNs');
select is((select has_table_privilege('authenticated','public.b2b_inventory_grns','insert')),false,'authenticated users cannot directly insert GRNs');
select is((select has_table_privilege('authenticated','public.b2b_inventory_grns','delete')),false,'authenticated users cannot directly delete GRNs');
select is((select has_table_privilege('authenticated','public.b2b_inventory_grns','truncate')),false,'authenticated users cannot truncate GRNs');
select is((select has_table_privilege('authenticated','public.b2b_inventory_grns','references')),false,'authenticated users cannot add references to GRNs');

select * from finish();
rollback;
