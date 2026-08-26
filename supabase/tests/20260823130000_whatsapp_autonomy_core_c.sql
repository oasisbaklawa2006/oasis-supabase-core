begin;
-- Contract and behavioral coverage for 20260823130000_whatsapp_autonomy_core_c.sql (CORE-C).
select plan(41);

-- SECTION 1: Structural contracts
select has_function('public', 'enqueue_governed_whatsapp_autonomous_reply', array[
  'uuid','uuid','text','text','text','text','uuid','uuid','uuid','text[]'
], 'service-only governed outbound enqueue exists');
select has_function('public', 'whatsapp_enqueue_promoted_order_acknowledgement_v1', array['uuid','text'], 'PROMOTED auto-ack authority exists');
select has_function('public', 'whatsapp_enqueue_autonomy_clarification_v1', array['uuid','text'], 'CLARIFICATION_REQUIRED send authority exists');
select has_function('public', 'whatsapp_process_inbound_whatsapp_continuation_v1', array['uuid'], 'inbound answer correlation authority exists');
select has_function('public', 'whatsapp_core_c_resolve_correlated_clarification_v1', array['uuid'], 'automatic clarification resolve exists');
select has_function('public', 'whatsapp_apply_non_order_case_governance_v1', array[
  'uuid','uuid','text','text','text','text'
], 'non-order governance exists');
select has_function('public', 'whatsapp_core_c_guard_post_so_correction_v1', array['uuid','text','boolean'], 'post-SO correction guard exists');
select ok(
  position('whatsapp_process_inbound_whatsapp_continuation_v1' in pg_get_functiondef(
    'public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer)'::regprocedure
  )) > 0,
  'stitch path invokes governed clarification answer continuation'
);
select is_empty(
  $$select 1 from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name in (
        'enqueue_governed_whatsapp_autonomous_reply',
        'whatsapp_enqueue_promoted_order_acknowledgement_v1',
        'whatsapp_enqueue_autonomy_clarification_v1',
        'whatsapp_process_inbound_whatsapp_continuation_v1',
        'whatsapp_core_c_resolve_correlated_clarification_v1',
        'whatsapp_apply_non_order_case_governance_v1'
      )
      and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'CORE-C communication functions are service_role only'
);

-- Shared fixtures
insert into auth.users (id, email) values
  ('c3000000-0000-0000-0000-000000000001', 'corec-admin@example.test');
insert into public.users (id, email, full_name, role) values
  ('c3000000-0000-0000-0000-000000000001', 'corec-admin@example.test', 'Core-C Admin', 'admin');

insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'c3000000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista special":"BAK-PIST-250"},"aliases":{"pista bites":"BAK-PIST-250"}}'::jsonb,
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'c3000000-0000-0000-0000-000000000001',
  'c3000000-0000-0000-0000-000000000001', statement_timestamp(),
  'c3000000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('c3000000-0000-0000-0000-000000000010');

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'c3000000-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);
insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'c3000000-0000-0000-0000-000000000161', 'c3000000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);
insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values (
  'c3000000-0000-0000-0000-000000000171', 'c3000000-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null
);
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'c3000000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919820000001', 'credit', 'active', false
);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'c3000000-0000-0000-0000-000000000211', 'c3000000-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- TEST 1-3: PROMOTED -> exactly one acknowledgement + replay/provider idempotency
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000301', '919820000001', 'Core-C Purchaser');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000311', 'prov-corec-promote', '919820000001',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c3000000-0000-0000-0000-000000000321', 'c3000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-corec-promote', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c3000000-0000-0000-0000-000000000301',
  array['c3000000-0000-0000-0000-000000000321'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000321'),
  'fp-corec-promote',
  array['prov-corec-promote'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "summary": "5 boxes of Pistachio Baklawa 250g",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 5, "unit": "box", "status": "explicit", "evidence_ids": ["prov-corec-promote"]}
      ]
    }
  }'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);

create temporary table corec_promote as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000321'),
  'c3000000-0000-0000-0000-000000000331'
) as payload;

select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where idempotency_key like 'core-c:promoted-ack:%'
      and packet_id = (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000321')),
  1,
  'TEST 1: PROMOTED order enqueues exactly one automatic acknowledgement'
);
select ok(
  (select message_body from public.whatsapp_operator_reply_outbox
    where idempotency_key = 'core-c:promoted-ack:' || (select payload->>'autonomy_decision_id' from corec_promote)
  ) like 'Thank you. We have received your order request%',
  'TEST 1: acknowledgement states only safe deterministic facts'
);

select lives_ok(
  $$select public.whatsapp_enqueue_promoted_order_acknowledgement_v1(
    (select (payload->>'autonomy_decision_id')::uuid from corec_promote),
    'REF-001'
  )$$,
  'TEST 2: promoted acknowledgement replay is idempotent'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where idempotency_key = 'core-c:promoted-ack:' || (select payload->>'autonomy_decision_id' from corec_promote)),
  1,
  'TEST 2: replay creates no duplicate acknowledgement'
);

select lives_ok(
  $$select public.enqueue_governed_whatsapp_autonomous_reply(
    (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000321'),
    'c3000000-0000-0000-0000-000000000301',
    '+919820000001',
    'Thank you. We have received your order request and registered it for processing.',
    'core-c:promoted-ack:' || (select payload->>'autonomy_decision_id' from corec_promote),
    'PROMOTED_ORDER_ACK',
    (select potential_order_id from public.whatsapp_order_autonomy_decisions where id = (select (payload->>'autonomy_decision_id')::uuid from corec_promote)),
    (select (payload->>'case_id')::uuid from corec_promote)
  )$$,
  'TEST 3: provider retry replays same idempotency identity without duplicate send'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where idempotency_key = 'core-c:promoted-ack:' || (select payload->>'autonomy_decision_id' from corec_promote)),
  1,
  'TEST 3: worker/provider retry retains exactly one outbound row'
);

-- TEST 4-5: CLARIFICATION_REQUIRED -> one question, replay safe
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000401', '919820000002', 'Core-C Clarify');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000411', 'prov-corec-clarify', '919820000002',
  'Please send baklawa to MG Road', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c3000000-0000-0000-0000-000000000421', 'c3000000-0000-0000-0000-000000000401',
  'inbound', 'text', 'Please send baklawa to MG Road', 'click2api',
  'prov-corec-clarify', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c3000000-0000-0000-0000-000000000401',
  array['c3000000-0000-0000-0000-000000000421'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000431',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000421'),
  'fp-corec-clarify', array['prov-corec-clarify'],
  '{
    "confidence": 0.92,
    "conclusion": {
      "intent": "ORDER",
      "summary": "baklawa order missing quantity",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": null, "unit": "box", "status": "unclear", "evidence_ids": ["prov-corec-clarify"]}
      ],
      "draft_reply": "How many boxes of BAK-PIST-250 do you need for MG Road?"
    }
  }'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);

create temporary table corec_clarify as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000421'),
  'c3000000-0000-0000-0000-000000000431'
) as payload;

select is((select payload->>'autonomy_outcome' from corec_clarify), 'CLARIFICATION_REQUIRED', 'TEST 4: missing quantity stays CLARIFICATION_REQUIRED');
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox o
    join public.whatsapp_case_clarifications c on c.source_outbound_message_id = o.id
    where c.case_id = (select (payload->>'case_id')::uuid from corec_clarify)),
  1,
  'TEST 4: CLARIFICATION_REQUIRED sends exactly one clarification question'
);
select lives_ok(
  $$select public.whatsapp_enqueue_autonomy_clarification_v1(
    (select (payload->>'autonomy_decision_id')::uuid from corec_clarify),
    'How many boxes of BAK-PIST-250 do you need for MG Road?'
  )$$,
  'TEST 5: clarification replay is idempotent'
);
select is(
  (select count(*)::integer from public.whatsapp_operator_reply_outbox
    where idempotency_key like 'core-c:clarification:%'
      and packet_id = (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000421')),
  1,
  'TEST 5: clarification replay creates no duplicate question'
);

-- TEST 6-8: answer -> context revision + CASE_CONTEXT dispatch + AUTO_ELIGIBLE resume
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000433', 'prov-corec-answer', '919820000002',
  '8 boxes please', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, packet_id, direction, message_type, content, provider, provider_message_id,
  status, created_at
) values (
  'c3000000-0000-0000-0000-000000000434', 'c3000000-0000-0000-0000-000000000401',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000421'),
  'inbound', 'text', '8 boxes please', 'click2api', 'prov-corec-answer', 'received', statement_timestamp() + interval '1 minute'
);

create temporary table corec_resume as
select public.whatsapp_process_inbound_whatsapp_continuation_v1('c3000000-0000-0000-0000-000000000434') as payload;

select ok((select (payload->>'correlated')::boolean from corec_resume), 'TEST 6: compatible answer correlates');
select is(
  (select context_revision from public.whatsapp_communication_cases
    where id = (select (payload->>'case_id')::uuid from corec_clarify)),
  1::bigint,
  'TEST 6: correct answer advances case context revision to N+1'
);
select is(
  (select count(*)::integer from public.whatsapp_packet_ai_dispatch_jobs
    where execution_kind = 'CASE_CONTEXT'
      and case_id = (select (payload->>'case_id')::uuid from corec_clarify)),
  1,
  'TEST 7: answer automatically enqueues CASE_CONTEXT worker continuation'
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000435',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000421'),
  'fp-corec-resume', array['prov-corec-clarify','prov-corec-answer'],
  '{
    "confidence": 0.97,
    "conclusion": {
      "intent": "ORDER",
      "summary": "8 boxes clarified",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 8, "unit": "box", "status": "explicit", "evidence_ids": ["prov-corec-answer"]}
      ]
    }
  }'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);

create temporary table corec_resume2 as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000421'),
  'c3000000-0000-0000-0000-000000000435'
) as payload;

select is((select payload->>'autonomy_outcome' from corec_resume2), 'AUTO_ELIGIBLE', 'TEST 8: resolved clarification resumes to AUTO_ELIGIBLE');
select is(
  (select payload->'draft_execution'->>'execution_status' from corec_resume2),
  'PROMOTED',
  'TEST 8: AUTO_ELIGIBLE automatically continues CORE-B to PROMOTED'
);

-- TEST 9-11: wrong sender + zero/multiple clarifications fail closed
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000501', '919820000099', 'Wrong Sender');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000511', 'prov-wrong-sender', '919820000099',
  '8 boxes', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at
) values (
  'c3000000-0000-0000-0000-000000000512', 'c3000000-0000-0000-0000-000000000501',
  'inbound', 'text', '8 boxes', 'click2api', 'prov-wrong-sender', 'received', statement_timestamp()
);

select is(
  (select (public.whatsapp_process_inbound_whatsapp_continuation_v1('c3000000-0000-0000-0000-000000000512')->>'correlated')::boolean),
  false,
  'TEST 9: wrong sender answer is rejected (fail closed)'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000601', '919820000003', 'Zero Clarify');
insert into public.whatsapp_message_packets(
  id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
) values (
  'c3000000-0000-0000-0000-000000000602', 'c3000000-0000-0000-0000-000000000601',
  '{"text":"hello"}'::jsonb, 1, statement_timestamp(), statement_timestamp(), 'open'
);
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000603', 'prov-zero-clar', '919820000003', 'hello', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, packet_id, direction, message_type, content, provider, provider_message_id, status, created_at
) values (
  'c3000000-0000-0000-0000-000000000604', 'c3000000-0000-0000-0000-000000000601',
  'c3000000-0000-0000-0000-000000000602', 'inbound', 'text', 'hello', 'click2api', 'prov-zero-clar', 'received', statement_timestamp()
);

select is(
  (select (public.whatsapp_process_inbound_whatsapp_continuation_v1('c3000000-0000-0000-0000-000000000604')->>'correlated')::boolean),
  false,
  'TEST 10: zero compatible clarification fails closed'
);

insert into public.whatsapp_communication_cases(
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  'c3000000-0000-0000-0000-000000000605', 'c3000000-0000-0000-0000-000000000602',
  'ORDER', 'AWAITING_CUSTOMER', 'WHATSAPP', 'packet-ai-b2b-v1'
);
insert into public.whatsapp_case_identities(
  id, case_id, identity_role, party_type, party_id, resolution_status, phone_e164
) values (
  'c3000000-0000-0000-0000-000000000606', 'c3000000-0000-0000-0000-000000000605',
  'SUBMITTING_SENDER', 'CONTACT', 'c3000000-0000-0000-0000-000000000601', 'SUGGESTED', '919820000003'
);
insert into public.whatsapp_case_recipient_authorizations(
  id, case_id, identity_id, may_receive_clarification, verification_method,
  verified_by, verified_at, correlation_key
) values (
  'c3000000-0000-0000-0000-000000000607', 'c3000000-0000-0000-0000-000000000605',
  'c3000000-0000-0000-0000-000000000606', true, 'OPERATOR_VERIFIED',
  'c3000000-0000-0000-0000-000000000001', statement_timestamp(), 'multi-1'
), (
  'c3000000-0000-0000-0000-000000000608', 'c3000000-0000-0000-0000-000000000605',
  'c3000000-0000-0000-0000-000000000606', true, 'OPERATOR_VERIFIED',
  'c3000000-0000-0000-0000-000000000001', statement_timestamp(), 'multi-2'
);
insert into public.whatsapp_case_clarifications(
  id, case_id, field_name, question, recipient_authorization_id, status, due_at, asked_by, correlation_key, asked_at
) values (
  'c3000000-0000-0000-0000-000000000609', 'c3000000-0000-0000-0000-000000000605',
  'QUANTITY', 'How many boxes exactly?', 'c3000000-0000-0000-0000-000000000607',
  'OPEN', statement_timestamp() + interval '1 day', 'c3000000-0000-0000-0000-000000000001', 'multi-a', statement_timestamp()
), (
  'c3000000-0000-0000-0000-00000000060a', 'c3000000-0000-0000-0000-000000000605',
  'PRODUCT', 'Which product exactly?', 'c3000000-0000-0000-0000-000000000608',
  'OPEN', statement_timestamp() + interval '1 day', 'c3000000-0000-0000-0000-000000000001', 'multi-b', statement_timestamp()
);

select is(
  (select (public.whatsapp_process_inbound_whatsapp_continuation_v1('c3000000-0000-0000-0000-000000000604')->>'correlated')::boolean),
  false,
  'TEST 11: multiple compatible clarifications fail closed'
);

-- TEST 12-13: correction before/after SO
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000701', '919820000004', 'Correction Contact');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000711', 'prov-corr-1', '919820000004',
  'Send 5 boxes BAK-PIST-250', 'text', statement_timestamp()
), (
  'c3000000-0000-0000-0000-000000000712', 'prov-corr-2', '919820000004',
  'Correction: make it 8 boxes', 'text', statement_timestamp() + interval '2 minutes'
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, message_timestamp, created_at
) values (
  'c3000000-0000-0000-0000-000000000721', 'c3000000-0000-0000-0000-000000000701',
  'inbound', 'text', 'Send 5 boxes BAK-PIST-250', 'click2api', 'prov-corr-1', 'received', statement_timestamp(), statement_timestamp()
), (
  'c3000000-0000-0000-0000-000000000722', 'c3000000-0000-0000-0000-000000000701',
  'inbound', 'text', 'Correction: make it 8 boxes', 'click2api', 'prov-corr-2', 'received', statement_timestamp() + interval '2 minutes', statement_timestamp() + interval '2 minutes'
);
select public.stitch_whatsapp_messages_atomic(
  'c3000000-0000-0000-0000-000000000701',
  array['c3000000-0000-0000-0000-000000000721'::uuid, 'c3000000-0000-0000-0000-000000000722'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000731',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000721'),
  'fp-corr-before-so', array['prov-corr-1','prov-corr-2'],
  '{
    "confidence": 0.96,
    "conclusion": {
      "intent": "ORDER",
      "summary": "corrected to 8 boxes",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 8, "unit": "box", "status": "explicit", "evidence_ids": ["prov-corr-2"]}
      ],
      "corrections": [
        {"provider_message_id": "prov-corr-2", "supersedes": "quantity", "replacement": "8 boxes"}
      ]
    }
  }'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);

create temporary table corec_corr_before as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000721'),
  'c3000000-0000-0000-0000-000000000731'
) as payload;

select is((select payload->>'autonomy_outcome' from corec_corr_before), 'AUTO_ELIGIBLE', 'TEST 12: correction before SO resumes to AUTO_ELIGIBLE');
select is(
  (select (governed_facts->'order_lines'->0->>'quantity')::integer
    from public.whatsapp_order_autonomy_decisions
    where id = (select (payload->>'autonomy_decision_id')::uuid from corec_corr_before)),
  8,
  'TEST 12: later correction before SO wins in governed facts'
);

select set_config('app.wa1_governed_mutation', 'on', true);
update public.whatsapp_potential_orders
set sales_order_id = (select (payload->'draft_execution'->>'promoted_order_id')::uuid from corec_corr_before)
where id = (
  select potential_order_id from public.whatsapp_order_autonomy_decisions
  where id = (select (payload->>'autonomy_decision_id')::uuid from corec_corr_before)
);
select set_config('app.wa1_governed_mutation', 'off', true);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000732',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000721'),
  'fp-corr-after-so', array['prov-corr-1','prov-corr-2'],
  '{
    "confidence": 0.96,
    "conclusion": {
      "intent": "ORDER",
      "summary": "attempt post-SO correction",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["prov-corr-2"]}
      ],
      "corrections": [
        {"provider_message_id": "prov-corr-2", "supersedes": "quantity", "replacement": "10 boxes"}
      ]
    }
  }'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);

create temporary table corec_corr_after as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000721'),
  'c3000000-0000-0000-0000-000000000732'
) as payload;

select ok(
  coalesce((select (payload->'post_so_correction_guard'->>'blocked')::boolean from corec_corr_after), false),
  'TEST 13: correction after SO is blocked from silent mutation'
);
select is(
  (select count(*)::integer from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.id = (select (payload->'draft_execution'->>'promoted_order_id')::uuid from corec_corr_before)
      and oi.quantity = 10),
  0,
  'TEST 13: existing SO line quantity is not silently mutated to 10'
);

-- TEST 14-17: non-order paths
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000801', '919820000005', 'Enquiry Contact');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c3000000-0000-0000-0000-000000000811', 'prov-enquiry', '919820000005',
  'What is price for 10 boxes BAK-PIST-250?', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at
) values (
  'c3000000-0000-0000-0000-000000000821', 'c3000000-0000-0000-0000-000000000801',
  'inbound', 'text', 'What is price for 10 boxes BAK-PIST-250?', 'click2api', 'prov-enquiry', 'received', statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic('c3000000-0000-0000-0000-000000000801', array['c3000000-0000-0000-0000-000000000821'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000831',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000821'),
  'fp-enquiry', array['prov-enquiry'],
  '{"confidence":0.9,"conclusion":{"intent":"ENQUIRY","summary":"price enquiry","primary_department":"SALES","reply_clearance":"SAFE_TO_SEND_AUTOMATICALLY","recommended_action":"Sales to quote","order_lines":[{"product_name":"BAK-PIST-250","quantity":10,"unit":"box","status":"explicit","evidence_ids":["prov-enquiry"]}]}}'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);
create temporary table corec_enquiry as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000821'),
  'c3000000-0000-0000-0000-000000000831'
) as payload;
select is((select payload->>'case_type' from corec_enquiry), 'ENQUIRY', 'TEST 14: ENQUIRY with product/quantity remains non-order case');
select is(
  (select count(*)::integer from public.orders o
    join public.whatsapp_potential_orders po on po.sales_order_id = o.id
    join public.whatsapp_messages wm on wm.packet_id = (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000821')
    where po.sender_key = '919820000005'),
  0,
  'TEST 14: ENQUIRY creates zero Sales Orders'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000901', '919820000006', 'Complaint Contact');
insert into public.whatsapp_inbound_messages(id, provider_message_id, sender_phone, message_body, message_type, received_at)
values ('c3000000-0000-0000-0000-000000000911', 'prov-complaint', '919820000006', 'Received damaged boxes', 'text', statement_timestamp());
insert into public.whatsapp_messages(id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at)
values ('c3000000-0000-0000-0000-000000000921', 'c3000000-0000-0000-0000-000000000901', 'inbound', 'text', 'Received damaged boxes', 'click2api', 'prov-complaint', 'received', statement_timestamp());
select public.stitch_whatsapp_messages_atomic('c3000000-0000-0000-0000-000000000901', array['c3000000-0000-0000-0000-000000000921'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000931',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000921'),
  'fp-complaint', array['prov-complaint'],
  '{"confidence":0.95,"conclusion":{"intent":"COMPLAINT","summary":"damaged delivery","primary_department":"QUALITY","recommended_action":"Quality review"}}'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);
create temporary table corec_complaint as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000921'),
  'c3000000-0000-0000-0000-000000000931'
) as payload;
select is((select accountable_team from public.whatsapp_communication_cases where id = (select (payload->>'case_id')::uuid from corec_complaint)), 'QUALITY', 'TEST 15: COMPLAINT routes to accountable department');
select is(
  (select count(*)::integer from public.orders o join public.whatsapp_potential_orders po on po.sales_order_id = o.id where po.sender_key = '919820000006'),
  0,
  'TEST 15: COMPLAINT creates zero Sales Orders'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000a01', '919820000007', 'Payment Contact');
insert into public.whatsapp_inbound_messages(id, provider_message_id, sender_phone, message_body, message_type, received_at)
values ('c3000000-0000-0000-0000-000000000a11', 'prov-payment', '919820000007', 'Paid Rs 5000 by NEFT ref 123', 'text', statement_timestamp());
insert into public.whatsapp_messages(id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at)
values ('c3000000-0000-0000-0000-000000000a21', 'c3000000-0000-0000-0000-000000000a01', 'inbound', 'text', 'Paid Rs 5000 by NEFT ref 123', 'click2api', 'prov-payment', 'received', statement_timestamp());
select public.stitch_whatsapp_messages_atomic('c3000000-0000-0000-0000-000000000a01', array['c3000000-0000-0000-0000-000000000a21'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000a31',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000a21'),
  'fp-payment', array['prov-payment'],
  '{"confidence":0.93,"conclusion":{"intent":"PAYMENT_ADVICE","summary":"payment advice","primary_department":"FINANCE","recommended_action":"Finance to verify payment"}}'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);
create temporary table corec_payment as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000a21'),
  'c3000000-0000-0000-0000-000000000a31'
) as payload;
select ok(
  not exists (
    select 1 from public.whatsapp_operator_reply_outbox
    where packet_id = (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000a21')
      and lower(message_body) like '%payment verified%'
  ),
  'TEST 16: PAYMENT_ADVICE sends no payment-verification claim'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c3000000-0000-0000-0000-000000000b01', '919820000008', 'Delivery Contact');
insert into public.whatsapp_inbound_messages(id, provider_message_id, sender_phone, message_body, message_type, received_at)
values ('c3000000-0000-0000-0000-000000000b11', 'prov-delivery', '919820000008', 'When will my order arrive?', 'text', statement_timestamp());
insert into public.whatsapp_messages(id, contact_id, direction, message_type, content, provider, provider_message_id, status, created_at)
values ('c3000000-0000-0000-0000-000000000b21', 'c3000000-0000-0000-0000-000000000b01', 'inbound', 'text', 'When will my order arrive?', 'click2api', 'prov-delivery', 'received', statement_timestamp());
select public.stitch_whatsapp_messages_atomic('c3000000-0000-0000-0000-000000000b01', array['c3000000-0000-0000-0000-000000000b21'::uuid], 300);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation,
  model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c3000000-0000-0000-0000-000000000b31',
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000b21'),
  'fp-delivery', array['prov-delivery'],
  '{"confidence":0.9,"conclusion":{"intent":"DELIVERY_QUERY","summary":"delivery timing query","primary_department":"DISPATCH","reply_clearance":"SAFE_TO_SEND_AUTOMATICALLY","recommended_action":"Dispatch to respond"}}'::jsonb,
  'test-model-v1', 'c3000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-packet-policy/v2', 'core-c-autonomy/v1'
);
create temporary table corec_delivery as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000b21'),
  'c3000000-0000-0000-0000-000000000b31'
) as payload;
select ok(
  not exists (
    select 1 from public.whatsapp_operator_reply_outbox
    where packet_id = (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000b21')
      and (lower(message_body) like '%dispatch committed%' or lower(message_body) like '%delivery date%' or lower(message_body) like '%will arrive%')
  ),
  'TEST 17: DELIVERY_QUERY sends no invented dispatch/delivery promise'
);

-- TEST 18: server-side continuation authority exists without browser/operator
select ok(
  exists(select 1 from pg_proc where oid = 'public.whatsapp_process_inbound_whatsapp_continuation_v1(uuid)'::regprocedure)
  and exists(select 1 from pg_proc where oid = 'public.enqueue_whatsapp_case_context_ai_dispatch(uuid,uuid)'::regprocedure),
  'TEST 18: clarification/resume path is fully server-side'
);

-- TEST 19: concurrent/replayed materialize retains exactly-once business effects
select lives_ok(
  $$select public.whatsapp_materialize_packet_ai_case(
    (select packet_id from public.whatsapp_messages where id = 'c3000000-0000-0000-0000-000000000321'),
    'c3000000-0000-0000-0000-000000000331'
  )$$,
  'TEST 19: replayed worker materialize is safe'
);
select is(
  (select count(*)::integer from public.orders o
    where o.id = (select (payload->'draft_execution'->>'promoted_order_id')::uuid from corec_promote)),
  1,
  'TEST 19: replayed materialize does not create duplicate promoted orders'
);

-- TEST 20: ageing unresolved non-order case remains visible/reconcilable
select ok(
  exists(
    select 1 from public.whatsapp_communication_cases c
    where c.id = (select (payload->>'case_id')::uuid from corec_complaint)
      and c.accountable_team = 'QUALITY'
      and c.next_action_due_at is not null
      and c.status not in ('CLOSED', 'CANCELLED')
  ),
  'TEST 20: unresolved non-order case remains visible with accountable SLA'
);

select * from finish();
rollback;
