-- WA-100 / #532: pgTAP safety regression for provider invalidated tokens and queue truth.
-- Runs on clean database replay; rolls back every fixture and audit row.
begin;
select plan(19);
select set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);

select has_function('public', 'fail_whatsapp_operator_reply',
  array['uuid','uuid','text','text','boolean']);

select public.whatsapp_core_c_ensure_system_principal();
insert into public.whatsapp_contacts(id, phone_number, customer_name)
values ('f5400000-0000-0000-0000-000000000010', '919540000010', 'WA100 fixture');

insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, first_message_at, last_message_at
) values (
  'f5400000-0000-0000-0000-000000000020',
  'f5400000-0000-0000-0000-000000000010',
  '{}'::jsonb, now(), now()
);

insert into public.whatsapp_operator_reply_outbox(
  id, packet_id, contact_id, recipient_phone_e164, message_body,
  idempotency_key, created_by, message_origin, status
) values
('f5400000-0000-0000-0000-000000000031',
 'f5400000-0000-0000-0000-000000000020',
 'f5400000-0000-0000-0000-000000000010',
 '+919540000010','WA100 auth 401 test','wa100-auth401',
 public.whatsapp_core_c_ensure_system_principal(), 'AUTONOMOUS', 'QUEUED'),
('f5400000-0000-0000-0000-000000000032',
 'f5400000-0000-0000-0000-000000000020',
 'f5400000-0000-0000-0000-000000000010',
 '+919540000010','WA100 transient 503 test','wa100-transient503',
 public.whatsapp_core_c_ensure_system_principal(), 'STAFF', 'QUEUED'),
('f5400000-0000-0000-0000-000000000033',
 'f5400000-0000-0000-0000-000000000020',
 'f5400000-0000-0000-0000-000000000010',
 '+919540000010','WA100 unknown acceptance test','wa100-unknown',
 public.whatsapp_core_c_ensure_system_principal(), 'STAFF', 'QUEUED');

create temporary table wa100_lease_401 as
select * from public.claim_whatsapp_operator_reply(
  'wa100-401-worker', 'f5400000-0000-0000-0000-000000000031', 60
);
select is((select status from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000031'),'SENDING',
  'provider rejection fixture has an authorized exclusive sending lease');
select lives_ok($$
  select public.fail_whatsapp_operator_reply(
    id, lease_token, 'HTTP_401', 'invalidated credential', false
  ) from wa100_lease_401
$$, 'HTTP_401 is recorded without a provider send acknowledgement');
select is((select status from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000031'),'FAILED_FINAL',
  'HTTP_401 is terminal after first attempt');
select ok((select next_attempt_at='infinity'::timestamptz
  from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000031'),
  'HTTP_401 has no auto-retry schedule');
select is((select attempt_count from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000031'),1,
  'no five-attempt credential rejection loop');
select ok((select provider_message_id is null and accepted_at is null and delivered_at is null
  from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000031'),
  '401 rejection never fabricates provider acceptance or delivery');
select is((select count(*)::integer from public.whatsapp_operator_reply_events
  where reply_id='f5400000-0000-0000-0000-000000000031'
    and event_type='SEND_FAILED' and evidence->>'retryable'='false'),1,
  'immutable SEND_FAILED audit correctly marks auth rejection non-retryable');
select is((select public.claim_whatsapp_operator_reply(
  'wa100-retry-worker','f5400000-0000-0000-0000-000000000031',60)),
  null::public.whatsapp_operator_reply_outbox,
  'terminal rejection cannot be reclaimed or resent');

create temporary table wa100_lease_503 as
select * from public.claim_whatsapp_operator_reply(
  'wa100-503-worker', 'f5400000-0000-0000-0000-000000000032', 60
);
select lives_ok($$
  select public.fail_whatsapp_operator_reply(
    id, lease_token, 'HTTP_503', 'transient service error', false
  ) from wa100_lease_503
$$, 'transient provider error can be recorded');
select is((select status from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000032'),'FAILED_RETRYABLE',
  'non-auth transient failure retains bounded retry behavior');
select ok((select next_attempt_at > statement_timestamp()
  and next_attempt_at <> 'infinity'::timestamptz
  from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000032'),
  'transient failure receives finite backoff');

create temporary table wa100_lease_unknown as
select * from public.claim_whatsapp_operator_reply(
  'wa100-unknown-worker', 'f5400000-0000-0000-0000-000000000033', 60
);
select lives_ok($$
  select public.fail_whatsapp_operator_reply(
    id, lease_token, 'HTTP_401', 'uncertain acceptance', true
  ) from wa100_lease_unknown
$$, 'acceptance-unknown takes precedence over terminal auth error');
select is((select status from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000033'),'ACCEPTANCE_UNKNOWN',
  'uncertain acceptance remains isolated from automatic retries');
select ok((select next_attempt_at='infinity'::timestamptz
  from public.whatsapp_operator_reply_outbox
  where id='f5400000-0000-0000-0000-000000000033'),
  'uncertain acceptance cannot be blindly resent');

select ok(
  position('AUTONOMOUS_NON_ORDER_RECEIPT_QUEUED' in
    pg_get_functiondef('public.whatsapp_apply_non_order_case_governance_v1(uuid,uuid,text,text,text,text)'::regprocedure)) > 0,
  'new non-order receipts use a truthful QUEUED event');
select ok(
  position('AUTONOMOUS_NON_ORDER_RECEIPT_SENT' in
    pg_get_functiondef('public.whatsapp_apply_non_order_case_governance_v1(uuid,uuid,text,text,text,text)'::regprocedure)) = 0,
  'new governance never fabricates SENT event before provider acceptance');
select ok(
  position('receipt_enqueued' in
    pg_get_functiondef('public.whatsapp_apply_non_order_case_governance_v1(uuid,uuid,text,text,text,text)'::regprocedure)) > 0,
  'governance reports explicit enqueue truth');
select ok(
  position('''receipt_sent'', false' in
    pg_get_functiondef('public.whatsapp_apply_non_order_case_governance_v1(uuid,uuid,text,text,text,text)'::regprocedure)) > 0,
  'legacy receipt_sent result is false without actual provider send');

select * from finish();
rollback;
