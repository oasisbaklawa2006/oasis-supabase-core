begin;
-- Contract coverage for 20260820140000_whatsapp_case_potential_order_bridge_fix.sql
-- Regression: stitcher packet id != WA4 commercial packet id must still resolve
-- the potential order through inbound provider_message_id, fail closed on
-- ambiguity, and refuse outbound / cross-sender bridges.
select plan(17);

select has_function(
  'public',
  'whatsapp_case_potential_order_id',
  array['uuid'],
  'whatsapp_case_potential_order_id exists'
);
select ok(
  (
    select prosecdef and proconfig is not null
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'whatsapp_case_potential_order_id'
  ),
  'resolver is security definer with search_path pinned'
);
select is_empty(
  $$
    select 1
    from information_schema.role_routine_grants
    where routine_schema = 'public'
      and routine_name = 'whatsapp_case_potential_order_id'
      and grantee in ('PUBLIC', 'anon', 'authenticated')
  $$,
  'resolver is not executable by PUBLIC, anon, or authenticated'
);
select function_privs_are(
  'public',
  'whatsapp_case_potential_order_id',
  array['uuid'],
  'service_role',
  array['EXECUTE'],
  'only service_role executes the case potential-order resolver'
);

-- Shared contacts
insert into public.whatsapp_contacts (id, phone_number, wa_contact_id) values
  ('a0000000-0000-0000-0000-000000000101', '919990121158', '919990121158'),
  ('a0000000-0000-0000-0000-000000000102', '918880000002', '918880000002');

-- ---------------------------------------------------------------------------
-- Split-packet happy path (T08 shape): stitcher packet != commercial packet
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-provider-001',
  '919990121158',
  'Please book 3 cartons of Cashew Pyramid Baklawa.',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  'a0000000-0000-0000-0000-000000000301',
  'a0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-provider-001',
  '919990121158',
  'bridge-fix-fingerprint-split',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

insert into public.whatsapp_commercial_packets (
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values (
  'a0000000-0000-0000-0000-000000000401',
  'a0000000-0000-0000-0000-000000000301',
  '919990121158',
  'bridge-fix-conversation-split',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'a0000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"Please book 3 cartons of Cashew Pyramid Baklawa."}'::jsonb,
  1,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  'a0000000-0000-0000-0000-000000000601',
  'a0000000-0000-0000-0000-000000000101',
  'a0000000-0000-0000-0000-000000000501',
  'inbound',
  'text',
  'Please book 3 cartons of Cashew Pyramid Baklawa.',
  'click2api',
  'wamid.bridge-fix-provider-001',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, original_payload,
  media_count, processing_state, processing_detail
) values (
  'a0000000-0000-0000-0000-000000000701',
  'a0000000-0000-0000-0000-000000000401',
  'a0000000-0000-0000-0000-000000000301',
  'a0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-provider-001',
  '919990121158',
  now(),
  1,
  'TEXT',
  'Please book 3 cartons of Cashew Pyramid Baklawa.',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'a0000000-0000-0000-0000-000000000801',
  'a0000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select is(
  public.whatsapp_case_potential_order_id('a0000000-0000-0000-0000-000000000801'),
  'a0000000-0000-0000-0000-000000000301'::uuid,
  'resolves potential order via inbound provider_message_id when WA4 packet id differs'
);
select is(
  public.whatsapp_case_potential_order_id('a0000000-0000-0000-0000-000000000801'),
  public.whatsapp_case_potential_order_id('a0000000-0000-0000-0000-000000000801'),
  'resolver is stable across repeated calls'
);
select is(
  (select count(*) from public.whatsapp_potential_orders where id = 'a0000000-0000-0000-0000-000000000301'),
  1::bigint,
  'repeated resolver execution does not duplicate the potential order'
);
select is(
  (select count(*) from public.whatsapp_commercial_evidence where potential_order_id = 'a0000000-0000-0000-0000-000000000301'),
  1::bigint,
  'repeated resolver execution does not duplicate commercial evidence'
);
select is(
  (select count(*) from public.whatsapp_communication_cases where id = 'a0000000-0000-0000-0000-000000000801'),
  1::bigint,
  'repeated resolver execution does not duplicate the communication case'
);
select is(
  (select status from public.whatsapp_communication_cases where id = 'a0000000-0000-0000-0000-000000000801'),
  'NEEDS_IDENTITY',
  'resolver does not bypass NEEDS_IDENTITY or mutate case status'
);

-- ---------------------------------------------------------------------------
-- Same-packet path: evidence.packet_id equals the communication case packet id
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-same-packet',
  '919990121158',
  'same packet order',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  'b0000000-0000-0000-0000-000000000301',
  'b0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-same-packet',
  '919990121158',
  'bridge-fix-fingerprint-same',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'b0000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"same packet order"}'::jsonb,
  1,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_commercial_packets (
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values (
  'b0000000-0000-0000-0000-000000000501',
  'b0000000-0000-0000-0000-000000000301',
  '919990121158',
  'bridge-fix-conversation-same',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  'b0000000-0000-0000-0000-000000000601',
  'a0000000-0000-0000-0000-000000000101',
  'b0000000-0000-0000-0000-000000000501',
  'inbound',
  'text',
  'same packet order',
  'click2api',
  'wamid.bridge-fix-same-packet-message',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, original_payload,
  media_count, processing_state, processing_detail
) values (
  'b0000000-0000-0000-0000-000000000701',
  'b0000000-0000-0000-0000-000000000501',
  'b0000000-0000-0000-0000-000000000301',
  'b0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-same-packet',
  '919990121158',
  now(),
  1,
  'TEXT',
  'same packet order',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'b0000000-0000-0000-0000-000000000801',
  'b0000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select is(
  public.whatsapp_case_potential_order_id('b0000000-0000-0000-0000-000000000801'),
  'b0000000-0000-0000-0000-000000000301'::uuid,
  'existing same-packet resolution remains valid when evidence packet id matches the case'
);

-- ---------------------------------------------------------------------------
-- No matching commercial evidence → NULL
-- ---------------------------------------------------------------------------
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'c0000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"no commercial evidence"}'::jsonb,
  1,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  'c0000000-0000-0000-0000-000000000601',
  'a0000000-0000-0000-0000-000000000101',
  'c0000000-0000-0000-0000-000000000501',
  'inbound',
  'text',
  'no commercial evidence',
  'click2api',
  'wamid.bridge-fix-none',
  'received',
  now()
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'c0000000-0000-0000-0000-000000000801',
  'c0000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select is(
  public.whatsapp_case_potential_order_id('c0000000-0000-0000-0000-000000000801'),
  null::uuid,
  'zero matches fail closed with NULL'
);

-- ---------------------------------------------------------------------------
-- Two inbound fragments mapping to two potential orders → fail closed
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values
  ('d0000000-0000-0000-0000-000000000201', 'wamid.bridge-fix-multi-a', '919990121158', 'first order', 'text', now()),
  ('d0000000-0000-0000-0000-000000000202', 'wamid.bridge-fix-multi-b', '919990121158', 'second order', 'text', now());

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values
  (
    'd0000000-0000-0000-0000-000000000301',
    'd0000000-0000-0000-0000-000000000201',
    'wamid.bridge-fix-multi-a',
    '919990121158',
    'bridge-fix-fingerprint-multi-a',
    '[]'::jsonb, 'UNASSIGNED', 'ACTIVE_PENDING', 'WA_COMMERCIAL_UNASSIGNED', 'ASSIGN_OWNER', now(), now()
  ),
  (
    'd0000000-0000-0000-0000-000000000302',
    'd0000000-0000-0000-0000-000000000202',
    'wamid.bridge-fix-multi-b',
    '919990121158',
    'bridge-fix-fingerprint-multi-b',
    '[]'::jsonb, 'UNASSIGNED', 'ACTIVE_PENDING', 'WA_COMMERCIAL_UNASSIGNED', 'ASSIGN_OWNER', now(), now()
  );

insert into public.whatsapp_commercial_packets (
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values
  ('d0000000-0000-0000-0000-000000000401', 'd0000000-0000-0000-0000-000000000301', '919990121158', 'bridge-fix-multi-a', 'OPEN', 'READY', now(), now()),
  ('d0000000-0000-0000-0000-000000000402', 'd0000000-0000-0000-0000-000000000302', '919990121158', 'bridge-fix-multi-b', 'OPEN', 'READY', now(), now());

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'd0000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"ambiguous stitch"}'::jsonb,
  2,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values
  ('d0000000-0000-0000-0000-000000000601', 'a0000000-0000-0000-0000-000000000101', 'd0000000-0000-0000-0000-000000000501', 'inbound', 'text', 'first order', 'click2api', 'wamid.bridge-fix-multi-a', 'received', now()),
  ('d0000000-0000-0000-0000-000000000602', 'a0000000-0000-0000-0000-000000000101', 'd0000000-0000-0000-0000-000000000501', 'inbound', 'text', 'second order', 'click2api', 'wamid.bridge-fix-multi-b', 'received', now());

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, original_payload,
  media_count, processing_state, processing_detail
) values
  (
    'd0000000-0000-0000-0000-000000000701',
    'd0000000-0000-0000-0000-000000000401',
    'd0000000-0000-0000-0000-000000000301',
    'd0000000-0000-0000-0000-000000000201',
    'wamid.bridge-fix-multi-a',
    '919990121158', now(), 1, 'TEXT', 'first order', '{}'::jsonb, 0, 'SUCCEEDED', '{}'::jsonb
  ),
  (
    'd0000000-0000-0000-0000-000000000702',
    'd0000000-0000-0000-0000-000000000402',
    'd0000000-0000-0000-0000-000000000302',
    'd0000000-0000-0000-0000-000000000202',
    'wamid.bridge-fix-multi-b',
    '919990121158', now(), 1, 'TEXT', 'second order', '{}'::jsonb, 0, 'SUCCEEDED', '{}'::jsonb
  );

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'd0000000-0000-0000-0000-000000000801',
  'd0000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select throws_ok(
  $$select public.whatsapp_case_potential_order_id('d0000000-0000-0000-0000-000000000801')$$,
  'P0001',
  'multiple potential orders are linked to this communication case',
  'multiple matching potential orders fail closed without LIMIT 1'
);

-- ---------------------------------------------------------------------------
-- Cross-sender: inbound wamid matches evidence owned by another sender_key
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'e0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-cross-sender',
  '918880000002',
  'other customer order',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  'e0000000-0000-0000-0000-000000000301',
  'e0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-cross-sender',
  '918880000002',
  'bridge-fix-fingerprint-cross',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

insert into public.whatsapp_commercial_packets (
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values (
  'e0000000-0000-0000-0000-000000000401',
  'e0000000-0000-0000-0000-000000000301',
  '918880000002',
  'bridge-fix-conversation-cross',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'e0000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"spoofed shared wamid"}'::jsonb,
  1,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  'e0000000-0000-0000-0000-000000000601',
  'a0000000-0000-0000-0000-000000000101',
  'e0000000-0000-0000-0000-000000000501',
  'inbound',
  'text',
  'spoofed shared wamid',
  'click2api',
  'wamid.bridge-fix-cross-sender',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, original_payload,
  media_count, processing_state, processing_detail
) values (
  'e0000000-0000-0000-0000-000000000701',
  'e0000000-0000-0000-0000-000000000401',
  'e0000000-0000-0000-0000-000000000301',
  'e0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-cross-sender',
  '918880000002',
  now(),
  1,
  'TEXT',
  'other customer order',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'e0000000-0000-0000-0000-000000000801',
  'e0000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select is(
  public.whatsapp_case_potential_order_id('e0000000-0000-0000-0000-000000000801'),
  null::uuid,
  'provider_message_id belonging to another sender_key does not bridge'
);

-- ---------------------------------------------------------------------------
-- Same packet id but evidence sender_key differs from case contact → NULL
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '10000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-same-packet-wrong-sender',
  '918880000002',
  'wrong sender same packet',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  '10000000-0000-0000-0000-000000000301',
  '10000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-same-packet-wrong-sender',
  '918880000002',
  'bridge-fix-fingerprint-same-packet-wrong-sender',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

insert into public.whatsapp_commercial_packets (
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values (
  '10000000-0000-0000-0000-000000000401',
  '10000000-0000-0000-0000-000000000301',
  '918880000002',
  'bridge-fix-conversation-same-packet-wrong-sender',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  '10000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"case contact packet"}'::jsonb,
  1,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  '10000000-0000-0000-0000-000000000601',
  'a0000000-0000-0000-0000-000000000101',
  '10000000-0000-0000-0000-000000000501',
  'inbound',
  'text',
  'case contact inbound',
  'click2api',
  'wamid.bridge-fix-same-packet-case-contact',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, original_payload,
  media_count, processing_state, processing_detail
) values (
  '10000000-0000-0000-0000-000000000701',
  '10000000-0000-0000-0000-000000000501',
  '10000000-0000-0000-0000-000000000301',
  '10000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-same-packet-wrong-sender',
  '918880000002',
  now(),
  1,
  'TEXT',
  'wrong sender same packet',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '10000000-0000-0000-0000-000000000801',
  '10000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select is(
  public.whatsapp_case_potential_order_id('10000000-0000-0000-0000-000000000801'),
  null::uuid,
  'same packet id with a different sender_key does not bridge'
);

-- ---------------------------------------------------------------------------
-- Outbound provider_message_id must not bridge
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'f0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-outbound-evidence',
  '919990121158',
  'outbound must not match',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  'f0000000-0000-0000-0000-000000000301',
  'f0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-outbound-evidence',
  '919990121158',
  'bridge-fix-fingerprint-outbound',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

insert into public.whatsapp_commercial_packets (
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values (
  'f0000000-0000-0000-0000-000000000401',
  'f0000000-0000-0000-0000-000000000301',
  '919990121158',
  'bridge-fix-conversation-outbound',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'f0000000-0000-0000-0000-000000000501',
  'a0000000-0000-0000-0000-000000000101',
  '{"text":"outbound only"}'::jsonb,
  1,
  now(),
  now(),
  'open'
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values
  (
    'f0000000-0000-0000-0000-000000000601',
    'a0000000-0000-0000-0000-000000000101',
    'f0000000-0000-0000-0000-000000000501',
    'inbound',
    'text',
    'unrelated inbound',
    'click2api',
    'wamid.bridge-fix-outbound-inbound',
    'received',
    now()
  ),
  (
    'f0000000-0000-0000-0000-000000000602',
    'a0000000-0000-0000-0000-000000000101',
    'f0000000-0000-0000-0000-000000000501',
    'outbound',
    'text',
    'operator reply',
    'click2api',
    'wamid.bridge-fix-outbound-evidence',
    'sent',
    now()
  );

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, original_payload,
  media_count, processing_state, processing_detail
) values (
  'f0000000-0000-0000-0000-000000000701',
  'f0000000-0000-0000-0000-000000000401',
  'f0000000-0000-0000-0000-000000000301',
  'f0000000-0000-0000-0000-000000000201',
  'wamid.bridge-fix-outbound-evidence',
  '919990121158',
  now(),
  1,
  'TEXT',
  'outbound must not match',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'f0000000-0000-0000-0000-000000000801',
  'f0000000-0000-0000-0000-000000000501',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'packet-ai-b2b-v1'
);

select is(
  public.whatsapp_case_potential_order_id('f0000000-0000-0000-0000-000000000801'),
  null::uuid,
  'outbound provider_message_id does not bridge a potential order'
);

select is(
  public.whatsapp_case_potential_order_id('00000000-0000-0000-0000-000000000000'),
  null::uuid,
  'unknown case id fails closed with NULL'
);

select * from finish();
rollback;
