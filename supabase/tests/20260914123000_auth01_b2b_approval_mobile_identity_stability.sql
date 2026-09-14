begin;

select plan(5);

select ok(
  position('V_MOBILE_RAW TEXT' in upper(pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure))) > 0,
  'approval keeps an unfiltered normalized mobile for stability comparison'
);

select ok(
  position('V_MOBILE := V_MOBILE_RAW' in upper(pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure))) > 0
  and position('LENGTH(V_MOBILE) < 10 OR LENGTH(V_MOBILE) > 15' in upper(pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure))) > 0,
  'only the advisory-lock/matching mobile is filtered to the supported length range'
);

select ok(
  position('IS DISTINCT FROM V_MOBILE_RAW' in upper(pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure))) > 0,
  'post-row-lock identity stability compares against the raw canonical mobile'
);

-- Legacy/trade-application path: this RPC historically accepted arbitrary
-- mobile strings. A 16-digit normalized value must not become a permanent
-- false APPLICATION_IDENTITY_CHANGED merely because it is excluded as a lock key.
insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94110000-0000-4000-8000-000000000001'::uuid,
  'auth01-legacy-mobile@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);
select set_config('request.jwt.claims', '{"sub":"94110000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select * from public.submit_b2b_trade_application_v1(
  p_business_name := 'AUTH01 LEGACY MOBILE CO',
  p_contact_name := 'Legacy Mobile Buyer',
  p_contact_email := 'auth01-legacy-mobile@example.invalid',
  p_mobile_number := '1234567890123456',
  p_registered_address := '1 Auth Test Lane, New Delhi',
  p_trade_declaration := true,
  p_data_consent := true
);

reset role;

-- A second, valid-mobile fixture proves supported mobile behavior is unchanged.
insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94110000-0000-4000-8000-000000000002'::uuid,
  'auth01-valid-mobile@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);
select set_config('request.jwt.claims', '{"sub":"94110000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;

select * from public.submit_b2b_trade_application_v1(
  p_business_name := 'AUTH01 VALID MOBILE CO',
  p_contact_name := 'Valid Mobile Buyer',
  p_contact_email := 'auth01-valid-mobile@example.invalid',
  p_mobile_number := '9900012399',
  p_registered_address := '2 Auth Test Lane, New Delhi',
  p_trade_declaration := true,
  p_data_consent := true
);

reset role;

-- Governed internal reviewer.
insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94110000-0000-4000-8000-000000000099'::uuid,
  'auth01-reviewer@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);
select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values (
  '94110000-0000-4000-8000-000000000099'::uuid,
  'auth01-reviewer@example.invalid',
  'super_admin', true, 'accepted'
)
on conflict (id) do update set role='super_admin', is_active=true, invite_status='accepted';
select set_config('oasis.staff_authority', 'off', true);

select set_config('request.jwt.claims', '{"sub":"94110000-0000-4000-8000-000000000099","role":"authenticated"}', true);
set local role authenticated;

select * from public.approve_b2b_access_request_v2(
  (select id from public.b2b_applications where contact_email='auth01-legacy-mobile@example.invalid'),
  'B2B',
  'AUTH-01 legacy out-of-range mobile stability regression'
);

select * from public.approve_b2b_access_request_v2(
  (select id from public.b2b_applications where contact_email='auth01-valid-mobile@example.invalid'),
  'B2B',
  'AUTH-01 valid mobile stability regression'
);

reset role;

select ok(
  (select status='approved' and resolved_company_id is not null
   from public.b2b_applications
   where contact_email='auth01-legacy-mobile@example.invalid'),
  'out-of-range legacy mobile no longer false-triggers APPLICATION_IDENTITY_CHANGED'
);

select ok(
  (select status='approved' and resolved_company_id is not null
   from public.b2b_applications
   where contact_email='auth01-valid-mobile@example.invalid'),
  'valid mobile approval behavior remains unchanged'
);

select * from finish();
rollback;
