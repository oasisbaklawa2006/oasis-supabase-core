begin;
-- Behavioral and concurrency coverage for 20260822120000_whatsapp_packet_ai_hardening_closure.sql.

select plan(41);

select has_function(
  'public',
  'whatsapp_persist_packet_ai_interpretation_governed',
  array['uuid','text','text[]','jsonb','text','uuid','text','text','text','text','text','uuid','uuid','bigint'],
  'governed interpretation persistence RPC exists'
);
select has_function(
  'public',
  'whatsapp_require_packet_ai_dispatch_lease',
  array['uuid','uuid','bigint'],
  'dispatch lease requirement helper exists'
);
select has_column(
  'public',
  'whatsapp_packet_ai_interpretations',
  'knowledge_snapshot_content_checksum',
  'interpretations pin knowledge checksum provenance'
);
select isnt_empty(
  $$select 1 from pg_trigger
    where tgrelid = 'public.whatsapp_intelligence_knowledge_snapshots'::regclass
      and tgname = 'whatsapp_intelligence_snapshot_content_immutable'
      and (tgtype & 4) <> 0$$,
  'knowledge snapshot guard runs on INSERT'
);
select isnt_empty(
  $$select 1 from pg_trigger
    where tgrelid = 'public.whatsapp_intelligence_knowledge_snapshots'::regclass
      and tgname = 'whatsapp_intelligence_snapshot_content_immutable'
      and (tgtype & 16) <> 0$$,
  'knowledge snapshot guard runs on UPDATE'
);

insert into auth.users(id, email) values
  ('86300000-0000-0000-0000-000000000001', 'hardening-admin@example.test');

select throws_ok(
  $$insert into public.whatsapp_intelligence_knowledge_snapshots(
    schema_version, lifecycle, knowledge, content_checksum
  ) values (
    'wa-knowledge/v1', 'ACTIVE', '{"rules":[]}'::jsonb,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  )$$,
  '42501',
  'knowledge activation must use governed activation RPC',
  'direct ACTIVE insert is blocked'
);

select lives_ok(
  $$insert into public.whatsapp_intelligence_knowledge_snapshots(
    schema_version, lifecycle, knowledge, content_checksum, created_by
  ) values (
    'wa-knowledge/v1', 'DRAFT', '{"rules":["draft-only"]}'::jsonb,
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    '86300000-0000-0000-0000-000000000001'
  )$$,
  'DRAFT knowledge snapshot insert is permitted'
);

insert into public.whatsapp_intelligence_knowledge_snapshots(
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86300000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista":"Pista Bulbul"}}'::jsonb,
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  '86300000-0000-0000-0000-000000000001',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  '86300000-0000-0000-0000-000000000001', statement_timestamp()
);

insert into public.whatsapp_intelligence_knowledge_snapshots(
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86300000-0000-0000-0000-000000000011',
  'wa-knowledge/v2', 'APPROVED',
  '{"terminology":{"pista":"Pista Royale"}}'::jsonb,
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  '86300000-0000-0000-0000-000000000001',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  '86300000-0000-0000-0000-000000000001', statement_timestamp()
);

select lives_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot('86300000-0000-0000-0000-000000000010')$$,
  'first governed activation succeeds with no prior ACTIVE row'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id='86300000-0000-0000-0000-000000000010'),
  'ACTIVE',
  'first activation leaves exactly one ACTIVE snapshot'
);
select is(
  (select count(*)::integer from public.whatsapp_intelligence_knowledge_snapshots where lifecycle='ACTIVE'),
  1,
  'exactly one ACTIVE snapshot after first activation'
);

select lives_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot('86300000-0000-0000-0000-000000000011')$$,
  'second governed activation supersedes the previous ACTIVE snapshot'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id='86300000-0000-0000-0000-000000000010'),
  'SUPERSEDED',
  'prior ACTIVE snapshot is superseded'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id='86300000-0000-0000-0000-000000000011'),
  'ACTIVE',
  'newer approved snapshot becomes ACTIVE'
);
select is(
  (select count(*)::integer from public.whatsapp_intelligence_knowledge_snapshots where lifecycle='ACTIVE'),
  1,
  'exactly one ACTIVE snapshot remains after supersession'
);

insert into public.whatsapp_intelligence_knowledge_snapshots(
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86300000-0000-0000-0000-000000000012',
  'wa-knowledge/v3', 'APPROVED',
  '{"terminology":{"pista":"Pista Flag"}}'::jsonb,
  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  '86300000-0000-0000-0000-000000000001',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  '86300000-0000-0000-0000-000000000001', statement_timestamp()
);

select throws_ok(
$flag_reset$
do $inner$
begin
  perform public.whatsapp_activate_intelligence_knowledge_snapshot('86300000-0000-0000-0000-000000000012');
  update public.whatsapp_intelligence_knowledge_snapshots
  set lifecycle = 'ACTIVE'
  where id = '86300000-0000-0000-0000-000000000011';
end $inner$;
$flag_reset$,
  '42501',
  'knowledge activation must use governed activation RPC',
  'activation flag reset blocks direct ACTIVE mutation in same transaction'
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;

select throws_ok(
  $$update public.whatsapp_intelligence_knowledge_snapshots
    set lifecycle = 'ACTIVE'
    where id = '86300000-0000-0000-0000-000000000010'$$,
  '42501',
  'knowledge activation must use governed activation RPC',
  'direct ACTIVE update is blocked outside governed activation'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86300000-0000-0000-0000-000000000020', '919630000020', 'Hardening lease contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values
  ('86300000-0000-0000-0000-000000000021', '86300000-0000-0000-0000-000000000020',
   'inbound', 'text', '10 boxes', 'click2api', 'hardening-a', 'received',
   '2026-08-22 11:00:00', '2026-08-22 11:00:00'),
  ('86300000-0000-0000-0000-000000000022', '86300000-0000-0000-0000-000000000020',
   'inbound', 'text', '12 cartons', 'click2api', 'hardening-b', 'received',
   '2026-08-22 11:00:10', '2026-08-22 11:00:10');

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86300000-0000-0000-0000-000000000020',
    array['86300000-0000-0000-0000-000000000021'::uuid], 300)$$,
  'hardening packet A stitches atomically'
);
create temporary table hardening_claim as
  select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select isnt(
  (select id from hardening_claim),
  null::uuid,
  'claimed dispatch lease id is non-null'
);
select is(
  (select state from hardening_claim),
  'LEASED',
  'claimed dispatch lease state is LEASED'
);
select is(
  (select execution_kind from hardening_claim),
  'PACKET',
  'claimed dispatch lease execution_kind is PACKET'
);
select is(
  (select packet_id from hardening_claim),
  (select packet_id from public.whatsapp_messages where id='86300000-0000-0000-0000-000000000021'),
  'claimed dispatch lease packet_id matches hardening-a packet'
);
select is(
  (select packet_revision from hardening_claim)::integer,
  1,
  'claimed dispatch lease packet_revision is 1'
);
select isnt(
  (select lease_token from hardening_claim),
  null::uuid,
  'claimed dispatch lease token is non-null'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86300000-0000-0000-0000-000000000020',
    array['86300000-0000-0000-0000-000000000022'::uuid], 300)$$,
  'hardening correction creates revision 2'
);

select throws_ok(
  $$select public.whatsapp_persist_packet_ai_interpretation_governed(
    (select packet_id from public.whatsapp_messages where id='86300000-0000-0000-0000-000000000021'),
    'fingerprint-stale',
    array['hardening-a'],
    '{"conclusion":{"summary":"x","recommended_action":"y"}}'::jsonb,
    'test-model',
    '86300000-0000-0000-0000-000000000011',
    'wa-knowledge/v2',
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
    'wa-packet-interpretation/v1',
    'wa-packet-policy/v1',
    'wa-resolver-policy/v1',
    (select id from hardening_claim),
    (select lease_token from hardening_claim),
  (select packet_revision from hardening_claim)
  )$$,
  '55000',
  null,
  'stale leased worker cannot persist interpretation after revision advance'
);

select throws_ok(
  $$select public.whatsapp_materialize_packet_ai_case(
    (select packet_id from public.whatsapp_messages where id='86300000-0000-0000-0000-000000000021'),
    '86300000-0000-0000-0000-000000000099',
    (select id from hardening_claim),
    (select lease_token from hardening_claim),
    (select packet_revision from hardening_claim)
  )$$,
  '55000',
  null,
  'stale leased worker cannot materialize case after revision advance'
);

-- Replay lineage self-healing: evidence first correlated without potential order,
-- then governed bridge arrives and replay heals missing lineage idempotently.
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86300000-0000-0000-0000-000000000030', '919630000030', 'Replay lineage contact');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  '86300000-0000-0000-0000-000000000031',
  '86300000-0000-0000-0000-000000000030',
  '{"text":"Please send 5 cartons"}'::jsonb,
  1, '2026-08-22 12:00:00', '2026-08-22 12:00:00', 'open'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '86300000-0000-0000-0000-000000000040',
  'replay-bridge-provider',
  '919630000030',
  'Please send 5 cartons',
  'text',
  '2026-08-22 12:00:00'
);
insert into public.whatsapp_messages(
  id, contact_id, packet_id, direction, message_type, content, provider,
  provider_message_id, status, created_at
) values (
  '86300000-0000-0000-0000-000000000041',
  '86300000-0000-0000-0000-000000000030',
  '86300000-0000-0000-0000-000000000031',
  'inbound', 'text', 'Please send 5 cartons', 'click2api',
  'replay-bridge-provider', 'received', '2026-08-22 12:00:00'
);
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '86300000-0000-0000-0000-000000000032',
  '86300000-0000-0000-0000-000000000031',
  'ORDER', 'AWAITING_CUSTOMER', 'WHATSAPP', 'packet-ai-b2b-v1'
);
insert into public.whatsapp_case_identities(
  id, case_id, identity_role, party_type, resolution_status
) values (
  '86300000-0000-0000-0000-000000000043',
  '86300000-0000-0000-0000-000000000032',
  'SUBMITTING_SENDER', 'CONTACT', 'UNRESOLVED'
);
insert into public.whatsapp_case_recipient_authorizations(
  id, case_id, identity_id, may_receive_clarification, verification_method,
  verified_by, verified_at, correlation_key
) values (
  '86300000-0000-0000-0000-000000000044',
  '86300000-0000-0000-0000-000000000032',
  '86300000-0000-0000-0000-000000000043',
  true, 'OPERATOR_VERIFIED',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  'replay-lineage-auth'
);
insert into public.whatsapp_case_clarifications(
  id, case_id, field_name, question, recipient_authorization_id, status,
  due_at, asked_by, correlation_key, asked_at
) values (
  '86300000-0000-0000-0000-000000000045',
  '86300000-0000-0000-0000-000000000032',
  'QUANTITY', 'How many cartons do you need exactly?', '86300000-0000-0000-0000-000000000044',
  'OPEN', statement_timestamp() + interval '1 day',
  '86300000-0000-0000-0000-000000000001', 'replay-lineage-clarification',
  '2026-08-22 12:00:00'
);
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  '86300000-0000-0000-0000-000000000035',
  '86300000-0000-0000-0000-000000000030',
  '{"text":"12 cartons please"}'::jsonb,
  1, '2026-08-22 12:05:00', '2026-08-22 12:05:00', 'open'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '86300000-0000-0000-0000-000000000033',
  'replay-clar-answer',
  '919630000030',
  '12 cartons please',
  'text',
  '2026-08-22 12:05:00'
);
insert into public.whatsapp_messages(
  id, contact_id, packet_id, direction, message_type, content, provider,
  provider_message_id, status, created_at
) values (
  '86300000-0000-0000-0000-000000000034',
  '86300000-0000-0000-0000-000000000030',
  '86300000-0000-0000-0000-000000000035',
  'inbound', 'text', '12 cartons please', 'click2api',
  'replay-clar-answer', 'received', '2026-08-22 12:05:00'
);

select lives_ok(
  $$select public.whatsapp_correlate_clarification_answer('86300000-0000-0000-0000-000000000034')$$,
  'first clarification correlation succeeds without commercial bridge'
);
select is(
  (select count(*)::integer from public.whatsapp_clarification_answer_evidence
    where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000034'),
  1,
  'first correlation creates exactly one answer evidence row'
);
select is(
  (select count(*)::integer from public.whatsapp_potential_order_evidence_lineage
    where clarification_answer_evidence_id in (
      select id from public.whatsapp_clarification_answer_evidence
      where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000034'
    )),
  0,
  'first correlation without bridge creates no potential-order lineage'
);
select is(
  (select count(*)::integer from public.whatsapp_case_context_executions
    where answer_evidence_id in (
      select id from public.whatsapp_clarification_answer_evidence
      where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000034'
    )),
  1,
  'first correlation enqueues one case-context execution'
);

insert into public.whatsapp_potential_orders(
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  '86300000-0000-0000-0000-000000000036',
  '86300000-0000-0000-0000-000000000040',
  'replay-bridge-provider',
  '919630000030',
  'replay-lineage-fingerprint',
  '[]'::jsonb,
  'UNASSIGNED', 'ACTIVE_PENDING', 'WA_COMMERCIAL_UNASSIGNED', 'ASSIGN_OWNER',
  '2026-08-22 12:00:00', '2026-08-22 12:00:00'
);
insert into public.whatsapp_commercial_packets(
  id, potential_order_id, sender_key, conversation_key, status, processing_state,
  first_received_at, last_received_at
) values (
  '86300000-0000-0000-0000-000000000037',
  '86300000-0000-0000-0000-000000000036',
  '919630000030', 'replay-lineage-conversation', 'OPEN', 'READY',
  '2026-08-22 12:00:00', '2026-08-22 12:00:00'
);
insert into public.whatsapp_commercial_evidence(
  id, packet_id, potential_order_id, source_message_id, provider_message_id,
  sender_key, provider_sent_at, deterministic_sequence, evidence_kind,
  original_body, original_payload, processing_state, processing_detail
) values (
  '86300000-0000-0000-0000-000000000038',
  '86300000-0000-0000-0000-000000000037',
  '86300000-0000-0000-0000-000000000036',
  '86300000-0000-0000-0000-000000000040',
  'replay-bridge-provider',
  '919630000030',
  '2026-08-22 12:00:00',
  1, 'TEXT',
  'Please send 5 cartons', '{}'::jsonb, 'SUCCEEDED', '{}'::jsonb
);

select lives_ok(
  $$select public.whatsapp_correlate_clarification_answer('86300000-0000-0000-0000-000000000034')$$,
  'replay correlation reuses canonical evidence and heals lineage'
);
select is(
  (select count(*)::integer from public.whatsapp_clarification_answer_evidence
    where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000034'),
  1,
  'replay correlation does not duplicate answer evidence'
);
select is(
  (select count(*)::integer from public.whatsapp_potential_order_evidence_lineage
    where potential_order_id='86300000-0000-0000-0000-000000000036'
      and source_inbound_message_id='86300000-0000-0000-0000-000000000033'),
  1,
  'replay correlation creates missing potential-order lineage'
);
select is(
  (select count(*)::integer from public.whatsapp_case_context_executions
    where answer_evidence_id in (
      select id from public.whatsapp_clarification_answer_evidence
      where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000034'
    )),
  1,
  'replay correlation does not duplicate case-context execution'
);
select is(
  (select count(*)::integer from public.whatsapp_packet_ai_dispatch_jobs
    where execution_kind='CASE_CONTEXT'
      and case_id='86300000-0000-0000-0000-000000000032'),
  1,
  'replay correlation does not duplicate case-context outbox job'
);

-- Runtime clarification failure paths: zero and multiple compatible open clarifications.
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86300000-0000-0000-0000-000000000050', '919630000050', 'Zero clar contact'),
  ('86300000-0000-0000-0000-000000000051', '919630000051', 'Multi clar contact');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  '86300000-0000-0000-0000-000000000052',
  '86300000-0000-0000-0000-000000000050',
  '{"text":"no clar"}'::jsonb,
  1, '2026-08-22 13:00:00', '2026-08-22 13:00:00', 'open'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '86300000-0000-0000-0000-000000000053',
  'zero-clar-answer',
  '919630000050',
  'no clar',
  'text',
  '2026-08-22 13:00:00'
);
insert into public.whatsapp_messages(
  id, contact_id, packet_id, direction, message_type, content, provider,
  provider_message_id, status, created_at
) values (
  '86300000-0000-0000-0000-000000000054',
  '86300000-0000-0000-0000-000000000050',
  '86300000-0000-0000-0000-000000000052',
  'inbound', 'text', 'no clar', 'click2api',
  'zero-clar-answer', 'received', '2026-08-22 13:00:00'
);

select throws_ok(
  $$select public.whatsapp_correlate_clarification_answer('86300000-0000-0000-0000-000000000054')$$,
  'P0001',
  'no compatible open clarification',
  'zero compatible clarifications fail closed with exact error'
);
select is(
  (select count(*)::integer from public.whatsapp_clarification_answer_evidence
    where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000054'),
  0,
  'zero-clarification failure leaves no answer evidence'
);
select is(
  (select count(*)::integer from public.whatsapp_case_context_executions),
  1,
  'zero-clarification failure leaves only prior replay execution'
);

insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  '86300000-0000-0000-0000-000000000055',
  '86300000-0000-0000-0000-000000000051',
  '{"text":"case one"}'::jsonb,
  1, '2026-08-22 13:10:00', '2026-08-22 13:10:00', 'open'
),
(
  '86300000-0000-0000-0000-000000000056',
  '86300000-0000-0000-0000-000000000051',
  '{"text":"case two"}'::jsonb,
  1, '2026-08-22 13:11:00', '2026-08-22 13:11:00', 'open'
);
insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '86300000-0000-0000-0000-000000000057',
  '86300000-0000-0000-0000-000000000055',
  'ORDER', 'AWAITING_CUSTOMER', 'WHATSAPP', 'packet-ai-b2b-v1'
),
(
  '86300000-0000-0000-0000-000000000058',
  '86300000-0000-0000-0000-000000000056',
  'ORDER', 'AWAITING_CUSTOMER', 'WHATSAPP', 'packet-ai-b2b-v1'
);
insert into public.whatsapp_case_identities(
  id, case_id, identity_role, party_type, resolution_status
) values (
  '86300000-0000-0000-0000-000000000059',
  '86300000-0000-0000-0000-000000000057',
  'SUBMITTING_SENDER', 'CONTACT', 'UNRESOLVED'
),
(
  '86300000-0000-0000-0000-000000000060',
  '86300000-0000-0000-0000-000000000058',
  'SUBMITTING_SENDER', 'CONTACT', 'UNRESOLVED'
);
insert into public.whatsapp_case_recipient_authorizations(
  id, case_id, identity_id, may_receive_clarification, verification_method,
  verified_by, verified_at, correlation_key
) values (
  '86300000-0000-0000-0000-000000000061',
  '86300000-0000-0000-0000-000000000057',
  '86300000-0000-0000-0000-000000000059',
  true, 'OPERATOR_VERIFIED',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  'multi-clar-auth-1'
),
(
  '86300000-0000-0000-0000-000000000062',
  '86300000-0000-0000-0000-000000000058',
  '86300000-0000-0000-0000-000000000060',
  true, 'OPERATOR_VERIFIED',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  'multi-clar-auth-2'
);
insert into public.whatsapp_case_clarifications(
  id, case_id, field_name, question, recipient_authorization_id, status,
  due_at, asked_by, correlation_key, asked_at
) values (
  '86300000-0000-0000-0000-000000000063',
  '86300000-0000-0000-0000-000000000057',
  'QUANTITY', 'How many cartons for case one?', '86300000-0000-0000-0000-000000000061',
  'OPEN', statement_timestamp() + interval '1 day',
  '86300000-0000-0000-0000-000000000001', 'multi-clar-1',
  '2026-08-22 13:10:00'
),
(
  '86300000-0000-0000-0000-000000000064',
  '86300000-0000-0000-0000-000000000058',
  'QUANTITY', 'How many cartons for case two?', '86300000-0000-0000-0000-000000000062',
  'OPEN', statement_timestamp() + interval '1 day',
  '86300000-0000-0000-0000-000000000001', 'multi-clar-2',
  '2026-08-22 13:11:00'
);
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  '86300000-0000-0000-0000-000000000065',
  '86300000-0000-0000-0000-000000000051',
  '{"text":"multi answer"}'::jsonb,
  1, '2026-08-22 13:12:00', '2026-08-22 13:12:00', 'open'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '86300000-0000-0000-0000-000000000066',
  'multi-clar-answer',
  '919630000051',
  'multi answer',
  'text',
  '2026-08-22 13:12:00'
);
insert into public.whatsapp_messages(
  id, contact_id, packet_id, direction, message_type, content, provider,
  provider_message_id, status, created_at
) values (
  '86300000-0000-0000-0000-000000000067',
  '86300000-0000-0000-0000-000000000051',
  '86300000-0000-0000-0000-000000000065',
  'inbound', 'text', 'multi answer', 'click2api',
  'multi-clar-answer', 'received', '2026-08-22 13:12:00'
);

select throws_ok(
  $$select public.whatsapp_correlate_clarification_answer('86300000-0000-0000-0000-000000000067')$$,
  'P0001',
  'multiple compatible clarifications',
  'multiple compatible clarifications fail closed with exact error'
);
select is(
  (select count(*)::integer from public.whatsapp_clarification_answer_evidence
    where answer_whatsapp_message_id='86300000-0000-0000-0000-000000000067'),
  0,
  'multi-clarification failure leaves no answer evidence'
);
select is(
  (select count(*)::integer from public.whatsapp_case_context_executions),
  1,
  'multi-clarification failure leaves only prior replay execution'
);

select * from finish();
rollback;
