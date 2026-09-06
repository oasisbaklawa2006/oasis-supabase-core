-- POINT67 — WhatsApp packet → governed draft canonical closure certification.
-- Synthetic fixtures only; no protected corpus; no migration; draft-creation lane only
-- (Point65 grouping, Point66 identity, Point68 review, Point69 promotion remain separate).
begin;
select plan(48);

-- ---------------------------------------------------------------------------
-- CENSUS: packet → draft authority surfaces
-- ---------------------------------------------------------------------------
select has_table('public', 'whatsapp_message_packets', 'CENSUS: stitch packet exists');
select has_table('public', 'whatsapp_packet_ai_interpretations', 'CENSUS: append-only AI interpretation exists');
select has_table('public', 'whatsapp_order_autonomy_decisions', 'CENSUS: governed autonomy decision ledger exists');
select has_table('public', 'whatsapp_order_autonomy_draft_executions', 'CENSUS: draft execution projection exists');
select has_table('public', 'sales_order_drafts', 'CENSUS: governed draft header exists');
select has_table('public', 'sales_order_draft_lines', 'CENSUS: governed draft lines exist');
select has_function('public', 'whatsapp_materialize_packet_ai_case', array['uuid', 'uuid', 'uuid', 'uuid', 'bigint']);
select has_function('public', 'whatsapp_evaluate_and_materialize_order_autonomy', array['uuid', 'uuid', 'uuid', 'uuid', 'bigint']);
select has_function('public', 'whatsapp_execute_autonomous_order_draft_v1', array['uuid', 'boolean']);
select has_function('public', 'whatsapp_resolve_governed_product_line', array['jsonb', 'uuid', 'uuid', 'uuid']);
select ok(
  exists(select 1 from pg_indexes where schemaname = 'public' and indexname = 'idx_sales_order_drafts_packet_active'),
  'CENSUS: one-active-draft-per-packet unique index exists'
);
select is_empty(
  $$select 1 from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name in (
        'whatsapp_execute_autonomous_order_draft_v1',
        'whatsapp_evaluate_and_materialize_order_autonomy',
        'whatsapp_materialize_packet_ai_case'
      )
      and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'CENSUS: packet→draft orchestration is service-role only'
);

-- ---------------------------------------------------------------------------
-- Shared synthetic fixtures (87000000 namespace)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('87000000-0000-0000-0000-000000000001', 'p67-operator@example.test');
insert into public.users (id, email, full_name, role) values
  ('87000000-0000-0000-0000-000000000001', 'p67-operator@example.test', 'P67 Operator', 'admin');

insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '87000000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista special":"P67-SKU"},"aliases":{"pista bites":"P67-SKU"}}'::jsonb,
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  '87000000-0000-0000-0000-000000000001',
  '87000000-0000-0000-0000-000000000001', statement_timestamp(),
  '87000000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('87000000-0000-0000-0000-000000000010');

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  '87000000-0000-0000-0000-000000000101', 'P67 Pistachio Baklawa', 'P67-SKU', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);
insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  '87000000-0000-0000-0000-000000000161', '87000000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);
insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values (
  '87000000-0000-0000-0000-000000000171', '87000000-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null
);

insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values
  ('87000000-0000-0000-0000-000000000201', 'P67 Customer Alpha', '29P67AA0000A1Z1', '919870000001', 'credit', 'active', false),
  ('87000000-0000-0000-0000-000000000202', 'P67 Customer Beta', '29P67BB1111B2Z2', '919870000002', 'credit', 'active', false);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values
  ('87000000-0000-0000-0000-000000000211', '87000000-0000-0000-0000-000000000201', 'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true),
  ('87000000-0000-0000-0000-000000000212', '87000000-0000-0000-0000-000000000202', 'Main Store', '200 Brigade Road', 'Bengaluru', 'Karnataka', '560001', true);

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('87000000-0000-0000-0000-000000000301', '919870000095', 'P67 Employee Relay'),
  ('87000000-0000-0000-0000-000000000302', '919870000001', 'P67 Customer Contact');

insert into public.users (id, email, full_name, role, phone) values
  ('87000000-0000-0000-0000-000000000310', 'p67-sales@oasis.test', 'P67 Sales Executive', 'SALES_EXECUTIVE', '919870000095');

insert into public.whatsapp_sender_commercial_authorizations (
  id, contact_id, company_id, disclosure_scope, identity_evidence, status,
  authorized_by, authorized_at, valid_until
) values (
  '87000000-0000-0000-0000-000000000320',
  '87000000-0000-0000-0000-000000000301',
  '87000000-0000-0000-0000-000000000201',
  array['customer_pricing']::text[],
  '{"method":"STANDING_AUTHORITY"}'::jsonb,
  'ACTIVE',
  '87000000-0000-0000-0000-000000000001',
  statement_timestamp(),
  statement_timestamp() + interval '30 days'
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- ---------------------------------------------------------------------------
-- FLOW1: AUTO_ELIGIBLE packet → governed draft (draft-only, no promotion)
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000401', 'p67-draft-ok', '919870000001',
  'Please send 5 boxes of P67-SKU to MG Road branch', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000411', '87000000-0000-0000-0000-000000000302',
  'inbound', 'text', 'Please send 5 boxes of P67-SKU to MG Road branch', 'click2api',
  'p67-draft-ok', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000302',
  array['87000000-0000-0000-0000-000000000411'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  '87000000-0000-0000-0000-000000000421',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000411'),
  'fp-p67-draft-ok',
  array['p67-draft-ok'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "summary": "5 boxes of P67 Pistachio Baklawa",
      "customer": {"company_name": "P67 Customer Alpha", "gst_number": "29P67AA0000A1Z1"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "P67-SKU",
          "product_name": "P67 Pistachio Baklawa",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["p67-draft-ok"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table p67_eval_ok as
select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000411'),
  '87000000-0000-0000-0000-000000000421'
) as payload;

create temporary table p67_draft_ok as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select payload->>'decision_id' from p67_eval_ok)::uuid,
  false
) as result;

select is((select payload->>'autonomy_outcome' from p67_eval_ok), 'AUTO_ELIGIBLE', 'FLOW1: governed packet resolves AUTO_ELIGIBLE');
select is((select result->>'execution_status' from p67_draft_ok), 'DRAFT_CREATED', 'FLOW1: draft-only orchestrator reaches DRAFT_CREATED');
select is(
  (select company_id::text from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  '87000000-0000-0000-0000-000000000201',
  'FLOW1: draft company_id matches governed customer, not sender inference'
);
select is(
  (select operator_quantity from public.sales_order_draft_lines
    where draft_id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  5::numeric,
  'FLOW1: draft line quantity is evidence-proven (5), never defaulted'
);
select is(
  (select extraction_request_key from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  'core-b:autonomy:' || (select payload->>'decision_id' from p67_eval_ok),
  'FLOW1: deterministic idempotency extraction_request_key bound to autonomy decision'
);
select ok(
  exists(
    select 1 from public.sales_order_draft_audit_log
    where draft_id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)
      and action = 'CREATE'
  ),
  'FLOW1: immutable CREATE audit row recorded for governed draft'
);

-- ---------------------------------------------------------------------------
-- FLOW2: idempotent replay does not duplicate drafts
-- ---------------------------------------------------------------------------
create temporary table p67_replay as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select payload->>'decision_id' from p67_eval_ok)::uuid,
  false
) as result;

select is(
  (select (result->>'idempotent_replay')::boolean from p67_replay),
  true,
  'FLOW2: replay returns idempotent_replay=true'
);
select is(
  (select count(*)::integer from public.sales_order_drafts
    where packet_id = (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000411')),
  1,
  'FLOW2: exactly one governed draft per packet after replay'
);
select is(
  (select result->>'sales_order_draft_id' from p67_replay),
  (select result->>'sales_order_draft_id' from p67_draft_ok),
  'FLOW2: replay returns same sales_order_draft_id'
);

-- ---------------------------------------------------------------------------
-- FLOW3: missing quantity fails closed — no draft, no quantity=1 default
-- ---------------------------------------------------------------------------
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('87000000-0000-0000-0000-000000000303', '919870000003', 'P67 Missing Qty Contact');
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000402', 'p67-no-qty', '919870000003',
  'Please send P67-SKU boxes', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000412', '87000000-0000-0000-0000-000000000303',
  'inbound', 'text', 'Please send P67-SKU boxes', 'click2api',
  'p67-no-qty', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000303',
  array['87000000-0000-0000-0000-000000000412'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  '87000000-0000-0000-0000-000000000422',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000412'),
  'fp-p67-no-qty',
  array['p67-no-qty'],
  '{
    "confidence": 0.90,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "P67 Customer Alpha", "gst_number": "29P67AA0000A1Z1"},
      "branch": {"label": "Main Store"},
      "order_lines": [{"sku": "P67-SKU", "product_name": "P67 Pistachio Baklawa", "unit": "box", "status": "explicit"}]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table p67_no_qty as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000412'),
  '87000000-0000-0000-0000-000000000422'
) as payload;

select is((select payload->>'autonomy_outcome' from p67_no_qty), 'CLARIFICATION_REQUIRED', 'FLOW3: missing quantity stays CLARIFICATION_REQUIRED');
select is(
  (select count(*)::integer from public.sales_order_drafts d
    where d.packet_id = (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000412')),
  0,
  'FLOW3: missing quantity creates zero governed drafts'
);

create temporary table p67_resolver_no_qty as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "P67-SKU", "product_name": "P67 Pistachio Baklawa", "unit": "box", "status": "explicit", "evidence_ids": ["p67-no-qty"]}'::jsonb,
  '87000000-0000-0000-0000-000000000010',
  '87000000-0000-0000-0000-000000000201',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000412')
);

select is((select quantity from p67_resolver_no_qty), null::numeric, 'FLOW3: resolver never defaults missing quantity to 1');

-- ---------------------------------------------------------------------------
-- FLOW4: invented / unknown SKU fails closed
-- ---------------------------------------------------------------------------
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('87000000-0000-0000-0000-000000000304', '919870000004', 'P67 Unknown SKU Contact');
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000403', 'p67-bad-sku', '919870000004',
  'Please send 5 boxes of FAKE-SKU-999', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000413', '87000000-0000-0000-0000-000000000304',
  'inbound', 'text', 'Please send 5 boxes of FAKE-SKU-999', 'click2api',
  'p67-bad-sku', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000304',
  array['87000000-0000-0000-0000-000000000413'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  '87000000-0000-0000-0000-000000000423',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000413'),
  'fp-p67-bad-sku',
  array['p67-bad-sku'],
  '{
    "confidence": 0.95,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "P67 Customer Alpha", "gst_number": "29P67AA0000A1Z1"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "FAKE-SKU-999",
          "product_name": "Invented Product",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["p67-bad-sku"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table p67_bad_sku as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000413'),
  '87000000-0000-0000-0000-000000000423'
) as payload;

select is((select payload->>'autonomy_outcome' from p67_bad_sku), 'CLARIFICATION_REQUIRED', 'FLOW4: invented SKU stays CLARIFICATION_REQUIRED');
select is(
  (select count(*)::integer from public.sales_order_drafts d
    where d.packet_id = (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000413')),
  0,
  'FLOW4: invented SKU creates zero governed drafts'
);

-- ---------------------------------------------------------------------------
-- FLOW5: non-order intent must not become commercial draft
-- ---------------------------------------------------------------------------
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('87000000-0000-0000-0000-000000000305', '919870000005', 'P67 Enquiry Contact');
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000404', 'p67-enquiry', '919870000005',
  'What is the price of P67-SKU?', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000414', '87000000-0000-0000-0000-000000000305',
  'inbound', 'text', 'What is the price of P67-SKU?', 'click2api',
  'p67-enquiry', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000305',
  array['87000000-0000-0000-0000-000000000414'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  '87000000-0000-0000-0000-000000000424',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000414'),
  'fp-p67-enquiry',
  array['p67-enquiry'],
  '{
    "confidence": 0.92,
    "conclusion": {
      "intent": "ENQUIRY",
      "summary": "Price enquiry for P67-SKU",
      "customer": {"company_name": "P67 Customer Alpha", "gst_number": "29P67AA0000A1Z1"},
      "order_lines": [
        {
          "sku": "P67-SKU",
          "product_name": "P67 Pistachio Baklawa",
          "quantity": 10,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["p67-enquiry"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table p67_enquiry as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000414'),
  '87000000-0000-0000-0000-000000000424'
) as payload;

select is((select payload->>'autonomy_outcome' from p67_enquiry), 'CLARIFICATION_REQUIRED', 'FLOW5: enquiry intent is not AUTO_ELIGIBLE');
select is(
  (select count(*)::integer from public.sales_order_drafts d
    where d.packet_id = (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000414')),
  0,
  'FLOW5: non-order enquiry creates zero governed drafts'
);

-- ---------------------------------------------------------------------------
-- FLOW6: later interpretation supersedes earlier autonomy decision
-- ---------------------------------------------------------------------------
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('87000000-0000-0000-0000-000000000306', '919870000006', 'P67 Supersession Contact');

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000407', 'p67-super-a', '919870000006',
  'Please send 5 boxes of P67-SKU', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000417', '87000000-0000-0000-0000-000000000306',
  'inbound', 'text', 'Please send 5 boxes of P67-SKU', 'click2api',
  'p67-super-a', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000306',
  array['87000000-0000-0000-0000-000000000417'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  '87000000-0000-0000-0000-000000000427',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000417'),
  'fp-p67-super-a',
  array['p67-super-a'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "P67 Customer Alpha", "gst_number": "29P67AA0000A1Z1"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "P67-SKU",
          "product_name": "P67 Pistachio Baklawa",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["p67-super-a"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000417'),
  '87000000-0000-0000-0000-000000000427'
);

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000408', 'p67-super-b', '919870000006',
  'not 5, make it 6 boxes of P67-SKU', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000418', '87000000-0000-0000-0000-000000000306',
  'inbound', 'text', 'not 5, make it 6 boxes of P67-SKU', 'click2api',
  'p67-super-b', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000306',
  array['87000000-0000-0000-0000-000000000418'::uuid], 300
);

select is(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000418'),
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000417'),
  'FLOW6a: correction message shares canonical packet_id with prior evidence'
);
select is(
  (select packet_revision from public.whatsapp_packet_ai_dispatch_jobs
    where packet_id = (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000417')
      and execution_kind = 'PACKET'),
  2::bigint,
  'FLOW6b: correction evidence advances packet_revision to 2 before superseding interpretation'
);

insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version,
  created_at
) values (
  '87000000-0000-0000-0000-000000000428',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000417'),
  'fp-p67-super-b',
  array['p67-super-b'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "P67 Customer Alpha", "gst_number": "29P67AA0000A1Z1"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "P67-SKU",
          "product_name": "P67 Pistachio Baklawa",
          "quantity": 6,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["p67-super-b"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1',
  statement_timestamp() + interval '1 hour'
);

select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000417'),
  '87000000-0000-0000-0000-000000000428'
);

select is(
  (select (governed_facts->'order_lines'->0->>'quantity')::numeric
    from public.whatsapp_order_autonomy_decisions
    where interpretation_id = '87000000-0000-0000-0000-000000000428'),
  6::numeric,
  'FLOW6c: superseding interpretation materializes corrected quantity in governed_facts'
);
select ok(
  public.whatsapp_autonomy_decision_is_current(
    (select id from public.whatsapp_order_autonomy_decisions
      where interpretation_id = '87000000-0000-0000-0000-000000000428')
  ),
  'FLOW6d: latest interpretation decision is canonical current after correction revision'
);

create temporary table p67_stale as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select id from public.whatsapp_order_autonomy_decisions
    where interpretation_id = '87000000-0000-0000-0000-000000000427'),
  false
) as result;

select is((select result->>'execution_status' from p67_stale), 'REJECTED_NOT_ELIGIBLE', 'FLOW6: stale autonomy decision rejected on replay');
select is((select result->>'blocking_reason' from p67_stale), 'stale_autonomy_decision_superseded', 'FLOW6: supersession reason recorded');

-- ---------------------------------------------------------------------------
-- FLOW7: employee relay sender≠customer — explicit candidate governs draft customer
-- ---------------------------------------------------------------------------
insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '87000000-0000-0000-0000-000000000406', 'p67-relay', '919870000095',
  'Please send 5 boxes of P67-SKU for P67 Customer Beta', 'text', statement_timestamp()
);
insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '87000000-0000-0000-0000-000000000416', '87000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes of P67-SKU for P67 Customer Beta', 'click2api',
  'p67-relay', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  '87000000-0000-0000-0000-000000000301',
  array['87000000-0000-0000-0000-000000000416'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations (
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  '87000000-0000-0000-0000-000000000426',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000416'),
  'fp-p67-relay',
  array['p67-relay'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "P67 Customer Beta", "gst_number": "29P67BB1111B2Z2"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "P67-SKU",
          "product_name": "P67 Pistachio Baklawa",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["p67-relay"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', '87000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table p67_relay_eval as
select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000416'),
  '87000000-0000-0000-0000-000000000426'
) as payload;

create temporary table p67_relay_draft as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select payload->>'decision_id' from p67_relay_eval)::uuid,
  false
) as result;

select is(
  (select company_id::text from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_relay_draft)),
  '87000000-0000-0000-0000-000000000202',
  'FLOW7: relay sender draft binds explicit Customer Beta, not sender authorization Alpha'
);

-- ---------------------------------------------------------------------------
-- FLOW8: Point69 boundary — draft-only path creates zero orders
-- ---------------------------------------------------------------------------
select ok(
  (select result->>'promoted_order_id' is null from p67_draft_ok),
  'FLOW8: draft-only orchestrator returns no promoted_order_id'
);
select is(
  (select count(*)::integer from public.orders o
    where o.company_id = '87000000-0000-0000-0000-000000000201'
      and o.id in (
        select promoted_order_id from public.whatsapp_order_autonomy_draft_execution_events
        where autonomy_decision_id = (select payload->>'decision_id' from p67_eval_ok)::uuid
          and event_type = 'PROMOTED'
      )),
  0,
  'FLOW8: draft-only path records zero PROMOTED orders (Point69 boundary)'
);

-- ---------------------------------------------------------------------------
-- FLOW9: Point68 boundary — draft creation does not invoke review RPCs
-- ---------------------------------------------------------------------------
select ok(
  position('submit_sales_order_draft_for_review_atomic' in lower(pg_get_functiondef(
    'public.whatsapp_execute_autonomous_order_draft_v1(uuid,boolean)'::regprocedure
  ))) = 0,
  'FLOW9: draft orchestrator does not embed Point68 review submit RPC'
);
select ok(
  position('approve_sales_order_draft_for_so_atomic' in lower(pg_get_functiondef(
    'public.whatsapp_execute_autonomous_order_draft_v1(uuid,boolean)'::regprocedure
  ))) = 0,
  'FLOW9: draft orchestrator does not embed Point69 approval RPC'
);
select is(
  (select status from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  'UNDER_REVIEW',
  'FLOW9: autonomous draft lands UNDER_REVIEW for human Point68 lane'
);

-- ---------------------------------------------------------------------------
-- FLOW10: persisted provenance on materialized governed draft
-- ---------------------------------------------------------------------------
select is(
  (select provider_message_ids from public.whatsapp_packet_ai_interpretations
    where id = (
      select interpretation_id from public.whatsapp_order_autonomy_decisions
      where id = (select (payload->>'decision_id')::uuid from p67_eval_ok)
    )),
  array['p67-draft-ok']::text[],
  'FLOW10a: decision-linked interpretation preserves provider_message_ids'
);
select is(
  (select ai_draft_snapshot->>'source' from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  'CORE_B_AUTONOMY',
  'FLOW10b: materialized draft snapshot records CORE_B_AUTONOMY source attribution'
);
select is(
  (select ai_draft_snapshot->>'autonomy_decision_id' from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  (select payload->>'decision_id' from p67_eval_ok),
  'FLOW10c: materialized draft snapshot binds evaluated autonomy_decision_id'
);
select is(
  (select ai_draft_snapshot->'governed_facts' from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  (select governed_facts from public.whatsapp_order_autonomy_decisions
    where id = (select (payload->>'decision_id')::uuid from p67_eval_ok)),
  'FLOW10d: materialized draft snapshot governed_facts matches autonomy decision ledger'
);
select is(
  (select (ai_draft_snapshot->'governed_facts'->'order_lines'->0->>'quantity')::numeric
    from public.sales_order_drafts
    where id = (select (result->>'sales_order_draft_id')::uuid from p67_draft_ok)),
  5::numeric,
  'FLOW10e: persisted governed_facts quantity is evidence-proven, not defaulted'
);

-- ---------------------------------------------------------------------------
-- FLOW11: static guard — no executable quantity=1 fallback in autonomy path
-- ---------------------------------------------------------------------------
select is_empty(
  $$select 1 from pg_proc
    where proname in (
      'whatsapp_resolve_governed_product_line',
      'whatsapp_evaluate_and_materialize_order_autonomy',
      'whatsapp_execute_autonomous_order_draft_v1'
    )
      and (pg_get_functiondef(oid) ~* 'coalesce\([^,]*quantity[^,]*,[ ]*1\)'
           or pg_get_functiondef(oid) ~* 'quantity[ ]*default[ ]*1')$$,
  'FLOW11: packet→draft authority has zero quantity=1 fallback expressions'
);

-- ---------------------------------------------------------------------------
-- FLOW12: AI quantity without evidence citation fails closed
-- ---------------------------------------------------------------------------
create temporary table p67_fake_qty as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "P67-SKU", "product_name": "P67 Pistachio Baklawa", "quantity": 5, "unit": "box", "status": "interpreted"}'::jsonb,
  '87000000-0000-0000-0000-000000000010',
  '87000000-0000-0000-0000-000000000201',
  (select packet_id from public.whatsapp_messages where id = '87000000-0000-0000-0000-000000000411')
);

select is((select quantity from p67_fake_qty), null::numeric, 'FLOW12: interpreted quantity without evidence_ids is not executable');
select isnt_empty(
  $$select 1 from p67_fake_qty where 'quantity_not_evidence_proven' = any(unresolved_reasons)$$,
  'FLOW12: quantity_not_evidence_proven surfaced for non-cited AI quantity'
);

select * from finish();
rollback;
