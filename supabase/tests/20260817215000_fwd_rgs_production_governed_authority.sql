begin;
-- Contract coverage for 20260817215000_fwd_rgs_production_governed_authority.sql.
-- Forward-only replacement of 20260817100000_rgs_production_governed_authority.sql
-- (below production max at reconciliation time).
select plan(3);
select has_function('public', 'create_production_shortage_demand', array['uuid','text','text','text'], 'shortage demand RPC exists');
select has_function('public', 'dispatch_production_to_rgs', array['uuid','numeric','text','text'], 'production-to-RGS dispatch RPC exists');
select isnt(has_table_privilege('authenticated', 'public.production_jobs', 'INSERT'), true, 'direct authenticated INSERT on production_jobs is revoked');
select * from finish();
rollback;
