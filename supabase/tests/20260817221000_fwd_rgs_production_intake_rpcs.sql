begin;
-- Contract coverage for 20260817221000_fwd_rgs_production_intake_rpcs.sql.
-- Forward-only replacement of 20260817120000_rgs_production_intake_rpcs.sql
-- (below production max at reconciliation time).
select plan(2);
select has_function('public', 'accept_production_job', array['uuid','text','text'], 'accept RPC exists');
select has_function('public', 'reject_production_job', array['uuid','text','text'], 'reject RPC exists');
select * from finish();
rollback;
