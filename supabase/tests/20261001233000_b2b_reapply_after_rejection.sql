-- Contract for migration 20261001233000_b2b_reapply_after_rejection.sql.
begin;
select plan(12);

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
    like '%status%rejected%',
  'email+mobile uniqueness excludes rejected history'
);

insert into public.b2b_applications(
  id,business_name,contact_name,contact_person,contact_email,contact_phone,mobile_number,
  trade_declaration,data_consent,status,reviewed_at,rejection_reason,created_at
) values (
  'b2b33000-0000-4000-8000-000000000001'::uuid,
  'Rejected Reapply Fixture',
  'Rejected Applicant',
  'Rejected Applicant',
  'reapply-cert@example.invalid',
  '9876500011',
  '9876500011',
  true,true,'rejected',
  '2026-09-30 10:00:00+00',
  'Prior rejection fixture',
  '2026-09-29 10:00:00+00'
);

set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);

create temporary table reapply_result as
select * from public.submit_b2b_access_request_v2(
  'Rejected Reapply Fixture',
  'Rejected Applicant',
  'reapply-cert@example.invalid',
  '9876500011',
  null,null,null,null,true,true
);

reset role;

select is((select application_status from reapply_result),'pending','reapply creates a fresh pending application');
select is((select duplicate from reapply_result),false,'first reapply is not reported as duplicate');
select isnt((select application_id from reapply_result),'b2b33000-0000-4000-8000-000000000001'::uuid,'reapply receives a new application identity');
select is((select status from public.b2b_applications where id='b2b33000-0000-4000-8000-000000000001'::uuid),'rejected','historical rejected application remains rejected');
select is(
  (select count(*)::integer from public.b2b_applications
   where lower(contact_email)='reapply-cert@example.invalid' and mobile_number='9876500011'),
  2,
  'reapply preserves rejected history plus one active pending cycle'
);
select is(
  (select count(*)::integer from public.audit_logs
   where action_type='B2B_ACCESS_REQUEST_REAPPLIED'
     and entity_id=(select application_id::text from reapply_result)),
  1,
  'reapply writes one lineage audit event'
);

set local role anon;
create temporary table retry_result as
select * from public.submit_b2b_access_request_v2(
  'Rejected Reapply Fixture',
  'Rejected Applicant',
  'reapply-cert@example.invalid',
  '9876500011',
  null,null,null,null,true,true
);
reset role;

select is((select duplicate from retry_result),true,'retry after reapply returns existing pending row');
select is((select application_status from retry_result),'pending','retry returns the pending status');
select is(
  (select application_id from retry_result),
  (select application_id from reapply_result),
  'retry returns the same pending application identity'
);
select is(
  (select count(*)::integer from public.b2b_applications
   where lower(contact_email)='reapply-cert@example.invalid' and mobile_number='9876500011'),
  2,
  'retry does not create a third application'
);

select * from finish();
rollback;
