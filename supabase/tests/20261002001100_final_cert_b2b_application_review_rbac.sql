-- Contract test for migration 20261002001100_final_cert_b2b_application_review_rbac.sql
select plan(10);

select has_function('public','enforce_b2b_application_review_authority_v1',array[]::text[],
  'B2B application review authority guard exists');

select ok(position('ADMIN' in upper(pg_get_functiondef(
  'public.enforce_b2b_application_review_authority_v1()'::regprocedure))) > 0,
  'review guard contains ADMIN authority');

select ok(position('SUPER_ADMIN' in upper(pg_get_functiondef(
  'public.enforce_b2b_application_review_authority_v1()'::regprocedure))) > 0,
  'review guard contains SUPER_ADMIN authority');

select ok(position('B2B_APPLICATION_ADMIN_REVIEW_REQUIRED' in upper(pg_get_functiondef(
  'public.enforce_b2b_application_review_authority_v1()'::regprocedure))) > 0,
  'review guard fails unauthorized mutations closed');

select ok(exists(
  select 1 from pg_trigger
  where tgrelid='public.b2b_applications'::regclass
    and tgname='trg_b2b_application_review_authority_v1'
    and not tgisinternal
), 'review authority trigger is installed');

select ok(
  position('BEFORE' in upper(pg_get_triggerdef((
    select oid from pg_trigger where tgrelid='public.b2b_applications'::regclass
      and tgname='trg_b2b_application_review_authority_v1'
  )))) > 0
  and position('UPDATE' in upper(pg_get_triggerdef((
    select oid from pg_trigger where tgrelid='public.b2b_applications'::regclass
      and tgname='trg_b2b_application_review_authority_v1'
  )))) > 0
  and position('DELETE' in upper(pg_get_triggerdef((
    select oid from pg_trigger where tgrelid='public.b2b_applications'::regclass
      and tgname='trg_b2b_application_review_authority_v1'
  )))) > 0,
  'guard executes before update/delete'
);

select ok(exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='b2b_applications'
    and policyname='Admins delete applications'
), 'delete policy is admin-scoped');

select ok(not exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='b2b_applications'
    and policyname='Staff delete applications'
), 'broad staff delete policy is removed');

select ok(not has_function_privilege('authenticated',
  'public.enforce_b2b_application_review_authority_v1()','execute'),
  'authenticated cannot invoke trigger function directly');

select ok(has_function_privilege('service_role',
  'public.enforce_b2b_application_review_authority_v1()','execute'),
  'service role retains governed trigger execution authority');

select * from finish();
