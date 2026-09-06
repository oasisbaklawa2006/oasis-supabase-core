-- Point19 — shared step-up authentication closure (authority census + behavioral pgTAP).
-- Schema authority already deployed via squashed baseline 20260723161256 and
-- subsequent migrations. Test-only closure; no migration scope.
begin;

select plan(29);

-- ---------------------------------------------------------------------------
-- Authority census: canonical helper, JWT claim contract, and grant boundaries
-- ---------------------------------------------------------------------------
select has_function('public', 'has_step_up_auth', array[]::text[], 'has_step_up_auth canonical helper exists');

select ok(
  not has_function_privilege('anon', 'public.has_step_up_auth()', 'EXECUTE'),
  'anon cannot evaluate step-up authority'
);

select ok(
  has_function_privilege('authenticated', 'public.has_step_up_auth()', 'EXECUTE'),
  'authenticated callers can evaluate their own step-up session'
);

select ok(
  has_function_privilege('service_role', 'public.has_step_up_auth()', 'EXECUTE'),
  'service_role retains step-up helper access for governed RPC execution'
);

select has_column(
  'public',
  'access_permissions',
  'requires_step_up',
  'access_permissions.requires_step_up metadata column exists'
);

select ok(
  exists(
    select 1
    from public.access_permissions
    where permission_key = 'rbac.manage'
      and requires_step_up
      and is_active
  ),
  'rbac.manage is configured for step-up authentication'
);

select ok(
  (select count(*)::bigint from public.access_permissions where requires_step_up and is_active) >= 4,
  'active step-up permission inventory includes rbac.manage and terminal WA capabilities'
);

select ok(
  pg_get_functiondef('public.has_app_permission(uuid,text,uuid,uuid)'::regprocedure) like '%has_step_up_auth()%',
  'has_app_permission delegates step-up enforcement to has_step_up_auth'
);

select ok(
  pg_get_functiondef('public.has_whatsapp_permission(text)'::regprocedure) like '%has_app_permission%',
  'has_whatsapp_permission inherits step-up-aware RBAC decisions'
);

-- ---------------------------------------------------------------------------
-- Behavioral JWT / AAL contract (mirrors auth.jwt() ->> ''aal'' semantics)
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;
select ok(not public.has_step_up_auth(), 'AAL1 session is not step-up authenticated');
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('role', 'authenticated', 'aal', 'aal2')::text,
  true
);
set local role authenticated;
select ok(public.has_step_up_auth(), 'AAL2 session satisfies step-up authentication');
reset role;

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;
select ok(public.has_step_up_auth(), 'service_role execution satisfies step-up authentication');
reset role;

-- ---------------------------------------------------------------------------
-- RBAC permission gate: rbac.manage requires AAL2 even for super_admin
-- ---------------------------------------------------------------------------
insert into public.users (id, email, role, is_active)
values ('a1900000-0000-0000-0000-000000000001', 'point19-super@test.invalid', 'super_admin', true)
on conflict (id) do update set role = excluded.role, is_active = true, deleted_at = null;

insert into public.user_role_map (user_id, role_id)
select 'a1900000-0000-0000-0000-000000000001', id
from public.roles
where role_key = 'super_admin'
on conflict (user_id, role_id) do nothing;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'a1900000-0000-0000-0000-000000000001',
    'role', 'authenticated',
    'aal', 'aal1'
  )::text,
  true
);
set local role authenticated;
select ok(
  not public.has_app_permission(
    'a1900000-0000-0000-0000-000000000001',
    'rbac.manage',
    null,
    null
  ),
  'super_admin rbac.manage is denied without AAL2'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'a1900000-0000-0000-0000-000000000001',
    'role', 'authenticated',
    'aal', 'aal2'
  )::text,
  true
);
select ok(
  public.has_app_permission(
    'a1900000-0000-0000-0000-000000000001',
    'rbac.manage',
    null,
    null
  ),
  'super_admin rbac.manage succeeds with AAL2'
);
reset role;

-- ---------------------------------------------------------------------------
-- WhatsApp terminal capability gate: wa.draft.promote requires AAL2
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'a1900000-0000-0000-0000-000000000001',
    'role', 'authenticated',
    'aal', 'aal1'
  )::text,
  true
);
set local role authenticated;
select ok(
  not public.has_whatsapp_permission('wa.draft.promote'),
  'wa.draft.promote fails without AAL2 even when role grants allow'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'a1900000-0000-0000-0000-000000000001',
    'role', 'authenticated',
    'aal', 'aal2'
  )::text,
  true
);
select ok(
  public.has_whatsapp_permission('wa.draft.promote'),
  'wa.draft.promote succeeds with AAL2'
);
reset role;

select ok(
  exists(
    select 1
    from public.access_permissions
    where permission_key = 'wa.disclosure.authorize'
      and requires_step_up
      and is_active
  ),
  'wa.disclosure.authorize requires step-up authentication'
);

-- ---------------------------------------------------------------------------
-- Sensitive RPC guard census: direct has_step_up_auth enforcement surfaces
-- ---------------------------------------------------------------------------
select ok(
  pg_get_functiondef('public.assert_credit_actor_v1(uuid,text)'::regprocedure) like '%has_step_up_auth()%'
  and pg_get_functiondef('public.assert_credit_actor_v1(uuid,text)'::regprocedure) like '%CREDIT_AAL2_REQUIRED%',
  'credit authority RPC fails closed without AAL2'
);

select ok(
  pg_get_functiondef('public.assert_finance_clearance_actor_v1(uuid)'::regprocedure) like '%has_step_up_auth()%'
  and pg_get_functiondef('public.assert_finance_clearance_actor_v1(uuid)'::regprocedure) like '%FINANCE_CLEARANCE_AAL2_REQUIRED%',
  'finance operations clearance RPC requires step-up authentication'
);

select ok(
  pg_get_functiondef('public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)'::regprocedure) like '%has_step_up_auth()%'
  and pg_get_functiondef('public.verify_order_payment_v1(uuid,numeric,text,text,text,text,text,uuid)'::regprocedure) like '%ORDER_PAYMENT_AAL2_REQUIRED%',
  'order payment verification RPC requires step-up authentication'
);

select ok(
  pg_get_functiondef('public.reject_order_payment_v1(uuid,text,text,text,uuid)'::regprocedure) like '%has_step_up_auth()%'
  and pg_get_functiondef('public.reject_order_payment_v1(uuid,text,text,text,uuid)'::regprocedure) like '%ORDER_PAYMENT_AAL2_REQUIRED%',
  'order payment rejection RPC requires step-up authentication'
);

select ok(
  pg_get_functiondef('public.assert_sales_order_pi_actor_v1(uuid,boolean)'::regprocedure) like '%has_step_up_auth()%'
  and pg_get_functiondef('public.assert_sales_order_pi_actor_v1(uuid,boolean)'::regprocedure) like '%SALES_ORDER_PI_AAL2_REQUIRED%',
  'sales-order PI actor assertion requires step-up when flagged'
);

select ok(
  pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%has_step_up_auth()%'
  and pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%COMPLAINT_LATE_EXCEPTION_AAL2_REQUIRED%',
  'late commercial complaint exception requires step-up authentication'
);

select ok(
  pg_get_functiondef('public.whatsapp_review_case_payment_proof(uuid,text,numeric,text,text,text)'::regprocedure) like '%has_step_up_auth()%',
  'WhatsApp payment-proof verification requires step-up authentication'
);

-- ---------------------------------------------------------------------------
-- Internal/mobile consumer census: staff provisioning step-up policy
-- ---------------------------------------------------------------------------
select has_column(
  'public',
  'staff_provisionable_roles',
  'requires_step_up',
  'staff_provisionable_roles.requires_step_up governs Edge Function step-up policy'
);

select ok(
  (select requires_step_up from public.staff_provisionable_roles where role_key = 'super_admin'),
  'super_admin provisioning requires step-up on the granting admin'
);

select ok(
  not (select requires_step_up from public.staff_provisionable_roles where role_key = 'tv_ready'),
  'operational TV roles do not require step-up for provisioning'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.grant_staff_role(uuid,text,text,text,uuid,text,text)',
    'EXECUTE'
  ),
  'authenticated cannot bypass Edge Function step-up gate via grant_staff_role'
);

-- ---------------------------------------------------------------------------
-- Behavioral negative: governed credit decision RPC rejects AAL1 finance actor
-- ---------------------------------------------------------------------------
insert into public.users (id, email, role, is_active)
values ('a1900000-0000-0000-0000-000000000002', 'point19-finance@test.invalid', 'FINANCE_EXEC', true)
on conflict (id) do update set role = excluded.role, is_active = true, deleted_at = null;

insert into public.companies (id, business_name, status)
values ('a1900000-0000-0000-0000-000000000010', 'Point19 Credit Co', 'active')
on conflict (id) do nothing;

insert into public.credit_requests (
  id, company_id, requested_by, credit_type, requested_amount, status, notes
)
values (
  'a1900000-0000-0000-0000-000000000011',
  'a1900000-0000-0000-0000-000000000010',
  'a1900000-0000-0000-0000-000000000002',
  'short_term_so',
  100,
  'pending',
  'point19 step-up negative probe'
)
on conflict (id) do nothing;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'a1900000-0000-0000-0000-000000000002',
    'role', 'authenticated',
    'aal', 'aal1'
  )::text,
  true
);
set local role authenticated;
select throws_ok(
  $$select public.decide_credit_request_v1(
    'a1900000-0000-0000-0000-000000000011'::uuid,
    true,
    'point19 approval attempt without step-up',
    'POINT19_TEST',
    'point19-corr',
    'point19-idem',
    'a1900000-0000-0000-0000-000000000002'::uuid
  )$$,
  'CREDIT_AAL2_REQUIRED',
  'governed credit decision RPC rejects AAL1 finance sessions'
);
reset role;

select * from finish();
rollback;
