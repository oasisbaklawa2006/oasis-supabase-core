begin;
-- Contract, behavioral, adversarial and safety coverage for 20260823110000_whatsapp_autonomy_core_b.sql (CORE-B).
select plan(68);

-- SECTION 1: Structural and privilege contracts
select has_table('public', 'whatsapp_order_autonomy_draft_executions', 'CORE-B draft execution projection exists');
select has_table('public', 'whatsapp_order_autonomy_draft_execution_events', 'CORE-B immutable lifecycle event ledger exists');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'autonomy_decision_id', 'execution links autonomy decision');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'sales_order_draft_id', 'execution links sales order draft');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'promoted_order_id', 'execution may link promoted order');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'execution_status', 'execution records status');

select has_function('public', 'whatsapp_autonomy_decision_is_current', array['uuid'], 'staleness guard exists');
select has_function('public', 'whatsapp_execute_autonomous_order_draft_v1', array['uuid', 'boolean'], 'CORE-B orchestrator exists');
select has_function('public', 'whatsapp_promote_autonomous_sales_order_draft_v1', array['uuid', 'text'], 'CORE-B promotion exists');
select has_function('public', 'promote_sales_order_draft_to_order_governed_v1', array['uuid', 'text', 'uuid', 'text', 'text', 'jsonb'], 'canonical governed promotion core exists');

select ok((select relrowsecurity from pg_class where oid = 'public.whatsapp_order_autonomy_draft_executions'::regclass), 'draft executions table has RLS');
select is_empty(
  $$select 1 from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name in (
        'whatsapp_execute_autonomous_order_draft_v1',
        'whatsapp_promote_autonomous_sales_order_draft_v1',
        'whatsapp_autonomy_decision_is_current'
      )
      and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'CORE-B orchestration functions are service_role only'
);

-- SECTION 2: Shared master data
insert into auth.users (id, email) values
  ('b2000000-0000-0000-0000-000000000001', 'coreb-admin@example.test');

insert into public.users (id, email, full_name, role) values
  ('b2000000-0000-0000-0000-000000000001', 'coreb-admin@example.test', 'Core-B Admin', 'admin');

insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'b2000000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista special":"BAK-PIST-250"},"aliases":{"pista bites":"BAK-PIST-250"}}'::jsonb,
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'b2000000-0000-0000-0000-000000000001',
  'b2000000-0000-0000-0000-000000000001', statement_timestamp(),
  'b2000000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('b2000000-0000-0000-0000-000000000010');

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values
  ('b2000000-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true);

insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'b2000000-0000-0000-0000-000000000161', 'b2000000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);

insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values (
  'b2000000-0000-0000-0000-000000000171', 'b2000000-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null
);

insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'b2000000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919820000001', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'b2000000-0000-0000-0000-000000000211', 'b2000000-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- TEST 1: AUTO_ELIGIBLE materialize auto-creates draft and promotes SO
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000301', '919820000001', 'Core-B Purchaser');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000311', 'prov-coreb-01', '919820000001',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000321', 'b2000000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-coreb-01', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000301',
  array['b2000000-0000-0000-0000-000000000321'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000321'),
  'fp-coreb-01',
  array['prov-coreb-01'],
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
          "evidence_ids": ["prov-coreb-01"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table coreb_test1 as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000321'),
  'b2000000-0000-0000-0000-000000000331'
) as payload;

select is((select payload->>'autonomy_outcome' from coreb_test1), 'AUTO_ELIGIBLE', 'TEST 1: AUTO_ELIGIBLE path preserved');
select ok((select payload->'draft_execution'->>'sales_order_draft_id' is not null from coreb_test1), 'TEST 1: draft created automatically');
select is(
  (select payload->'draft_execution'->>'execution_status' from coreb_test1),
  'PROMOTED',
  'TEST 1: materialize auto-creates governed draft and promotes SO without external caller'
);
select ok(
  (select payload->'draft_execution'->>'promoted_order_id' is not null from coreb_test1),
  'TEST 1: materialize returns promoted order id from production worker path'
);
select ok(
  exists(
    select 1 from public.whatsapp_order_autonomy_draft_execution_events e
    where e.autonomy_decision_id = (select payload->>'autonomy_decision_id' from coreb_test1)::uuid
      and e.event_type = 'DRAFT_CREATED'
  ),
  'TEST 1: durable DRAFT_CREATED lifecycle event recorded'
);
select ok(
  exists(
    select 1 from public.whatsapp_order_autonomy_draft_execution_events e
    where e.autonomy_decision_id = (select payload->>'autonomy_decision_id' from coreb_test1)::uuid
      and e.event_type = 'PROMOTED'
  ),
  'TEST 1: durable PROMOTED lifecycle event recorded'
);
select is(
  (select count(*)::integer from public.orders o
    where o.id = (select (payload->'draft_execution'->>'promoted_order_id')::uuid from coreb_test1)),
  1,
  'TEST 1: exactly one canonical order created by materialize path'
);

-- TEST 2: Draft fields populated from governed facts
select is(
  (select company_id::text from public.sales_order_drafts
    where id = ((select payload->'draft_execution'->>'sales_order_draft_id' from coreb_test1)::uuid)),
  'b2000000-0000-0000-0000-000000000201',
  'TEST 2: draft company_id matches governed customer'
);
select is(
  (select sku from public.sales_order_draft_lines
    where draft_id = ((select payload->'draft_execution'->>'sales_order_draft_id' from coreb_test1)::uuid)),
  'BAK-PIST-250',
  'TEST 2: draft line SKU matches governed product'
);
select is(
  (select operator_quantity from public.sales_order_draft_lines
    where draft_id = ((select payload->'draft_execution'->>'sales_order_draft_id' from coreb_test1)::uuid)),
  5::numeric,
  'TEST 2: draft line quantity is evidence-proven'
);

-- TEST 3: Case transitions to DRAFTED
select is(
  (select status from public.whatsapp_communication_cases
    where id = ((select payload->>'case_id' from coreb_test1)::uuid)),
  'DRAFTED',
  'TEST 3: case status advanced to DRAFTED'
);

-- TEST 4: Idempotent replay via orchestrator returns same promoted order
select is(
  (select (public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid, true
  )->>'idempotent_replay')::boolean),
  true,
  'TEST 4: orchestrator idempotent replay returns existing execution'
);
select is(
  (select count(*)::integer from public.whatsapp_order_autonomy_draft_executions
    where autonomy_decision_id = (select payload->>'autonomy_decision_id' from coreb_test1)::uuid),
  1,
  'TEST 4: exactly one execution projection row'
);
select is(
  (select public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid, true
  )->>'promoted_order_id'),
  (select payload->'draft_execution'->>'promoted_order_id' from coreb_test1),
  'TEST 4: replay after promotion returns same promoted order'
);
select is(
  (select count(*)::integer from public.orders o
    where o.company_id = 'b2000000-0000-0000-0000-000000000201'
      and o.id in (
        select promoted_order_id from public.whatsapp_order_autonomy_draft_execution_events
        where autonomy_decision_id = (select payload->>'autonomy_decision_id' from coreb_test1)::uuid
          and event_type = 'PROMOTED'
      )),
  1,
  'TEST 4: replay does not create duplicate promoted orders'
);

-- TEST 5: Idempotent materialize replay does not duplicate drafts
create temporary table coreb_test5 as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000321'),
  'b2000000-0000-0000-0000-000000000331'
) as payload;

select is(
  (select count(*)::integer from public.sales_order_drafts d
    where d.packet_id = (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000321')),
  1,
  'TEST 5: materialize replay does not create duplicate drafts'
);

-- TEST 6: CLARIFICATION_REQUIRED does not create draft
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000401', '919820000002', 'Core-B Purchaser 2');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000411', 'prov-coreb-02', '919820000002',
  'Please send pistachio baklawa boxes', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000421', 'b2000000-0000-0000-0000-000000000401',
  'inbound', 'text', 'Please send pistachio baklawa boxes', 'click2api',
  'prov-coreb-02', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000401',
  array['b2000000-0000-0000-0000-000000000421'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000431',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000421'),
  'fp-coreb-02',
  array['prov-coreb-02'],
  '{
    "confidence": 0.90,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "unit": "box", "status": "explicit"}]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table coreb_test6 as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000421'),
  'b2000000-0000-0000-0000-000000000431'
) as payload;

select is((select payload->>'autonomy_outcome' from coreb_test6), 'CLARIFICATION_REQUIRED', 'TEST 6: missing quantity stays CLARIFICATION_REQUIRED');
select ok(
  (select payload->'draft_execution' is null or payload->'draft_execution' = 'null'::jsonb from coreb_test6),
  'TEST 6: no draft execution for CLARIFICATION_REQUIRED'
);

-- TEST 7: Direct orchestrator rejects non-eligible decision
select is(
  (select public.whatsapp_execute_autonomous_order_draft_v1(
    (select id from public.whatsapp_order_autonomy_decisions
      where interpretation_id = 'b2000000-0000-0000-0000-000000000431'),
    true
  )->>'execution_status'),
  'REJECTED_NOT_ELIGIBLE',
  'TEST 7: non-eligible decision rejected'
);

-- TEST 8: Stale decision rejected after newer interpretation
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000701', '919820000005', 'Core-B Stale Test');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000711', 'prov-coreb-05', '919820000005',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000721', 'b2000000-0000-0000-0000-000000000701',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-coreb-05', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000701',
  array['b2000000-0000-0000-0000-000000000721'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000731',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000721'),
  'fp-coreb-05',
  array['prov-coreb-05'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-coreb-05"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000721'),
  'b2000000-0000-0000-0000-000000000731'
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version,
  created_at
) values (
  'b2000000-0000-0000-0000-000000000732',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000721'),
  'fp-coreb-05-newer',
  array['prov-coreb-05'],
  (select interpretation from public.whatsapp_packet_ai_interpretations where id = 'b2000000-0000-0000-0000-000000000731'),
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1',
  statement_timestamp() + interval '1 hour'
);

create temporary table coreb_test8 as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select id from public.whatsapp_order_autonomy_decisions
    where interpretation_id = 'b2000000-0000-0000-0000-000000000731'),
  true
) as result;

select is((select result->>'execution_status' from coreb_test8), 'REJECTED_NOT_ELIGIBLE', 'TEST 8: stale decision rejected');
select is((select result->>'blocking_reason' from coreb_test8), 'stale_autonomy_decision_superseded', 'TEST 8: stale reason recorded');

-- TEST 9: Service role required
select throws_ok(
  $sql$
    select set_config('request.jwt.claims', json_build_object('sub','b2000000-0000-0000-0000-000000000001','role','authenticated')::text, true);
    select public.whatsapp_execute_autonomous_order_draft_v1('b2000000-0000-0000-0000-000000000001', true);
  $sql$,
  '42501',
  'trusted packet processor required',
  'TEST 9: authenticated caller rejected'
);
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- TEST 10: Immutable event ledger and governed projection
select throws_ok(
  $$update public.whatsapp_order_autonomy_draft_execution_events set blocking_reason = 'tamper' where true$$,
  '55000',
  'whatsapp_order_autonomy_draft_execution_events is append-only',
  'TEST 10: lifecycle event ledger is immutable'
);
select throws_ok(
  $$update public.whatsapp_order_autonomy_draft_executions set blocking_reason = 'tamper' where true$$,
  '55000',
  'whatsapp_order_autonomy_draft_executions projection is governed-only',
  'TEST 10: execution projection cannot be mutated directly'
);

-- TEST 11: Conflicting manual draft blocks autonomous creation
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000501', '919820000003', 'Core-B Purchaser 3');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000511', 'prov-coreb-03', '919820000003',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000521', 'b2000000-0000-0000-0000-000000000501',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-coreb-03', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000501',
  array['b2000000-0000-0000-0000-000000000521'::uuid], 300
);

insert into public.sales_order_drafts(
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text, created_by, updated_by
) values (
  'b2000000-0000-0000-0000-000000000903',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000521'),
  'manual-conflict-v1', 'UNDER_REVIEW',
  'b2000000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', 100,
  '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"ready","score":100},{"dimension":"payment_terms","status":"ready","score":100}]',
  'manual', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001'
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000531',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000521'),
  'fp-coreb-03',
  array['prov-coreb-03'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-coreb-03"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table coreb_test11 as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000521'),
  'b2000000-0000-0000-0000-000000000531'
) as payload;

select is(
  (select payload->'draft_execution'->>'blocking_reason' from coreb_test11),
  'conflicting_active_draft_for_packet',
  'TEST 11: conflicting draft fails closed'
);

-- TEST 12: B2B pricing authority used in line snapshot
select ok(
  (select (ai_line_snapshot ? 'selling_price') from public.sales_order_draft_lines
    where draft_id = ((select payload->'draft_execution'->>'sales_order_draft_id' from coreb_test1)::uuid)),
  'TEST 12: line snapshot carries canonical B2B selling_price'
);

-- TEST 13: Potential order converted by automatic materialize promotion
select is(
  (select state from public.whatsapp_potential_orders
    where id = (select potential_order_id from public.whatsapp_order_autonomy_decisions
      where id = (select payload->>'autonomy_decision_id' from coreb_test1)::uuid)),
  'CONVERTED',
  'TEST 13: potential order reaches CONVERTED after automatic materialize promotion'
);

-- TEST 14: Exactly one draft per packet active index respected
select ok(
  exists(select 1 from pg_indexes where schemaname = 'public' and indexname = 'idx_sales_order_drafts_packet_active'),
  'TEST 14: active draft unique index exists'
);

-- TEST 15: Promotion without CORE-B linkage blocked
select ok(
  (select promotion_blocked from public.whatsapp_promote_autonomous_sales_order_draft_v1(
    'b2000000-0000-0000-0000-000000000903', 'manual-conflict-v1'
  )),
  'TEST 15: non-CORE-B draft cannot use autonomous promotion'
);

-- TEST 16: Frozen customer POLICY path does not auto-draft
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'b2000000-0000-0000-0000-000000000203', 'Frozen Sweets Mart', '29KLMNO9012P3Z7', '919820000004', 'credit', 'active', true
);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode
) values (
  'b2000000-0000-0000-0000-000000000231', 'b2000000-0000-0000-0000-000000000203',
  'Main', '10 Frozen Way', 'Bengaluru', 'Karnataka', '560001'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000601', '919820000004', 'Frozen Purchaser');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000611', 'prov-coreb-04', '919820000004',
  'Please send 5 boxes of BAK-PIST-250', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000621', 'b2000000-0000-0000-0000-000000000601',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250', 'click2api',
  'prov-coreb-04', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000601',
  array['b2000000-0000-0000-0000-000000000621'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000631',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000621'),
  'fp-coreb-04',
  array['prov-coreb-04'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "Frozen Sweets Mart", "gst_number": "29KLMNO9012P3Z7"},
      "branch": {"label": "Main"},
      "order_lines": [{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 5, "unit": "box", "status": "explicit"}]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table coreb_test16 as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000621'),
  'b2000000-0000-0000-0000-000000000631'
) as payload;

select is((select payload->>'autonomy_outcome' from coreb_test16), 'POLICY_APPROVAL_REQUIRED', 'TEST 16: frozen customer blocked at CORE-A');
select ok(
  (select payload->'draft_execution' is null or payload->'draft_execution' = 'null'::jsonb from coreb_test16),
  'TEST 16: no autonomous draft for policy-blocked case'
);

-- TEST 17: Concurrent idempotent replays remain single draft and single order
create temporary table coreb_test17 as
select
  public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid, true
  ) as r1,
  public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid, true
  ) as r2;

select is(
  (select r1->>'sales_order_draft_id' from coreb_test17),
  (select r2->>'sales_order_draft_id' from coreb_test17),
  'TEST 17: concurrent idempotent calls return same draft id'
);
select is(
  (select r1->>'promoted_order_id' from coreb_test17),
  (select r2->>'promoted_order_id' from coreb_test17),
  'TEST 17: concurrent idempotent calls return same promoted order'
);

-- TEST 18: Draft extraction key is deterministic from autonomy decision
select is(
  (select extraction_request_key from public.sales_order_drafts
    where id = ((select payload->'draft_execution'->>'sales_order_draft_id' from coreb_test1)::uuid)),
  'core-b:autonomy:' || (select payload->>'autonomy_decision_id' from coreb_test1),
  'TEST 18: deterministic idempotency extraction key'
);

-- TEST 19: Human and service wrappers share canonical promotion implementation
select ok(
  position('promote_sales_order_draft_to_order_governed_v1' in lower(pg_get_functiondef(
    'public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb)'::regprocedure
  ))) > 0,
  'TEST 19: human wrapper delegates to canonical governed promotion core'
);
select ok(
  position('promote_sales_order_draft_to_order_governed_v1' in lower(pg_get_functiondef(
    'public.whatsapp_promote_autonomous_sales_order_draft_v1(uuid,text)'::regprocedure
  ))) > 0,
  'TEST 19: service wrapper delegates to canonical governed promotion core'
);

-- TEST 20: CLARIFICATION_REQUIRED creates zero promoted orders
select is(
  (select count(*)::integer from public.whatsapp_order_autonomy_draft_execution_events e
    join public.whatsapp_order_autonomy_decisions d on d.id = e.autonomy_decision_id
    where d.interpretation_id = 'b2000000-0000-0000-0000-000000000431'
      and e.event_type = 'PROMOTED'),
  0,
  'TEST 20: non-eligible clarification path creates zero promoted orders'
);

-- TEST 21: Resume after draft-only orchestrator call can promote durably
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000801', '919820000006', 'Core-B Resume Test');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000811', 'prov-coreb-06', '919820000006',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000821', 'b2000000-0000-0000-0000-000000000801',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-coreb-06', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000801',
  array['b2000000-0000-0000-0000-000000000821'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000831',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000821'),
  'fp-coreb-06',
  array['prov-coreb-06'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-coreb-06"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table coreb_resume_decision as
select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000821'),
  'b2000000-0000-0000-0000-000000000831'
) as payload;

create temporary table coreb_resume_draft as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select payload->>'decision_id' from coreb_resume_decision)::uuid,
  false
) as result;

select is(
  (select result->>'execution_status' from coreb_resume_draft),
  'DRAFT_CREATED',
  'TEST 21: draft-only orchestrator records DRAFT_CREATED projection'
);

create temporary table coreb_resume_promote as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select payload->>'decision_id' from coreb_resume_decision)::uuid,
  true
) as result;

select is(
  (select result->>'execution_status' from coreb_resume_promote),
  'PROMOTED',
  'TEST 21: later promotion resumes and reaches PROMOTED'
);
select ok(
  exists(
    select 1 from public.whatsapp_order_autonomy_draft_execution_events e
    where e.autonomy_decision_id = (select payload->>'decision_id' from coreb_resume_decision)::uuid
      and e.event_type = 'DRAFT_CREATED'
  ) and exists(
    select 1 from public.whatsapp_order_autonomy_draft_execution_events e
    where e.autonomy_decision_id = (select payload->>'decision_id' from coreb_resume_decision)::uuid
      and e.event_type = 'PROMOTED'
  ),
  'TEST 21: both draft and promoted lifecycle events remain auditable'
);

-- TEST 22: Incomplete governed facts cannot create a draft
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000851', '919820000008', 'Core-B Incomplete Facts');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000852', 'prov-coreb-08', '919820000008',
  'Please send 5 boxes of BAK-PIST-250', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000853', 'b2000000-0000-0000-0000-000000000851',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250', 'click2api',
  'prov-coreb-08', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000851',
  array['b2000000-0000-0000-0000-000000000853'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000854',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000853'),
  'fp-coreb-08',
  array['prov-coreb-08'],
  '{"confidence": 0.98, "conclusion": {"intent": "ORDER"}}'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  'b2000000-0000-0000-0000-000000000956',
  'b2000000-0000-0000-0000-000000000852',
  'prov-coreb-08',
  '919820000008',
  'fp-coreb-08',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'TRIAGE_INTAKE',
  statement_timestamp(),
  statement_timestamp()
);

insert into public.whatsapp_order_autonomy_decisions (
  id, potential_order_id, case_id, packet_id, interpretation_id,
  autonomy_outcome, governed_facts, readiness_snapshot, knowledge_snapshot_id
) values (
  'b2000000-0000-0000-0000-000000000901',
  'b2000000-0000-0000-0000-000000000956',
  null,
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000853'),
  'b2000000-0000-0000-0000-000000000854',
  'AUTO_ELIGIBLE',
  jsonb_build_object(
    'customer', jsonb_build_object('company_id', 'b2000000-0000-0000-0000-000000000201'),
    'branch', jsonb_build_object('label', 'Main Store'),
    'order_lines', jsonb_build_array(jsonb_build_object(
      'line_number', 1,
      'product_id', 'b2000000-0000-0000-0000-000000000101',
      'quantity', 5,
      'uom', 'box'
    ))
  ),
  '{"ready": true}'::jsonb,
  'b2000000-0000-0000-0000-000000000010'
);

create temporary table coreb_test22 as
select public.whatsapp_execute_autonomous_order_draft_v1(
  'b2000000-0000-0000-0000-000000000901', true
) as result;

select is(
  (select result->>'execution_status' from coreb_test22),
  'REJECTED_NOT_ELIGIBLE',
  'TEST 22: incomplete governed facts reject without draft'
);
select is(
  (select result->>'blocking_reason' from coreb_test22),
  'governed_delivery_address_missing',
  'TEST 22: durable rejection reason names missing delivery address'
);
select is(
  (select count(*)::integer from public.sales_order_drafts d
    where d.extraction_request_key = 'core-b:autonomy:b2000000-0000-0000-0000-000000000901'),
  0,
  'TEST 22: incomplete governed facts create zero drafts'
);

-- TEST 23: Multi-line preflight rejects before any partial draft side effects
insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'b2000000-0000-0000-0000-000000000102', 'Unpriced Baklawa 250g', 'BAK-NO-PRICE', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000901', '919820000009', 'Core-B Preflight Test');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000911', 'prov-coreb-07', '919820000009',
  'Please send 5 boxes of BAK-PIST-250 and 2 boxes of BAK-NO-PRICE', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000921', 'b2000000-0000-0000-0000-000000000901',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 and 2 boxes of BAK-NO-PRICE', 'click2api',
  'prov-coreb-07', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000901',
  array['b2000000-0000-0000-0000-000000000921'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000931',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000921'),
  'fp-coreb-07',
  array['prov-coreb-07'],
  '{"confidence": 0.98, "conclusion": {"intent": "ORDER"}}'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action,
  first_received_at, last_evidence_at
) values (
  'b2000000-0000-0000-0000-000000000958',
  'b2000000-0000-0000-0000-000000000911',
  'prov-coreb-07',
  '919820000009',
  'fp-coreb-07',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'TRIAGE_INTAKE',
  statement_timestamp(),
  statement_timestamp()
);

insert into public.whatsapp_order_autonomy_decisions (
  id, potential_order_id, case_id, packet_id, interpretation_id,
  autonomy_outcome, governed_facts, readiness_snapshot, knowledge_snapshot_id
) values (
  'b2000000-0000-0000-0000-000000000902',
  'b2000000-0000-0000-0000-000000000958',
  null,
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000921'),
  'b2000000-0000-0000-0000-000000000931',
  'AUTO_ELIGIBLE',
  jsonb_build_object(
    'customer', jsonb_build_object('company_id', 'b2000000-0000-0000-0000-000000000201'),
    'branch', jsonb_build_object('delivery_address_id', 'b2000000-0000-0000-0000-000000000211', 'label', 'Main Store'),
    'order_lines', jsonb_build_array(
      jsonb_build_object('line_number', 1, 'product_id', 'b2000000-0000-0000-0000-000000000101', 'quantity', 5, 'uom', 'box'),
      jsonb_build_object('line_number', 2, 'product_id', 'b2000000-0000-0000-0000-000000000102', 'quantity', 2, 'uom', 'box')
    )
  ),
  '{"ready": true}'::jsonb,
  'b2000000-0000-0000-0000-000000000010'
);

create temporary table coreb_test23 as
select public.whatsapp_execute_autonomous_order_draft_v1(
  'b2000000-0000-0000-0000-000000000902', true
) as result;

select is(
  (select result->>'execution_status' from coreb_test23),
  'REJECTED_NOT_ELIGIBLE',
  'TEST 23: later-line authority failure rejects without draft'
);
select is(
  (select result->>'blocking_reason' from coreb_test23),
  'missing_b2b_product_authority_line_2',
  'TEST 23: durable rejection reason names failing line'
);
select is(
  (select count(*)::integer from public.sales_order_drafts d
    where d.extraction_request_key = 'core-b:autonomy:b2000000-0000-0000-0000-000000000902'),
  0,
  'TEST 23: multi-line preflight creates zero drafts'
);
select is(
  (select count(*)::integer from public.sales_order_draft_lines l
    join public.sales_order_drafts d on d.id = l.draft_id
    where d.extraction_request_key = 'core-b:autonomy:b2000000-0000-0000-0000-000000000902'),
  0,
  'TEST 23: multi-line preflight creates zero draft lines'
);

-- TEST 24-25: Dedicated draft-only fixture for promotion retry/blocked semantics
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b2000000-0000-0000-0000-000000000871', '919820000010', 'Core-B Retry Test');

insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'b2000000-0000-0000-0000-000000000872', 'prov-coreb-09', '919820000010',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'b2000000-0000-0000-0000-000000000873', 'b2000000-0000-0000-0000-000000000871',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-coreb-09', 'received', statement_timestamp(), statement_timestamp()
);

select public.stitch_whatsapp_messages_atomic(
  'b2000000-0000-0000-0000-000000000871',
  array['b2000000-0000-0000-0000-000000000873'::uuid], 300
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'b2000000-0000-0000-0000-000000000874',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000873'),
  'fp-coreb-09',
  array['prov-coreb-09'],
  '{
    "confidence": 0.98,
    "conclusion": {
      "intent": "ORDER",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-coreb-09"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'b2000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-b-autonomy/v1'
);

create temporary table coreb_retry_decision as
select public.whatsapp_evaluate_and_materialize_order_autonomy(
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000873'),
  'b2000000-0000-0000-0000-000000000874'
) as payload;

create temporary table coreb_retry_draft as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select payload->>'decision_id' from coreb_retry_decision)::uuid,
  false
) as result;

-- TEST 24: Unexpected promotion failures propagate and remain retryable
update public.sales_order_drafts
set readiness_dimensions = '[]'::jsonb
where id = (select (result->>'sales_order_draft_id')::uuid from coreb_retry_draft);

select throws_ok(
  $$select public.whatsapp_promote_autonomous_sales_order_draft_v1(
    (select (result->>'sales_order_draft_id')::uuid from coreb_retry_draft),
    (select 'core-b:autonomy:' || (payload->>'decision_id') from coreb_retry_decision)
  )$$,
  'Missing readiness dimension: client',
  'TEST 24: unexpected promotion failure propagates instead of terminal PROMOTION_BLOCKED'
);

select is(
  (select execution_status from public.whatsapp_order_autonomy_draft_executions
    where autonomy_decision_id = (select (payload->>'decision_id')::uuid from coreb_retry_decision)),
  'DRAFT_CREATED',
  'TEST 24: transient promotion failure leaves DRAFT_CREATED projection for retry'
);

-- TEST 25: Deterministic promotion block persists recoverable case state
update public.sales_order_drafts
set readiness_dimensions = public.whatsapp_build_core_b_readiness_dimensions(
      (select governed_facts from public.whatsapp_order_autonomy_decisions
        where id = (select (payload->>'decision_id')::uuid from coreb_retry_decision))
    ),
    status = 'REJECTED'
where id = (select (result->>'sales_order_draft_id')::uuid from coreb_retry_draft);

create temporary table coreb_test25_promo as
select *
from public.whatsapp_promote_autonomous_sales_order_draft_v1(
  (select (result->>'sales_order_draft_id')::uuid from coreb_retry_draft),
  (select 'core-b:autonomy:' || (payload->>'decision_id') from coreb_retry_decision)
) as promo;

select ok(
  (select promotion_blocked from coreb_test25_promo),
  'TEST 25: deterministic promotion gate returns promotion_blocked without raising'
);
select is(
  (select blocking_reason from coreb_test25_promo),
  'DRAFT_NOT_READY',
  'TEST 25: deterministic promotion gate exposes durable blocking reason'
);

insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, rule_version
) values (
  'b2000000-0000-0000-0000-000000000875',
  (select packet_id from public.whatsapp_messages where id = 'b2000000-0000-0000-0000-000000000873'),
  'ORDER',
  'DRAFTED',
  'core-b-test/v1'
);

select public.whatsapp_record_autonomous_so_promotion_blocked_v1(
  'b2000000-0000-0000-0000-000000000875',
  'b2000000-0000-0000-0000-000000000874',
  (select (payload->>'decision_id')::uuid from coreb_retry_decision),
  (select (result->>'sales_order_draft_id')::uuid from coreb_retry_draft),
  'DRAFT_NOT_READY'
);

select is(
  (select next_action from public.whatsapp_communication_cases
    where id = 'b2000000-0000-0000-0000-000000000875'),
  'SO_PROMOTION_BLOCKED',
  'TEST 25: blocked promotion sets recoverable case next_action'
);
select ok(
  exists(
    select 1 from public.whatsapp_case_events e
    where e.case_id = 'b2000000-0000-0000-0000-000000000875'
      and e.event_type = 'AUTONOMOUS_SO_PROMOTION_BLOCKED'
      and e.metadata->>'blocking_reason' = 'DRAFT_NOT_READY'
      and e.metadata->>'draft_id' = (select result->>'sales_order_draft_id' from coreb_retry_draft)
  ),
  'TEST 25: governed case event records blocking reason and draft linkage'
);

create temporary table coreb_test25 as
select public.whatsapp_execute_autonomous_order_draft_v1(
  (select (payload->>'decision_id')::uuid from coreb_retry_decision), true
) as result;

select is(
  (select result->>'execution_status' from coreb_test25),
  'PROMOTION_BLOCKED',
  'TEST 25: orchestrator resume records PROMOTION_BLOCKED projection'
);

-- TEST 26: Readiness helper is always non-null and blocked when facts are incomplete
select ok(
  public.whatsapp_build_core_b_readiness_dimensions('{"customer": {}, "order_lines": [], "branch": {}}'::jsonb) is not null,
  'TEST 26: readiness helper never returns NULL'
);
select ok(
  not public.whatsapp_core_b_governed_facts_draft_eligible('{"customer": {}, "order_lines": [], "branch": {}}'::jsonb),
  'TEST 26: incomplete governed facts are not draft-eligible'
);

select * from finish();
rollback;
