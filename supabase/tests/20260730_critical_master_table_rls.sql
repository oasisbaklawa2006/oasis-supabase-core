-- Contract test for 20260730123000_harden_critical_master_table_rls.sql
begin;

select plan(15);

select has_function(
  'public',
  'protect_user_privilege_fields',
  array[]::text[],
  'user privilege-field guard exists'
);

select function_privs_are(
  'public',
  'protect_user_privilege_fields',
  array[]::text[],
  'authenticated',
  array[]::text[],
  'authenticated cannot invoke the trigger function directly'
);

select trigger_is(
  'public',
  'users',
  'trg_protect_user_privilege_fields',
  'public',
  'protect_user_privilege_fields',
  'users table has the privilege-field guard trigger'
);

select is(
  (
    select count(*)::integer
    from pg_policies
    where schemaname = 'public'
      and tablename in ('users','products','categories','product_variants','product_media')
      and cmd = 'ALL'
      and coalesce(qual, '') = 'true'
      and coalesce(with_check, '') = 'true'
  ),
  0,
  'no critical master table retains unrestricted authenticated ALL access'
);

select is(
  (select count(*)::integer from pg_policies where schemaname='public' and tablename='users' and policyname in (
    'Users read self or admins read all','Users update self or admins update all','Admins insert users','Admins delete users'
  )),
  4,
  'users has four scoped policies'
);

select is(
  (select count(*)::integer from pg_policies where schemaname='public' and tablename='products' and policyname like 'Admins % products'),
  3,
  'products has admin-only mutation policies'
);

select is(
  (select count(*)::integer from pg_policies where schemaname='public' and tablename='categories' and policyname like 'Admins % categories'),
  3,
  'categories has admin-only mutation policies'
);

select is(
  (select count(*)::integer from pg_policies where schemaname='public' and tablename='product_variants' and policyname like 'Admins % product variants'),
  3,
  'product variants has admin-only mutation policies'
);

select is(
  (select count(*)::integer from pg_policies where schemaname='public' and tablename='product_media' and policyname like 'Admins % product media'),
  3,
  'product media has admin-only mutation policies'
);

select ok(
  exists(select 1 from pg_policies where schemaname='public' and tablename='products' and policyname='Authenticated read products' and cmd='SELECT'),
  'authenticated product read policy remains'
);

select ok(
  exists(select 1 from pg_policies where schemaname='public' and tablename='categories' and policyname='Authenticated read categories' and cmd='SELECT'),
  'authenticated category read policy remains'
);

select ok(
  exists(select 1 from pg_policies where schemaname='public' and tablename='product_variants' and policyname='Authenticated read product variants' and cmd='SELECT'),
  'authenticated product-variant read policy remains'
);

select ok(
  exists(select 1 from pg_policies where schemaname='public' and tablename='product_media' and policyname='Authenticated read product media' and cmd='SELECT'),
  'authenticated product-media read policy remains'
);

select ok(
  not exists(select 1 from pg_policies where schemaname='public' and tablename='users' and policyname='OASIS_ADMIN_FULL_CONTROL'),
  'legacy unrestricted users policy is removed'
);

select ok(
  not exists(select 1 from pg_policies where schemaname='public' and tablename in ('products','categories','product_variants','product_media') and policyname in ('OASIS_ADMIN_FULL_CONTROL','OASIS_AUTHENTICATED_FULL_ACCESS','Authenticated write media')),
  'legacy unrestricted catalogue policies are removed'
);

select * from finish();
rollback;
