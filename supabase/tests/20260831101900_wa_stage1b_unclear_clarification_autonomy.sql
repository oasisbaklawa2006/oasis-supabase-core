-- Contract and regression coverage for 20260831101900_wa_stage1b_unclear_clarification_autonomy.sql
begin;

select plan(18);

-- Structural contracts on the forward migration body
select isnt_empty(
  $$select 1
      from pg_proc
     where oid = 'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure
       and pg_get_functiondef(oid) like '%unclear_intent_requires_clarification%'$$,
  'autonomy evaluator retains governed UNCLEAR clarification path'
);

select isnt_empty(
  $$select 1
      from pg_proc
     where oid = 'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure
       and pg_get_functiondef(oid) like '%v_intent = ''UNCLEAR''%'
       and pg_get_functiondef(oid) like '%v_confidence >= 0.50%'$$,
  'UNCLEAR autonomous clarification requires governed confidence floor'
);

select isnt_empty(
  $$select 1
      from pg_proc
     where oid = 'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure
       and pg_get_functiondef(oid) like '%unresolved_line_%'
       and pg_get_functiondef(oid) like '%v_all_lines_resolved := false%'$$,
  'every non-RESOLVED product line fail-closes autonomous progression'
);

-- Minimal master data for behavioral regression
insert into auth.users (id, email) values
  ('b3110190-0000-0000-0000-000000000001', 'stage1b-s1b@example.test');

insert into public.users (id, email, full_name, role) values
  ('b3110190-0000-0000-0000-000000000001', 'stage1b-s1b@example.test', 'Stage1B S1B Admin', 'admin');

insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'b3110190-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista special":"BAK-PIST-250"}}'::jsonb,
  '2222222222222222222222222222222222222222222222222222222222222222',
  'b3110190-0000-0000-0000-000000000001',
  'b3110190-0000-0000-0000-000000000001', statement_timestamp(),
  'b3110190-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('b3110190-0000-0000-0000-000000000010');

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'b3110190-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);

insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values (
  'b3110190-0000-0000-0000-000000000161', 'b3110190-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1
);

insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values (
  'b3110190-0000-0000-0000-000000000171', 'b3110190-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null
);

insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'b3110190-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919811111111', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'b3110190-0000-0000-0000-000000000211', 'b3110190-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- Helper: evaluate autonomy for a stitched packet + interpretation JSON
create or replace function pg_temp.stage1b_eval(
  p_contact uuid,
  p_provider text,
  p_body text,
  p_interpretation jsonb,
  p_interp_id uuid default gen_random_uuid()
) returns jsonb
language plpgsql
as $$
declare
  v_inbound uuid := gen_random_uuid();
  v_msg uuid := gen_random_uuid();
  v_packet uuid;
begin
  insert into public.whatsapp_inbound_messages(
    id, provider_message_id, sender_phone, message_body, message_type, received_at
  ) values (
    v_inbound, p_provider, '919811111111', p_body, 'text', statement_timestamp()
  );

  insert into public.whatsapp_messages(
    id, contact_id, direction, message_type, content, provider, provider_message_id,
    status, message_timestamp, created_at
  ) values (
    v_msg, p_contact, 'inbound', 'text', p_body, 'click2api', p_provider,
    'received', statement_timestamp(), statement_timestamp()
  );

  select public.stitch_whatsapp_messages_atomic(p_contact, array[v_msg], 300) into v_packet;

  insert into public.whatsapp_packet_ai_interpretations(
    id, packet_id, content_fingerprint, provider_message_ids,
    interpretation, model_version, knowledge_snapshot_id, knowledge_snapshot_schema_version,
    knowledge_snapshot_content_checksum, interpretation_schema_version, prompt_policy_version, resolver_policy_version
  ) values (
    p_interp_id, v_packet, 'fp-' || p_provider, array[p_provider], p_interpretation,
    'test-model-v1', 'b3110190-0000-0000-0000-000000000010', 'wa-knowledge/v1',
    '2222222222222222222222222222222222222222222222222222222222222222',
    'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1'
  );

  return public.whatsapp_evaluate_and_materialize_order_autonomy(v_packet, p_interp_id);
end;
$$;

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('b3110190-0000-0000-0000-000000000301', '919811111111', 'Stage1B Regression Contact');

-- A: low-confidence UNCLEAR with clarification signals must NOT autonomously clarify
create temporary table s1b_low_conf as
select pg_temp.stage1b_eval(
  'b3110190-0000-0000-0000-000000000301',
  'prov-s1b-lowconf-clarify',
  'maybe order something',
  '{
    "confidence": 0.0,
    "conclusion": {
      "intent": "UNCLEAR",
      "reply_clearance": "CLARIFICATION_REQUIRED",
      "explicit_facts": [{"field": "quantity", "status": "missing"}],
      "order_lines": []
    }
  }'::jsonb,
  'b3110190-0000-0000-0000-000000000401'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from s1b_low_conf),
  'FAILED_INTERPRETATION',
  'A: confidence 0.0 with clarification signals stays FAILED_INTERPRETATION'
);

select isnt(
  (select payload->>'autonomy_outcome' from s1b_low_conf),
  'CLARIFICATION_REQUIRED',
  'A: confidence 0.0 must not enter autonomous CLARIFICATION_REQUIRED'
);

-- B: governed-confidence UNCLEAR with valid clarification signal may clarify
create temporary table s1b_high_conf as
select pg_temp.stage1b_eval(
  'b3110190-0000-0000-0000-000000000301',
  'prov-s1b-highconf-clarify',
  'need more detail',
  '{
    "confidence": 0.72,
    "conclusion": {
      "intent": "UNCLEAR",
      "reply_clearance": "CLARIFICATION_REQUIRED",
      "explicit_facts": [{"field": "sku", "status": "missing"}],
      "order_lines": []
    }
  }'::jsonb,
  'b3110190-0000-0000-0000-000000000402'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from s1b_high_conf),
  'CLARIFICATION_REQUIRED',
  'B: UNCLEAR above confidence floor with clarification signal becomes CLARIFICATION_REQUIRED'
);

-- C: unsupported intent must not inherit UNCLEAR autonomous clarification path
create temporary table s1b_unsupported as
select pg_temp.stage1b_eval(
  'b3110190-0000-0000-0000-000000000301',
  'prov-s1b-unsupported',
  'random widget request',
  '{
    "confidence": 0.95,
    "conclusion": {
      "intent": "WIDGET_REQUEST",
      "reply_clearance": "CLARIFICATION_REQUIRED",
      "explicit_facts": [{"field": "widget", "status": "unknown"}],
      "order_lines": []
    }
  }'::jsonb,
  'b3110190-0000-0000-0000-000000000403'
) as payload;

select is(
  (select payload->>'autonomy_outcome' from s1b_unsupported),
  'FAILED_INTERPRETATION',
  'C: unsupported intent fails closed instead of UNCLEAR clarification'
);

select ok(
  not exists (
    select 1
      from unnest(
        coalesce(
          (select array(select jsonb_array_elements_text(payload->'decision_reasons')) from s1b_unsupported),
          '{}'::text[]
        )
      ) reason
     where reason = 'unclear_intent_requires_clarification'
  ),
  'C: unsupported intent does not record unclear_intent_requires_clarification'
);

-- Resolver-level non-RESOLVED reasons (fail-closed inputs)
create temporary table s1b_qty_pos as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 0, "unit": "box", "status": "explicit", "evidence_ids": ["ev-qty-pos"]}'::jsonb,
  'b3110190-0000-0000-0000-000000000010',
  'b3110190-0000-0000-0000-000000000201'
);

select is((select resolution_status from s1b_qty_pos), 'UNRESOLVED', 'quantity_must_be_positive marks line UNRESOLVED');
select isnt_empty(
  $$select 1 from s1b_qty_pos where 'quantity_must_be_positive' = any(unresolved_reasons)$$,
  'quantity_must_be_positive unresolved reason is surfaced'
);

create temporary table s1b_qty_unparseable as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": "five-ish", "unit": "box", "status": "explicit", "evidence_ids": ["ev-qty-unparseable"]}'::jsonb,
  'b3110190-0000-0000-0000-000000000010',
  'b3110190-0000-0000-0000-000000000201'
);

select is((select resolution_status from s1b_qty_unparseable), 'UNRESOLVED', 'quantity_unparseable marks line UNRESOLVED');
select isnt_empty(
  $$select 1 from s1b_qty_unparseable where 'quantity_unparseable' = any(unresolved_reasons)$$,
  'quantity_unparseable unresolved reason is surfaced'
);

create temporary table s1b_carton as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 5, "unit": "carton", "status": "explicit", "evidence_ids": ["ev-carton"]}'::jsonb,
  'b3110190-0000-0000-0000-000000000010',
  'b3110190-0000-0000-0000-000000000201'
);

select is((select resolution_status from s1b_carton), 'UNRESOLVED', 'carton_without_governed_carton_authority marks line UNRESOLVED');
select isnt_empty(
  $$select 1 from s1b_carton where 'carton_without_governed_carton_authority' = any(unresolved_reasons)$$,
  'carton_without_governed_carton_authority unresolved reason is surfaced'
);

create temporary table s1b_unknown_reason as
select * from public.whatsapp_resolve_governed_product_line(
  '{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 5, "unit": "barrel", "status": "explicit", "evidence_ids": ["ev-unknown-uom"]}'::jsonb,
  'b3110190-0000-0000-0000-000000000010',
  'b3110190-0000-0000-0000-000000000201'
);

select is((select resolution_status from s1b_unknown_reason), 'AMBIGUOUS', 'future/unknown resolver reason remains non-RESOLVED');

-- Mixed resolved + unresolved lines must not AUTO_ELIGIBLE
create temporary table s1b_mixed as
select pg_temp.stage1b_eval(
  'b3110190-0000-0000-0000-000000000301',
  'prov-s1b-mixed-lines',
  '5 boxes BAK-PIST-250 and 2 boxes mystery',
  '{
    "confidence": 0.96,
    "conclusion": {
      "intent": "ORDER",
      "summary": "Mixed resolved and unresolved lines",
      "customer": {"company_name": "Taj Sweets Bengaluru", "gst_number": "29ABCDE1234F1Z5"},
      "branch": {"label": "Main Store"},
      "order_lines": [
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 5,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-s1b-mixed-lines"]
        },
        {
          "sku": "BAK-PIST-250",
          "product_name": "Pistachio Baklawa 250g",
          "quantity": 0,
          "unit": "box",
          "status": "explicit",
          "evidence_ids": ["prov-s1b-mixed-lines"]
        }
      ]
    }
  }'::jsonb,
  'b3110190-0000-0000-0000-000000000404'
) as payload;

select isnt(
  (select payload->>'autonomy_outcome' from s1b_mixed),
  'AUTO_ELIGIBLE',
  'mixed RESOLVED + UNRESOLVED lines must not become AUTO_ELIGIBLE'
);

select isnt_empty(
  $$select 1
      from s1b_mixed,
           unnest(coalesce(array(select jsonb_array_elements_text(payload->'blocking_reasons')), '{}'::text[])) reason
     where reason like 'unresolved_line_%'$$,
  'mixed unresolved line records generic unresolved_line_ blocking reason'
);

select * from finish();
rollback;
