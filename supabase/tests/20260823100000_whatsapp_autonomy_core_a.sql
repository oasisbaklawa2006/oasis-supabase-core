begin;
-- Contract, behavioral and safety coverage for 20260823100000_whatsapp_autonomy_core_a.sql (CORE-A).
select plan(42);

-- SECTION 1: Structural and Privilege Contracts
select has_table('public', 'whatsapp_order_autonomy_decisions', 'governed autonomy decisions ledger exists');
select has_column('public', 'whatsapp_order_autonomy_decisions', 'potential_order_id', 'autonomy decision links potential order');
select has_column('public', 'whatsapp_order_autonomy_decisions', 'case_id', 'autonomy decision links communication case');
select has_column('public', 'whatsapp_order_autonomy_decisions', 'autonomy_outcome', 'autonomy decision records canonical outcome');
select has_column('public', 'whatsapp_order_autonomy_decisions', 'governed_facts', 'autonomy decision records verified facts');
select has_column('public', 'whatsapp_order_autonomy_decisions', 'readiness_snapshot', 'autonomy decision records readiness snapshot');
select has_column('public', 'whatsapp_order_autonomy_decisions', 'resolver_rule_version', 'autonomy decision records resolver rule version');

select has_function('public', 'whatsapp_resolve_governed_customer', array['uuid', 'jsonb'], 'deterministic customer resolver exists');
select has_function('public', 'whatsapp_resolve_governed_branch', array['uuid', 'jsonb'], 'deterministic branch resolver exists');
select has_function('public', 'whatsapp_resolve_governed_product_line', array['jsonb', 'uuid'], 'deterministic product line resolver exists');
select has_function('public', 'whatsapp_evaluate_and_materialize_order_autonomy', array['uuid', 'uuid', 'uuid', 'uuid', 'bigint'], 'autonomy evaluation & materialisation RPC exists');
select has_function('public', 'whatsapp_materialize_packet_ai_case', array['uuid', 'uuid', 'uuid', 'uuid', 'bigint'], 'packet case materialisation with autonomy exists');

select ok((select relrowsecurity from pg_class where oid = 'public.whatsapp_order_autonomy_decisions'::regclass), 'autonomy decisions table has RLS enabled');
select is_empty(
  $$select 1 from information_schema.role_table_grants where table_schema = 'public' and table_name = 'whatsapp_order_autonomy_decisions' and grantee in ('PUBLIC', 'anon')$$,
  'untrusted roles have no table grants on autonomy decisions'
);
select is_empty(
  $$select 1 from information_schema.role_routine_grants where routine_schema = 'public' and routine_name in (
    'whatsapp_resolve_governed_customer',
    'whatsapp_resolve_governed_branch',
    'whatsapp_resolve_governed_product_line',
    'whatsapp_evaluate_and_materialize_order_autonomy'
  ) and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'internal autonomy resolver functions are service_role only'
);

-- SECTION 2: Master Data Setup for Behavioral Testing
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'corea-admin@example.test');

-- Knowledge Snapshot
insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'a1000000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista special":"BAK-PIST-250"},"aliases":{"pista bites":"BAK-PIST-250"}}'::jsonb,
  '1111111111111111111111111111111111111111111111111111111111111111',
  'a1000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001', statement_timestamp(),
  'a1000000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('a1000000-0000-0000-0000-000000000010');

-- Products
insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active
) values
  ('a1000000-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true),
  ('a1000000-0000-0000-0000-000000000102', 'Pistachio Baklawa 500g', 'BAK-PIST-500', 'Sweets', '1905', 'Box', '500g', 1, 1, true),
  ('a1000000-0000-0000-0000-000000000103', 'Cashew Pyramid 500g', 'CAS-PYR-500', 'Sweets', '1905', 'Box', '500g', 2, 2, true);

-- Governed Product Alias
insert into public.product_aliases (
  id, alias_text, canonical_name, product_id
) values (
  'a1000000-0000-0000-0000-000000000150', 'pistachio delight', 'Pistachio Baklawa 250g', 'a1000000-0000-0000-0000-000000000101'
);

-- Company 1: Clean Active Customer with 1 delivery branch
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'a1000000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919800000001', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'a1000000-0000-0000-0000-000000000211', 'a1000000-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

-- Company 2: Customer with 2 delivery branches
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'a1000000-0000-0000-0000-000000000202', 'Oberoi Gourmet Foods', '29FGHIJ5678K2Z6', '919800000002', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values
  ('a1000000-0000-0000-0000-000000000221', 'a1000000-0000-0000-0000-000000000202', 'Indiranagar Branch', '12 100ft Rd', 'Bengaluru', 'Karnataka', '560038', true),
  ('a1000000-0000-0000-0000-000000000222', 'a1000000-0000-0000-0000-000000000202', 'Koramangala Branch', '45 80ft Rd', 'Bengaluru', 'Karnataka', '560034', false);

-- Company 3: Frozen Customer
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'a1000000-0000-0000-0000-000000000203', 'Frozen Sweets Mart', '29KLMNO9012P3Z7', '919800000003', 'credit', 'active', true
);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode
) values (
  'a1000000-0000-0000-0000-000000000231', 'a1000000-0000-0000-0000-000000000203',
  'Main', '10 Frozen Way', 'Bengaluru', 'Karnataka', '560001'
);

-- Company 4A and 4B: Shared Phone (Ambiguous Customer)
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values
  ('a1000000-0000-0000-0000-000000000204', 'Alpha Traders', '29AAAAA0000A1Z1', '919800000099', 'prepaid', 'active', false),
  ('a1000000-0000-0000-0000-000000000205', 'Beta Traders', '29BBBBB1111B2Z2', '919800000099', 'prepaid', 'active', false);

-- Switch to service_role context for RPC executions
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- =========================================================================
-- TEST 1: Clear exact order => AUTO_ELIGIBLE (No routine human review needed)
-- =========================================================================
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000301', '919800000001', 'Taj Sweets Purchaser');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000311', 'prov-msg-test1', '919800000001',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000321', 'a1000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-msg-test1', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000301',
  array['a1000000-0000-0000-0000-000000000321'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321'),
  'fp-test1',
  array['prov-msg-test1'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "summary": "5 boxes of Pistachio Baklawa 250g",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-msg-test1"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table test1_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321'),
  'a1000000-0000-0000-0000-000000000331'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from test1_res),
  'AUTO_ELIGIBLE',
  'TEST 1: Clear exact order evaluates to AUTO_ELIGIBLE'
);
select is(
  (select (payload->>'human_decision_required')::boolean from test1_res),
  false,
  'TEST 1: AUTO_ELIGIBLE order does NOT require routine human review'
);
select is(
  (select status from public.whatsapp_communication_cases where packet_id = (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321')),
  'READY_FOR_DRAFT',
  'TEST 1: Case status advanced to READY_FOR_DRAFT'
);

-- =========================================================================
-- TEST 2: Missing quantity => CLARIFICATION_REQUIRED
-- =========================================================================
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000401', '919800000012', 'Taj Sweets Purchaser 2');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000411', 'prov-msg-test2', '919800000012',
  'Please send pistachio baklawa boxes', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000421', 'a1000000-0000-0000-0000-000000000401',
  'inbound', 'text', 'Please send pistachio baklawa boxes', 'click2api',
  'prov-msg-test2', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000401',
  array['a1000000-0000-0000-0000-000000000421'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000431',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000421'),
  'fp-test2',
  array['prov-msg-test2'],
  '{
    "confidence": 0.95,
    "conclusion": {
      "intent": "ORDER",
      "summary": "Pistachio Baklawa 250g with missing quantity",
      "customer": {"company_name": "Taj Sweets Bengaluru"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": null,
          "unit": "box",
          "status": "unclear",
          "evidence_ids": ["prov-msg-test2"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table test2_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000421'),
  'a1000000-0000-0000-0000-000000000431'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from test2_res),
  'CLARIFICATION_REQUIRED',
  'TEST 2: Missing quantity evaluates to CLARIFICATION_REQUIRED'
);
select is(
  (select status from public.whatsapp_communication_cases where packet_id = (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000421')),
  'AWAITING_CUSTOMER',
  'TEST 2: Case status set to AWAITING_CUSTOMER'
);
select isnt_empty(
  $$select 1 from public.whatsapp_order_clarification_tasks where field_key = 'quantity' and status = 'OPEN'$$,
  'TEST 2: Open clarification task created for missing quantity'
);

-- =========================================================================
-- TEST 3: Ambiguous customer => fail closed
-- =========================================================================
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000501', '919800000099', 'Shared Phone Contact');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000511', 'prov-msg-test3', '919800000099',
  'Send 10 boxes of BAK-PIST-250', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000521', 'a1000000-0000-0000-0000-000000000501',
  'inbound', 'text', 'Send 10 boxes of BAK-PIST-250', 'click2api',
  'prov-msg-test3', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000501',
  array['a1000000-0000-0000-0000-000000000521'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000531',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000521'),
  'fp-test3',
  array['prov-msg-test3'],
  '{
    "confidence": 0.90,
    "conclusion": {
      "intent": "ORDER",
      "summary": "10 boxes of BAK-PIST-250",
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 10,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-msg-test3"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table test3_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000521'),
  'a1000000-0000-0000-0000-000000000531'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from test3_res),
  'HUMAN_EXCEPTION_REQUIRED',
  'TEST 3: Ambiguous customer fails closed to HUMAN_EXCEPTION_REQUIRED'
);
select is(
  (select (payload->>'human_decision_required')::boolean from test3_res),
  true,
  'TEST 3: Ambiguous customer requires human triage'
);

-- =========================================================================
-- TEST 4: Ambiguous SKU => fail closed
-- =========================================================================
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000601', '919800000014', 'Taj Purchaser SKU Ambiguous');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000611', 'prov-msg-test4', '919800000014',
  'Send 10 boxes of Pistachio Baklawa', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000621', 'a1000000-0000-0000-0000-000000000601',
  'inbound', 'text', 'Send 10 boxes of Pistachio Baklawa', 'click2api',
  'prov-msg-test4', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000601',
  array['a1000000-0000-0000-0000-000000000621'::uuid], 300
);

-- AI provides ambiguous product name matching both 250g and 500g products without SKU
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000631',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000621'),
  'fp-test4',
  array['prov-msg-test4'],
  '{
    "confidence": 0.88,
    "conclusion": {
      "intent": "ORDER",
      "summary": "10 boxes of Pistachio Baklawa",
      "customer": {"company_name": "Taj Sweets Bengaluru"},
      "order_lines": [
        {
          "product_name": "Pistachio Baklawa",
          "quantity": 10,
          "unit": "box",
          "status": "interpreted",
          "evidence_ids": ["prov-msg-test4"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table test4_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000621'),
  'a1000000-0000-0000-0000-000000000631'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from test4_res),
  'CLARIFICATION_REQUIRED',
  'TEST 4: Ambiguous product family name requires clarification'
);
select is(
  (select status from public.whatsapp_communication_cases where packet_id = (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000621')),
  'AWAITING_CUSTOMER',
  'TEST 4: Case status set to AWAITING_CUSTOMER for ambiguous SKU'
);

-- =========================================================================
-- TEST 5: Explicit later correction wins (Immutable evidence preserved)
-- =========================================================================
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000312', 'prov-msg-test1-corr', '919800000001',
  'Please make that 12 boxes instead of 5', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000322', 'a1000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please make that 12 boxes instead of 5', 'click2api',
  'prov-msg-test1-corr', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000301',
  array['a1000000-0000-0000-0000-000000000322'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000332',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321'),
  'fp-test1-corr',
  array['prov-msg-test1', 'prov-msg-test1-corr'],
  '{
    "confidence": 0.99,
    "conclusion": {
      "intent": "ORDER",
      "summary": "12 boxes of Pistachio Baklawa 250g (corrected from 5)",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 12,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-msg-test1-corr"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table test5_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321'),
  'a1000000-0000-0000-0000-000000000332'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from test5_res),
  'AUTO_ELIGIBLE',
  'TEST 5: Explicit later correction evaluates to AUTO_ELIGIBLE'
);
select is(
  (select (payload->'governed_facts'->'order_lines'->0->>'quantity')::numeric from test5_res),
  12::numeric,
  'TEST 5: Later explicit correction supersedes prior quantity in governed facts'
);
select is(
  (select count(*)::integer from public.whatsapp_order_field_evidence where potential_order_id = (select id from public.whatsapp_potential_orders where source_message_id = 'a1000000-0000-0000-0000-000000000311') and field_key = 'quantity'),
  2,
  'TEST 5: Both initial evidence and correction evidence are immutably preserved in WA-3'
);

-- =========================================================================
-- TEST 6: Replay => no duplicate governed facts
-- =========================================================================
create temporary table test6_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321'),
  'a1000000-0000-0000-0000-000000000331'
) as payload;

select is(
  (select (payload->>'idempotent_replay')::boolean from test6_res),
  true,
  'TEST 6: Replay returns idempotent_replay = true'
);
select is(
  (select count(*)::integer from public.whatsapp_order_autonomy_decisions where packet_id = (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000321') and interpretation_id = 'a1000000-0000-0000-0000-000000000331'),
  1,
  'TEST 6: Replay does not insert duplicate autonomy decisions'
);

-- =========================================================================
-- TEST 7: Stale revision => cannot materialise
-- =========================================================================
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000701', '919800000017', 'Taj Revision Test');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values
  ('a1000000-0000-0000-0000-000000000721', 'a1000000-0000-0000-0000-000000000701',
   'inbound', 'text', 'Order 5 boxes', 'click2api', 'prov-msg-test7a', 'received', statement_timestamp(), statement_timestamp()),
  ('a1000000-0000-0000-0000-000000000722', 'a1000000-0000-0000-0000-000000000701',
   'inbound', 'text', 'actually 8 boxes', 'click2api', 'prov-msg-test7b', 'received', statement_timestamp(), statement_timestamp());

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000701',
  array['a1000000-0000-0000-0000-000000000721'::uuid], 300
);

create temporary table test7_claim as
with updated as (
  update public.whatsapp_packet_ai_dispatch_jobs
  set state = 'LEASED',
      claimed_at = statement_timestamp(),
      lease_token = 'a1000000-0000-0000-0000-000000000777'::uuid,
      lease_expires_at = statement_timestamp() + interval '120 seconds',
      updated_at = statement_timestamp()
  where packet_id = (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000721')
  returning *
)
select * from updated;

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000731',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000721'),
  'fp-test7',
  array['prov-msg-test7a'],
  '{"confidence": 0.95, "conclusion": {"intent": "ORDER", "summary": "5 boxes", "order_lines": []}}'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

-- Revision advances when second message is stitched
select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000701',
  array['a1000000-0000-0000-0000-000000000722'::uuid], 300
);

select throws_ok(
  $$select public.whatsapp_materialize_packet_ai_case(
    (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000721'),
    'a1000000-0000-0000-0000-000000000731',
    (select id from test7_claim),
    (select lease_token from test7_claim),
    (select packet_revision from test7_claim)
  )$$,
  '55000',
  null,
  'TEST 7: Stale leased worker cannot materialize case after revision advance'
);

-- =========================================================================
-- TEST 8: Cross-customer evidence => rejected
-- =========================================================================
select throws_ok(
  $$select public.record_whatsapp_order_field_evidence(
    (select id from public.whatsapp_potential_orders where source_message_id = 'a1000000-0000-0000-0000-000000000311'),
    'quantity',
    'a1000000-0000-0000-0000-000000000511',
    'cross-customer-hack',
    '99'::jsonb,
    'resolved',
    1.0,
    'cross customer',
    '{}'::jsonb,
    true
  )$$,
  'WA3_SOURCE_NOT_LINKED',
  'TEST 8: Cross-customer source message evidence is strictly rejected'
);

-- =========================================================================
-- TEST 9: Non-order message with product/quantity => NOT auto-order
-- =========================================================================
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000801', '919800000019', 'Taj Enquiry Contact');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000811', 'prov-msg-test9', '919800000019',
  'What is the price of 10 boxes of BAK-PIST-250?', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000821', 'a1000000-0000-0000-0000-000000000801',
  'inbound', 'text', 'What is the price of 10 boxes of BAK-PIST-250?', 'click2api',
  'prov-msg-test9', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000801',
  array['a1000000-0000-0000-0000-000000000821'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000831',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000821'),
  'fp-test9',
  array['prov-msg-test9'],
  '{
    "confidence": 0.95,
    "conclusion": {
      "intent": "ENQUIRY",
      "summary": "Asking price for 10 boxes",
      "customer": {"company_name": "Taj Sweets Bengaluru"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 10,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-msg-test9"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table test9_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000821'),
  'a1000000-0000-0000-0000-000000000831'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from test9_res),
  'CLARIFICATION_REQUIRED',
  'TEST 9: Enquiry intent is not auto-order'
);
select is(
  (select case_type from public.whatsapp_communication_cases where packet_id = (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000821')),
  'ENQUIRY',
  'TEST 9: Case type remains ENQUIRY, not ORDER'
);

-- =========================================================================
-- TEST 10: No executable quantity=1 fallback anywhere in this path
-- =========================================================================
create temporary table test10_line as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "unit": "box"}'::jsonb
);

select is(
  (select quantity from test10_line),
  null::numeric,
  'TEST 10: Product line resolver never defaults missing quantity to 1'
);
select is(
  (select resolution_status from test10_line),
  'UNRESOLVED',
  'TEST 10: Missing quantity marks line resolution UNRESOLVED'
);
select isnt_empty(
  $$select 1 from test10_line where 'missing_quantity' = any(unresolved_reasons)$$,
  'TEST 10: Missing quantity explicitly flagged in unresolved reasons'
);

-- Static assertion: No executable quantity default fallback in source code of autonomy RPCs
select is_empty(
  $$select 1 from pg_proc
    where proname in ('whatsapp_resolve_governed_product_line', 'whatsapp_evaluate_and_materialize_order_autonomy')
      and (pg_get_functiondef(oid) ~* 'coalesce\([^,]*quantity[^,]*,[ ]*1\)'
           or pg_get_functiondef(oid) ~* 'quantity[ ]*default[ ]*1')$$,
  'TEST 10: Source code has zero quantity=1 fallback expressions'
);

-- =========================================================================
-- Additional Edge Cases: Frozen Customer & Deterministic Branch
-- =========================================================================
-- Frozen customer => POLICY_APPROVAL_REQUIRED
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('a1000000-0000-0000-0000-000000000901', '919800000003', 'Frozen Customer Contact');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'a1000000-0000-0000-0000-000000000911', 'prov-msg-frozen', '919800000003',
  '5 boxes BAK-PIST-250', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'a1000000-0000-0000-0000-000000000921', 'a1000000-0000-0000-0000-000000000901',
  'inbound', 'text', '5 boxes BAK-PIST-250', 'click2api',
  'prov-msg-frozen', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'a1000000-0000-0000-0000-000000000901',
  array['a1000000-0000-0000-0000-000000000921'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'a1000000-0000-0000-0000-000000000931',
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000921'),
  'fp-frozen',
  array['prov-msg-frozen'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "summary": "5 boxes of Pistachio Baklawa",
      "customer": {"company_name": "Frozen Sweets Mart"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-msg-frozen"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  '1111111111111111111111111111111111111111111111111111111111111111',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table frozen_res as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'a1000000-0000-0000-0000-000000000921'),
  'a1000000-0000-0000-0000-000000000931'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from frozen_res),
  'POLICY_APPROVAL_REQUIRED',
  'Frozen company order evaluates to POLICY_APPROVAL_REQUIRED'
);

-- Governed alias & knowledge snapshot terminology mapping
create temporary table alias_res as
select * from public.whatsapp_resolve_governed_product_line(
  '{"product_name": "pistachio delight", "quantity": 3, "unit": "box"}'::jsonb
);

select is(
  (select sku from alias_res),
  'BAK-PIST-250',
  'Approved governed alias in product_aliases resolves to canonical product'
);

create temporary table know_res as
select * from public.whatsapp_resolve_governed_product_line(
  '{"product_name": "pista special", "quantity": 4, "unit": "box"}'::jsonb,
  'a1000000-0000-0000-0000-000000000010'
);

select is(
  (select sku from know_res),
  'BAK-PIST-250',
  'Active knowledge snapshot terminology maps to exact product SKU'
);

-- Deterministic branch resolution
create temporary table branch_res as
select * from public.whatsapp_resolve_governed_branch(
  'a1000000-0000-0000-0000-000000000201'
);

select is(
  (select match_method from branch_res),
  'DETERMINISTIC_EXACTLY_ONE',
  'Company with single delivery address resolves via DETERMINISTIC_EXACTLY_ONE rule'
);

select * from finish();
rollback;
