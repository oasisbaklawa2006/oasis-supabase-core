-- Release-wave contract: provider callback status + audit evidence are one atomic write.
begin;

select plan(17);

select has_function(
  'public',
  'persist_whatsapp_operator_reply_provider_status',
  array['text', 'text', 'jsonb'],
  'atomic provider status persistence rpc exists'
);

select ok(
  not has_function_privilege('anon', 'public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)', 'EXECUTE'),
  'anon cannot execute provider status persistence'
);
select ok(
  not has_function_privilege('authenticated', 'public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)', 'EXECUTE'),
  'authenticated clients cannot execute provider status persistence'
);
select ok(
  has_function_privilege('service_role', 'public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)', 'EXECUTE'),
  'service_role can execute provider status persistence'
);

insert into auth.users(id, email)
values ('f3480000-0000-0000-0000-000000000001', 'pr348-atomic@example.invalid');

insert into public.users(id, email, name, role, is_active)
values (
  'f3480000-0000-0000-0000-000000000001',
  'pr348-atomic@example.invalid',
  'PR348 Atomic Fixture',
  'admin',
  true
);

insert into public.whatsapp_contacts(id, phone_number, customer_name)
values ('f3480000-0000-0000-0000-000000000010', '919888888888', 'PR348 Recipient');

insert into public.whatsapp_message_packets(
  id,
  contact_id,
  stitched_content,
  first_message_at,
  last_message_at
)
values (
  'f3480000-0000-0000-0000-000000000020',
  'f3480000-0000-0000-0000-000000000010',
  '{}',
  now(),
  now()
);

insert into public.whatsapp_operator_reply_outbox(
  id,
  packet_id,
  contact_id,
  recipient_phone_e164,
  message_body,
  idempotency_key,
  status,
  provider,
  provider_message_id,
  accepted_at,
  created_by
)
values (
  'f3480000-0000-0000-0000-000000000030',
  'f3480000-0000-0000-0000-000000000020',
  'f3480000-0000-0000-0000-000000000010',
  '+919888888888',
  'PR348 atomic callback fixture',
  'pr348-atomic-1',
  'ACCEPTED',
  'click2api',
  'wamid-pr348-atomic-1',
  now(),
  'f3480000-0000-0000-0000-000000000001'
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

create temporary table pr348_delivered as
select public.persist_whatsapp_operator_reply_provider_status(
  'wamid-pr348-atomic-1',
  'DELIVERED',
  '{"callback":true}'::jsonb
) as payload;

select is((select payload->>'updated' from pr348_delivered), 'true', 'DELIVERED callback advances status');
select is(
  (select status from public.whatsapp_operator_reply_outbox where id = 'f3480000-0000-0000-0000-000000000030'),
  'DELIVERED',
  'DELIVERED status is committed'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_events where reply_id = 'f3480000-0000-0000-0000-000000000030' and event_type = 'PROVIDER_STATUS_CALLBACK'),
  1,
  'DELIVERED transition writes one callback audit event'
);

create temporary table pr348_duplicate as
select public.persist_whatsapp_operator_reply_provider_status(
  'wamid-pr348-atomic-1',
  'DELIVERED',
  '{"callback":"retry"}'::jsonb
) as payload;

select is((select payload->>'updated' from pr348_duplicate), 'false', 'duplicate callback is a no-op');
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_events where reply_id = 'f3480000-0000-0000-0000-000000000030' and event_type = 'PROVIDER_STATUS_CALLBACK'),
  1,
  'duplicate callback does not duplicate audit evidence'
);

create temporary table pr348_read as
select public.persist_whatsapp_operator_reply_provider_status(
  'wamid-pr348-atomic-1',
  'READ',
  '{"callback":true}'::jsonb
) as payload;

select is((select payload->>'updated' from pr348_read), 'true', 'READ callback advances status');
select is(
  (select status from public.whatsapp_operator_reply_outbox where id = 'f3480000-0000-0000-0000-000000000030'),
  'READ',
  'READ status is committed'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_events where reply_id = 'f3480000-0000-0000-0000-000000000030' and event_type = 'PROVIDER_STATUS_CALLBACK'),
  2,
  'READ transition adds exactly one audit event'
);

create temporary table pr348_stale as
select public.persist_whatsapp_operator_reply_provider_status(
  'wamid-pr348-atomic-1',
  'DELIVERED',
  '{"callback":"late"}'::jsonb
) as payload;

select is((select payload->>'updated' from pr348_stale), 'false', 'out-of-order callback is a no-op');
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_events where reply_id = 'f3480000-0000-0000-0000-000000000030' and event_type = 'PROVIDER_STATUS_CALLBACK'),
  2,
  'out-of-order callback does not add audit evidence'
);

insert into public.whatsapp_operator_reply_outbox(
  id,
  packet_id,
  contact_id,
  recipient_phone_e164,
  message_body,
  idempotency_key,
  status,
  provider,
  provider_message_id,
  accepted_at,
  created_by
)
values (
  'f3480000-0000-0000-0000-000000000031',
  'f3480000-0000-0000-0000-000000000020',
  'f3480000-0000-0000-0000-000000000010',
  '+919888888888',
  'PR348 rollback fixture',
  'pr348-atomic-2',
  'ACCEPTED',
  'click2api',
  'wamid-pr348-atomic-2',
  now(),
  'f3480000-0000-0000-0000-000000000001'
);

create function public._test_pr348_fail_status_event()
returns trigger
language plpgsql
as $$
begin
  if new.evidence->>'force_test_failure' = 'true' then
    raise exception 'TEST_EVENT_INSERT_FAILURE';
  end if;
  return new;
end;
$$;

create trigger _test_pr348_fail_status_event
before insert on public.whatsapp_operator_reply_events
for each row
execute function public._test_pr348_fail_status_event();

select throws_ok(
  $$select public.persist_whatsapp_operator_reply_provider_status(
    'wamid-pr348-atomic-2',
    'DELIVERED',
    '{"force_test_failure":true}'::jsonb
  )$$,
  'TEST_EVENT_INSERT_FAILURE',
  'audit insert failure aborts the rpc'
);

select is(
  (select status from public.whatsapp_operator_reply_outbox where id = 'f3480000-0000-0000-0000-000000000031'),
  'ACCEPTED',
  'status update rolls back when audit insert fails'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_events where reply_id = 'f3480000-0000-0000-0000-000000000031'),
  0,
  'failed atomic write leaves no audit evidence'
);

select * from finish();
rollback;
