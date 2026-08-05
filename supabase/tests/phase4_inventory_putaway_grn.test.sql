begin;
-- Contract coverage for 20260805130000_phase4_inventory_putaway_grn.sql.
select plan(9);

select has_table('public','b2b_inventory_bins','bins exist');
select has_table('public','b2b_inventory_putaway_tasks','put-away tasks exist');
select has_table('public','b2b_inventory_grns','GRNs exist');
select has_table('public','b2b_supplier_discrepancies','supplier discrepancies exist');
select has_function('public','allocate_b2b_inventory_putaway',array['uuid','jsonb','text'],'allocation RPC exists');
select has_function('public','confirm_b2b_inventory_putaway',array['uuid','text','numeric','text'],'scan confirmation RPC exists');
select has_function('public','finalise_b2b_inventory_grn',array['uuid','text','text'],'GRN finalisation RPC exists');
select is((select has_table_privilege('anon','public.b2b_inventory_grns','select')),false,'anonymous cannot read GRNs');
select is((select has_table_privilege('authenticated','public.b2b_inventory_grns','insert')),false,'authenticated users cannot directly insert GRNs');

select * from finish();
rollback;
