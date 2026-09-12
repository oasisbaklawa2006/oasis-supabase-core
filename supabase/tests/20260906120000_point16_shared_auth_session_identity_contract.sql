-- Point 16: shared authentication / session identity behavioral closure.
-- Authority census confirms canonical auth→profile contracts already exist on
-- main through c89c538 (#259 Trace identity/handover, #256 inventory, #255
-- finance, #206 Point17 hierarchy, #252 baseline pgTAP). This file closes the
-- remaining contract gap with behavioral pgTAP only — no migration scope and
-- no competition with Point36 #209→#215 or migration-bearing #260 chronology.
begin;

select plan(55);

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
select has_function('public', 'has_active_company_membership', array['uuid','uuid'], 'has_active_company_membership(uuid,uuid) exists (Point17 boundary)');
select has_function('public', 'trace_sign_handover_evidence_v1', array['text','text','text','text','jsonb','uuid','text'], 'trace_sign_handover_evidence_v1 exists (#259 Trace session binding)');
select has_function('public', 'trace_verify_handover_evidence_v1', array['jsonb','text','text','boolean'], 'trace_verify_handover_evidence_v1 exists (#259 Trace session binding)');
select has_function('public', 'get_company_ar_ageing_facts_v1', array['uuid'], 'get_company_ar_ageing_facts_v1 exists (#255 finance scope gate)');

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
select ok(
  not has_function_privilege('anon', 'public.trace_sign_handover_evidence_v1(text,text,text,text,jsonb,uuid,text)', 'EXECUTE'),
  'anon cannot execute trace_sign_handover_evidence_v1 (#259 boundary)'
);

-- ══════════════════════════════════════════════════════════════════════
-- 3. Fixture: auth.users → staff / buyer / orphan identities
-- ══════════════════════════════════════════════════════════════════════

insert into auth.users (id, email) values
  ('b1600000-0000-0000-0000-000000000001', 'point16-staff@example.invalid'),
  ('b1600000-0000-0000-0000-000000000002', 'point16-buyer@example.invalid'),
  ('b1600000-0000-0000-0000-000000000003', 'point16-orphan@example.invalid'),
  ('b1600000-0000-0000-0000-000000000004', 'point16-inactive-staff@example.invalid'),
  ('b1600000-0000-0000-0000-000000000005', 'point16-tv@example.invalid'),
  ('b1600000-0000-0000-0000-000000000006', 'point16-packing@example.invalid');

do $$
declare
  v_company uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status)
  values ('Point16 Buyer Co', 'active')
  returning id into v_company;

  insert into public.companies (id, business_name, status)
  values ('b1600000-0000-0000-0000-00000000f001', 'Point16 Foreign Co', 'active');

  insert into public.users (id, email, role, is_active, company_id)
  values
    ('b1600000-0000-0000-0000-000000000001', 'point16-staff@example.invalid', 'admin', true, v_company),
    ('b1600000-0000-0000-0000-000000000004', 'point16-inactive-staff@example.invalid', 'admin', false, null),
    ('b1600000-0000-0000-0000-000000000005', 'point16-tv@example.invalid', 'TV_READY', true, null),
    ('b1600000-0000-0000-0000-000000000006', 'point16-packing@example.invalid', 'PACKING_SUPERVISOR', true, null);

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

  insert into public.roles (id, role_key, role_name, is_active)
  values ('b1600000-0000-0000-0000-00000000a001', 'sales_executive', 'Sales Executive', true)
  on conflict do nothing;

  insert into public.user_role_map (user_id, role_id)
  values (
    'b1600000-0000-0000-0000-000000000006',
    'b1600000-0000-0000-0000-00000000a001'
  );

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

-- ══════════════════════════════════════════════════════════════════════
-- 9. Behavioral: #259 Trace handover binds auth.uid() (session identity)
-- ══════════════════════════════════════════════════════════════════════

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.trace_verify_handover_evidence_v1('{"version":"1.0"}'::jsonb, null, null, false)$$,
  'TRACE_HANDOVER_VERIFY_AUTHORITY_REQUIRED',
  'buyer cannot verify Trace handover evidence (#259 uses is_internal_staff gate)'
);

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000001';
select is(
  public.trace_verify_handover_evidence_v1('{"version":"1.0"}'::jsonb, null, null, false),
  false,
  'internal staff can invoke verify but malformed evidence still returns false'
);

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000006';
select throws_ok(
  $$select public.trace_sign_handover_evidence_v1(
    'packing', 'carton', 'b1600000-0000-0000-0000-000000000099',
    'CTN-POINT16', '{}'::jsonb,
    'b1600000-0000-0000-0000-000000000001'::uuid, null
  )$$,
  'TRACE_HANDOVER_ACTOR_MISMATCH',
  'trace_sign_handover_evidence_v1 rejects client-supplied actor_id spoofing'
);

-- ══════════════════════════════════════════════════════════════════════
-- 10. Behavioral: #255 finance AR ageing enforces buyer company scope
-- ══════════════════════════════════════════════════════════════════════

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.get_company_ar_ageing_facts_v1('b1600000-0000-0000-0000-00000000f001'::uuid)$$,
  'AR_AGEING_COMPANY_SCOPE_REQUIRED',
  'buyer AR ageing is fail-closed to own company via auth_buyer_company_id scope (#255)'
);

-- ══════════════════════════════════════════════════════════════════════
-- 11. Behavioral: legacy vs governed resolver + role-key union semantics
-- ══════════════════════════════════════════════════════════════════════

select ok(
  has_function_privilege('anon', 'public.auth_buyer_company_id()', 'EXECUTE'),
  'legacy auth_buyer_company_id retains baseline anon grant (governed buyer RPCs use customer_buyer_eligible_company_id instead)'
);

reset request.jwt.claim.sub;
select ok(
  public.auth_buyer_company_id() is null,
  'auth_buyer_company_id() is null without authenticated JWT sub'
);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000001';
select ok(
  public.auth_buyer_company_id() is not null,
  'legacy auth_buyer_company_id resolves staff users.company_id (governed gate remains null)'
);

set local request.jwt.claim.sub = 'b1600000-0000-0000-0000-000000000002';
select ok(
  'b2b_buyer' = any(public.get_my_role_keys()),
  'approved buyer get_my_role_keys includes profiles.role union branch'
);

select is(
  upper(public.get_user_role('b1600000-0000-0000-0000-000000000006')),
  'SALES_EXECUTIVE',
  'get_user_role prefers user_role_map over conflicting public.users.role'
);

select is(
  public.is_team_member('b1600000-0000-0000-0000-000000000006'),
  false,
  'is_team_member is orthogonal to is_internal_staff (packing role without catalogue team map)'
);

select * from finish();
rollback;
