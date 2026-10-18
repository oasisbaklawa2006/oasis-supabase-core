-- MC#631 acceptance: authorized human early-SO recording, pending-detail holds,
-- authority separation, duplicate prevention. Synthetic fixtures only.
begin;
select plan(31);
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- Actors: an operator holding wa.draft.promote (super_admin) and one without it
-- (support_executive: intake.read + draft.manage only).
insert into auth.users(id, email) values
  ('c6312000-0000-0000-0000-000000000001', 'mc631-promoter@test.invalid'),
  ('c6312000-0000-0000-0000-000000000002', 'mc631-support@test.invalid');
insert into public.users(id, role, name, is_active) values
  ('c6312000-0000-0000-0000-000000000001', 'SUPER_ADMIN', 'MC631 Promoter', true),
  ('c6312000-0000-0000-0000-000000000002', 'SUPPORT_EXECUTIVE', 'MC631 Support', true);
insert into public.user_role_map(user_id, role_id)
select 'c6312000-0000-0000-0000-000000000001', id from public.roles where role_key = 'super_admin'
on conflict (user_id, role_id) do nothing;
insert into public.user_role_map(user_id, role_id)
select 'c6312000-0000-0000-0000-000000000002', id from public.roles where role_key = 'support_executive'
on conflict (user_id, role_id) do nothing;

insert into public.companies(id, business_name, status)
values ('c6312000-0000-0000-0000-000000000010', 'MC631 Early SO Company', 'approved');
insert into public.products(id, name, product_name, category, sku, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
values ('c6312000-0000-0000-0000-000000000020', 'MC631 Product', 'MC631 Product', 'test', 'MC631-EARLY', '1905', true, true, true, 1, 1, 650, 650);
insert into public.product_pricing_rules(product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
values ('c6312000-0000-0000-0000-000000000020', 'b2b', 'approved', 650, 650, 'INR', 'box', 0, true);
insert into public.product_moq_rules(product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
values ('c6312000-0000-0000-0000-000000000020', 'b2b', true, 1, 1, 1);
insert into public.whatsapp_contacts(id, phone_number, customer_name)
values ('c6312000-0000-0000-0000-000000000030', '919111222333', 'MC631 Employee Relay');
insert into public.whatsapp_message_packets(id, contact_id, stitched_content, first_message_at, last_message_at, status)
select ('c6312000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid,
       'c6312000-0000-0000-0000-000000000030', '{}', now(), now(), 'closed'
from generate_series(1, 9) n;

-- Early-SO readiness: client/product/quantity ready; address + payment pending.
-- Drafts: 1 early (promoter), 2 early (unauthorized/spoof attempts), 3 no company,
-- 4 unknown SKU, 5 missing quantity, 6 fully ready (non-early / existing behaviour).
insert into public.sales_order_drafts(
  id, packet_id, extraction_request_key, status, company_id, company_name, readiness_overall_score,
  readiness_dimensions, original_whatsapp_text, created_by, updated_by, potential_order_id
)
select d.id::uuid, d.packet::uuid, d.ekey, 'UNDER_REVIEW', d.company::uuid, 'MC631 Early SO Company', 80,
       d.dims::jsonb, 'Bengal Sweets, South Ex, Mukesh - 10 kg Pistachio Baklawa', 'c6312000-0000-0000-0000-000000000001'::uuid,
       'c6312000-0000-0000-0000-000000000001'::uuid, null::uuid
from (values
  ('c6312000-0000-0000-0000-000000000101', 'c6312000-0000-0000-0000-000000000101', 'mc631-early-v1', 'c6312000-0000-0000-0000-000000000010',
   '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"pending","score":0},{"dimension":"payment_terms","status":"pending","score":0}]'),
  ('c6312000-0000-0000-0000-000000000102', 'c6312000-0000-0000-0000-000000000102', 'mc631-early-v2', 'c6312000-0000-0000-0000-000000000010',
   '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"pending","score":0},{"dimension":"payment_terms","status":"pending","score":0}]'),
  ('c6312000-0000-0000-0000-000000000103', 'c6312000-0000-0000-0000-000000000103', 'mc631-no-company', null,
   '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"pending","score":0},{"dimension":"payment_terms","status":"pending","score":0}]'),
  ('c6312000-0000-0000-0000-000000000104', 'c6312000-0000-0000-0000-000000000104', 'mc631-unknown-sku', 'c6312000-0000-0000-0000-000000000010',
   '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"pending","score":0},{"dimension":"payment_terms","status":"pending","score":0}]'),
  ('c6312000-0000-0000-0000-000000000105', 'c6312000-0000-0000-0000-000000000105', 'mc631-missing-qty', 'c6312000-0000-0000-0000-000000000010',
   '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"missing","score":0},{"dimension":"address","status":"pending","score":0},{"dimension":"payment_terms","status":"pending","score":0}]'),
  ('c6312000-0000-0000-0000-000000000106', 'c6312000-0000-0000-0000-000000000106', 'mc631-full-ready', 'c6312000-0000-0000-0000-000000000010',
   '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"ready","score":100},{"dimension":"payment_terms","status":"ready","score":100}]')
) as d(id, packet, ekey, company, dims);

insert into public.sales_order_draft_lines(draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit)
values
  ('c6312000-0000-0000-0000-000000000101', 0, 'c6312000-0000-0000-0000-000000000020', 'MC631 Product', 'MC631-EARLY', 2, 'box', 2, 'box'),
  ('c6312000-0000-0000-0000-000000000102', 0, 'c6312000-0000-0000-0000-000000000020', 'MC631 Product', 'MC631-EARLY', 2, 'box', 2, 'box'),
  ('c6312000-0000-0000-0000-000000000103', 0, 'c6312000-0000-0000-0000-000000000020', 'MC631 Product', 'MC631-EARLY', 2, 'box', 2, 'box'),
  ('c6312000-0000-0000-0000-000000000104', 0, null, 'Mystery Baklawa', null, 5, 'box', 5, 'box'),
  ('c6312000-0000-0000-0000-000000000105', 0, 'c6312000-0000-0000-0000-000000000020', 'MC631 Product', 'MC631-EARLY', 0, 'box', null, 'box'),
  ('c6312000-0000-0000-0000-000000000106', 0, 'c6312000-0000-0000-0000-000000000020', 'MC631 Product', 'MC631-EARLY', 2, 'box', 2, 'box');

-- ---------------------------------------------------------------------------
-- 4/5. Unauthorized human cannot select the early-SO gate, even by spoofing
--      the autonomous marker; and no order is created.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'c6312000-0000-0000-0000-000000000002', 'role', 'authenticated', 'aal', 'aal2')::text, true);
select throws_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000102', 'mc631-early-v2', 'c6312000-0000-0000-0000-000000000002', 'MC631 Support', null,
       '{"readiness_gate":"SO_RECORDABLE"}'::jsonb) $$,
  'P0001', null,
  'operator without wa.draft.promote cannot record an early SO'
);
select throws_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000102', 'mc631-early-v2', 'c6312000-0000-0000-0000-000000000002', 'MC631 Support', null,
       '{"readiness_gate":"SO_RECORDABLE","autonomous":true,"human_early_so":true}'::jsonb) $$,
  'P0001', null,
  'spoofed autonomous/human_early_so metadata does not bypass the gate'
);
select ok(
  (select promoted_order_id is null and status = 'UNDER_REVIEW' from public.sales_order_drafts where id = 'c6312000-0000-0000-0000-000000000102'),
  'rejected attempts create no order and leave the draft reviewable'
);

-- Diagnostic (temporary): which authority primitive rejects the promoter?
select set_config('request.jwt.claims', json_build_object('sub', 'c6312000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text, true);
select diag(format('DIAG uid=%s role=%s aal=%s step_up=%s app_read=%s wa_read=%s wa_promote=%s inbox_reader=%s roles=%s',
  auth.uid(), auth.role(), auth.jwt()->>'aal', public.has_step_up_auth(),
  public.has_app_permission('c6312000-0000-0000-0000-000000000001', 'wa.intake.read', null, null),
  public.has_whatsapp_permission('wa.intake.read'), public.has_whatsapp_permission('wa.draft.promote'),
  public.is_whatsapp_inbox_reader('c6312000-0000-0000-0000-000000000001'),
  (select string_agg(r.role_key, ',') from public.user_role_map m join public.roles r on r.id = m.role_id where m.user_id = 'c6312000-0000-0000-0000-000000000001')));
-- Authorized operator without an explicit early-SO request keeps the FULL gate.
select set_config('request.jwt.claims', json_build_object('sub', 'c6312000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text, true);
select throws_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000102', 'mc631-early-v2', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', null, '{}'::jsonb) $$,
  'P0001', null,
  'without an explicit early-SO request the FULL gate still blocks pending address/payment (existing behaviour)'
);

-- Autonomous authority stays service-only and Core-B-draft-only.
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select throws_ok(
  $$ select * from public.promote_sales_order_draft_to_order_governed_v1(
       'c6312000-0000-0000-0000-000000000102', 'mc631-early-v2', null, 'CORE-B_AUTONOMY', null,
       '{"autonomous":true,"readiness_gate":"SO_RECORDABLE"}'::jsonb) $$,
  'P0001', null,
  'service role cannot use the autonomous gate on a draft that is not a Core-B autonomy draft'
);
-- ---------------------------------------------------------------------------
-- 6/7. Unsupported orders are never created.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000103', 'mc631-no-company', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', null,
       '{"readiness_gate":"SO_RECORDABLE"}'::jsonb) $$,
  'P0001', 'DRAFT_NOT_READY',
  'no verified commercial customer (ambiguous/unknown) -> no SO'
);
select throws_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000104', 'mc631-unknown-sku', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', null,
       '{"readiness_gate":"SO_RECORDABLE"}'::jsonb) $$,
  'P0001', 'DRAFT_HAS_NO_VALID_LINES',
  'unknown SKU -> no invented line, no SO'
);
select throws_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000105', 'mc631-missing-qty', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', null,
       '{"readiness_gate":"SO_RECORDABLE"}'::jsonb) $$,
  'P0001', null,
  'missing quantity -> no SO (not defaulted to 1)'
);
select is(
  (select count(*) from public.sales_order_drafts where id in (
     'c6312000-0000-0000-0000-000000000103', 'c6312000-0000-0000-0000-000000000104', 'c6312000-0000-0000-0000-000000000105')
     and promoted_order_id is not null),
  0::bigint, 'none of the unsupported drafts produced an order'
);

-- ---------------------------------------------------------------------------
-- 1. Authorized human records the early SO with pending billing/delivery details.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000101', 'mc631-early-v1', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', 'early SO',
       '{"readiness_gate":"SO_RECORDABLE"}'::jsonb) $$,
  'authorized human records an early SO with address and payment terms pending'
);
select is((select status from public.sales_order_drafts where id = 'c6312000-0000-0000-0000-000000000101'), 'APPROVED_FOR_SO', 'draft reaches APPROVED_FOR_SO');
select ok((select promoted_order_id is not null from public.sales_order_drafts where id = 'c6312000-0000-0000-0000-000000000101'), 'a stable Sales Order reference exists');
select is(
  (select o.order_origin from public.orders o join public.sales_order_drafts d on d.promoted_order_id = o.id where d.id = 'c6312000-0000-0000-0000-000000000101'),
  'WHATSAPP', 'canonical order carries WhatsApp provenance'
);
select is(
  (select o.company_id::text from public.orders o join public.sales_order_drafts d on d.promoted_order_id = o.id where d.id = 'c6312000-0000-0000-0000-000000000101'),
  'c6312000-0000-0000-0000-000000000010', 'order is attributed to the verified commercial customer'
);
select ok(
  exists (select 1 from public.sales_order_draft_audit_log
           where draft_id = 'c6312000-0000-0000-0000-000000000101' and action = 'APPROVE'
             and metadata->>'human_early_so' = 'true' and metadata->>'readiness_gate' = 'SO_RECORDABLE'
             and actor_id = 'c6312000-0000-0000-0000-000000000001'),
  'audit log records the human early-SO actor and gate'
);

-- ---------------------------------------------------------------------------
-- 2/3. Downstream holds: delivery + billing are explicit open tasks with owners
--      and deadlines; no finance release, production release or dispatch.
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from public.sales_order_governance_pending_tasks t join public.sales_order_drafts d on d.promoted_order_id = t.order_id
    where d.id = 'c6312000-0000-0000-0000-000000000101' and t.status = 'OPEN'),
  2::bigint, 'exactly two open pending-detail holds (delivery, billing)'
);
select ok(
  exists (select 1 from public.sales_order_governance_pending_tasks t join public.sales_order_drafts d on d.promoted_order_id = t.order_id
           where d.id = 'c6312000-0000-0000-0000-000000000101' and t.readiness_gate = 'DISPATCH_READY'
             and t.hold_code = 'DELIVERY_DETAILS_PENDING' and t.owner_role = 'dispatch' and t.due_at > now()),
  'missing delivery address creates a DISPATCH_READY hold with owner and deadline'
);
select ok(
  exists (select 1 from public.sales_order_governance_pending_tasks t join public.sales_order_drafts d on d.promoted_order_id = t.order_id
           where d.id = 'c6312000-0000-0000-0000-000000000101' and t.readiness_gate = 'BILLING_READY'
             and t.hold_code = 'BILLING_DETAILS_PENDING' and t.owner_role = 'finance' and t.due_at > now()),
  'missing commercial/billing terms create a BILLING_READY hold with owner and deadline'
);
select ok(
  (select o.status = 'submitted' and o.finance_verified_at is null and coalesce(o.advance_paid, 0) = 0
     from public.orders o join public.sales_order_drafts d on d.promoted_order_id = o.id where d.id = 'c6312000-0000-0000-0000-000000000101'),
  'recording the SO does not verify finance, take payment or advance the order'
);
create temporary table mc631_release_probe(released boolean) on commit drop;
do $$
declare
  v_order uuid;
  v_result jsonb;
begin
  select promoted_order_id into v_order from public.sales_order_drafts where id = 'c6312000-0000-0000-0000-000000000101';
  begin
    v_result := public.release_order_to_manufacturing_v1(v_order);
  exception when others then
    v_result := jsonb_build_object('ok', false, 'raised', sqlerrm);
  end;
  insert into mc631_release_probe values (coalesce((v_result->>'ok')::boolean, false));
end $$;
select ok(not (select released from mc631_release_probe), 'finance/production release is refused without finance verification');
select is(
  (select o.status from public.orders o join public.sales_order_drafts d on d.promoted_order_id = o.id where d.id = 'c6312000-0000-0000-0000-000000000101'),
  'submitted', 'order is still submitted after the refused release attempt'
);

-- ---------------------------------------------------------------------------
-- 8. Duplicate message / retry: same order, same holds.
-- ---------------------------------------------------------------------------
select is(
  (select already_promoted from public.approve_sales_order_draft_for_so_atomic(
     'c6312000-0000-0000-0000-000000000101', 'mc631-early-v1', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', 'retry',
     '{"readiness_gate":"SO_RECORDABLE"}'::jsonb)),
  true, 'retry returns the existing order (already_promoted)'
);
select is(
  (select count(*) from public.orders where company_id = 'c6312000-0000-0000-0000-000000000010'),
  1::bigint, 'one order for the verified customer after retries'
);
select is(
  (select count(*) from public.sales_order_governance_pending_tasks t join public.sales_order_drafts d on d.promoted_order_id = t.order_id
    where d.id = 'c6312000-0000-0000-0000-000000000101'),
  2::bigint, 'retry does not duplicate holds'
);

-- ---------------------------------------------------------------------------
-- 9. Later verified details release only the matching hold, with evidence.
-- ---------------------------------------------------------------------------
create temporary table mc631_order(id uuid) on commit drop;
insert into mc631_order select promoted_order_id from public.sales_order_drafts where id = 'c6312000-0000-0000-0000-000000000101';

select throws_ok(
  $$ select * from public.resolve_sales_order_governance_pending_task_v1(
       (select id from mc631_order), 'DISPATCH_READY', 'DELIVERY_DETAILS_PENDING', '  ') $$,
  'P0001', 'RESOLUTION_EVIDENCE_REQUIRED', 'a hold cannot be released without evidence'
);
select lives_ok(
  $$ select * from public.resolve_sales_order_governance_pending_task_v1(
       (select id from mc631_order), 'DISPATCH_READY', 'DELIVERY_DETAILS_PENDING', 'Delivery address confirmed by customer on call') $$,
  'verified delivery details release the delivery hold'
);
select is(
  (select string_agg(t.readiness_gate || ':' || t.status, ',' order by t.readiness_gate) from public.sales_order_governance_pending_tasks t where t.order_id = (select id from mc631_order)),
  'BILLING_READY:OPEN,DISPATCH_READY:RESOLVED', 'only the matching hold is released; billing hold stays open'
);
select is((select o.status from public.orders o where o.id = (select id from mc631_order)), 'submitted', 'releasing a hold does not itself advance the order');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
select throws_ok(
  $$ select * from public.resolve_sales_order_governance_pending_task_v1(
       (select id from mc631_order), 'BILLING_READY', 'BILLING_DETAILS_PENDING', 'forged') $$,
  'P0001', 'NOT_AUTHORIZED', 'an unauthenticated caller cannot release a hold'
);

-- ---------------------------------------------------------------------------
-- 10. Existing (full-readiness) promotion keeps its governed behaviour.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'c6312000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal2')::text, true);
select lives_ok(
  $$ select * from public.approve_sales_order_draft_for_so_atomic(
       'c6312000-0000-0000-0000-000000000106', 'mc631-full-ready', 'c6312000-0000-0000-0000-000000000001', 'MC631 Promoter', null, '{}'::jsonb) $$,
  'a fully ready draft still promotes through the unchanged FULL gate'
);
select is(
  (select count(*) from public.sales_order_governance_pending_tasks t join public.sales_order_drafts d on d.promoted_order_id = t.order_id
    where d.id = 'c6312000-0000-0000-0000-000000000106'),
  0::bigint, 'a fully ready order creates no pending-detail holds'
);

select * from finish();
rollback;
