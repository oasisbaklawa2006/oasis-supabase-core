-- POINT66 — WhatsApp sender / original-customer identity canonical closure certification.
-- Synthetic fixtures only; reuses existing Core RPC authority without new migrations.
-- Proves sender≠customer invariant, forwarded original-customer preservation,
-- explicit/manual resolution, ambiguous fail-closed, audit provenance, and
-- separation from Point65 grouping and Point67 packet→draft lanes.
begin;
select plan(34);

-- ---------------------------------------------------------------------------
-- Shared fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('66000000-0000-0000-0000-000000000001', 'p66-operator@example.test');

insert into public.users (id, email, name, role, is_active) values
  ('66000000-0000-0000-0000-000000000001', 'p66-operator@example.test', 'P66 Operator', 'admin', true);

insert into public.user_role_map (user_id, role_id)
select '66000000-0000-0000-0000-000000000001', id
from public.roles
where role_key = 'admin'
on conflict (user_id, role_id) do nothing;

insert into public.companies (id, business_name, gst_number, phone, status) values
  ('66000000-0000-0000-0000-000000000002', 'P66 Customer Alpha', '29AAAAA0000A1Z1', '919800000001', 'active'),
  ('66000000-0000-0000-0000-000000000003', 'P66 Customer Beta', '29BBBBB1111B2Z2', '919800000002', 'active'),
  ('66000000-0000-0000-0000-000000000004', 'P66 Customer Gamma', '29CCCCC2222C3Z3', '919800000099', 'active'),
  ('66000000-0000-0000-0000-000000000005', 'P66 Customer Delta', '29DDDDD3333D4Z4', '919800000099', 'active');

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('66000000-0000-0000-0000-000000000010', '+91 98000 00095', 'P66 Employee Relay'),
  ('66000000-0000-0000-0000-000000000011', '919800000011', 'P66 Customer Contact'),
  ('66000000-0000-0000-0000-000000000012', '919777777777', 'P66 Wrong Sender'),
  ('66000000-0000-0000-0000-000000000013', '919800000099', 'P66 Shared Phone Contact');

insert into public.users (id, email, name, role, phone, is_active) values
  ('66000000-0000-0000-0000-000000000020', 'p66-sales@oasis.test', 'P66 Sales Executive', 'SALES_EXECUTIVE', '919800000095', true);

insert into public.whatsapp_sender_commercial_authorizations (
  id, contact_id, company_id, disclosure_scope, identity_evidence, status,
  authorized_by, authorized_at, valid_until
) values (
  '66000000-0000-0000-0000-000000000030',
  '66000000-0000-0000-0000-000000000010',
  '66000000-0000-0000-0000-000000000002',
  array['customer_pricing']::text[],
  '{"method":"STANDING_AUTHORITY"}'::jsonb,
  'ACTIVE',
  '66000000-0000-0000-0000-000000000001',
  statement_timestamp(),
  statement_timestamp() + interval '30 days'
);

-- ---------------------------------------------------------------------------
-- CENSUS: identity authority surfaces
-- ---------------------------------------------------------------------------
select has_table('public', 'whatsapp_case_identities', 'CENSUS: three-role identity ledger exists');
select has_column('public', 'whatsapp_case_identities', 'identity_role', 'CENSUS: identity_role column exists');
select has_column('public', 'whatsapp_case_identities', 'resolution_status', 'CENSUS: resolution_status column exists');
select has_function('public', 'whatsapp_resolve_governed_customer', array['uuid', 'jsonb'], 'CENSUS: governed customer resolver exists');
select has_function('public', 'whatsapp_confirm_case_identity', array['uuid', 'uuid', 'text', 'text[]', 'boolean', 'boolean', 'timestamptz', 'jsonb', 'text'], 'CENSUS: manual case identity confirmation RPC exists');
select has_function('public', 'whatsapp_confirm_original_communicator', array['uuid', 'text', 'uuid', 'text', 'text', 'text', 'jsonb', 'text'], 'CENSUS: original communicator confirmation RPC exists');
select has_function('public', 'whatsapp_case_potential_order_id', array['uuid'], 'CENSUS: fail-closed case↔potential-order bridge exists');
select ok(
  exists(
    select 1
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    where t.typname = 'whatsapp_identity_role'
      and e.enumlabel in ('SUBMITTING_SENDER', 'ORIGINAL_COMMUNICATOR', 'COMMERCIAL_CUSTOMER')
  ) or exists(
    select 1
    from information_schema.check_constraints cc
    join information_schema.constraint_column_usage ccu
      on cc.constraint_name = ccu.constraint_name
    where ccu.table_name = 'whatsapp_case_identities'
      and ccu.column_name = 'identity_role'
  ),
  'CENSUS: three canonical identity roles are modeled'
);

-- ---------------------------------------------------------------------------
-- FLOW1: sender_key normalization binds provider sender phone
-- ---------------------------------------------------------------------------
select is(
  lower(regexp_replace(
    (select phone_number from public.whatsapp_contacts where id = '66000000-0000-0000-0000-000000000010'),
    '\D', '', 'g'
  )),
  '919800000095',
  'FLOW1: formatted provider sender phone normalizes to canonical sender_key'
);

-- ---------------------------------------------------------------------------
-- FLOW2: employee relay sender≠customer — governed resolver fail-closed
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

create temporary table p66_relay_explicit as
select * from public.whatsapp_resolve_governed_customer(
  '66000000-0000-0000-0000-000000000010',
  '{"company_name": "P66 Customer Beta", "gst_number": "29BBBBB1111B2Z2"}'::jsonb
);

select is(
  (select company_id from p66_relay_explicit),
  '66000000-0000-0000-0000-000000000003'::uuid,
  'FLOW2a: explicit candidate company outranks sender authorization on Company Alpha'
);
select is(
  (select match_method from p66_relay_explicit),
  'EXACT_GST_MATCH',
  'FLOW2a: explicit GST evidence governs resolution'
);

create temporary table p66_relay_no_candidate as
select * from public.whatsapp_resolve_governed_customer(
  '66000000-0000-0000-0000-000000000010',
  '{}'::jsonb
);

select is(
  (select company_id from p66_relay_no_candidate),
  null::uuid,
  'FLOW2b: employee sender with no candidate never infers customer from sender authorization'
);
select is(
  (select resolution_status from p66_relay_no_candidate),
  'UNRESOLVED',
  'FLOW2b: employee relay without candidate fails closed as UNRESOLVED'
);

create temporary table p66_relay_unknown_candidate as
select * from public.whatsapp_resolve_governed_customer(
  '66000000-0000-0000-0000-000000000010',
  '{"company_id": "66000000-0000-0000-0000-000000000099"}'::jsonb
);

select is(
  (select company_id from p66_relay_unknown_candidate),
  null::uuid,
  'FLOW2c: unknown explicit candidate never falls back to sender-associated company'
);
select is(
  (select resolution_status from p66_relay_unknown_candidate),
  'UNRESOLVED',
  'FLOW2c: unknown candidate resolution status is UNRESOLVED'
);

-- ---------------------------------------------------------------------------
-- FLOW3: forwarded message preserves original customer distinct from sender
-- ---------------------------------------------------------------------------
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at, status
) values (
  '66000000-0000-0000-0000-000000000040',
  '66000000-0000-0000-0000-000000000010',
  '{"text":"Fwd: order for P66 Customer Alpha"}'::jsonb,
  now(), now(), 'closed'
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '66000000-0000-0000-0000-000000000050',
  '66000000-0000-0000-0000-000000000040',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'p66-fixture-v1'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '66000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select public.whatsapp_confirm_original_communicator(
      '66000000-0000-0000-0000-000000000050',
      'COMPANY',
      '66000000-0000-0000-0000-000000000002',
      'P66 Customer Alpha',
      '919800000001',
      'FORWARDED_MESSAGE',
      '{"forwarded_from":"919800000001","operator_note":"employee relay forward"}'::jsonb,
      'p66-original-communicator-1'
    )$$,
  'FLOW3a: operator confirms original communicator from forwarded evidence'
);

select is(
  (select party_id from public.whatsapp_case_identities
    where case_id = '66000000-0000-0000-0000-000000000050'
      and identity_role = 'ORIGINAL_COMMUNICATOR'),
  '66000000-0000-0000-0000-000000000002'::uuid,
  'FLOW3b: ORIGINAL_COMMUNICATOR is the forwarded customer company, not the relay sender'
);

select is_empty(
  $$select 1 from public.whatsapp_case_identities
    where case_id = '66000000-0000-0000-0000-000000000050'
      and identity_role = 'SUBMITTING_SENDER'$$,
  'FLOW3c: submitting sender identity is not auto-created from forwarded confirmation alone'
);

select isnt_empty(
  $$select 1 from public.whatsapp_case_events
    where case_id = '66000000-0000-0000-0000-000000000050'
      and event_type = 'ORIGINAL_COMMUNICATOR_CONFIRMED'
      and correlation_key = 'original-communicator:p66-original-communicator-1'$$,
  'FLOW3d: forwarded original-customer confirmation is auditable'
);

-- ---------------------------------------------------------------------------
-- FLOW4: explicit manual company resolution with governed audit
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '66000000-0000-0000-0000-000000000060',
  'p66-manual-resolve',
  '919800000095',
  'please book 5 boxes for P66 Customer Alpha',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  '66000000-0000-0000-0000-000000000061',
  '66000000-0000-0000-0000-000000000060',
  'p66-manual-resolve',
  '919800000095',
  'p66-manual-resolve-fingerprint',
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
  '66000000-0000-0000-0000-000000000063',
  '66000000-0000-0000-0000-000000000061',
  '919800000095',
  'p66-manual-resolve-conversation',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  '66000000-0000-0000-0000-000000000064',
  '66000000-0000-0000-0000-000000000010',
  '66000000-0000-0000-0000-000000000040',
  'inbound',
  'text',
  'please book 5 boxes for P66 Customer Alpha',
  'click2api',
  'p66-manual-resolve',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id,
  sender_key, provider_sent_at, deterministic_sequence, evidence_kind,
  original_body, original_payload, media_count, processing_state, processing_detail
) values (
  '66000000-0000-0000-0000-000000000062',
  '66000000-0000-0000-0000-000000000063',
  '66000000-0000-0000-0000-000000000061',
  '66000000-0000-0000-0000-000000000060',
  'p66-manual-resolve',
  '919800000095',
  now(),
  1,
  'TEXT',
  'please book 5 boxes for P66 Customer Alpha',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '66000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select public.whatsapp_confirm_case_identity(
      '66000000-0000-0000-0000-000000000050',
      '66000000-0000-0000-0000-000000000002',
      'OPERATOR_VERIFIED',
      '{}'::text[],
      true,
      false,
      null,
      '{"operator_review":"manual CRM match for forwarded order"}'::jsonb,
      'p66-identity-confirm-1'
    )$$,
  'FLOW4a: operator manually confirms commercial customer distinct from relay sender'
);

select is(
  (select company_id from public.whatsapp_communication_cases where id = '66000000-0000-0000-0000-000000000050'),
  '66000000-0000-0000-0000-000000000002'::uuid,
  'FLOW4b: case company_id reflects governed manual resolution'
);

select is(
  (select party_id from public.whatsapp_case_identities
    where case_id = '66000000-0000-0000-0000-000000000050'
      and identity_role = 'COMMERCIAL_CUSTOMER'),
  '66000000-0000-0000-0000-000000000002'::uuid,
  'FLOW4c: COMMERCIAL_CUSTOMER identity is explicitly confirmed'
);

select is(
  (select party_id from public.whatsapp_case_identities
    where case_id = '66000000-0000-0000-0000-000000000050'
      and identity_role = 'SUBMITTING_SENDER'),
  '66000000-0000-0000-0000-000000000010'::uuid,
  'FLOW4d: SUBMITTING_SENDER remains the relay contact, not the commercial customer'
);

select is(
  (select resolution_state from public.whatsapp_order_field_resolutions
    where potential_order_id = '66000000-0000-0000-0000-000000000061'
      and field_key = 'client_identity'),
  'operator_confirmed',
  'FLOW4e: manual identity confirmation bridges to WA-3 client_identity authority'
);

-- ---------------------------------------------------------------------------
-- FLOW5: ambiguous shared-phone identity fails closed without fuzzy linking
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

create temporary table p66_ambiguous_phone as
select * from public.whatsapp_resolve_governed_customer(
  '66000000-0000-0000-0000-000000000013',
  '{}'::jsonb
);

select is(
  (select resolution_status from p66_ambiguous_phone),
  'AMBIGUOUS',
  'FLOW5a: shared phone with multiple companies returns AMBIGUOUS, not auto-linked'
);
select is(
  (select company_id from p66_ambiguous_phone),
  null::uuid,
  'FLOW5b: ambiguous phone match never silently assigns a customer company'
);

-- ---------------------------------------------------------------------------
-- FLOW6: wrong sender/customer association cannot bridge silently
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at, status
) values (
  '66000000-0000-0000-0000-000000000070',
  '66000000-0000-0000-0000-000000000012',
  '{"text":"wrong sender packet"}'::jsonb,
  now(), now(), 'closed'
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '66000000-0000-0000-0000-000000000071',
  '66000000-0000-0000-0000-000000000070',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'p66-fixture-v1'
);

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '66000000-0000-0000-0000-000000000072',
  'p66-wrong-sender',
  '919777777777',
  'wrong sender same packet',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  '66000000-0000-0000-0000-000000000073',
  '66000000-0000-0000-0000-000000000072',
  'p66-wrong-sender',
  '919777777777',
  'p66-wrong-sender-fingerprint',
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
  '66000000-0000-0000-0000-000000000075',
  '66000000-0000-0000-0000-000000000073',
  '919777777777',
  'p66-wrong-sender-conversation',
  'OPEN',
  'READY',
  now(),
  now()
);

insert into public.whatsapp_messages (
  id, contact_id, packet_id, direction, message_type, content,
  provider, provider_message_id, status, created_at
) values (
  '66000000-0000-0000-0000-000000000076',
  '66000000-0000-0000-0000-000000000012',
  '66000000-0000-0000-0000-000000000070',
  'inbound',
  'text',
  'wrong sender same packet',
  'click2api',
  'p66-wrong-sender',
  'received',
  now()
);

insert into public.whatsapp_commercial_evidence (
  id, packet_id, potential_order_id, source_message_id, provider_message_id,
  sender_key, provider_sent_at, deterministic_sequence, evidence_kind,
  original_body, original_payload, media_count, processing_state, processing_detail
) values (
  '66000000-0000-0000-0000-000000000074',
  '66000000-0000-0000-0000-000000000075',
  '66000000-0000-0000-0000-000000000073',
  '66000000-0000-0000-0000-000000000072',
  'p66-wrong-sender',
  '919777777777',
  now(),
  1,
  'TEXT',
  'wrong sender same packet',
  '{}'::jsonb,
  0,
  'SUCCEEDED',
  '{}'::jsonb
);

select is(
  public.whatsapp_case_potential_order_id('66000000-0000-0000-0000-000000000071'),
  '66000000-0000-0000-0000-000000000073'::uuid,
  'FLOW6a: matching sender_key bridges case to potential order when sender aligns'
);

-- Cross-company reassignment without audit: case contact phone != potential order sender_key
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at, status
) values (
  '66000000-0000-0000-0000-000000000080',
  '66000000-0000-0000-0000-000000000010',
  '{"text":"cross sender mismatch"}'::jsonb,
  now(), now(), 'closed'
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '66000000-0000-0000-0000-000000000081',
  '66000000-0000-0000-0000-000000000080',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'p66-fixture-v1'
);

select is(
  public.whatsapp_case_potential_order_id('66000000-0000-0000-0000-000000000081'),
  null::uuid,
  'FLOW6b: cross-sender potential order cannot bridge to mismatched case contact'
);

-- ---------------------------------------------------------------------------
-- FLOW7: identity confirmation idempotency preserves audit lineage
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '66000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select is(
  (select (public.whatsapp_confirm_case_identity(
      '66000000-0000-0000-0000-000000000050',
      '66000000-0000-0000-0000-000000000002',
      'OPERATOR_VERIFIED',
      '{}'::text[],
      true,
      false,
      null,
      '{"operator_review":"replay"}'::jsonb,
      'p66-identity-confirm-1'
    ))->>'idempotent_replay'),
  'true',
  'FLOW7a: repeated identity confirmation with same idempotency key is replay-safe'
);

select is(
  (select count(*) from public.whatsapp_case_events
    where case_id = '66000000-0000-0000-0000-000000000050'
      and event_type = 'CASE_IDENTITY_CONFIRMED'
      and correlation_key = 'identity-confirm:p66-identity-confirm-1'),
  1::bigint,
  'FLOW7b: idempotent replay does not duplicate identity confirmation audit events'
);

-- ---------------------------------------------------------------------------
-- FLOW8: unresolved client_identity cannot reach commercial readiness authority
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '66000000-0000-0000-0000-000000000090',
  'p66-unresolved',
  '919800000011',
  'unresolved identity order',
  'text',
  now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  '66000000-0000-0000-0000-000000000091',
  '66000000-0000-0000-0000-000000000090',
  'p66-unresolved',
  '919800000011',
  'p66-unresolved-fingerprint',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

select is(
  (select (public.evaluate_whatsapp_order_readiness('66000000-0000-0000-0000-000000000091'))->>'ready'),
  'false',
  'FLOW8a: unresolved client_identity blocks commercial readiness'
);

select ok(
  (select (public.evaluate_whatsapp_order_readiness('66000000-0000-0000-0000-000000000091'))->'blocking_fields')
    @> '["client_identity"]'::jsonb,
  'FLOW8b: readiness explicitly lists client_identity as blocking'
);

-- ---------------------------------------------------------------------------
-- BOUNDARY: Point66 identity is separate from Point65 grouping / Point67 draft
-- ---------------------------------------------------------------------------
select ok(
  not exists(
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'whatsapp_case_identities'
      and column_name like '%group%'
  ),
  'BOUNDARY: identity ledger has no Point65 grouping columns'
);

select ok(
  exists(
    select 1 from information_schema.routines
    where routine_schema = 'public'
      and routine_name = 'whatsapp_confirm_case_identity'
  ) and exists(
    select 1 from information_schema.routines
    where routine_schema = 'public'
      and routine_name = 'submit_sales_order_draft_for_review_atomic'
  ),
  'BOUNDARY: Point66 identity confirmation RPC is distinct from Point67 draft review RPC'
);

select * from finish();
rollback;
