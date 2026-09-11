-- Contract for migration 20260910010000_fix_auth_user_onboarding_provisioning.sql.
-- Proves genuine GoTrue end-user identities receive exactly one non-privileged
-- PENDING public.users identity while MSG91 phone identities and direct SQL
-- system/test principals remain owned by their explicit governed paths.

begin;

select plan(12);

select has_function(
  'public',
  'handle_new_user',
  array[]::text[],
  'public.handle_new_user() exists'
);

select has_trigger(
  'auth',
  'users',
  'on_auth_user_created',
  'auth.users keeps the canonical onboarding trigger'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace n on n.oid = p.pronamespace
    where t.tgrelid = 'auth.users'::regclass
      and t.tgname = 'on_auth_user_created'
      and not t.tgisinternal
      and n.nspname = 'public'
      and p.proname = 'handle_new_user'
  ),
  'on_auth_user_created invokes public.handle_new_user'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'handle_new_user'
      and p.prosecdef
  ),
  'handle_new_user remains SECURITY DEFINER'
);

select ok(
  not has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE'),
  'anon cannot execute handle_new_user directly'
);

select ok(
  not has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE'),
  'authenticated cannot execute handle_new_user directly'
);

-- GoTrue-like e-mail identity: provider metadata is present and no phone is
-- bound. This is the exact class that was orphaned in production UAT.
insert into auth.users (
  id, email, aud, role, raw_app_meta_data
)
values (
  '91000000-0000-4000-8000-000000000001'::uuid,
  'b2b-onboarding-trigger-cert@example.invalid',
  'authenticated',
  'authenticated',
  '{"provider":"email","providers":["email"]}'::jsonb
);

select is(
  (select role from public.users where id = '91000000-0000-4000-8000-000000000001'::uuid),
  'PENDING'::text,
  'GoTrue end-user identity is provisioned as PENDING'
);

select is(
  (select is_active from public.users where id = '91000000-0000-4000-8000-000000000001'::uuid),
  true,
  'fresh onboarding identity is active'
);

select is(
  (select invite_status from public.users where id = '91000000-0000-4000-8000-000000000001'::uuid),
  'pending'::text,
  'fresh onboarding identity is not treated as an active staff invite'
);

select is(
  (select count(*)::integer from public.users where id = '91000000-0000-4000-8000-000000000001'::uuid),
  1,
  'trigger creates exactly one governed identity row'
);

-- Direct SQL/system fixtures deliberately carry no GoTrue provider metadata.
-- Their owning migration/test remains responsible for public.users authority.
insert into auth.users (id, email, aud, role)
values (
  '91000000-0000-4000-8000-000000000002'::uuid,
  'direct-system-fixture@example.invalid',
  'authenticated',
  'authenticated'
);

select is(
  (select count(*)::integer from public.users where id = '91000000-0000-4000-8000-000000000002'::uuid),
  0,
  'direct SQL/system identity is not auto-provisioned'
);

-- MSG91 v73 owns phone-bound identity creation after provider verification and
-- performs its own canonical public.users insert. The generic trigger must not
-- pre-empt that write.
insert into auth.users (
  id, email, phone, aud, role, raw_app_meta_data
)
values (
  '91000000-0000-4000-8000-000000000003'::uuid,
  'msg91-owned-cert@example.invalid',
  '+919100000003',
  'authenticated',
  'authenticated',
  '{"provider":"email","providers":["email","phone"]}'::jsonb
);

select is(
  (select count(*)::integer from public.users where id = '91000000-0000-4000-8000-000000000003'::uuid),
  0,
  'phone-bound identity stays owned by MSG91 canonical provisioning'
);

select * from finish();
rollback;
