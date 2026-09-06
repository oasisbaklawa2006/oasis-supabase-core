-- POINT69 — approved WhatsApp draft → canonical live order closure certification.
-- Behavioral pgTAP over existing governed promotion authority; synthetic fixtures only.
begin;
select plan(35);

-- ---------------------------------------------------------------------------
-- Shared fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('89000000-0000-0000-0000-000000000001', 'p69-promoter@example.test');
insert into public.users (id, email, name, role, is_active) values
  ('89000000-0000-0000-0000-000000000001', 'p69-promoter@example.test', 'P69 Promoter', 'SUPER_ADMIN', true);
insert into public.user_role_map (user_id, role_id)
select '89000000-0000-0000-0000-000000000001', id
from public.roles
where role_key = 'super_admin'
on conflict (user_id, role_id) do nothing;

insert into public.companies (id, business_name, status) values
  ('89000000-0000-0000-0000-000000000002', 'P69 Test Company', 'approved');
insert into public.products (
  id, name, product_name, category, sku, hsn_code, is_active,
  visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b
) values (
  '89000000-0000-0000-0000-000000000003', 'P69 Product', 'P69 Product', 'test',
  'P69-SKU', '1905', true, true, true, 1, 1, 650, 650
);
insert into public.product_pricing_rules (
  product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
) values (
  '89000000-0000-0000-0000-000000000003', 'b2b', 'approved', 650, 650, 'INR', 'box', 0, true
);
insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
values ('89000000-0000-0000-0000-000000000003', 'b2b', true, 1, 1, 1);

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('89000000-0000-0000-0000-000000000010', '919666666666', 'P69 Contact');
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at, status
) values
  ('89000000-0000-0000-0000-000000000020', '89000000-0000-0000-0000-000000000010', '{"text":"send 5 boxes"}'::jsonb, now(), now(), 'closed'),
  ('89000000-0000-0000-0000-000000000021', '89000000-0000-0000-0000-000000000010', '{"text":"unresolved"}'::jsonb, now(), now(), 'closed'),
  ('89000000-0000-0000-0000-000000000022', '89000000-0000-0000-0000-000000000010', '{"text":"ai draft"}'::jsonb, now(), now(), 'closed'),
  ('89000000-0000-0000-0000-000000000023', '89000000-0000-0000-0000-000000000010', '{"text":"aal1 gate"}'::jsonb, now(), now(), 'closed');

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, raw_payload, resolver_status
) values (
  '89000000-0000-0000-0000-000000000030', 'p69-source-ok', '919666666666', 'send 5 boxes pistachio',
  '{"commercial_eligible":true}'::jsonb, 'failed'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '89000000-0000-0000-0000-000000000001', 'role', 'service_role', 'aal', 'aal2')::text,
  true
);

insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by
) values (
  '89000000-0000-0000-0000-000000000060',
  '89000000-0000-0000-0000-000000000020',
  'p69-ready-v1',
  'UNDER_REVIEW',
  '89000000-0000-0000-0000-000000000002',
  'P69 Test Company',
  100,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'send 5 boxes pistachio',
  '89000000-0000-0000-0000-000000000001',
  '89000000-0000-0000-0000-000000000001'
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '89000000-0000-0000-0000-000000000060', 0, '89000000-0000-0000-0000-000000000003',
  'P69 Product', 'P69-SKU', 5, 'box', 5, 'box'
);

-- Draft in wrong status for promotion denial
insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by
) values (
  '89000000-0000-0000-0000-000000000061',
  '89000000-0000-0000-0000-000000000022',
  'p69-ai-draft-v1',
  'AI_DRAFT',
  '89000000-0000-0000-0000-000000000002',
  'P69 Test Company',
  100,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'not yet submitted',
  '89000000-0000-0000-0000-000000000001',
  '89000000-0000-0000-0000-000000000001'
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '89000000-0000-0000-0000-000000000061', 0, '89000000-0000-0000-0000-000000000003',
  'P69 Product', 'P69-SKU', 2, 'box', 2, 'box'
);

-- UNDER_REVIEW draft reserved for AAL1 step-up denial (must not be AI_DRAFT)
insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by
) values (
  '89000000-0000-0000-0000-000000000063',
  '89000000-0000-0000-0000-000000000023',
  'p69-aal1-v1',
  'UNDER_REVIEW',
  '89000000-0000-0000-0000-000000000002',
  'P69 Test Company',
  100,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'aal1 gate draft',
  '89000000-0000-0000-0000-000000000001',
  '89000000-0000-0000-0000-000000000001'
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '89000000-0000-0000-0000-000000000063', 0, '89000000-0000-0000-0000-000000000003',
  'P69 Product', 'P69-SKU', 2, 'box', 2, 'box'
);

-- WA3-governed draft with linked potential order (unresolved dimensions)
insert into public.whatsapp_potential_orders (
  id, source_message_id, provider_message_id, sender_key, source_fingerprint,
  source_evidence, state, disposition, queue, next_action, first_received_at, last_evidence_at
) values (
  '89000000-0000-0000-0000-000000000041',
  '89000000-0000-0000-0000-000000000030',
  'p69-source-ok',
  '919666666666',
  'p69-unresolved-fingerprint',
  '[]'::jsonb,
  'UNASSIGNED',
  'ACTIVE_PENDING',
  'WA_COMMERCIAL_UNASSIGNED',
  'TRIAGE_INTAKE',
  now(),
  now()
);
insert into public.sales_order_drafts (
  id, packet_id, extraction_request_key, status, company_id, company_name,
  readiness_overall_score, readiness_dimensions, original_whatsapp_text,
  created_by, updated_by, potential_order_id
) values (
  '89000000-0000-0000-0000-000000000062',
  '89000000-0000-0000-0000-000000000021',
  'p69-wa3-unresolved-v1',
  'UNDER_REVIEW',
  '89000000-0000-0000-0000-000000000002',
  'P69 Test Company',
  100,
  '[
    {"dimension":"client","status":"ready","score":100},
    {"dimension":"product","status":"ready","score":100},
    {"dimension":"quantity","status":"ready","score":100},
    {"dimension":"address","status":"ready","score":100},
    {"dimension":"payment_terms","status":"ready","score":100}
  ]'::jsonb,
  'send pistachio',
  '89000000-0000-0000-0000-000000000001',
  '89000000-0000-0000-0000-000000000001',
  '89000000-0000-0000-0000-000000000041'
);
insert into public.sales_order_draft_lines (
  draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
) values (
  '89000000-0000-0000-0000-000000000062', 0, '89000000-0000-0000-0000-000000000003',
  'P69 Product', 'P69-SKU', 2, 'box', 2, 'box'
);

-- ---------------------------------------------------------------------------
-- FLOW 1: human-approved promotion creates canonical live order
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '89000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);
set local role authenticated;

create temporary table p69_promo1 as
select *
from public.approve_sales_order_draft_for_so_atomic(
  '89000000-0000-0000-0000-000000000060',
  'p69-ready-v1',
  '89000000-0000-0000-0000-000000000001',
  'P69 Promoter',
  'Point69 certification promotion'
);

select ok(
  (select promoted_order_id is not null from p69_promo1),
  'FLOW1: human approval returns promoted_order_id'
);
select is(
  (select already_promoted from p69_promo1),
  false,
  'FLOW1: first promotion is not a replay'
);
select is(
  (select status from public.sales_order_drafts where id = '89000000-0000-0000-0000-000000000060'),
  'APPROVED_FOR_SO',
  'FLOW1: draft reaches APPROVED_FOR_SO'
);
select is(
  (select o.order_origin from public.orders o
    join public.sales_order_drafts d on d.promoted_order_id = o.id
   where d.id = '89000000-0000-0000-0000-000000000060'),
  'WHATSAPP',
  'FLOW1: promoted order preserves WhatsApp provenance'
);
select is(
  (select count(*)::integer from public.order_items oi
    join public.sales_order_drafts d on d.promoted_order_id = oi.order_id
   where d.id = '89000000-0000-0000-0000-000000000060'),
  1,
  'FLOW1: exactly one order line materialized from draft'
);
select ok(
  (select o.order_number ~ '^SO[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{4}$'
     from public.orders o
     join public.sales_order_drafts d on d.promoted_order_id = o.id
    where d.id = '89000000-0000-0000-0000-000000000060'),
  'FLOW1: canonical SO allocator assigned order_number'
);

-- ---------------------------------------------------------------------------
-- FLOW 2: idempotent replay returns same order without duplication
-- ---------------------------------------------------------------------------
create temporary table p69_promo2 as
select *
from public.approve_sales_order_draft_for_so_atomic(
  '89000000-0000-0000-0000-000000000060',
  'p69-ready-v1',
  '89000000-0000-0000-0000-000000000001',
  'P69 Promoter',
  'Point69 replay'
);

select is(
  (select already_promoted from p69_promo2),
  true,
  'FLOW2: replay reports already_promoted'
);
select is(
  (select promoted_order_id from p69_promo2),
  (select promoted_order_id from p69_promo1),
  'FLOW2: replay returns stable promoted_order_id'
);
select is(
  (select count(*)::integer from public.orders o
    join public.sales_order_drafts d on d.promoted_order_id = o.id
   where d.id = '89000000-0000-0000-0000-000000000060'),
  1,
  'FLOW2: replay does not create a second order'
);

-- ---------------------------------------------------------------------------
-- FLOW 3: forged extraction key fails closed
-- ---------------------------------------------------------------------------
create temporary table p69_forged (sqlstate text, message text) on commit drop;
do $$
begin
  perform *
  from public.approve_sales_order_draft_for_so_atomic(
    '89000000-0000-0000-0000-000000000060',
    'p69-forged-key',
    '89000000-0000-0000-0000-000000000001',
    'P69 Promoter'
  );
exception
  when others then
    insert into p69_forged values (sqlstate, sqlerrm);
end $$;

select is((select sqlstate from p69_forged), 'P0001', 'FLOW3: forged extraction key fails closed');
select ok(
  (select message = 'IDEMPOTENCY_KEY_MISMATCH' from p69_forged),
  'FLOW3: failure identifies idempotency key mismatch'
);

-- ---------------------------------------------------------------------------
-- FLOW 4: unapproved draft status cannot promote
-- ---------------------------------------------------------------------------
create temporary table p69_not_ready (sqlstate text, message text) on commit drop;
do $$
begin
  perform *
  from public.approve_sales_order_draft_for_so_atomic(
    '89000000-0000-0000-0000-000000000061',
    'p69-ai-draft-v1',
    '89000000-0000-0000-0000-000000000001',
    'P69 Promoter'
  );
exception
  when others then
    insert into p69_not_ready values (sqlstate, sqlerrm);
end $$;

select is((select sqlstate from p69_not_ready), 'P0001', 'FLOW4: AI_DRAFT status fails closed');
select ok(
  (select message = 'DRAFT_NOT_READY' from p69_not_ready),
  'FLOW4: failure identifies draft not ready'
);
select ok(
  (select promoted_order_id is null from public.sales_order_drafts where id = '89000000-0000-0000-0000-000000000061'),
  'FLOW4: unapproved draft has no promoted_order_id'
);

-- ---------------------------------------------------------------------------
-- FLOW 5: AAL1 cannot promote (wa.draft.promote step-up required)
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '89000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);

create temporary table p69_aal1 (sqlstate text, message text) on commit drop;
do $$
begin
  perform *
  from public.approve_sales_order_draft_for_so_atomic(
    '89000000-0000-0000-0000-000000000063',
    'p69-aal1-v1',
    '89000000-0000-0000-0000-000000000001',
    'P69 Promoter'
  );
exception
  when others then
    insert into p69_aal1 values (sqlstate, sqlerrm);
end $$;

select is((select sqlstate from p69_aal1), 'P0001', 'FLOW5: AAL1 session cannot promote');
select ok(
  (select message = 'WA2_DRAFT_PROMOTE_REQUIRED' from p69_aal1),
  'FLOW5: failure identifies missing wa.draft.promote step-up'
);

-- Restore AAL2 for remaining flows
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '89000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text,
  true
);

-- ---------------------------------------------------------------------------
-- FLOW 6: WA3 unresolved commercial dimensions block promotion
-- ---------------------------------------------------------------------------
create temporary table p69_wa3 (sqlstate text, message text) on commit drop;
do $$
begin
  perform *
  from public.approve_sales_order_draft_for_so_atomic(
    '89000000-0000-0000-0000-000000000062',
    'p69-wa3-unresolved-v1',
    '89000000-0000-0000-0000-000000000001',
    'P69 Promoter'
  );
exception
  when others then
    insert into p69_wa3 values (sqlstate, sqlerrm);
end $$;

select is((select sqlstate from p69_wa3), 'P0001', 'FLOW6: WA3 unresolved dimensions fail closed');
select ok(
  (select message like 'WA3_COMMERCIAL_DIMENSIONS_UNRESOLVED:%' from p69_wa3),
  'FLOW6: failure identifies unresolved WA-3 dimensions'
);
select is(
  (select status from public.sales_order_drafts where id = '89000000-0000-0000-0000-000000000062'),
  'UNDER_REVIEW',
  'FLOW6: blocked draft remains UNDER_REVIEW'
);
select ok(
  (select promoted_order_id is null from public.sales_order_drafts where id = '89000000-0000-0000-0000-000000000062'),
  'FLOW6: blocked draft has no partial promoted_order_id'
);

-- ---------------------------------------------------------------------------
-- FLOW 7: commercial version and audit trail on successful promotion
-- ---------------------------------------------------------------------------
select is(
  (select v.source_reference from public.sales_order_commercial_versions v
    join public.sales_order_drafts d on d.promoted_order_id = v.order_id
   where d.id = '89000000-0000-0000-0000-000000000060' and v.version_number = 1),
  'wa-draft:89000000-0000-0000-0000-000000000060',
  'FLOW7: immutable commercial version preserves governed draft reference'
);
select ok(
  exists(
    select 1 from public.sales_order_draft_audit_log
    where draft_id = '89000000-0000-0000-0000-000000000060'
      and action = 'APPROVE'
      and to_status = 'APPROVED_FOR_SO'
  ),
  'FLOW7: draft audit log records APPROVE transition'
);
select ok(
  pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure)
    like '%WA_DRAFT_PROMOTED_TO_SO%',
  'FLOW7: governed promotion core appends operational audit_logs row'
);

-- ---------------------------------------------------------------------------
-- FLOW 8: authority census — promotion chain contracts (no new RPCs)
-- ---------------------------------------------------------------------------
select has_function(
  'public', 'promote_sales_order_draft_to_order_governed_v1',
  array['uuid', 'text', 'uuid', 'text', 'text', 'jsonb'],
  'CENSUS: canonical governed promotion core exists'
);
select has_function(
  'public', 'approve_sales_order_draft_for_so_atomic',
  array['uuid', 'text', 'uuid', 'text', 'text', 'jsonb'],
  'CENSUS: human approval wrapper exists'
);
select has_function(
  'public', 'whatsapp_promote_autonomous_sales_order_draft_v1',
  array['uuid', 'text'],
  'CENSUS: CORE-B autonomous wrapper exists (separate from human approval)'
);
select ok(
  position('promote_sales_order_draft_to_order_governed_v1' in lower(pg_get_functiondef(
    'public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb)'::regprocedure
  ))) > 0,
  'CENSUS: human wrapper delegates to governed promotion core'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)',
    'EXECUTE'
  ),
  'CENSUS: governed promotion core is service-role-only at privilege boundary'
);
select ok(
  position('for update' in lower(pg_get_functiondef(
    'public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure
  ))) > 0,
  'CENSUS: promotion core locks draft row FOR UPDATE'
);
select ok(
  pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure)
    like '%WHATSAPP_DRAFT_PROMOTION%'
  and pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure)
    like '%sales_order_creation_scopes%',
  'CENSUS: promotion uses private WHATSAPP_DRAFT_PROMOTION creation scope'
);
select ok(
  exists(select 1 from pg_trigger where tgname = 'wa3_draft_promotion_readiness' and not tgisinternal),
  'CENSUS: WA-3 readiness trigger guards promotion writes'
);
select ok(
  exists(select 1 from pg_trigger where tgname = 'wa2_sales_order_drafts_write_guard' and not tgisinternal),
  'CENSUS: WA-2 AAL2/wa.draft.promote guard on terminal draft writes'
);

-- ---------------------------------------------------------------------------
-- FLOW 9: direct core bypass denied for authenticated callers
-- ---------------------------------------------------------------------------
select throws_like(
  $$select * from public.promote_sales_order_draft_to_order_governed_v1(
      '89000000-0000-0000-0000-000000000061',
      'p69-ai-draft-v1',
      '89000000-0000-0000-0000-000000000001',
      'P69 Promoter'
    )$$,
  '%permission denied%',
  'FLOW9: authenticated cannot call governed promotion core directly'
);

-- ---------------------------------------------------------------------------
-- FLOW 10: autonomous CORE-B wrapper is isolated (not human approval path)
-- ---------------------------------------------------------------------------
select ok(
  pg_get_functiondef('public.whatsapp_promote_autonomous_sales_order_draft_v1(uuid,text)'::regprocedure)
    like '%core-b:autonomy:%',
  'FLOW10: CORE-B wrapper requires core-b:autonomy extraction key prefix'
);
select ok(
  position('promote_sales_order_draft_to_order_governed_v1' in lower(pg_get_functiondef(
    'public.whatsapp_promote_autonomous_sales_order_draft_v1(uuid,text)'::regprocedure
  ))) > 0,
  'FLOW10: CORE-B wrapper still delegates to same governed core'
);

select * from finish();
rollback;
