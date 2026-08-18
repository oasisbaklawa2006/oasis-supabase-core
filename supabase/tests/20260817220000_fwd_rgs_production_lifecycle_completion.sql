begin;
-- Contract coverage for 20260817220000_fwd_rgs_production_lifecycle_completion.sql.
-- Forward-only replacement of 20260817110000_rgs_production_lifecycle_completion.sql
-- (below production max at reconciliation time).
select plan(2);
select has_function('public', 'pause_production_job', array['uuid','text','text','text'], 'pause RPC exists');
select has_function('public', 'resume_production_job', array['uuid','text'], 'resume RPC exists');
select * from finish();
rollback;
