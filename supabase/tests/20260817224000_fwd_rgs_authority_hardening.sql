begin;
-- Contract coverage for 20260817224000_fwd_rgs_authority_hardening.sql.
-- Forward-only replacement of 20260817150000_rgs_authority_hardening.sql
-- (below production max at reconciliation time).
select plan(2);
select has_table('public', 'production_job_stage_transitions', 'idempotent stage-transition ledger exists');
select has_function('public', 'advance_production_job_stage', array['uuid','text'], 'idempotent stage-advance RPC exists');
select * from finish();
rollback;
