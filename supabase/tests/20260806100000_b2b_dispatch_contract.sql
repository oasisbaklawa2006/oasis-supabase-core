begin;
-- Contract coverage for 20260806100000_b2b_dispatch_contract.sql.
select plan(9);

select has_table('public','b2b_dispatch_consignments','B2B dispatch consignment table exists');
select has_table('public','b2b_dispatch_handoffs','B2B dispatch handoff table exists');
select has_table('public','b2b_dispatch_shipments','B2B dispatch shipment table exists');
select has_table('public','b2b_dispatch_exceptions','B2B dispatch exception table exists');
select has_function('public','can_manage_b2b_dispatch',array['uuid'],'dispatch management authority RPC exists');
select has_function('public','can_verify_b2b_dispatch_finance',array['uuid'],'dispatch finance verification RPC exists');
select is((select has_function_privilege('anon','public.can_manage_b2b_dispatch(uuid)','execute')),false,'anonymous cannot call dispatch management authority RPC');
select is((select has_table_privilege('anon','public.b2b_dispatch_consignments','select')),false,'anonymous cannot read dispatch consignments');
select is((select has_table_privilege('authenticated','public.b2b_dispatch_consignments','select')),true,'authenticated staff can enter the RLS-governed consignments table');

select * from finish();
rollback;
