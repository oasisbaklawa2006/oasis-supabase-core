-- POINT68 — WhatsApp draft review/correction canonical closure certification.
-- Audit-first lane: reuses existing Core RPC authority (WA-3, CORE-A/B, operator
-- workspace) without duplicating promotion or media (#188) paths.
begin;
select plan(28);

-- ---------------------------------------------------------------------------
-- Shared fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('88000000-0000-0000-0000-000000000001', 'p68-reviewer@example.test');
insert into public.users (id, email, name, role, is_active) values
  ('88000000-0000-0000-0000-000000000001', 'p68-reviewer@example.test', 'P68 Reviewer', 'SUPER_ADMIN', true);
insert into public.user_role_map (user_id, role_id)
select '88000000-0000-0000-0000-000000000001', id
from public.roles
where role_key = 'super_admin'
on conflict (user_id, role_id) do nothing;

insert into public.companies (id, business_name, status) values
  ('88000000-0000-0000-0000-000000000002', 'P68 Test Company', 'approved');
insert into public.products (
  id, name, product_name, category, sku, hsn_code, is_active,
  visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b
) values (
  '88000000-0000-0000-0000-000000000003', 'P68 Product', 'P68 Product', 'test',
  'P68-SKU', '1905', true, true, true, 1, 1, 650, 650
);
insert into public.product_pricing_rules (
  product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
) values (
  '88000000-0000-0000-0000-000000000003', 'b2b', 'approved', 650, 650, 'INR', 'box', 0, true
);
insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
values ('88000000-0000-0000-0000-000000000003', 'b2b', true, 1, 1, 1);

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('88000000-0000-0000-0000-000000000010', '919888888888', 'P68 Contact'),
  ('88000000-0000-0000-0000-000000000011', '919777777777', 'Other Contact');
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at, status
) values
  ('88000000-0000-0000-0000-000000000020', '88000000-0000-0000-0000-000000000010', '{"text":"send 5 boxes"}'::jsonb, now(), now(), 'closed'),
  ('88000000-0000-0000-0000-000000000021', '88000000-0000-0000-0000-000000000011', '{"text":"wrong sender packet"}'::jsonb, now(), now(), 'closed'),
  ('88000000-0000-0000-0000-000000000022', '88000000-0000-0000-0000-000000000010', '{"text":"unresolved"}'::jsonb, now(), now(), 'closed');

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, raw_payload, resolver_status
) values (
  '88000000-0000-0000-0000-000000000030', 'p68-source-ok', '919888888888', 'send 5 boxes pistachio',
  '{"commercial_eligible":true}'::jsonb, 'failed'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'service_role', 'aal', 'aal1')::text,
  true
);

insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by
) values (
  '88000000-0000-0000-0000-000000000060',
  '88000000-0000-0000-0000-000000000020',
  'p68-unchanged-v1',
  'AI_DRAFT',
  '88000000-0000-0000-0000-000000000002',
  'P68 Test Company',
  100,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'send 5 boxes pistachio',
  '88000000-0000-0000-0000-000000000001',
  '88000000-0000-0000-0000-000000000001'
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '88000000-0000-0000-0000-000000000060', 0, '88000000-0000-0000-0000-000000000003',
  'P68 Product', 'P68-SKU', 5, 'box', 5, 'box'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select ok(
  exists(select 1 from public.sales_order_drafts where id = '88000000-0000-0000-0000-000000000060'),
  'FLOW1 setup: packet-linked draft exists for review certification'
);

select lives_ok(
  $$select public.submit_sales_order_draft_for_review_atomic(
      (select id from public.sales_order_drafts where extraction_request_key = 'p68-unchanged-v1'),
      'p68-unchanged-v1',
      '{}'::jsonb,
      100,
      '[
        {"dimension":"client","status":"ready","score":100},
        {"dimension":"product","status":"ready","score":100},
        {"dimension":"quantity","status":"ready","score":100},
        {"dimension":"address","status":"ready","score":100},
        {"dimension":"payment_terms","status":"ready","score":100}
      ]'::jsonb,
      '[]'::jsonb,
      '88000000-0000-0000-0000-000000000001',
      'P68 Reviewer'
    )$$,
  'FLOW1: correct draft accepted unchanged moves to UNDER_REVIEW'
);
select is(
  (select status from public.sales_order_drafts where extraction_request_key = 'p68-unchanged-v1'),
  'UNDER_REVIEW',
  'FLOW1: unchanged review reaches UNDER_REVIEW approval-ready state'
);
select is(
  (select promoted_order_id is null from public.sales_order_drafts where extraction_request_key = 'p68-unchanged-v1'),
  true,
  'FLOW1: review path does not create a live order'
);

-- ---------------------------------------------------------------------------
-- FLOW 2: operator correction persists and supersedes prior interpretation
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'service_role', 'aal', 'aal1')::text,
  true
);
insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by
) values (
  '88000000-0000-0000-0000-000000000061',
  '88000000-0000-0000-0000-000000000021',
  'p68-correct-v1',
  'AI_DRAFT',
  '88000000-0000-0000-0000-000000000002',
  'P68 Test Company',
  80,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'wrong sender packet',
  '88000000-0000-0000-0000-000000000001',
  '88000000-0000-0000-0000-000000000001'
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '88000000-0000-0000-0000-000000000061', 0, '88000000-0000-0000-0000-000000000003',
  'P68 Product', 'P68-SKU', 5, 'box', 5, 'box'
);
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select public.update_sales_order_draft_operator_final(
      (select id from public.sales_order_drafts where extraction_request_key = 'p68-correct-v1'),
      'p68-correct-v1',
      '{"operator_note":"corrected qty to 8"}'::jsonb,
      100,
      '[
        {"dimension":"client","status":"ready","score":100},
        {"dimension":"product","status":"ready","score":100},
        {"dimension":"quantity","status":"ready","score":100},
        {"dimension":"address","status":"ready","score":100},
        {"dimension":"payment_terms","status":"ready","score":100}
      ]'::jsonb,
      jsonb_build_array(jsonb_build_object(
        'line_index', 0,
        'operator_quantity', 8,
        'operator_line_snapshot', '{"reason":"operator correction"}'::jsonb
      )),
      '88000000-0000-0000-0000-000000000001',
      'P68 Reviewer'
    )$$,
  'FLOW2: operator correction persists through governed RPC'
);
select is(
  (select operator_quantity from public.sales_order_draft_lines
    where draft_id = (select id from public.sales_order_drafts where extraction_request_key = 'p68-correct-v1')),
  8::numeric,
  'FLOW2: corrected quantity supersedes prior normalized quantity'
);
select lives_ok(
  $$select public.update_sales_order_draft_operator_final(
      (select id from public.sales_order_drafts where extraction_request_key = 'p68-correct-v1'),
      'p68-correct-v1',
      '{"operator_note":"second correction to 10"}'::jsonb,
      100,
      '[
        {"dimension":"client","status":"ready","score":100},
        {"dimension":"product","status":"ready","score":100},
        {"dimension":"quantity","status":"ready","score":100},
        {"dimension":"address","status":"ready","score":100},
        {"dimension":"payment_terms","status":"ready","score":100}
      ]'::jsonb,
      jsonb_build_array(jsonb_build_object(
        'line_index', 0,
        'operator_quantity', 10,
        'operator_line_snapshot', '{"reason":"second correction supersedes first"}'::jsonb
      )),
      '88000000-0000-0000-0000-000000000001',
      'P68 Reviewer'
    )$$,
  'FLOW2: later operator correction supersedes earlier correction'
);
select is(
  (select operator_quantity from public.sales_order_draft_lines
    where draft_id = (select id from public.sales_order_drafts where extraction_request_key = 'p68-correct-v1')),
  10::numeric,
  'FLOW2: active line quantity reflects latest superseding correction'
);

-- ---------------------------------------------------------------------------
-- FLOW 3: unresolved ambiguity fails closed before promotion
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'service_role', 'aal', 'aal2')::text,
  true
);
select lives_ok(
  $$select public.capture_whatsapp_potential_order(
      '88000000-0000-0000-0000-000000000030', true, true, '{"test":"p68-unresolved"}'::jsonb
    )$$,
  'FLOW3 setup: commercial ingress captured for WA-3 readiness gate'
);

insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by, potential_order_id
) values (
  '88000000-0000-0000-0000-000000000040',
  '88000000-0000-0000-0000-000000000022',
  'p68-unresolved-v1',
  'UNDER_REVIEW',
  '88000000-0000-0000-0000-000000000002',
  'P68 Test Company',
  100,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'send pistachio',
  '88000000-0000-0000-0000-000000000001',
  '88000000-0000-0000-0000-000000000001',
  (select id from public.whatsapp_potential_orders where source_message_id = '88000000-0000-0000-0000-000000000030')
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '88000000-0000-0000-0000-000000000040', 0, '88000000-0000-0000-0000-000000000003',
  'P68 Product', 'P68-SKU', 2, 'box', 2, 'box'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);
set local role authenticated;

create temporary table p68_blocked (sqlstate text, message text) on commit drop;
do $$
begin
  perform *
  from public.approve_sales_order_draft_for_so_atomic(
    '88000000-0000-0000-0000-000000000040',
    'p68-unresolved-v1',
    '88000000-0000-0000-0000-000000000001',
    'P68 unresolved test'
  );
exception
  when others then
    insert into p68_blocked values (sqlstate, sqlerrm);
end $$;

select is((select sqlstate from p68_blocked), 'P0001', 'FLOW3: unresolved WA-3 dimensions fail closed at promotion boundary');
select ok(
  (select message like 'WA3_COMMERCIAL_DIMENSIONS_UNRESOLVED:%' from p68_blocked),
  'FLOW3: failure identifies unresolved commercial dimensions'
);
select is(
  (select status from public.sales_order_drafts where id = '88000000-0000-0000-0000-000000000040'),
  'UNDER_REVIEW',
  'FLOW3: blocked draft remains in reviewable state'
);

-- ---------------------------------------------------------------------------
-- FLOW 4: wrong sender/customer association cannot bridge silently
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'service_role', 'aal', 'aal1')::text,
  true
);
insert into public.whatsapp_communication_cases (
  id, packet_id, case_type, status, source_channel, rule_version
) values (
  '88000000-0000-0000-0000-000000000050',
  '88000000-0000-0000-0000-000000000021',
  'ORDER',
  'NEEDS_IDENTITY',
  'WHATSAPP',
  'p68-fixture-v1'
);

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at
) values (
  '88000000-0000-0000-0000-000000000031', 'p68-wrong-sender', '919777777777',
  'wrong sender same packet', 'text', now()
);

insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action, first_received_at, last_evidence_at
) values (
  '88000000-0000-0000-0000-000000000041',
  '88000000-0000-0000-0000-000000000031',
  'p68-wrong-sender',
  '919777777777',
  'p68-wrong-sender-fingerprint',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'ASSIGN_OWNER',
  now(),
  now()
);

select is(
  public.whatsapp_case_potential_order_id('88000000-0000-0000-0000-000000000050'),
  null::uuid,
  'FLOW4: wrong sender/customer association does not bridge to a promotable potential order'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

-- ---------------------------------------------------------------------------
-- FLOW 5: repeated review/correction is replay-safe
-- ---------------------------------------------------------------------------
select throws_like(
  $$select public.submit_sales_order_draft_for_review_atomic(
      (select id from public.sales_order_drafts where extraction_request_key = 'p68-unchanged-v1'),
      'p68-unchanged-v1',
      '{}'::jsonb,
      100,
      '[]'::jsonb,
      '[]'::jsonb,
      '88000000-0000-0000-0000-000000000001',
      'P68 Reviewer'
    )$$,
  '%Submit for review only allowed from AI_DRAFT%',
  'FLOW5: duplicate submit replay is rejected after first transition'
);
select throws_like(
  $$select public.submit_sales_order_draft_for_review_atomic(
      (select id from public.sales_order_drafts where extraction_request_key = 'p68-correct-v1'),
      'p68-stale-key',
      '{}'::jsonb,
      100,
      '[]'::jsonb,
      '[]'::jsonb,
      '88000000-0000-0000-0000-000000000001',
      'P68 Reviewer'
    )$$,
  '%Extraction version mismatch%',
  'FLOW5: stale extraction key replay fails closed'
);
select is(
  (select count(*) from public.sales_order_draft_audit_log
    where draft_id = (select id from public.sales_order_drafts where extraction_request_key = 'p68-unchanged-v1')
      and action = 'SUBMIT_REVIEW'),
  1::bigint,
  'FLOW5: exactly one submit audit row after replay attempts'
);

-- ---------------------------------------------------------------------------
-- FLOW 6: review/correction lane is separated from Point69 live-order creation
-- ---------------------------------------------------------------------------
select ok(
  position('insert into public.orders' in lower(pg_get_functiondef(
    'public.submit_sales_order_draft_for_review_atomic(uuid,text,jsonb,integer,jsonb,jsonb,uuid,text,jsonb)'::regprocedure
  ))) = 0,
  'FLOW6: submit-for-review RPC does not create orders'
);
select ok(
  position('insert into public.orders' in lower(pg_get_functiondef(
    'public.update_sales_order_draft_operator_final(uuid,text,jsonb,integer,jsonb,jsonb,uuid,text,jsonb)'::regprocedure
  ))) = 0,
  'FLOW6: operator-final correction RPC does not create orders'
);
select ok(
  position('promote_sales_order_draft_to_order_governed_v1' in lower(pg_get_functiondef(
    'public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb)'::regprocedure
  ))) > 0,
  'FLOW6: live-order promotion is isolated to the approve wrapper (Point69 boundary RPC)'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)',
    'EXECUTE'
  ),
  'FLOW6: direct promotion core remains service-role-only; review lane cannot bypass it'
);

-- Chain census contracts (canonical tables/RPCs/events — no duplication)
select has_table('public', 'sales_order_drafts', 'census: governed draft header');
select has_table('public', 'sales_order_draft_lines', 'census: governed draft lines');
select has_table('public', 'sales_order_draft_audit_log', 'census: immutable review audit');
select has_function('public', 'submit_sales_order_draft_for_review_atomic', array['uuid','text','jsonb','integer','jsonb','jsonb','uuid','text','jsonb']);
select has_function('public', 'update_sales_order_draft_operator_final', array['uuid','text','jsonb','integer','jsonb','jsonb','uuid','text','jsonb']);
select has_function('public', 'approve_sales_order_draft_for_so_atomic', array['uuid','text','uuid','text','text','jsonb']);
select ok(
  exists(select 1 from pg_trigger where tgname = 'wa3_draft_promotion_readiness' and not tgisinternal),
  'census: WA-3 readiness trigger guards promotion boundary'
);
select ok(
  exists(select 1 from pg_trigger where tgname = 'wa2_sales_order_drafts_write_guard' and not tgisinternal),
  'census: WA-2 AAL2/wa.draft.promote guard on terminal draft writes'
);

select * from finish();
rollback;
