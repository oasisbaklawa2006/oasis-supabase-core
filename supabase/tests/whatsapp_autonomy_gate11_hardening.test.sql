begin;
-- Gate 11: commercial-invention and ledger hardening on CORE-A/B already on main.
-- AI-proposed price, discount, and payment terms must not become commercial truth.
select plan(16);

-- Privilege contracts
select is_empty(
  $$select 1 from information_schema.table_privileges
    where table_schema = 'public'
      and table_name = 'whatsapp_order_autonomy_decisions'
      and grantee in ('PUBLIC', 'anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE')$$,
  'G11: untrusted roles cannot mutate autonomy decisions'
);
select is_empty(
  $$select 1 from information_schema.table_privileges
    where table_schema = 'public'
      and table_name in (
        'whatsapp_order_autonomy_draft_executions',
        'whatsapp_order_autonomy_draft_execution_events'
      )
      and grantee in ('PUBLIC', 'anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE')$$,
  'G11: untrusted roles cannot mutate CORE-B execution ledgers'
);

select is_empty(
  $$select 1 from pg_proc
    where proname = 'whatsapp_evaluate_and_materialize_order_autonomy'
      and (pg_get_functiondef(oid) ~* 'unit_price' or pg_get_functiondef(oid) ~* 'discount')$$,
  'G11: evaluator source never copies unit_price or discount from AI'
);
select isnt_empty(
  $$select 1 from pg_proc
    where proname = 'whatsapp_evaluate_and_materialize_order_autonomy'
      and pg_get_functiondef(oid) like '%v_customer_rec.payment_terms%'$$,
  'G11: payment terms materialise from company master, not AI conclusion'
);
select isnt_empty(
  $$select 1 from pg_proc
    where proname = 'whatsapp_execute_autonomous_order_draft_v1'
      and pg_get_functiondef(oid) like '%CORE_B_GOVERNED%'
      and pg_get_functiondef(oid) like '%v_b2b.selling_price%'$$,
  'G11: draft line snapshot prices come from buyer B2B authority'
);

-- Master data
insert into auth.users (id, email) values
  ('c1100000-0000-0000-0000-000000000001', 'gate11-admin@example.test');
insert into public.users (id, email, full_name, role) values
  ('c1100000-0000-0000-0000-000000000001', 'gate11-admin@example.test', 'Gate-11 Admin', 'admin');

insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'c1100000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{},"aliases":{}}'::jsonb,
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'c1100000-0000-0000-0000-000000000001',
  'c1100000-0000-0000-0000-000000000001', statement_timestamp(),
  'c1100000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('c1100000-0000-0000-0000-000000000010');

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'c1100000-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);
insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'c1100000-0000-0000-0000-000000000161', 'c1100000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);
insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values (
  'c1100000-0000-0000-0000-000000000171', 'c1100000-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null
);
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'c1100000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919830000001', 'credit', 'active', false
);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'c1100000-0000-0000-0000-000000000211', 'c1100000-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- Invented price/discount/COD on an otherwise explicit order
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c1100000-0000-0000-0000-000000000301', '919830000001', 'Gate-11 Purchaser');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c1100000-0000-0000-0000-000000000311', 'prov-g11-01', '919830000001',
  'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c1100000-0000-0000-0000-000000000321', 'c1100000-0000-0000-0000-000000000301',
  'inbound', 'text', 'Please send 5 boxes of BAK-PIST-250 to MG Road branch', 'click2api',
  'prov-g11-01', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c1100000-0000-0000-0000-000000000301',
  array['c1100000-0000-0000-0000-000000000321'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c1100000-0000-0000-0000-000000000331',
  (select packet_id from public.whatsapp_messages where id = 'c1100000-0000-0000-0000-000000000321'),
  'fp-g11-01',
  array['prov-g11-01'],
  '{
    "confidence": 0.99,
    "conclusion": {
      "intent": "ORDER",
      "summary": "5 boxes at invented discount",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "payment_terms": "COD",
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "unit_price": 1,
          "discount": 99,
          "status": "explicit",
          "evidence_ids": ["prov-g11-01"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'c1100000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table g11_invented as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c1100000-0000-0000-0000-000000000321'),
  'c1100000-0000-0000-0000-000000000331'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from g11_invented),
  'AUTO_ELIGIBLE',
  'G11: invented commercial terms do not block an otherwise evidence-proven order'
);
select is(
  (select payload->'draft_execution'->>'execution_status' from g11_invented),
  'PROMOTED',
  'G11: auto-draft/promotion still uses governed facts only'
);
select is(
  (
    select (l.ai_line_snapshot->>'selling_price')::numeric
    from public.sales_order_draft_lines l
    where l.draft_id = ((select payload->'draft_execution'->>'sales_order_draft_id' from g11_invented)::uuid)
  ),
  500::numeric,
  'G11: draft selling_price is canonical B2B 500, not AI unit_price 1'
);
select ok(
  not exists (
    select 1
    from public.whatsapp_order_autonomy_decisions d,
         jsonb_array_elements(d.governed_facts->'order_lines') as line
    where d.id = (select payload->>'autonomy_decision_id' from g11_invented)::uuid
      and ((line ? 'unit_price') or (line ? 'discount'))
  ),
  'G11: governed line facts omit AI unit_price and discount'
);
select is(
  (
    select d.governed_facts->'customer'->>'payment_terms'
    from public.whatsapp_order_autonomy_decisions d
    where d.id = (select payload->>'autonomy_decision_id' from g11_invented)::uuid
  ),
  'credit',
  'G11: payment_terms stay company master credit, not AI COD'
);

select throws_ok(
  format(
    'update public.whatsapp_order_autonomy_decisions set resolver_rule_version = %L where id = %L',
    'tamper',
    (select payload->>'autonomy_decision_id' from g11_invented)
  ),
  '55000',
  'whatsapp_order_autonomy_decisions is append-only',
  'G11: autonomy decisions remain append-only after auto-action'
);

-- Cancellation is not an auto-order
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c1100000-0000-0000-0000-000000000401', '919830000002', 'Gate-11 Cancel');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c1100000-0000-0000-0000-000000000411', 'prov-g11-02', '919830000002',
  'Please cancel 5 boxes BAK-PIST-250', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c1100000-0000-0000-0000-000000000421', 'c1100000-0000-0000-0000-000000000401',
  'inbound', 'text', 'Please cancel 5 boxes BAK-PIST-250', 'click2api',
  'prov-g11-02', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c1100000-0000-0000-0000-000000000401',
  array['c1100000-0000-0000-0000-000000000421'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c1100000-0000-0000-0000-000000000431',
  (select packet_id from public.whatsapp_messages where id = 'c1100000-0000-0000-0000-000000000421'),
  'fp-g11-02',
  array['prov-g11-02'],
  '{
    "confidence": 0.97,
    "conclusion": {
      "intent": "CANCELLATION",
      "summary": "Cancel 5 boxes",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-g11-02"]
        }
      ]
    }
  }'::jsonb,
  'test-model-v1', 'c1100000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table g11_cancel as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c1100000-0000-0000-0000-000000000421'),
  'c1100000-0000-0000-0000-000000000431'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from g11_cancel),
  'HUMAN_EXCEPTION_REQUIRED',
  'G11: cancellation never auto-actions as a new order'
);
select ok(
  (select payload->'draft_execution'->>'sales_order_draft_id' is null from g11_cancel),
  'G11: cancellation creates no autonomous sales order draft'
);

-- Payment advice is not an auto-order
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('c1100000-0000-0000-0000-000000000501', '919830000003', 'Gate-11 Payment');
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  'c1100000-0000-0000-0000-000000000511', 'prov-g11-03', '919830000003',
  'Paid 50000 by NEFT for last invoice', 'text', statement_timestamp()
);
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'c1100000-0000-0000-0000-000000000521', 'c1100000-0000-0000-0000-000000000501',
  'inbound', 'text', 'Paid 50000 by NEFT for last invoice', 'click2api',
  'prov-g11-03', 'received', statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'c1100000-0000-0000-0000-000000000501',
  array['c1100000-0000-0000-0000-000000000521'::uuid], 300
);
insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids,
  interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
  knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
) values (
  'c1100000-0000-0000-0000-000000000531',
  (select packet_id from public.whatsapp_messages where id = 'c1100000-0000-0000-0000-000000000521'),
  'fp-g11-03',
  array['prov-g11-03'],
  '{
    "confidence": 0.96,
    "conclusion": {
      "intent": "PAYMENT_ADVICE",
      "summary": "NEFT payment advice",
      "customer": {"company_name": "Taj Sweets Bengaluru"}
    }
  }'::jsonb,
  'test-model-v1', 'c1100000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
);

create temporary table g11_pay as
select public.whatsapp_materialize_packet_ai_case(
  (select packet_id from public.whatsapp_messages where id = 'c1100000-0000-0000-0000-000000000521'),
  'c1100000-0000-0000-0000-000000000531'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from g11_pay),
  'HUMAN_EXCEPTION_REQUIRED',
  'G11: payment advice never auto-actions as a sales order'
);

select is(
  (
    select po.state
    from public.whatsapp_order_autonomy_decisions d
    join public.whatsapp_potential_orders po on po.id = d.potential_order_id
    where d.id = (select payload->>'autonomy_decision_id' from g11_invented)::uuid
  ),
  'CONVERTED',
  'G13: auto-promoted autonomy path converts the WA-1 potential order'
);
select is(
  (
    select po.disposition
    from public.whatsapp_order_autonomy_decisions d
    join public.whatsapp_potential_orders po on po.id = d.potential_order_id
    where d.id = (select payload->>'autonomy_decision_id' from g11_invented)::uuid
  ),
  'CONVERTED',
  'G13: auto-promoted potential order is accounted as CONVERTED'
);

select * from finish();
rollback;
