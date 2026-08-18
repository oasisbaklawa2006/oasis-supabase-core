begin;
-- Contract coverage for 20260817225000_fwd_rgs_demand_source_linkage.sql.
-- Forward-only replacement of 20260817160000_rgs_demand_source_linkage.sql
-- (below production max at reconciliation time).
select plan(2);
select has_column('public', 'inventory_reservations', 'demand_source_type', 'internal/pna/outlet demand source column exists');
select has_function('public', 'reserve_rgs_stock', array['text','uuid','uuid','text','numeric','text','text','text','text','uuid','uuid','text','text'], 'demand-source-aware reserve RPC exists');
select * from finish();
rollback;
