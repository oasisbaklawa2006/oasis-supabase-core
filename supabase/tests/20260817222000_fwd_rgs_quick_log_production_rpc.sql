begin;
-- Contract coverage for 20260817222000_fwd_rgs_quick_log_production_rpc.sql.
-- Forward-only replacement of 20260817130000_rgs_quick_log_production_rpc.sql
-- (below production max at reconciliation time).
select plan(1);
select has_function('public', 'quick_log_production_to_rgs', array['uuid','text','numeric','numeric','text','text'], 'quick-log RPC exists');
select * from finish();
rollback;
