-- Contract for 20261117110000_wa100_order_notification_command_foundation.sql
-- WA-100 #540: staged Core outbound command boundary; never live sends.
begin;
select plan(34);

select has_table('public','wa100_utility_template_registry','wa100_utility_template_registry exists');
select has_table('public','wa100_order_notification_commands','wa100_order_notification_commands exists');
select has_table('public','wa100_order_notification_command_events','wa100_order_notification_command_events exists');
select has_function('public','enqueue_wa100_order_notification_v1',
  array['uuid','text','uuid','text','text','integer']);

select ok(has_function_privilege('service_role',
  'public.enqueue_wa100_order_notification_v1(uuid,text,uuid,text,text,integer)',
  'EXECUTE'), 'service_role can invoke protected enqueue');
select ok(not has_function_privilege('authenticated',
  'public.enqueue_wa100_order_notification_v1(uuid,text,uuid,text,text,integer)',
  'EXECUTE'), 'ordinary authenticated users cannot enqueue');
select ok(not has_function_privilege('anon',
  'public.enqueue_wa100_order_notification_v1(uuid,text,uuid,text,text,integer)',
  'EXECUTE'), 'anonymous users cannot enqueue');
select ok(not has_table_privilege('authenticated',
  'public.wa100_order_notification_commands','INSERT'),
  'ordinary users cannot forge outbound commands');
select ok(not has_table_privilege('authenticated',
  'public.wa100_order_notification_commands','SELECT'),
  'ordinary users cannot read confidential recipient rows');
select ok(exists (
  select 1 from pg_trigger
  where tgrelid='public.wa100_order_notification_commands'::regclass
    and tgname='wa100_command_immutability' and not tgisinternal
), 'immutable command guard blocks even privileged mutation');
select ok(not has_table_privilege('service_role',
  'public.wa100_order_notification_commands','INSERT'),
  'service_role cannot bypass trusted Core RPC with direct ledger insert');

select ok(exists (
  select 1 from pg_constraint c
  where c.conrelid='public.wa100_order_notification_commands'::regclass
    and c.conname='wa100_order_event_revision_uniq'
), 'one durable command per order event and revision');

select ok(exists (
  select 1 from pg_constraint c
  where c.conrelid='public.wa100_utility_template_registry'::regclass
    and c.conname='wa100_template_approval_guard'
), 'enabled template metadata requires approval evidence');
select ok(exists (
  select 1 from pg_constraint c
  where c.conrelid='public.wa100_order_notification_commands'::regclass
    and c.contype='c'
    and pg_get_constraintdef(c.oid) like '%NOT_SENT_RELEASE_GATED%'
), 'command status cannot claim sent/delivered in this release');

select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select throws_ok($wa100_untrusted$
  select public.enqueue_wa100_order_notification_v1(
    '55550000-0000-0000-0000-000000000001',
    'SO_CREATED','55550000-0000-0000-0000-000000000002','so_confirmation','en',1)
$wa100_untrusted$, '42501');

select set_config('request.jwt.claims','{"role":"service_role"}',true);
select throws_ok($wa100_bad_event$
  select public.enqueue_wa100_order_notification_v1(
    '55550000-0000-0000-0000-000000000001',
    'INVALID','55550000-0000-0000-0000-000000000002','so_confirmation','en',1)
$wa100_bad_event$, '22023');
select throws_ok($wa100_no_order$
  select public.enqueue_wa100_order_notification_v1(
    '55550000-0000-0000-0000-000000000001',
    'SO_CREATED','55550000-0000-0000-0000-000000000002','so_confirmation','en',1)
$wa100_no_order$, '23503');


-- Runtime contract fixtures: local disposable DB only. Every row rolls back.
-- Provider credentials, Edge Functions and any network sender are not called.
insert into public.companies (id,business_name,status,is_frozen)
values
  ('55000000-0000-4000-8000-000000000001','WA100_LOCAL_TEST_COMPANY','active',false),
  ('55000000-0000-4000-8000-000000000002','WA100_OTHER_COMPANY','active',false);
insert into public.users (id,role,full_name)
values ('55000000-0000-4000-8000-000000000003','ADMIN','WA100 LOCAL TEST ACTOR');
insert into public.whatsapp_contacts (id,phone_number)
values ('55000000-0000-4000-8000-000000000004','919900000001');
insert into public.whatsapp_message_packets
  (id,contact_id,stitched_content,first_message_at,last_message_at)
values (
  '55000000-0000-4000-8000-000000000005',
  '55000000-0000-4000-8000-000000000004',
  '{}'::jsonb,now()::timestamp,now()::timestamp
);
insert into public.whatsapp_communication_cases
  (id,packet_id,company_id,rule_version)
values (
  '55000000-0000-4000-8000-000000000006',
  '55000000-0000-4000-8000-000000000005',
  '55000000-0000-4000-8000-000000000001','WA100_LOCAL_ONLY'
);
insert into public.whatsapp_case_identities (
  id,case_id,identity_role,party_type,party_id,phone_e164,
  resolution_status,resolved_by,resolved_at
) values (
  '55000000-0000-4000-8000-000000000007',
  '55000000-0000-4000-8000-000000000006',
  'COMMERCIAL_CUSTOMER','COMPANY',
  '55000000-0000-4000-8000-000000000001','+919900000001',
  'CONFIRMED','55000000-0000-4000-8000-000000000003',now()
);
insert into public.whatsapp_sender_commercial_authorizations (
  id,contact_id,company_id,disclosure_scope,identity_evidence,
  authorized_by,authorized_at,valid_until,status
) values (
  '55000000-0000-4000-8000-000000000008',
  '55000000-0000-4000-8000-000000000004',
  '55000000-0000-4000-8000-000000000001',
  array['sales_order']::text[],
  '{"origin":"WA100_TEST_ONLY_NOT_REAL_AUTHORITY"}'::jsonb,
  '55000000-0000-4000-8000-000000000003',
  now(),now()+interval '1 day','ACTIVE'
);
insert into public.whatsapp_communication_preferences (
  id,identity_id,communication_class,consent_status,
  effective_from,reason,correlation_key
) values (
  '55000000-0000-4000-8000-000000000009',
  '55000000-0000-4000-8000-000000000007',
  'TRANSACTIONAL','OPTED_IN',now()-interval '1 day',
  'WA100_LOCAL_TEST_NOT_CUSTOMER_CONSENT','WA100_LOCAL_CONSENT_550'
);
insert into public.orders (id,company_id,status,order_number,order_origin)
values (
  '55000000-0000-4000-8000-000000000010',
  '55000000-0000-4000-8000-000000000001',
  'submitted','WA100_TEST_SO_550','MANUAL'
),(
  '55000000-0000-4000-8000-000000000011',
  '55000000-0000-4000-8000-000000000002',
  'submitted','WA100_TEST_OTHER_550','MANUAL'
);
insert into public.wa100_utility_template_registry (
  event_type,template_name,language_code,provider_approval_reference,
  approved_by,approved_at,enabled
) values (
  'SO_CREATED','so_confirmation','en','WA100_FAKE_TEST_APPROVAL',
  '55000000-0000-4000-8000-000000000003',now(),true
),(
  'SO_CREATED','so_confirmation_alt','en','WA100_FAKE_TEST_APPROVAL',
  '55000000-0000-4000-8000-000000000003',now(),true
);

select lives_ok($wa100_valid$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000010',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'so_confirmation','en',1)
$wa100_valid$, 'explicitly authorized local test command can be staged');
select is((
  select count(*)::integer from public.wa100_order_notification_commands
  where order_id='55000000-0000-4000-8000-000000000010'
),1,'exactly one durable command created');
select is((
  select status from public.wa100_order_notification_commands
  where order_id='55000000-0000-4000-8000-000000000010'
),'NOT_SENT_RELEASE_GATED','even eligible command is never sent');
select is((
  select recipient_phone_e164 from public.wa100_order_notification_commands
  where order_id='55000000-0000-4000-8000-000000000010'
),'+919900000001','recipient is bound to confirmed contact identity');
select is((
  select count(*)::integer from public.wa100_order_notification_command_events
  where event_type='CREATED_NOT_SENT'
),1,'one initial audit event persists');
select lives_ok($wa100_replay$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000010',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'so_confirmation','en',1)
$wa100_replay$, 'identical retry returns the immutable same command');
select is((
  select count(*)::integer from public.wa100_order_notification_commands
  where order_id='55000000-0000-4000-8000-000000000010'
),1,'identical replay cannot insert a second command');
select is((
  select count(*)::integer from public.wa100_order_notification_command_events
  where event_type='REPLAYED_NOT_SENT'
),1,'replay has a separate append-only audit receipt');

select throws_ok($wa100_cross_company$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000011',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'so_confirmation','en',1)
$wa100_cross_company$, '42501');
select throws_ok($wa100_unapproved_template$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000010',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'unapproved','en',1)
$wa100_unapproved_template$, '42501');
select throws_ok($wa100_conflicting_replay$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000010',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'so_confirmation_alt','en',1)
$wa100_conflicting_replay$, '23505');

select throws_ok($wa100_untrusted_revision$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000010',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'so_confirmation','en',2)
$wa100_untrusted_revision$, '42501');

update public.whatsapp_communication_preferences
set consent_status='OPTED_OUT'
where id='55000000-0000-4000-8000-000000000009';
select throws_ok($wa100_revoked_consent$
  select public.enqueue_wa100_order_notification_v1(
    '55000000-0000-4000-8000-000000000010',
    'SO_CREATED','55000000-0000-4000-8000-000000000004',
    'so_confirmation','en',1)
$wa100_revoked_consent$, '42501');

select throws_ok($wa100_update$
  update public.wa100_order_notification_commands
  set status='NOT_SENT_RELEASE_GATED'
  where order_id='55000000-0000-4000-8000-000000000010'
$wa100_update$, '42501');
select throws_ok($wa100_event_delete$
  delete from public.wa100_order_notification_command_events
  where event_type='CREATED_NOT_SENT'
$wa100_event_delete$, '42501');
select is((
  select count(*)::integer from public.wa100_order_notification_commands
  where order_id='55000000-0000-4000-8000-000000000010'
),1,'revoked consent and immutable guard cannot erase original receipt');
select is((
  select count(*)::integer from public.whatsapp_automations
  where order_id='55000000-0000-4000-8000-000000000010'
),0,'staging command never creates a legacy sender automation');

select * from finish();
rollback;
