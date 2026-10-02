-- Contract for 20261002140000_b2b_reapplication_policy_revert.sql.
begin;
select plan(6);

select has_function(
  'public','submit_b2b_access_request_v2',
  array['text','text','text','text','text','text','text','text','boolean','boolean'],
  'pre-login B2B access request RPC exists'
);

select ok(
  (select indexdef from pg_indexes
    where schemaname='public'
      and tablename='b2b_applications'
      and indexname='uq_b2b_applications_email_mobile')
    not like '%status%',
  'email+mobile uniqueness again includes rejected history'
);

insert into public.b2b_applications(
  id,business_name,contact_name,contact_person,contact_email,contact_phone,mobile_number,
  trade_declaration,data_consent,status,reviewed_at,rejection_reason,created_at
) values (
  'b2b34000-0000-4000-8000-000000000001'::uuid,
  'Rejected Policy Fixture',
  'Rejected Applicant',
  'Rejected Applicant',
  'revert-384-cert@example.invalid',
  '9876500099',
  '9876500099',
  true,true,'rejected',
  '2026-09-30 10:00:00+00',
  'Prior rejection fixture',
  '2026-09-29 10:00:00+00'
);

set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);

create temporary table reverted_policy_result as
select * from public.submit_b2b_access_request_v2(
  'Rejected Policy Fixture',
  'Rejected Applicant',
  'revert-384-cert@example.invalid',
  '9876500099',
  null,null,null,null,true,true
);

reset role;

select is(
  (select application_status from reverted_policy_result),
  'rejected',
  'rejected application remains the canonical matching application'
);
select is(
  (select duplicate from reverted_policy_result),
  true,
  'rejected application retry is treated as duplicate under restored policy'
);
select is(
  (select application_id from reverted_policy_result),
  'b2b34000-0000-4000-8000-000000000001'::uuid,
  'restored policy returns the historical rejected application identity'
);
select is(
  (select count(*)::integer from public.b2b_applications
   where lower(contact_email)='revert-384-cert@example.invalid'
     and public.normalize_b2b_access_mobile_v2(coalesce(mobile_number,contact_phone,'')) =
         public.normalize_b2b_access_mobile_v2('9876500099')),
  1,
  'restored policy does not create a fresh pending application after rejection'
);

select * from finish();
rollback;
