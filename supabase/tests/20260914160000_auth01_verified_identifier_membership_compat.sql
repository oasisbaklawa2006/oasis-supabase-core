begin;

-- Contract for migration 20260914160000_auth01_verified_identifier_membership_compat.sql.
select plan(11);

select has_function(
  'public', 'claim_approved_b2b_access_request_v2', array[]::text[],
  'canonical B2B identity claim RPC remains available'
);

select ok(
  not has_function_privilege('anon', 'public.claim_approved_b2b_access_request_v2()', 'EXECUTE'),
  'anonymous callers cannot execute the identity claim RPC'
);

-- Submit one application before login with both an approved email and mobile.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select * from public.submit_b2b_access_request_v2(
  'LEGACY SPLIT IDENTITY CERT CO',
  'Legacy Split Buyer',
  'legacy-split-cert@example.invalid',
  '9900003991',
  '07ABCDE1234F1Z8',
  '16 Test Commerce Centre, New Delhi',
  'OTHER',
  'CERT TRANSPORTER',
  true,
  true
);
reset role;

-- Synthetic internal reviewer approves the request.
insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94200000-0000-4000-8000-000000000001'::uuid,
  'legacy-split-reviewer@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values (
  '94200000-0000-4000-8000-000000000001'::uuid,
  'legacy-split-reviewer@example.invalid',
  'super_admin', true, 'accepted'
)
on conflict (id) do update set role='super_admin', is_active=true, invite_status='accepted';
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94200000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
select * from public.approve_b2b_access_request_v2(
  (select id from public.b2b_applications where contact_email='legacy-split-cert@example.invalid'),
  'B2B',
  'legacy split identity certification'
);
reset role;

select ok(
  (select status='approved' and user_id is null and resolved_company_id is not null
   from public.b2b_applications where contact_email='legacy-split-cert@example.invalid'),
  'approved fixture begins unclaimed with one resolved company'
);

-- First, the legacy confirmed-email Auth identity claims the application.
insert into auth.users (
  id, email, aud, role, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94200000-0000-4000-8000-000000000002'::uuid,
  'legacy-split-cert@example.invalid',
  'authenticated', 'authenticated', now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values (
  '94200000-0000-4000-8000-000000000002'::uuid,
  'legacy-split-cert@example.invalid',
  'PENDING', true, 'pending'
)
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94200000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
with legacy_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok((select claimed from legacy_claim), 'legacy confirmed-email identity claims the application first');
reset role;

select is(
  (select user_id from public.b2b_applications where contact_email='legacy-split-cert@example.invalid'),
  '94200000-0000-4000-8000-000000000002'::uuid,
  'application is bound to the legacy email Auth UUID'
);

-- A separate provider-confirmed phone Auth UUID now owns the approved mobile.
-- This mirrors the production regression: mobile Auth exists, public row is
-- pending, and the approved application is already bound to an older email UUID.
insert into auth.users (
  id, phone, aud, role, phone_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94200000-0000-4000-8000-000000000003'::uuid,
  '+919900003991',
  'authenticated', 'authenticated', now(), now(), now(),
  '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, phone, role, is_active, invite_status)
values (
  '94200000-0000-4000-8000-000000000003'::uuid,
  '+919900003991',
  'PENDING', true, 'pending'
)
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94200000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
with phone_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok(
  (select claimed and not already_active and company_id is not null from phone_claim),
  'verified mobile UUID activates membership from the legacy-bound approved application'
);
reset role;

select is(
  (select user_id from public.b2b_applications where contact_email='legacy-split-cert@example.invalid'),
  '94200000-0000-4000-8000-000000000002'::uuid,
  'mobile compatibility activation preserves the existing application owner'
);

select ok(
  (select upper(role)='B2B_BUYER' and is_active and company_id=(
      select resolved_company_id from public.b2b_applications where contact_email='legacy-split-cert@example.invalid'
    )
   from public.users where id='94200000-0000-4000-8000-000000000003'::uuid),
  'verified mobile UUID becomes an active Buyer member of the approved company'
);

select ok(
  (select is_approved and lower(status)='approved' and lower(role)='b2b_buyer'
   from public.profiles where id='94200000-0000-4000-8000-000000000003'::uuid),
  'verified mobile UUID receives an approved Buyer profile'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"94200000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
with replay_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok(
  (select already_active and not claimed from replay_claim),
  'verified mobile membership replay is idempotent'
);
reset role;

select ok(
  exists (
    select 1
    from public.audit_logs
    where action_type='B2B_ACCESS_REQUEST_IDENTITY_CLAIMED'
      and actor_id='94200000-0000-4000-8000-000000000003'::uuid
      and coalesce((new_value->>'verified_mobile_present')::boolean, false)
      and coalesce((new_value->>'application_binding_preserved')::boolean, false)
      and coalesce((new_value->>'membership_activated')::boolean, false)
  ),
  'legacy-bound mobile membership activation is explicitly audited without rebinding'
);

select * from finish();
rollback;
