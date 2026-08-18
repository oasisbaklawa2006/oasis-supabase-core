begin;
-- Contract coverage for 20260817214000_fwd_rgs_department_taxonomy.sql.
-- Forward-only replacement of 20260817090000_rgs_department_taxonomy.sql
-- (below production max at reconciliation time; see supabase/tests/rgs_department_taxonomy.test.sql
-- for the full behavioural contract this replacement reproduces verbatim).
select plan(2);
select has_table('public', 'production_departments', 'canonical department master exists');
select has_function('public', 'canonical_production_department', array['text'], 'canonical mapping function exists');
select * from finish();
rollback;
