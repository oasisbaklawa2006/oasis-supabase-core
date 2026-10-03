-- Contract for 20261001233000_b2b_reapply_after_rejection.sql.
-- The migration was never applied to production and is canonically paired with
-- 20261002140000_b2b_reapplication_policy_revert.sql. Canonical replay must
-- therefore finish in the restored pre-#384 behavior rather than retaining the
-- transient reapply-after-rejection policy.
begin;
select plan(6);

select has_function(
  'public','submit_b2b_access_request_v2',
  array['text','text','text','text','text','text','text','text','boolean','boolean'],
  'pre-login B2B access request RPC exists after canonical replay'
);

select ok(
  (select indexdef from pg_indexes
    where schemaname='public'
      and tablename='b2b_applications'
      and indexname='uq_b2b_applications_email_mobile')
    not like '%status%',
  'canonical replay restores email+mobile uniqueness across rejected history'
);

insert into public.b2b_applications(
  id,business_name,contact_name,contact_person,contact_email,contact_phone,mobile_number,
  trade_declaration,data_consent,status,reviewed_at,rejection_reason,created_at
) values (
  'b2b12330-0000-4000-8000-000000000001'::uuid,
  'Reconciled Policy Fixture',
  'Rejected Applicant',
  'Rejected Applicant',
  'reconciled-384-cert@example.invalid',
  '9876501233',
  '9876501233',
  true,true,'rejected',
  '2026-09-30 10:00:00+00',
  'Prior rejection fixture',
  '2026-09-29 10:00:00+00'
);

set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);

create temporary table reconciled_policy_result as
select * from public.submit_b2b_access_request_v2(
  'Reconciled Policy Fixture',
  'Rejected Applicant',
  'reconciled-384-cert@example.invalid',
  '9876501233',
  null,null,null,null,true,true
);

reset role;

select is(
  (select application_status from reconciled_policy_result),
  'rejected',
  'canonical replay keeps the historical rejected application canonical'
);
select is(
  (select duplicate from reconciled_policy_result),
  true,
  'rejected application retry remains a duplicate after the paired revert'
);
select is(
  (select application_id from reconciled_policy_result),
  'b2b12330-0000-4000-8000-000000000001'::uuid,
  'canonical replay returns the historical rejected application identity'
);
select is(
  (select count(*)::integer from public.b2b_applications
   where lower(contact_email)='reconciled-384-cert@example.invalid'
     and public.normalize_b2b_access_mobile_v2(coalesce(mobile_number,contact_phone,'')) =
         public.normalize_b2b_access_mobile_v2('9876501233')),
  1,
  'canonical replay does not create a fresh pending application after rejection'
);

select * from finish();
rollback;
