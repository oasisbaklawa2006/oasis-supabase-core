-- Point 16: shared authentication / session identity behavioral closure.
-- Authority census confirms canonical auth→profile contracts already exist on
-- main (squashed baseline 20260723161256 + governed identity lanes). This
-- file closes the remaining contract gap with behavioral pgTAP only — no
-- migration scope and no competition with Point36 #209→#215 chronology.
begin;

select plan(40);

-- ══════════════════════════════════════════════════════════════════════
-- 1. Census: canonical auth/session identity authority objects
-- ══════════════════════════════════════════════════════════════════════

select ok(to_regclass('public.identity_profiles') is not null, 'identity_profiles table exists');
select ok(to_regclass('public.profiles') is not null, 'profiles table exists');
select ok(to_regclass('public.users') is not null, 'users staff authority table exists');
select ok(to_regclass('public.user_role_map') is not null, 'user_role_map legacy role bridge exists');
select ok(to_regclass('public.roles') is not null, 'roles catalog exists');
select ok(to_regclass('public.org_memberships') is not null, 'org_memberships hierarchy table exists (Point17 boundary)');

select has_function('public', 'is_internal_staff', array['uuid'], 'is_internal_staff(uuid) exists');
select has_function('public', 'is_team_member', array['uuid'], 'is_team_member(uuid) exists');
select has_function('public', 'is_staff_role', array['text'], 'is_staff_role(text) exists');
select has_function('public', 'get_user_role', array['uuid'], 'get_user_role(uuid) exists');
select has_function('public', 'get_my_role_keys', array[]::text[], 'get_my_role_keys() exists');
select has_function('public', 'customer_buyer_eligible_company_id', array[]::text[], 'customer_buyer_eligible_company_id() exists');
select has_function('public', 'auth_buyer_company_id', array[]::text[], 'auth_buyer_company_id() exists');
select has_function('public', 'has_app_permission', array['uuid','text','uuid','uuid'], 'has_app_permission(uuid,text,uuid,uuid) exists (Point18 boundary)');
select has_function('public', 'has_step_up_auth', array[]::text[], 'has_step_up_auth() exists (Point19 boundary)');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.identity_profiles'::regclass),
  'identity_profiles has RLS enabled'
);

-- ══════════════════════════════════════════════════════════════════════
-- 2. Grant boundaries: anon denial on session identity helpers
-- ══════════════════════════════════════════════════════════════════════

select ok(
  not has_function_privilege('anon', 'public.is_internal_staff(uuid)', 'EXECUTE'),
  'anon cannot execute is_internal_staff(uuid)'
);
select ok(
  not has_function_privilege('anon', 'public.get_user_role(uuid)', 'EXECUTE'),
  'anon cannot execute get_user_role(uuid)'
);
select ok(
  not has_function_privilege('anon', 'public.customer_buyer_eligible_company_id()', 'EXECUTE'),
  'anon cannot execute customer_buyer_eligible_company_id()'
);
select ok(
  not has_function_privilege('anon', 'public.get_my_role_keys()', 'EXECUTE'),
  'anon cannot execute get_my_role_keys()'
);
select ok(
  has_function_privilege('authenticated', 'public.is_internal_staff(uuid)', 'EXECUTE'),
  'authenticated can execute is_internal_staff(uuid)'
);
select ok(
  has_function_privilege('authenticated', 'public.customer_buyer_eligible_company_id()', 'EXECUTE'),
  'authenticated can execute customer_buyer_eligible_company_id()'
);

-- ══════════════════════════════════════════════════════════════════════
-- 3. Fixture: auth.users → staff / buyer / orphan identities
-- ══════════════════════════════════════════════════════════════════════

insert into auth.users (id, email) values
  ('b1600000-0000-0000-0000-000000000001', 'point16-staff@example.invalid'),
  ('b1600000-0000-0000-0000-000000000002', 'point16-buyer@example.invalid'),
  ('b1600000-0000-0000-0000-000000000003', 'point16-orphan@example.invalid'),
  ('b1600000-0000-0000-0000-000000000004', 'point16-inactive-staff@example.invalid'),
  ('b1600000-0000-0000-0000-000000000005', 'point16-tv@example.invalid');

do $$
declare
  v_company uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status)
  values ('Point16 Buyer Co', 'active')
  returning id into v_company;

  insert into public.users (id, email, role, is_active, company_id)
  values
    ('b1600000-0000-0000-0000-000000000001', 'point16-staff@example.invalid', 'admin', true, v_company),
    ('b1600000-0000-0000-0000-000000000004', 'point16-inactive-staff@example.invalid', 'admin', false, null),
    ('b1600000-0000-0000-0000-000000000005', 'point16-tv@example.invalid', 'TV_READY', true, null);

  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (
    'b1600000-0000-0000-0000-000000000002',
    v_company,
    'b2b_buyer',
    true,
    'approved',
    'point16-buyer@example.invalid'
  );

  insert into public.identity_profiles (user_id, identity_class, status, display_name)
  values
    ('b1600000-0000-0000-0000-000000000001', 'staff', 'active', 'Point16 Staff'),
    ('b1600000-0000-0000-0000-000000000002', 'customer', 'active', 'Point16 Buyer'),
    ('b1600000-0000-0000-0000-000000000005', 'device', 'active', 'Point16 TV');

  set local session_replication_role = default;
end $$;

-- ══════════════════════════════════════════════════════════════════════
-- 4. Behavioral: staff identity contract (auth.users → public.users)
-- ══════════════════════════════════════════════════════════════════════

select is(
  public.is_internal_staff('b1600000-0000-0000-0000-000000000001'),
  true,
  'active staff user resolves through public.users role authority'
);
select is(
  public.is_internal_staff('b1600000-0000-0000-0000-000000000004'),
  true,
  'inactive staff user still matches is_internal_staff role predicate (revocation is is_active/is_admin lane)'
);
select is(
  public.is_internal_staff('b1600000-0000-0000-0000-000000000005'),
  false,
  'dedicated TV device identity is not internal staff'
);
select is(
  public.is_internal_staff('b1600000-0000-0000-0000-000000000003'),
  false,
  'auth user without profile mapping is not internal staff'
);
select is(
  upper(public.get_user_role('b1600000-0000-0000-0000-000000000001')),
  'ADMIN',
  'get_user_role resolves staff role from public.users fallback'
);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000004';
select is(public.is_admin(), false, 'inactive admin fails is_admin() fail-closed gate');

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000001';
select is(public.is_admin(), true, 'active admin satisfies is_admin()');

-- ══════════════════════════════════════════════════════════════════════
-- 5. Behavioral: buyer identity contract (auth.users → profiles → companies)
-- ══════════════════════════════════════════════════════════════════════

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000002';
select ok(
  public.customer_buyer_eligible_company_id() is not null,
  'approved buyer resolves company through governed customer_buyer_eligible_company_id()'
);
select is(
  (select count(*)::integer from public.customer_company_v1()),
  1,
  'approved buyer receives exactly one customer_company_v1 projection row'
);

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000001';
select ok(
  public.customer_buyer_eligible_company_id() is null,
  'internal staff is not customer-buyer eligible even when public.users has company_id'
);

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000003';
select ok(
  public.customer_buyer_eligible_company_id() is null,
  'orphan auth user without profiles/users mapping is fail-closed for buyer eligibility'
);
select ok(
  (select cardinality(public.get_my_role_keys())) = 0,
  'orphan auth user receives empty role key set from get_my_role_keys()'
);

-- ══════════════════════════════════════════════════════════════════════
-- 6. Behavioral: identity_profiles self-read vs cross-user isolation
-- ══════════════════════════════════════════════════════════════════════

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000002';
set local role authenticated;
select is(
  (select identity_class from public.identity_profiles where user_id = auth.uid()),
  'customer',
  'authenticated buyer can read own identity_profiles row'
);
select is(
  (select count(*)::integer from public.identity_profiles where user_id = 'b1600000-0000-0000-0000-000000000001'),
  0,
  'buyer cannot read another user identity_profiles row through RLS'
);
reset role;

-- ══════════════════════════════════════════════════════════════════════
-- 7. Behavioral: JWT session claims boundary (Point19 cross-reference only)
-- ══════════════════════════════════════════════════════════════════════

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000001';
select is(public.has_step_up_auth(), false, 'AAL1 session does not satisfy has_step_up_auth()');

select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'b1600000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);
select is(public.has_step_up_auth(), true, 'AAL2 JWT claim satisfies has_step_up_auth()');

select set_config('request.jwt.claims', null, true);

-- ══════════════════════════════════════════════════════════════════════
-- 8. Behavioral: unauthenticated session-bound helpers fail closed
-- ══════════════════════════════════════════════════════════════════════

reset request.jwt.claim.sub;
select ok(
  public.customer_buyer_eligible_company_id() is null,
  'customer_buyer_eligible_company_id() is null without authenticated JWT sub'
);
select ok(
  (select cardinality(public.get_my_role_keys())) = 0,
  'get_my_role_keys() is empty without authenticated JWT sub'
);

select * from finish();
rollback;
