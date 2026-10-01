-- Regression contract for deterministic WhatsApp packet failure handling.
begin;
select plan(10);

select ok(
  position('BLOCKED_INPUT_VALIDATION' in pg_get_constraintdef(
    (select oid from pg_constraint
      where conrelid='public.whatsapp_packet_ai_dispatch_jobs'::regclass
        and conname='whatsapp_packet_ai_dispatch_jobs_state_check')
  )) > 0,
  'dispatch state contract includes terminal input-validation block'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('87700000-0000-0000-0000-000000000001', '919770000001', 'Permanent failure fixture'),
  ('87700000-0000-0000-0000-000000000002', '919770000002', 'Transient failure fixture');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values
(
  '87700000-0000-0000-0000-000000000011',
  '87700000-0000-0000-0000-000000000001',
  'inbound','text','oversized fixture seed','click2api','perm-input-a','received',
  statement_timestamp(),statement_timestamp()
),
(
  '87700000-0000-0000-0000-000000000012',
  '87700000-0000-0000-0000-000000000002',
  'inbound','text','transient fixture seed','click2api','transient-a','received',
  statement_timestamp()+interval '1 second',statement_timestamp()+interval '1 second'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '87700000-0000-0000-0000-000000000001',
    array['87700000-0000-0000-0000-000000000011'::uuid],300)$$,
  'permanent-failure fixture stitches'
);

create temp table lease_permanent as
select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select ok((select id from lease_permanent) is not null, 'permanent-failure job is leased');

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from lease_permanent),
    (select lease_token from lease_permanent),
    (select packet_revision from lease_permanent),
    'INTERPRETATION_PACKET_TOO_LARGE',
    'INTERPRETATION_PACKET_TOO_LARGE',
    false
  ),
  'oversized packet failure is recorded'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs where id=(select id from lease_permanent)),
  'BLOCKED_INPUT_VALIDATION'::text,
  'oversized packet becomes terminal input-validation block'
);

select is(
  (select next_retry_at from public.whatsapp_packet_ai_dispatch_jobs where id=(select id from lease_permanent)),
  null::timestamptz,
  'oversized packet has no autonomous retry time'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '87700000-0000-0000-0000-000000000002',
    array['87700000-0000-0000-0000-000000000012'::uuid],300)$$,
  'transient-failure fixture stitches'
);

create temp table lease_transient as
select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select ok((select id from lease_transient) is not null, 'transient-failure job is leased');

select ok(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from lease_transient),
    (select lease_token from lease_transient),
    (select packet_revision from lease_transient),
    'NETWORK_TIMEOUT',
    'temporary provider timeout',
    false
  ),
  'transient failure is recorded'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs where id=(select id from lease_transient)),
  'RETRY'::text,
  'transient failure remains retryable'
);

select ok(
  (select next_retry_at is not null from public.whatsapp_packet_ai_dispatch_jobs where id=(select id from lease_transient)),
  'transient failure retains bounded retry schedule'
);

select * from finish();
rollback;
