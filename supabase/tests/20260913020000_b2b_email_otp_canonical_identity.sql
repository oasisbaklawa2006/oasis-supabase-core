begin;

-- Contract coverage for migration 20260913020000_b2b_email_otp_canonical_identity.sql.
select plan(16);

select has_table('public', 'b2b_email_otp_challenges', 'email OTP challenge table exists');
select has_function(
  'public', 'consume_b2b_email_otp_challenge_v1', array['uuid','text'],
  'atomic email OTP consume RPC exists'
);
select has_function(
  'public', 'activate_approved_b2b_access_by_verified_email_v1', array['uuid','uuid','text'],
  'verified-email Buyer activation RPC exists'
);

select ok(
  not has_function_privilege('anon', 'public.consume_b2b_email_otp_challenge_v1(uuid,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.consume_b2b_email_otp_challenge_v1(uuid,text)', 'EXECUTE'),
  'public roles cannot consume server email OTP challenges'
);
select ok(
  not has_function_privilege('anon', 'public.activate_approved_b2b_access_by_verified_email_v1(uuid,uuid,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.activate_approved_b2b_access_by_verified_email_v1(uuid,uuid,text)', 'EXECUTE'),
  'public roles cannot activate Buyer identity by email'
);
select ok(
  has_function_privilege('service_role', 'public.consume_b2b_email_otp_challenge_v1(uuid,text)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.activate_approved_b2b_access_by_verified_email_v1(uuid,uuid,text)', 'EXECUTE'),
  'service role owns both email OTP authorities'
);
select ok(
  not has_table_privilege('anon', 'public.b2b_email_otp_challenges', 'SELECT')
  and not has_table_privilege('authenticated', 'public.b2b_email_otp_challenges', 'SELECT'),
  'OTP challenge storage is not readable by public roles'
);
select ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='b2b_email_otp_challenges'),
  'OTP challenge storage has RLS enabled'
);

select * from public.submit_b2b_access_request_v2(
  'EMAIL OTP CERT CO',
  'Email OTP Buyer',
  'email-otp-cert@example.invalid',
  '9900013991',
  null, null, null, null,
  true, true
);

insert into public.companies (id, business_name, phone, status, price_tier)
values (
  '93930000-0000-4000-8000-000000000001'::uuid,
  'EMAIL OTP CERT CO',
  '+919900013991',
  'pending',
  'CERT'
);

perform set_config('app.b2b_application_rpc_managed', 'on', true);
update public.b2b_applications
set status='approved',
    resolved_company_id='93930000-0000-4000-8000-000000000001'::uuid,
    assigned_price_tier='CERT',
    reviewed_at=now()
where contact_email='email-otp-cert@example.invalid';
perform set_config('app.b2b_application_rpc_managed', 'off', true);

insert into auth.users (
  id, email, phone, aud, role, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data
) values (
  '93930000-0000-4000-8000-000000000002'::uuid,
  '919900013991@phone.oasis.local',
  '+919900013991',
  'authenticated', 'authenticated', now(),
  now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
);

insert into public.b2b_email_otp_challenges (
  id, application_id, normalized_email, otp_mac, expires_at, max_attempts
)
select
  '93930000-0000-4000-8000-000000000003'::uuid,
  id,
  'email-otp-cert@example.invalid',
  repeat('a', 64),
  now() + interval '10 minutes',
  3
from public.b2b_applications
where contact_email='email-otp-cert@example.invalid';

select ok(
  not (select verified from public.consume_b2b_email_otp_challenge_v1(
    '93930000-0000-4000-8000-000000000003'::uuid, repeat('b',64)
  )),
  'wrong OTP MAC is rejected'
);
select is(
  (select attempt_count from public.b2b_email_otp_challenges
   where id='93930000-0000-4000-8000-000000000003'::uuid),
  1,
  'wrong OTP increments the server-side attempt counter'
);
select ok(
  (select verified from public.consume_b2b_email_otp_challenge_v1(
    '93930000-0000-4000-8000-000000000003'::uuid, repeat('a',64)
  )),
  'correct OTP MAC atomically verifies and consumes the challenge'
);
select ok(
  not (select verified from public.consume_b2b_email_otp_challenge_v1(
    '93930000-0000-4000-8000-000000000003'::uuid, repeat('a',64)
  )),
  'consumed OTP challenge cannot be replayed'
);

select ok(
  (select activated from public.activate_approved_b2b_access_by_verified_email_v1(
    (select id from public.b2b_applications where contact_email='email-otp-cert@example.invalid'),
    '93930000-0000-4000-8000-000000000002'::uuid,
    'EMAIL-OTP-CERT@EXAMPLE.INVALID'
  )),
  'server-verified email activates the canonical phone-bound Buyer identity'
);
select ok(
  exists (
    select 1 from public.b2b_applications a
    where a.contact_email='email-otp-cert@example.invalid'
      and a.user_id='93930000-0000-4000-8000-000000000002'::uuid
  )
  and exists (
    select 1 from public.users u
    where u.id='93930000-0000-4000-8000-000000000002'::uuid
      and lower(u.role)='b2b_buyer'
      and u.company_id='93930000-0000-4000-8000-000000000001'::uuid
  ),
  'application and public Buyer authority converge on one UUID'
);
select ok(
  (select status='active' from public.companies
   where id='93930000-0000-4000-8000-000000000001'::uuid),
  'verified email activation activates the resolved company'
);
select ok(
  exists (
    select 1 from public.audit_logs
    where action_type='B2B_ACCESS_REQUEST_EMAIL_IDENTITY_ACTIVATED'
      and entity_id=(select id::text from public.b2b_applications where contact_email='email-otp-cert@example.invalid')
  ),
  'verified-email activation is audited'
);

select * from finish();
rollback;
