-- Contract for migration 20261118082500_wa100_shadow_client_approval_queue.sql.
begin;
select plan(15);

select ok(
  not has_function_privilege('anon', 'public.queue_whatsapp_shadow_client_for_approval_v1(uuid,text,text,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.queue_whatsapp_shadow_client_for_approval_v1(uuid,text,text,text,text)', 'EXECUTE'),
  'approval queue RPC is callable only by authenticated sessions'
);

insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values
  ('78c85400-0000-4000-8000-000000000001', 'wa100-queue-admin@example.invalid', 'authenticated', 'authenticated', now(), now(), now()),
  ('78c85400-0000-4000-8000-000000000002', 'wa100-queue-buyer@example.invalid', 'authenticated', 'authenticated', now(), now(), now());

select set_config('oasis.staff_authority', 'governed', true);
insert into public.users (id, email, role, is_active, invite_status)
values ('78c85400-0000-4000-8000-000000000001', 'wa100-queue-admin@example.invalid', 'super_admin', true, 'accepted')
on conflict (id) do update set role = 'super_admin', is_active = true, invite_status = 'accepted';
select set_config('oasis.staff_authority', 'off', true);

insert into public.companies (id, business_name, gst_number, status)
values ('78c85400-0000-4000-8000-000000000003', 'WA100 Shadow Queue Fixture', 'WA:919876543210', 'shadow'),
       ('78c85400-0000-4000-8000-000000000004', 'WA100 Active Company Fixture', null, 'active');

select set_config('request.jwt.claims', '{"sub":"78c85400-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;
select throws_ok($$
  select public.queue_whatsapp_shadow_client_for_approval_v1(
    '78c85400-0000-4000-8000-000000000003', 'WA100 Queued Client', null, null, null)
$$, '42501', 'Shadow client approval requires an active administrator');
reset role;

select set_config('request.jwt.claims', '{"sub":"78c85400-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select set_config('wa100.first_app_id', coalesce((select public.queue_whatsapp_shadow_client_for_approval_v1(
    '78c85400-0000-4000-8000-000000000003', 'WA100 Queued Client', null, null, '1 Test Lane'))::text, ''), true);
select ok(nullif(current_setting('wa100.first_app_id', true), '') is not null,
  'first authorized queue call returns a nonnull application UUID');
select throws_ok($$
  select public.queue_whatsapp_shadow_client_for_approval_v1(
    '78c85400-0000-4000-8000-000000000004', 'WA100 Wrong Target', null, null, null)
$$, '55000', 'Company is no longer in the Shadow Client queue');
reset role;

select is(
  (select status from public.companies where id = '78c85400-0000-4000-8000-000000000003'),
  'pending_approval', 'company still awaits formal approval'
);
select is(
  (select count(*) from public.b2b_applications where resolved_company_id = '78c85400-0000-4000-8000-000000000003'
    and status = 'pending' and registered_address = '1 Test Lane' and user_id is null),
  1::bigint, 'formal application points to the existing company without inventing a buyer identity'
);
select is(
  (select id::text from public.b2b_applications
   where resolved_company_id = '78c85400-0000-4000-8000-000000000003'),
  current_setting('wa100.first_app_id', true),
  'the very first response identifies the inserted application'
);
select is(
  (select mobile_number from public.b2b_applications
   where resolved_company_id = '78c85400-0000-4000-8000-000000000003'),
  '+919876543210', 'Client Governance can display recovered shadow phone'
);
select is(
  (select wa100_shadow_queue_origin from public.b2b_applications
   where resolved_company_id = '78c85400-0000-4000-8000-000000000003'),
  'wa100_shadow_queue_v1', 'immutable-intent origin is independent of editable notes'
);
select is(
  public.queue_whatsapp_shadow_client_for_approval_v1(
    '78c85400-0000-4000-8000-000000000003', 'WA100 Queued Client', null, null, '1 Test Lane')::text,
  current_setting('wa100.first_app_id', true),
  'a retry returns the original first-call application UUID'
);
select is(
  (select count(*) from public.b2b_applications
    where resolved_company_id = '78c85400-0000-4000-8000-000000000003'),
  1::bigint, 'separate-statement count proves the retry made no duplicate'
);
update public.b2b_applications
set admin_notes = 'Follow-up requested by reviewer'
where resolved_company_id = '78c85400-0000-4000-8000-000000000003';
select is(
  public.queue_whatsapp_shadow_client_for_approval_v1(
    '78c85400-0000-4000-8000-000000000003', 'WA100 Queued Client', null, null, '1 Test Lane')::text,
  current_setting('wa100.first_app_id', true),
  'editing governance notes does not break idempotent retry'
);
select is(
  (select count(*) from public.b2b_applications
    where resolved_company_id = '78c85400-0000-4000-8000-000000000003'),
  1::bigint, 'post-notes retry still links to one application'
);
select throws_ok($$
  select public.queue_whatsapp_shadow_client_for_approval_v1(
    '78c85400-0000-4000-8000-000000000003', 'WA100 Conflicting Retry', null, null, null)
$$, '55000', 'Client is already queued with different details');
select ok(
  not exists (select 1 from public.orders where company_id = '78c85400-0000-4000-8000-000000000003')
  and not exists (select 1 from public.sales_order_drafts where company_id = '78c85400-0000-4000-8000-000000000003'),
  'queueing a client creates neither a commercial order nor a draft'
);

select * from finish();
rollback;
