begin;

select plan(28);

select has_function(
  'public', 'submit_b2b_access_request_v2',
  array['text','text','text','text','text','text','text','text','boolean','boolean'],
  'pre-login B2B access intake RPC exists'
);
select has_function(
  'public', 'approve_b2b_access_request_v2',
  array['uuid','text','text'],
  'staff approval RPC exists'
);
select has_function(
  'public', 'claim_approved_b2b_access_request_v2',
  array[]::text[],
  'provider-confirmed identity claim RPC exists'
);

select ok(
  has_function_privilege('anon', 'public.submit_b2b_access_request_v2(text,text,text,text,text,text,text,text,boolean,boolean)', 'EXECUTE'),
  'anon may execute only the governed pre-login intake RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.submit_b2b_access_request_v2(text,text,text,text,text,text,text,text,boolean,boolean)', 'EXECUTE'),
  'stale authenticated sessions may still submit through the same safe intake RPC'
);
select ok(
  not has_function_privilege('anon', 'public.approve_b2b_access_request_v2(uuid,text,text)', 'EXECUTE'),
  'anon cannot execute approval RPC'
);
select ok(
  not has_function_privilege('anon', 'public.claim_approved_b2b_access_request_v2()', 'EXECUTE'),
  'anon cannot execute identity claim RPC'
);
select ok(
  not has_table_privilege('anon', 'public.b2b_applications', 'INSERT'),
  'generic anon direct application INSERT privilege is revoked'
);
select ok(
  not has_table_privilege('authenticated', 'public.b2b_applications', 'INSERT'),
  'generic authenticated direct application INSERT privilege is revoked'
);
select is(
  public.normalize_b2b_access_mobile_v2('9900001999'),
  '919900001999'::text,
  'Indian 10-digit mobile normalizes to country-code canonical digits'
);
select is(
  public.normalize_b2b_access_mobile_v2('+91 99000 01999'),
  '919900001999'::text,
  'formatted +91 mobile normalizes to the same canonical digits'
);

-- Anonymous prospect: no Supabase/Auth identity exists at application time.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;

with submitted as (
  select * from public.submit_b2b_access_request_v2(
    'PRELOGIN CERT TRADING CO',
    'Prelogin Applicant',
    'prelogin-cert@example.invalid',
    '9900001999',
    '07ABCDE1234F1Z5',
    '12 Test Commerce Centre, New Delhi',
    'OTHER',
    'CERT TRANSPORTER',
    true,
    true
  )
)
select is((select application_status from submitted), 'pending'::text, 'anonymous access request lands pending');

reset role;

select is(
  (select count(*)::integer from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  1,
  'anonymous submit creates exactly one canonical application row'
);
select is(
  (select status from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  'pending'::text,
  'application remains pending before staff review'
);
select is(
  (select user_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  null::uuid,
  'pre-login application has no user identity'
);
select is(
  (select resolved_company_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  null::uuid,
  'pre-login submission does not create or resolve a company authority'
);
select is(
  (select mobile_number from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  '919900001999'::text,
  'application stores normalized mobile for later verified claim matching'
);

select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
with replay as (
  select * from public.submit_b2b_access_request_v2(
    'PRELOGIN CERT TRADING CO',
    'Prelogin Applicant',
    'prelogin-cert@example.invalid',
    '+91 99000 01999',
    '07ABCDE1234F1Z5',
    '12 Test Commerce Centre, New Delhi',
    'OTHER',
    'CERT TRANSPORTER',
    true,
    true
  )
)
select ok((select duplicate from replay), 'anonymous retry is idempotent and returns existing application');
reset role;

-- Synthetic internal reviewer.
insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94000000-0000-4000-8000-000000000001'::uuid,
  'b2b-reviewer-cert@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values (
  '94000000-0000-4000-8000-000000000001'::uuid,
  'b2b-reviewer-cert@example.invalid',
  'super_admin', true, 'accepted'
)
on conflict (id) do update set role='super_admin', is_active=true, invite_status='accepted';
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;
with approved as (
  select * from public.approve_b2b_access_request_v2(
    (select id from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
    'B2B',
    'pre-login lifecycle certification'
  )
)
select ok((select identity_activation_required from approved), 'anonymous application approval requires later identity activation');
reset role;

select is(
  (select status from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  'approved'::text,
  'staff review approves the application without fabricating an identity'
);
select isnt(
  (select resolved_company_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  null::uuid,
  'staff approval resolves a canonical company'
);
select is(
  (select user_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  null::uuid,
  'approved application remains unclaimed until provider-verified login'
);
select is(
  (select status from public.companies where id=(select resolved_company_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid')),
  'pending'::text,
  'new company stays pending until verified identity claims approval'
);

-- Wrong verified phone must not claim the approved request.
insert into auth.users (
  id, email, aud, role, phone, phone_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94000000-0000-4000-8000-000000000002'::uuid,
  'wrong-phone-cert@example.invalid',
  'authenticated', 'authenticated', '+919900001998', now(), now(), now(),
  '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values ('94000000-0000-4000-8000-000000000002'::uuid, 'wrong-phone-cert@example.invalid', 'PENDING', true, 'pending')
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
with wrong_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok(not (select claimed from wrong_claim), 'different provider-confirmed phone cannot claim approved request');
reset role;

-- Correct provider-confirmed phone claims and activates exactly once.
insert into auth.users (
  id, email, aud, role, phone, phone_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94000000-0000-4000-8000-000000000003'::uuid,
  'right-phone-cert@example.invalid',
  'authenticated', 'authenticated', '+919900001999', now(), now(), now(),
  '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values ('94000000-0000-4000-8000-000000000003'::uuid, 'right-phone-cert@example.invalid', 'PENDING', true, 'pending')
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94000000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
with claimed as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok((select claimed from claimed), 'matching provider-confirmed phone claims approved request');
reset role;

select is(
  (select user_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid'),
  '94000000-0000-4000-8000-000000000003'::uuid,
  'claim binds canonical Auth identity to approved application'
);
select is(
  (select status from public.companies where id=(select resolved_company_id from public.b2b_applications where contact_email='prelogin-cert@example.invalid')),
  'active'::text,
  'company activates only after verified identity claim'
);
select is(
  upper((select role from public.users where id='94000000-0000-4000-8000-000000000003'::uuid)),
  'B2B_BUYER'::text,
  'verified claimant receives canonical public.users buyer role'
);
select ok(
  (select is_approved and lower(status)='approved' and lower(role)='b2b_buyer'
   from public.profiles where id='94000000-0000-4000-8000-000000000003'::uuid),
  'verified claimant receives approved Buyer profile linked through governed authority'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"94000000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
with replay_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok((select already_active from replay_claim) and not (select claimed from replay_claim), 'identity claim replay is idempotent');
reset role;

select ok(
  exists (
    select 1 from public.audit_logs
    where action_type='B2B_ACCESS_REQUEST_APPROVED_PENDING_IDENTITY'
      and entity_id=(select id::text from public.b2b_applications where contact_email='prelogin-cert@example.invalid')
  ),
  'staff approval pending identity is audited'
);
select ok(
  exists (
    select 1 from public.audit_logs
    where action_type='B2B_ACCESS_REQUEST_IDENTITY_CLAIMED'
      and entity_id=(select id::text from public.b2b_applications where contact_email='prelogin-cert@example.invalid')
  ),
  'provider-confirmed identity claim is audited'
);

select * from finish();
rollback;
