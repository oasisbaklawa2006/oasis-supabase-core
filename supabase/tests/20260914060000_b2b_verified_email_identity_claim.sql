begin;

select plan(15);

select has_function(
  'public', 'claim_approved_b2b_access_request_v2', array[]::text[],
  'canonical B2B identity claim RPC remains available'
);

select ok(
  not has_function_privilege('anon', 'public.claim_approved_b2b_access_request_v2()', 'EXECUTE'),
  'anonymous callers still cannot execute the identity claim RPC'
);

select ok(
  has_function_privilege('authenticated', 'public.claim_approved_b2b_access_request_v2()', 'EXECUTE'),
  'authenticated verified identities may execute the claim RPC'
);

-- Create two pre-login applications. One will be claimed by confirmed email;
-- the second proves an unconfirmed Auth email cannot claim.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;

select * from public.submit_b2b_access_request_v2(
  'EMAIL CLAIM CERT CO',
  'Email Claim Buyer',
  'email-claim-cert@example.invalid',
  '9900002991',
  '07ABCDE1234F1Z6',
  '14 Test Commerce Centre, New Delhi',
  'OTHER',
  'CERT TRANSPORTER',
  true,
  true
);

select * from public.submit_b2b_access_request_v2(
  'UNCONFIRMED EMAIL CERT CO',
  'Unconfirmed Email Buyer',
  'unconfirmed-email-cert@example.invalid',
  '9900002992',
  '07ABCDE1234F1Z7',
  '15 Test Commerce Centre, New Delhi',
  'OTHER',
  'CERT TRANSPORTER',
  true,
  true
);

reset role;

-- Synthetic internal reviewer.
insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94100000-0000-4000-8000-000000000001'::uuid,
  'email-claim-reviewer@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values (
  '94100000-0000-4000-8000-000000000001'::uuid,
  'email-claim-reviewer@example.invalid',
  'super_admin', true, 'accepted'
)
on conflict (id) do update set role='super_admin', is_active=true, invite_status='accepted';
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94100000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
set local role authenticated;

select * from public.approve_b2b_access_request_v2(
  (select id from public.b2b_applications where contact_email='email-claim-cert@example.invalid'),
  'B2B',
  'verified email identity certification'
);
select * from public.approve_b2b_access_request_v2(
  (select id from public.b2b_applications where contact_email='unconfirmed-email-cert@example.invalid'),
  'B2B',
  'unconfirmed email negative certification'
);

reset role;

select ok(
  (select status='approved' and user_id is null and resolved_company_id is not null
   from public.b2b_applications where contact_email='email-claim-cert@example.invalid'),
  'approved email fixture is ready for later identity activation'
);

-- A different confirmed email must not claim the approved request.
insert into auth.users (
  id, email, aud, role, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94100000-0000-4000-8000-000000000002'::uuid,
  'wrong-email-cert@example.invalid',
  'authenticated', 'authenticated', now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values ('94100000-0000-4000-8000-000000000002'::uuid, 'wrong-email-cert@example.invalid', 'PENDING', true, 'pending')
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94100000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
set local role authenticated;
with wrong_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok(not (select claimed from wrong_claim), 'different confirmed email cannot claim an approved request');
reset role;

-- A matching but unconfirmed email must not claim either.
insert into auth.users (
  id, email, aud, role, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94100000-0000-4000-8000-000000000003'::uuid,
  'unconfirmed-email-cert@example.invalid',
  'authenticated', 'authenticated', now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values ('94100000-0000-4000-8000-000000000003'::uuid, 'unconfirmed-email-cert@example.invalid', 'PENDING', true, 'pending')
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94100000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
set local role authenticated;
with unconfirmed_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok(not (select claimed from unconfirmed_claim), 'unconfirmed Auth email cannot claim an approved request');
reset role;

-- Correct provider-confirmed email claims and activates the approved request.
insert into auth.users (
  id, email, aud, role, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
) values (
  '94100000-0000-4000-8000-000000000004'::uuid,
  'email-claim-cert@example.invalid',
  'authenticated', 'authenticated', now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values ('94100000-0000-4000-8000-000000000004'::uuid, 'email-claim-cert@example.invalid', 'PENDING', true, 'pending')
on conflict (id) do nothing;
select set_config('oasis.staff_authority', 'off', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"94100000-0000-4000-8000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;
with claimed as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok((select claimed from claimed), 'matching provider-confirmed email claims approved request');
reset role;

select is(
  (select user_id from public.b2b_applications where contact_email='email-claim-cert@example.invalid'),
  '94100000-0000-4000-8000-000000000004'::uuid,
  'verified email claimant is bound to the canonical application'
);

select is(
  (select status from public.companies where id=(select resolved_company_id from public.b2b_applications where contact_email='email-claim-cert@example.invalid')),
  'active'::text,
  'company activates after verified email claim'
);

select is(
  upper((select role from public.users where id='94100000-0000-4000-8000-000000000004'::uuid)),
  'B2B_BUYER'::text,
  'verified email claimant receives Buyer role'
);

select ok(
  (select is_approved and lower(status)='approved' and lower(role)='b2b_buyer'
   from public.profiles where id='94100000-0000-4000-8000-000000000004'::uuid),
  'verified email claimant receives approved Buyer profile'
);

select is(
  lower((select email from public.profiles where id='94100000-0000-4000-8000-000000000004'::uuid)),
  'email-claim-cert@example.invalid'::text,
  'approved Buyer profile retains the approved contact email'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"94100000-0000-4000-8000-000000000004","role":"authenticated"}',
  true
);
set local role authenticated;
with replay_claim as (
  select * from public.claim_approved_b2b_access_request_v2()
)
select ok((select already_active from replay_claim) and not (select claimed from replay_claim), 'verified email claim replay is idempotent');
reset role;

select ok(
  exists (
    select 1 from public.audit_logs
    where action_type='B2B_ACCESS_REQUEST_IDENTITY_CLAIMED'
      and actor_id='94100000-0000-4000-8000-000000000004'::uuid
      and coalesce((new_value->>'verified_email_present')::boolean, false)
  ),
  'email-based Buyer claim is explicitly audited as verified email'
);

select is(
  (select user_id from public.b2b_applications where contact_email='unconfirmed-email-cert@example.invalid'),
  null::uuid,
  'negative unconfirmed-email fixture remains unclaimed'
);

select * from finish();
rollback;
