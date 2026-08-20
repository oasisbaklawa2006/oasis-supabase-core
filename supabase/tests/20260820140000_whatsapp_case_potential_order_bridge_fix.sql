begin;
-- Regression: stitcher packet id != WA4 commercial packet id must still resolve potential order.
select plan(2);

insert into public.whatsapp_contacts (id, phone_number, wa_contact_id) values
  ('a0000000-0000-0000-0000-000000000101', '919990121158', '919990121158');

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
  'bridge-fix-fingerprint',
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
  'bridge-fix-conversation',
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
  id, contact_id, packet_id, direction, message_type, content, provider_message_id, status, created_at
) values (
  'a0000000-0000-0000-0000-000000000601',
  'a0000000-0000-0000-0000-000000000101',
  'a0000000-0000-0000-0000-000000000501',
  'inbound',
  'text',
  'Please book 3 cartons of Cashew Pyramid Baklawa.',
  'wamid.bridge-fix-provider-001',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id, sender_key,
  provider_sent_at, deterministic_sequence, evidence_kind, original_body, media_count,
  processing_state, processing_detail
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

select * from finish();
rollback;
