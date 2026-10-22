begin;
-- Case-level autonomous receipt governance proofs for
-- 20261022130000_whatsapp_core_c_case_receipt_governance.sql
select plan(25);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

insert into auth.users (id, email) values ('f2000000-0000-0000-0000-000000000001', 'receipt-gov-human@example.test');
insert into public.users (id, email, full_name, role) values
  ('f2000000-0000-0000-0000-000000000001', 'receipt-gov-human@example.test', 'Receipt Gov Human', 'admin');
select public.whatsapp_core_c_ensure_system_principal();

-- Fixtures: 5 contacts / packets / cases. Triggers are bypassed only while seeding so message and
-- outbox timestamps can be set explicitly; governance itself always runs with triggers enabled.
set local session_replication_role = replica;

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('f2000000-0000-0000-0000-000000000301', '919820000101', 'Receipt Gov Fresh'),
  ('f2000000-0000-0000-0000-000000000302', '919820000102', 'Receipt Gov Stale'),
  ('f2000000-0000-0000-0000-000000000303', '919820000103', 'Receipt Gov Quarantine'),
  ('f2000000-0000-0000-0000-000000000304', '919820000104', 'Receipt Gov Owned'),
  ('f2000000-0000-0000-0000-000000000305', '919820000105', 'Receipt Gov Historical');

insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values
  ('f2000000-0000-0000-0000-000000000311', 'f2000000-0000-0000-0000-000000000301', '{"text":"hello"}'::jsonb, 1, (now() at time zone 'UTC') - interval '10 minutes', (now() at time zone 'UTC') - interval '10 minutes', 'open'),
  ('f2000000-0000-0000-0000-000000000312', 'f2000000-0000-0000-0000-000000000302', '{"text":"hello"}'::jsonb, 1, (now() at time zone 'UTC') - interval '2 days', (now() at time zone 'UTC') - interval '2 days', 'open'),
  ('f2000000-0000-0000-0000-000000000313', 'f2000000-0000-0000-0000-000000000303', '{"text":"hello"}'::jsonb, 1, (now() at time zone 'UTC') - interval '10 minutes', (now() at time zone 'UTC') - interval '10 minutes', 'open'),
  ('f2000000-0000-0000-0000-000000000314', 'f2000000-0000-0000-0000-000000000304', '{"text":"hello"}'::jsonb, 1, (now() at time zone 'UTC') - interval '10 minutes', (now() at time zone 'UTC') - interval '10 minutes', 'open'),
  ('f2000000-0000-0000-0000-000000000315', 'f2000000-0000-0000-0000-000000000305', '{"text":"hello"}'::jsonb, 1, (now() at time zone 'UTC') - interval '10 minutes', (now() at time zone 'UTC') - interval '10 minutes', 'open');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, provider, provider_message_id, status, packet_id, created_at
) values
  ('f2000000-0000-0000-0000-000000000411', 'f2000000-0000-0000-0000-000000000301', 'inbound', 'text', 'whatsapp', 'wamid.f2.411', 'received', 'f2000000-0000-0000-0000-000000000311', (now() at time zone 'UTC') - interval '10 minutes'),
  ('f2000000-0000-0000-0000-000000000412', 'f2000000-0000-0000-0000-000000000302', 'inbound', 'text', 'whatsapp', 'wamid.f2.412', 'received', 'f2000000-0000-0000-0000-000000000312', (now() at time zone 'UTC') - interval '2 days'),
  ('f2000000-0000-0000-0000-000000000413', 'f2000000-0000-0000-0000-000000000303', 'inbound', 'text', 'whatsapp', 'wamid.f2.413', 'received', 'f2000000-0000-0000-0000-000000000313', (now() at time zone 'UTC') - interval '10 minutes'),
  ('f2000000-0000-0000-0000-000000000414', 'f2000000-0000-0000-0000-000000000304', 'inbound', 'text', 'whatsapp', 'wamid.f2.414', 'received', 'f2000000-0000-0000-0000-000000000314', (now() at time zone 'UTC') - interval '10 minutes'),
  ('f2000000-0000-0000-0000-000000000415', 'f2000000-0000-0000-0000-000000000305', 'inbound', 'text', 'whatsapp', 'wamid.f2.415', 'received', 'f2000000-0000-0000-0000-000000000315', (now() at time zone 'UTC') - interval '10 minutes');

insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version, accountable_team, accountability_status
) values
  ('f2000000-0000-0000-0000-000000000321', 'f2000000-0000-0000-0000-000000000311', 'COMPLAINT', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'OPERATIONS', 'UNASSIGNED'),
  ('f2000000-0000-0000-0000-000000000322', 'f2000000-0000-0000-0000-000000000312', 'ENQUIRY', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'OPERATIONS', 'UNASSIGNED'),
  ('f2000000-0000-0000-0000-000000000323', 'f2000000-0000-0000-0000-000000000313', 'ENQUIRY', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'OPERATIONS', 'UNASSIGNED'),
  ('f2000000-0000-0000-0000-000000000325', 'f2000000-0000-0000-0000-000000000315', 'ENQUIRY', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1', 'OPERATIONS', 'UNASSIGNED');
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version,
  accountable_team, accountable_owner_id, accountability_status,
  assigned_at, assigned_by, next_action, next_action_due_at
) values (
  'f2000000-0000-0000-0000-000000000324', 'f2000000-0000-0000-0000-000000000314',
  'COMPLAINT', 'OPEN', 'WHATSAPP', 'packet-ai-b2b-v1',
  'QUALITY', 'f2000000-0000-0000-0000-000000000001', 'ASSIGNED',
  now(), 'f2000000-0000-0000-0000-000000000001', 'Operator claimed complaint', now() + interval '1 day'
);

update public.whatsapp_messages set message_timestamp = created_at where id::text like 'f2000000%';
set local session_replication_role = origin;

create temporary table po_before as select count(*)::integer as n from public.whatsapp_potential_orders;

-- Policy function contract.
select ok(
  has_function_privilege('service_role', 'public.whatsapp_core_c_receipt_policy_v1(uuid, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'public.whatsapp_core_c_receipt_policy_v1(uuid, timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public.whatsapp_core_c_receipt_policy_v1(uuid, timestamptz)', 'execute'),
  'receipt policy function is service_role only'
);
select ok(
  position('for update' in lower((select prosrc from pg_proc where proname = 'whatsapp_apply_non_order_case_governance_v1' and pronamespace = 'public'::regnamespace))) > 0
  and position('for update' in lower((select prosrc from pg_proc where proname = 'whatsapp_apply_non_order_case_governance_v1' and pronamespace = 'public'::regnamespace)))
    < position('whatsapp_core_c_receipt_policy_v1' in (select prosrc from pg_proc where proname = 'whatsapp_apply_non_order_case_governance_v1' and pronamespace = 'public'::regnamespace)),
  'receipt decision is taken after the case row lock (concurrent calls serialize)'
);

-- 1. Normal processing: first interpretation of a fresh packet is acknowledged once.
create temporary table gov_first as
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000321', 'f2000000-0000-0000-0000-000000000501', 'COMPLAINT', 'QUALITY'
) as payload;
select ok((select (payload->>'receipt_sent')::boolean from gov_first), 'fresh packet: first interpretation is acknowledged');
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000311' and idempotency_key like 'core-c:non-order-receipt:%'),
  1, 'fresh packet: exactly one outbox row'
);

-- 2. Retry / repeated RPC execution of the same interpretation is idempotent.
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000321', 'f2000000-0000-0000-0000-000000000501', 'COMPLAINT', 'QUALITY'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000311'),
  1, 'replay of the same interpretation adds no outbox row'
);
select is(
  (select count(*)::integer from public.whatsapp_case_events
    where case_id = 'f2000000-0000-0000-0000-000000000321' and event_type = 'AUTONOMOUS_NON_ORDER_RECEIPT_SENT'),
  1, 'replay adds no SENT event'
);

-- 3. Duplicate interpretation of the same case (inside the cooldown, no newer message) is suppressed.
create temporary table gov_dup as
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000321', 'f2000000-0000-0000-0000-000000000502', 'COMPLAINT', 'QUALITY'
) as payload;
select ok(
  (select (payload->>'receipt_suppressed')::boolean and not coalesce((payload->>'receipt_sent')::boolean, false) from gov_dup),
  'duplicate interpretation: receipt suppressed, not sent'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000311'),
  1, 'duplicate interpretation: still exactly one outbox row'
);
select is(
  (select metadata->>'suppression_reason' from public.whatsapp_case_events
    where case_id = 'f2000000-0000-0000-0000-000000000321'
      and correlation_key = 'core-c-receipt-suppressed:core-c:non-order-receipt:f2000000-0000-0000-0000-000000000502'),
  'CASE_RECEIPT_ALREADY_SENT', 'duplicate interpretation: suppression is audited with its reason'
);
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000321', 'f2000000-0000-0000-0000-000000000502', 'COMPLAINT', 'QUALITY'
);
select is(
  (select count(*)::integer from public.whatsapp_case_events
    where case_id = 'f2000000-0000-0000-0000-000000000321' and event_type = 'AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED'),
  1, 'replay of a suppressed interpretation adds no event'
);
select ok(
  (select count(*) from public.whatsapp_case_events
    where case_id = 'f2000000-0000-0000-0000-000000000321' and event_type = 'NON_ORDER_TEAM_ROUTED') = 2,
  'suppression does not stop team routing (one routing event per interpretation)'
);

-- 4. Legitimate new customer interaction: prior receipt is older than the cooldown and a newer
--    inbound message exists, so a new acknowledgement is allowed.
set local session_replication_role = replica;
update public.whatsapp_operator_reply_outbox
set created_at = now() - interval '2 hours'
where packet_id = 'f2000000-0000-0000-0000-000000000311';
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, provider, provider_message_id, status, packet_id, created_at
) values (
  'f2000000-0000-0000-0000-000000000421', 'f2000000-0000-0000-0000-000000000301', 'inbound', 'text',
  'whatsapp', 'wamid.f2.421', 'received', 'f2000000-0000-0000-0000-000000000311', (now() at time zone 'UTC') - interval '1 minute'
);
update public.whatsapp_messages set message_timestamp = created_at where id::text like 'f2000000%';
set local session_replication_role = origin;
create temporary table gov_new as
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000321', 'f2000000-0000-0000-0000-000000000503', 'COMPLAINT', 'QUALITY'
) as payload;
select ok((select (payload->>'receipt_sent')::boolean from gov_new), 'newer customer message after the cooldown is acknowledged');
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000311' and idempotency_key like 'core-c:non-order-receipt:%'),
  2, 'new interaction adds exactly one outbox row'
);

-- 5. Delayed recovery / stale replay: last inbound message is days old, so no receipt is queued,
--    but the case is still routed.
create temporary table gov_stale as
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000322', 'f2000000-0000-0000-0000-000000000504', 'ENQUIRY', 'SALES'
) as payload;
select ok(
  (select (payload->>'receipt_suppressed')::boolean and not coalesce((payload->>'receipt_sent')::boolean, false) from gov_stale),
  'stale replay: receipt suppressed'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000312'),
  0, 'stale replay: zero outbox rows'
);
select is(
  (select metadata->>'suppression_reason' from public.whatsapp_case_events
    where case_id = 'f2000000-0000-0000-0000-000000000322' and event_type = 'AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED'),
  'STALE_REPLAY', 'stale replay: suppression is audited with its reason'
);
select is(
  (select accountable_team from public.whatsapp_communication_cases where id = 'f2000000-0000-0000-0000-000000000322'),
  'SALES', 'stale replay: case is still routed to its team'
);

-- 6. A quarantined (never-sent) receipt does not block a timely acknowledgement.
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000323', 'f2000000-0000-0000-0000-000000000505', 'ENQUIRY', 'SALES'
);
select public.quarantine_whatsapp_operator_reply(
  (select id from public.whatsapp_operator_reply_outbox where packet_id = 'f2000000-0000-0000-0000-000000000313'),
  'TEST_QUARANTINE', '{}'::jsonb
);
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000323', 'f2000000-0000-0000-0000-000000000506', 'ENQUIRY', 'SALES'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000313' and status = 'QUEUED'),
  1, 'quarantined prior receipt does not suppress a new acknowledgement'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000313' and status = 'QUARANTINED'),
  1, 'quarantined row is preserved'
);

-- 7. Human override: an owned case keeps its team, owner and assignment.
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000324', 'f2000000-0000-0000-0000-000000000507', 'COMPLAINT', 'FINANCE'
);
select ok(
  (select accountable_team = 'QUALITY'
      and accountable_owner_id = 'f2000000-0000-0000-0000-000000000001'::uuid
      and accountability_status = 'ASSIGNED'
      and assigned_by = 'f2000000-0000-0000-0000-000000000001'::uuid
      and next_action = 'Operator claimed complaint'
    from public.whatsapp_communication_cases where id = 'f2000000-0000-0000-0000-000000000324'),
  'owned case: team, owner, assignment and next action are preserved'
);
select is(
  (select department from public.whatsapp_case_department_tasks
    where case_id = 'f2000000-0000-0000-0000-000000000324' and correlation_key = 'core-c-non-order:f2000000-0000-0000-0000-000000000507'),
  'QUALITY', 'owned case: department task uses the preserved team'
);

-- 8. Historical provider-accepted receipt is never altered, and blocks a duplicate.
set local session_replication_role = replica;
insert into public.whatsapp_operator_reply_outbox(
  id, packet_id, contact_id, recipient_phone_e164, message_body, message_type, disclosure_scope,
  idempotency_key, status, provider_message_id, accepted_at, created_by, message_origin, created_at
) values (
  'f2000000-0000-0000-0000-000000000601', 'f2000000-0000-0000-0000-000000000315', 'f2000000-0000-0000-0000-000000000305',
  '+919820000105', 'Thank you. We have received your message.', 'TEXT', '{}'::text[],
  'core-c:non-order-receipt:f2000000-0000-0000-0000-000000000509', 'ACCEPTED', 'wamid.f2.hist', now() - interval '5 minutes',
  (select id from public.users where email = 'receipt-gov-human@example.test'), 'AUTONOMOUS', now() - interval '5 minutes'
);
set local session_replication_role = origin;
create temporary table hist_before as
select status, provider_message_id, accepted_at, created_at, message_body
from public.whatsapp_operator_reply_outbox where id = 'f2000000-0000-0000-0000-000000000601';
select public.whatsapp_apply_non_order_case_governance_v1(
  'f2000000-0000-0000-0000-000000000325', 'f2000000-0000-0000-0000-000000000510', 'ENQUIRY', 'SALES'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox where packet_id = 'f2000000-0000-0000-0000-000000000315'),
  1, 'provider-accepted receipt blocks a duplicate on the same case'
);
select ok(
  not exists (
    select 1 from public.whatsapp_operator_reply_outbox o, hist_before h
    where o.id = 'f2000000-0000-0000-0000-000000000601'
      and (o.status, o.provider_message_id, o.accepted_at, o.created_at, o.message_body)
        is distinct from (h.status, h.provider_message_id, h.accepted_at, h.created_at, h.message_body)
  ),
  'historical provider-accepted receipt is unchanged'
);

-- 9. Commercial order authority is not touched.
select is(
  (select count(*)::integer from public.whatsapp_potential_orders),
  (select n from po_before), 'governance creates no potential order'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where packet_id = 'f2000000-0000-0000-0000-000000000312'),
  0, 'stale scenario still has zero outbox rows at the end of the run'
);

select * from finish();
rollback;
