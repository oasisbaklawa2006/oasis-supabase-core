-- Contract test for migration 20261002001300_final_cert_legacy_dispatch_rbac.sql
select plan(8);

select ok(not exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
    and policyname='Allow authenticated full access on dispatches'
), 'authenticated full-access dispatch policy is removed');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
    and policyname='Users can view their dispatches'
), 'buyer-own dispatch read policy is preserved');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
    and policyname='Internal staff read legacy dispatches'
), 'internal staff can retain legacy dispatch read compatibility');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
    and policyname='Dispatch authority insert legacy dispatches'
    and upper(with_check) like '%DISPATCH_MANAGER%'
), 'legacy dispatch insert is Dispatch-scoped');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
    and policyname='Dispatch authority update legacy dispatches'
    and upper(qual) like '%OPERATIONS_MANAGER%'
), 'legacy dispatch update permits governed Operations authority');

select ok(exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
    and policyname='Dispatch authority delete legacy dispatches'
    and upper(qual) like '%ADMIN%'
), 'legacy dispatch delete permits governed Admin authority');

select ok(not exists(
  select 1 from pg_policies where schemaname='public' and tablename='dispatches'
  and cmd in ('INSERT','UPDATE','DELETE','ALL')
  and coalesce(qual,with_check,'') = '(auth.role() = ''authenticated''::text)'
), 'no blanket authenticated mutation policy remains');

select ok((select relrowsecurity from pg_class where oid='public.dispatches'::regclass),
  'RLS remains enabled on legacy dispatches');

select * from finish();
