begin;
-- Contract coverage for 20260817223000_fwd_rgs_department_execution_metadata.sql.
-- Forward-only replacement of 20260817140000_rgs_department_execution_metadata.sql
-- (below production max at reconciliation time).
select plan(1);
select has_column('public', 'production_job_outputs', 'execution_metadata', 'execution metadata column exists on production_job_outputs');
select * from finish();
rollback;
