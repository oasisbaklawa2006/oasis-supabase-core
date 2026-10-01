-- Contract for 20261001190000_b2b_reapplication_after_rejection.sql
begin;
select plan(9);

insert into public.b2b_applications(
  id,business_name,contact_name,contact_person,contact_email,contact_phone,mobile_number,
  trade_declaration,data_consent,status,created_at
) values (
  '91100000-0000-0000-0000-000000000001',
  'Rejected Reapply Co','Rejected User','Rejected User','reapply@example.invalid',
  '+91 99999 11111','919999911111',true,true,'rejected',statement_timestamp()-interval '1 day'
);

create temp table reapplied as
select * from public.submit_b2b_access_request_v2(
  'Rejected Reapply Co',
  'Rejected User',
  'reapply@example.invalid',
  '+91 99999 11111',
  null,null,null,null,true,true
);

select isnt(
  (select application_id from reapplied),
  '91100000-0000-0000-0000-000000000001'::uuid,
  'reapplication creates a new application instead of rewriting rejected history'
);
select is((select application_status from reapplied),'pending'::text,'reapplication starts a fresh pending review');
select is((select duplicate from reapplied),false,'first reapplication is not reported as duplicate');
select is(
  (select status from public.b2b_applications where id='91100000-0000-0000-0000-000000000001'),
  'rejected'::text,
  'original rejection history remains intact'
);
select is(
  (select count(*)::int from public.b2b_applications
    where lower(contact_email)='reapply@example.invalid'
      and mobile_number='919999911111'),
  2,
  'rejected history and new pending cycle coexist'
);

create temp table replay as
select * from public.submit_b2b_access_request_v2(
  'Rejected Reapply Co',
  'Rejected User',
  'reapply@example.invalid',
  '+91 99999 11111',
  null,null,null,null,true,true
);

select is(
  (select application_id from replay),
  (select application_id from reapplied),
  'retry of the fresh application returns the same pending application'
);
select is((select duplicate from replay),true,'retry is explicitly idempotent');

insert into public.b2b_applications(
  id,business_name,contact_name,contact_person,contact_email,contact_phone,mobile_number,
  trade_declaration,data_consent,status,created_at
) values (
  '91100000-0000-0000-0000-000000000002',
  'Approved Existing Co','Approved User','Approved User','approved-existing@example.invalid',
  '+91 99999 22222','919999922222',true,true,'approved',statement_timestamp()
);

select is(
  (select application_status from public.submit_b2b_access_request_v2(
    'Approved Existing Co','Approved User','approved-existing@example.invalid',
    '+91 99999 22222',null,null,null,null,true,true
  )),
  'approved'::text,
  'approved application remains idempotent and cannot be bypassed by reapplying'
);
select is(
  (select duplicate from public.submit_b2b_access_request_v2(
    'Approved Existing Co','Approved User','approved-existing@example.invalid',
    '+91 99999 22222',null,null,null,null,true,true
  )),
  true,
  'approved identity pair returns duplicate=true'
);

select * from finish();
rollback;
