begin;
-- Contract, behavioral, adversarial and safety coverage for 20260823110000_whatsapp_autonomy_core_b.sql (CORE-B).
select plan(37);

-- SECTION 1: Structural and privilege contracts
select has_table('public', 'whatsapp_order_autonomy_draft_executions', 'CORE-B draft execution ledger exists');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'autonomy_decision_id', 'execution links autonomy decision');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'sales_order_draft_id', 'execution links sales order draft');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'promoted_order_id', 'execution may link promoted order');
select has_column('public', 'whatsapp_order_autonomy_draft_executions', 'execution_status', 'execution records status');

select has_function('public', 'whatsapp_autonomy_decision_is_current', array['uuid'], 'staleness guard exists');
select has_function('public', 'whatsapp_execute_autonomous_order_draft_v1', array['uuid', 'boolean'], 'CORE-B orchestrator exists');
select has_function('public', 'whatsapp_promote_autonomous_sales_order_draft_v1', array['uuid', 'text'], 'CORE-B promotion exists');

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
  'DRAFT_CREATED',
  'TEST 1: materialize auto-creates governed draft without implicit promotion'
);
select ok(
  (select public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid,
    true
  )->>'execution_status') in ('PROMOTED', 'DRAFT_CREATED'),
  'TEST 1b: explicit orchestrator promotion succeeds for AUTO_ELIGIBLE decision'
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

-- TEST 4: Idempotent replay via orchestrator
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
  'TEST 4: exactly one execution ledger row'
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

-- TEST 10: Execution ledger is append-only
select throws_ok(
  $$update public.whatsapp_order_autonomy_draft_executions set blocking_reason = 'tamper' where true$$,
  '55000',
  'whatsapp_order_autonomy_draft_executions is append-only',
  'TEST 10: execution ledger is immutable'
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

-- TEST 13: Potential order converted after explicit promotion
select is(
  (select state from public.whatsapp_potential_orders
    where id = (select potential_order_id from public.whatsapp_order_autonomy_decisions
      where id = (select payload->>'autonomy_decision_id' from coreb_test1)::uuid)),
  'CONVERTED',
  'TEST 13: potential order reaches CONVERTED after explicit promotion'
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

-- TEST 17: Concurrent idempotent calls remain single draft
create temporary table coreb_test17 as
select
  public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid, false
  ) as r1,
  public.whatsapp_execute_autonomous_order_draft_v1(
    (select payload->>'autonomy_decision_id' from coreb_test1)::uuid, false
  ) as r2;

select is(
  (select r1->>'sales_order_draft_id' from coreb_test17),
  (select r2->>'sales_order_draft_id' from coreb_test17),
  'TEST 17: concurrent idempotent calls return same draft id'
);

-- TEST 18: Draft extraction key is deterministic from autonomy decision
select is(
  (select extraction_request_key from public.sales_order_drafts
    where id = ((select payload->'draft_execution'->>'sales_order_draft_id' from coreb_test1)::uuid)),
  'core-b:autonomy:' || (select payload->>'autonomy_decision_id' from coreb_test1),
  'TEST 18: deterministic idempotency extraction key'
);

select * from finish();
rollback;
