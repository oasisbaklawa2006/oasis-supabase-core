begin;

select plan(18);

select has_function(
  'public', 'inspect_b2b_pending_phone_placeholder_v1', array['text'],
  'placeholder preflight RPC exists'
);
select has_function(
  'public', 'reconcile_b2b_pending_phone_placeholder_v1', array['text','uuid','uuid'],
  'placeholder reconciliation RPC exists'
);
select ok(
  not has_function_privilege('anon', 'public.inspect_b2b_pending_phone_placeholder_v1(text)', 'EXECUTE'),
  'anon cannot inspect identity placeholders'
);
select ok(
  not has_function_privilege('authenticated', 'public.reconcile_b2b_pending_phone_placeholder_v1(text,uuid,uuid)', 'EXECUTE'),
  'ordinary authenticated users cannot reconcile identities'
);
select ok(
  has_function_privilege('service_role', 'public.inspect_b2b_pending_phone_placeholder_v1(text)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.reconcile_b2b_pending_phone_placeholder_v1(text,uuid,uuid)', 'EXECUTE'),
  'service role owns the narrow compatibility authority'
);

-- Safe legacy placeholder tied to one pending B2B application.
select * from public.submit_b2b_access_request_v2(
  'PLACEHOLDER CERT CO', 'Pending Applicant', 'placeholder-cert@example.invalid',
  '9900012991', null, null, null, null, true, true
);
insert into public.users (
  id, role, phone, is_active, invite_status, is_sales_executive
) values (
  '92920000-0000-4000-8000-000000000001'::uuid,
  'PENDING', '+919900012991', true, 'active', false
);

select ok(
  (select eligible from public.inspect_b2b_pending_phone_placeholder_v1('+91 99000 12991')),
  'one PENDING/no-company/no-Auth placeholder with one application is eligible'
);
select is(
  (select placeholder_user_id from public.inspect_b2b_pending_phone_placeholder_v1('9900012991')),
  '92920000-0000-4000-8000-000000000001'::uuid,
  'preflight returns the exact legacy placeholder id'
);

-- Provider-confirmed Auth identity is created only after preflight. The generic
-- auth trigger intentionally leaves phone identities to the MSG91 authority.
insert into auth.users (
  id, email, phone, aud, role, phone_confirmed_at, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data
) values (
  '92920000-0000-4000-8000-000000000002'::uuid,
  '919900012991@phone.oasis.local', '+919900012991',
  'authenticated', 'authenticated', now(), now(), now(), now(),
  '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb
);

with repaired as (
  select * from public.reconcile_b2b_pending_phone_placeholder_v1(
    '+919900012991',
    '92920000-0000-4000-8000-000000000001'::uuid,
    '92920000-0000-4000-8000-000000000002'::uuid
  )
)
select ok((select reconciled and not replayed from repaired), 'safe placeholder reconciles exactly once');

select ok(
  (select is_active = false and deleted_at is not null and phone is null
          and mobile_number is null and cardinality(coalesce(secondary_phones, array[]::text[])) = 0
   from public.users where id='92920000-0000-4000-8000-000000000001'::uuid),
  'legacy row is preserved but loses every executable phone binding'
);
select ok(
  (select upper(role)='PENDING' and is_active and deleted_at is null
          and public.normalize_b2b_access_mobile_v2(phone)='919900012991'
   from public.users where id='92920000-0000-4000-8000-000000000002'::uuid),
  'new confirmed Auth id becomes the sole active PENDING public identity'
);
select is(
  (select count(*)::integer from public.users u
   where public.normalize_b2b_access_mobile_v2(coalesce(u.phone,''))='919900012991'
      or public.normalize_b2b_access_mobile_v2(coalesce(u.mobile_number,''))='919900012991'
      or exists (
        select 1 from unnest(coalesce(u.secondary_phones,array[]::text[])) p(phone)
        where public.normalize_b2b_access_mobile_v2(coalesce(p.phone,''))='919900012991'
      )),
  1,
  'reconciliation leaves exactly one public phone owner'
);
select ok(
  exists (
    select 1 from public.audit_logs
    where action_type='B2B_PENDING_AUTH_PLACEHOLDER_RECONCILED'
      and entity_id='92920000-0000-4000-8000-000000000002'
  ),
  'identity compatibility transition is audited'
);
with replay as (
  select * from public.reconcile_b2b_pending_phone_placeholder_v1(
    '919900012991',
    '92920000-0000-4000-8000-000000000001'::uuid,
    '92920000-0000-4000-8000-000000000002'::uuid
  )
)
select ok((select replayed and not reconciled from replay), 'reconciliation replay is idempotent');

-- Staff/company authority must never be interpreted as a recoverable placeholder.
select * from public.submit_b2b_access_request_v2(
  'STAFF COLLISION CERT CO', 'Staff Collision', 'staff-collision@example.invalid',
  '9900012992', null, null, null, null, true, true
);
insert into public.users (
  id, role, phone, is_active, invite_status, is_sales_executive
) values (
  '92920000-0000-4000-8000-000000000003'::uuid,
  'SUPER_ADMIN', '+919900012992', true, 'accepted', false
);
select is(
  (select reason from public.inspect_b2b_pending_phone_placeholder_v1('9900012992')),
  'authoritative_identity_not_placeholder'::text,
  'staff identity remains fail-closed'
);

-- Two public owners for one phone are ambiguous even when both look pending.
select * from public.submit_b2b_access_request_v2(
  'AMBIGUOUS CERT CO', 'Ambiguous Applicant', 'ambiguous-cert@example.invalid',
  '9900012993', null, null, null, null, true, true
);
insert into public.users (id, role, phone, is_active, invite_status, is_sales_executive) values
  ('92920000-0000-4000-8000-000000000004'::uuid, 'PENDING', '+919900012993', true, 'active', false),
  ('92920000-0000-4000-8000-000000000005'::uuid, 'PENDING', '9900012993', true, 'active', false);
select is(
  (select reason from public.inspect_b2b_pending_phone_placeholder_v1('9900012993')),
  'ambiguous_public_identity'::text,
  'duplicate public phone ownership is rejected'
);

-- Existing Auth ownership blocks recovery rather than creating another Auth user.
select * from public.submit_b2b_access_request_v2(
  'AUTH OWNER CERT CO', 'Auth Owner Applicant', 'auth-owner-cert@example.invalid',
  '9900012994', null, null, null, null, true, true
);
insert into public.users (id, role, phone, is_active, invite_status, is_sales_executive)
values ('92920000-0000-4000-8000-000000000006'::uuid, 'PENDING', '+919900012994', true, 'active', false);
insert into auth.users (
  id, email, phone, aud, role, phone_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '92920000-0000-4000-8000-000000000007'::uuid,
  'auth-owner-cert@example.invalid', '+919900012994',
  'authenticated', 'authenticated', now(), now(), now(),
  '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb
);
select is(
  (select reason from public.inspect_b2b_pending_phone_placeholder_v1('9900012994')),
  'auth_phone_already_owned'::text,
  'conflicting Auth phone ownership is rejected before mutation'
);

-- Confirm the rejected negative fixtures remain untouched.
select ok(
  (select is_active and deleted_at is null and phone is not null
   from public.users where id='92920000-0000-4000-8000-000000000003'::uuid),
  'staff collision row was not mutated'
);
select is(
  (select count(*)::integer from public.audit_logs
   where action_type='B2B_PENDING_AUTH_PLACEHOLDER_RECONCILED'
     and entity_id in (
       '92920000-0000-4000-8000-000000000003',
       '92920000-0000-4000-8000-000000000004',
       '92920000-0000-4000-8000-000000000005',
       '92920000-0000-4000-8000-000000000006'
     )),
  0,
  'negative collision cases produce no reconciliation audit/mutation'
);

select * from finish();
rollback;
