-- Contract for 20260919130000_whatsapp_operator_reply_quarantine_and_consumer_hardening.sql
begin;
select plan(25);

select has_column(
  'public', 'whatsapp_operator_reply_outbox', 'message_origin',
  'message_origin distinguishes staff from autonomous governed replies'
);
select has_column(
  'public', 'whatsapp_operator_reply_outbox', 'quarantine_reason',
  'quarantine reason is persisted'
);
select has_function(
  'public', 'quarantine_whatsapp_operator_reply',
  array['uuid', 'text', 'jsonb']
);
select has_function(
  'public', 'disposition_historical_gate3_stale_autonomous_receipts',
  array[]::text[]
);
select is_empty(
  $$select 1 from information_schema.role_routine_grants
    where routine_schema = 'public'
      and routine_name in (
        'quarantine_whatsapp_operator_reply',
        'disposition_historical_gate3_stale_autonomous_receipts'
      )
      and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'quarantine disposition is service-only'
);

insert into auth.users(id, email) values
  ('86500000-0000-0000-0000-000000000001', 'wa5b-admin@example.test');
insert into public.users(id, email, name, role, is_active) values
  ('86500000-0000-0000-0000-000000000001', 'wa5b-admin@example.test', 'WA5B Admin', 'admin', true);
insert into public.user_role_map(user_id, role_id)
select '86500000-0000-0000-0000-000000000001', id from public.roles where role_key = 'admin';
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86500000-0000-0000-0000-000000000010', '919650000010', 'Outbound A'),
  ('86500000-0000-0000-0000-000000000011', '919650000011', 'Outbound B');
insert into public.whatsapp_message_packets(id, contact_id, stitched_content, first_message_at, last_message_at) values
  ('86500000-0000-0000-0000-000000000020', '86500000-0000-0000-0000-000000000010', '{}', now(), now()),
  ('86500000-0000-0000-0000-000000000021', '86500000-0000-0000-0000-000000000011', '{}', now(), now());

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '86500000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
select lives_ok(
  $$select public.enqueue_whatsapp_operator_reply(
    '86500000-0000-0000-0000-000000000020',
    '86500000-0000-0000-0000-000000000010',
    '+919650000010',
    'Staff clarification pending review',
    'wa5b-staff-1'
  )$$,
  'staff enqueue stamps STAFF origin'
);
select is(
  (select message_origin from public.whatsapp_operator_reply_outbox where idempotency_key = 'wa5b-staff-1'),
  'STAFF',
  'staff origin is persisted'
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select lives_ok(
  $$select public.enqueue_governed_whatsapp_autonomous_reply(
    '86500000-0000-0000-0000-000000000021',
    '86500000-0000-0000-0000-000000000011',
    '+919650000011',
    'Thank you for contacting Oasis Baklawa. We received your message.',
    'core-c:non-order-receipt:test-fixture',
    'NON_ORDER_RECEIPT'
  )$$,
  'autonomous governed enqueue stamps AUTONOMOUS origin'
);
select is(
  (select message_origin from public.whatsapp_operator_reply_outbox
    where idempotency_key = 'core-c:non-order-receipt:test-fixture'),
  'AUTONOMOUS',
  'autonomous origin is persisted'
);

select lives_ok(
  $$select public.quarantine_whatsapp_operator_reply(
    (select id from public.whatsapp_operator_reply_outbox where idempotency_key = 'core-c:non-order-receipt:test-fixture'),
    'TEST_QUARANTINE',
    '{"fixture":true}'::jsonb
  )$$,
  'service role can quarantine a queued autonomous receipt'
);
select is(
  (select status from public.whatsapp_operator_reply_outbox
    where idempotency_key = 'core-c:non-order-receipt:test-fixture'),
  'QUARANTINED',
  'quarantine moves row to terminal non-sendable state'
);
select is(
  (select public.claim_whatsapp_operator_reply(
    'worker-quarantine',
    (select id from public.whatsapp_operator_reply_outbox
      where idempotency_key = 'core-c:non-order-receipt:test-fixture'),
    60
  )),
  null::public.whatsapp_operator_reply_outbox,
  'quarantined rows are never claimable'
);
select throws_ok(
  $$select public.quarantine_whatsapp_operator_reply(
    (select id from public.whatsapp_operator_reply_outbox where idempotency_key = 'core-c:non-order-receipt:test-fixture'),
    'REPEAT',
    '{}'::jsonb
  )$$,
  'WA5_QUARANTINE_BOUNDARY',
  'already quarantined rows cannot be re-quarantined'
);

insert into public.whatsapp_operator_reply_outbox(
  packet_id, contact_id, recipient_phone_e164, message_body, idempotency_key,
  created_by, message_origin, status
) values (
  '86500000-0000-0000-0000-000000000020',
  '86500000-0000-0000-0000-000000000010',
  '+919650000010',
  'Cancelled superseded reply',
  'wa5b-cancelled',
  '86500000-0000-0000-0000-000000000001',
  'STAFF',
  'CANCELLED'
);
select is(
  (select public.claim_whatsapp_operator_reply(
    'worker-cancelled',
    (select id from public.whatsapp_operator_reply_outbox where idempotency_key = 'wa5b-cancelled'),
    60
  )),
  null::public.whatsapp_operator_reply_outbox,
  'cancelled rows are never claimable'
);

create temporary table claim_a as
  select * from public.claim_whatsapp_operator_reply('worker-a', null, 60);
select isnt(
  (select id from claim_a),
  null::uuid,
  'worker A claims staff reply'
);
select is(
  (select status from public.whatsapp_operator_reply_outbox where idempotency_key = 'wa5b-staff-1'),
  'SENDING',
  'claim moves row to SENDING with lease'
);

create temporary table claim_b as
  select * from public.claim_whatsapp_operator_reply('worker-b', null, 60);
select is(
  (select id from claim_b),
  null::uuid,
  'concurrent consumer cannot claim the same active lease'
);

update public.whatsapp_operator_reply_outbox
set lease_expires_at = statement_timestamp() - interval '1 second'
where idempotency_key = 'wa5b-staff-1';

create temporary table claim_c as
  select * from public.claim_whatsapp_operator_reply('worker-c', null, 60);
select is(
  (select id from claim_c),
  (select id from claim_a),
  'expired lease can be reclaimed by another worker'
);
select isnt(
  (select lease_token from claim_c),
  (select lease_token from claim_a),
  'reclaim issues a fresh lease token'
);

select throws_ok(
  $$select public.complete_whatsapp_operator_reply(
    (select id from claim_a),
    (select lease_token from claim_a),
    'click2api',
    'late-provider-id'
  )$$,
  'WA5_STALE_OR_INVALID_LEASE',
  'stale lease holder cannot complete after reclaim'
);

select lives_ok(
  $$select public.complete_whatsapp_operator_reply(
    (select id from claim_c),
    (select lease_token from claim_c),
    'click2api',
    'provider-wa5b-1'
  )$$,
  'current lease holder completes provider acceptance'
);
select is(
  (select status from public.whatsapp_operator_reply_outbox where idempotency_key = 'wa5b-staff-1'),
  'ACCEPTED',
  'completed row is terminal for send'
);
select is(
  (select public.claim_whatsapp_operator_reply('worker-done', null, 60)),
  null::public.whatsapp_operator_reply_outbox,
  'already-completed rows are never reclaimed for send'
);

insert into public.whatsapp_operator_reply_outbox(
  packet_id, contact_id, recipient_phone_e164, message_body, idempotency_key,
  created_by, message_origin, status, next_attempt_at
) values (
  '86500000-0000-0000-0000-000000000021',
  '86500000-0000-0000-0000-000000000011',
  '+919650000011',
  'Retryable failure body long enough for validation',
  'wa5b-retryable',
  '86500000-0000-0000-0000-000000000001',
  'STAFF',
  'FAILED_RETRYABLE',
  statement_timestamp()
);
create temporary table claim_retry as
  select * from public.claim_whatsapp_operator_reply('worker-retry', null, 60);
select isnt(
  (select id from claim_retry),
  null::uuid,
  'failed retryable rows remain claimable'
);

select ok(
  exists(
    select 1 from public.whatsapp_operator_reply_events
    where reply_id = (select id from public.whatsapp_operator_reply_outbox where idempotency_key = 'core-c:non-order-receipt:test-fixture')
      and event_type = 'QUARANTINED'
  ),
  'quarantine audit event preserves evidence linkage'
);

select * from finish();
rollback;
