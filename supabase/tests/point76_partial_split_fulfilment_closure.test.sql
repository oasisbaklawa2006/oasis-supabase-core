begin;
-- POINT76 — partial / split fulfilment canonical closure (evidence-only).
-- Census + behavioral pgTAP against existing deployed authority.
-- No new migration: active train remains #209→#215→#226→#228.
-- Synthetic fixtures only; no production mutation.
select plan(37);

-- =============================================================================
-- A. Census — partial / split fulfilment constructs on Core main
-- =============================================================================
select has_view(
  'public', 'b2b_dispatch_so_line_fulfilment',
  'census: SO-line fulfilment residual truth view exists'
);
select has_table(
  'public', 'b2b_dispatch_residual_closures',
  'census: governed residual-closure authority table exists'
);
select has_column(
  'public', 'b2b_dispatch_consignment_lines', 'original_order_qty',
  'census: consignment lines snapshot immutable ordered quantity'
);
select has_column(
  'public', 'b2b_dispatch_consignment_lines', 'selected_qty',
  'census: per-leg selected quantity exists'
);
select has_column(
  'public', 'b2b_dispatch_consignment_lines', 'accepted_ready_qty',
  'census: accepted-ready quantity exists'
);
select has_column(
  'public', 'b2b_dispatch_consignment_lines', 'packed_qty',
  'census: packed quantity exists'
);
select has_column(
  'public', 'b2b_dispatch_consignment_lines', 'loaded_qty',
  'census: loaded quantity exists'
);
select has_column(
  'public', 'b2b_dispatch_consignment_lines', 'dispatched_qty',
  'census: physically-dispatched quantity exists'
);
select has_function(
  'public', 'create_b2b_dispatch_consignment',
  'census: governed split-leg consignment entry RPC exists'
);
select has_function(
  'public', 'create_b2b_dispatch_shipment',
  'census: governed per-leg shipment RPC exists'
);
select has_function(
  'public', 'declare_b2b_dispatch_source_handoff',
  'census: factory source handoff RPC exists (Point87–98 execution lane — not Point76 owner)'
);
select has_function(
  'public', 'amend_sales_order_commercial_v1',
  'census: commercial amendment RPC exists (Point75 lane — separate from fulfilment)'
);
select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid = 'public.b2b_dispatch_consignment_lines'::regclass
      and tgname = 'trg_b2b_dispatch_line_allocation'
      and tgenabled <> 'D'
  ),
  'census: allocation guard trigger prevents cross-leg oversubscription'
);
select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid = 'public.b2b_dispatch_consignment_lines'::regclass
      and tgname = 'trg_b2b_dispatch_line_identity'
      and tgenabled <> 'D'
  ),
  'census: identity guard trigger prevents mutating original/selected quantities'
);
select has_table(
  'public', 'b2b_dispatch_events',
  'census: append-only dispatch audit/event provenance table exists'
);
select has_column(
  'public', 'inventory_reservations', 'fulfilled_qty',
  'census: RGS reservation fulfilled_qty exists (factory lane — not duplicated here)'
);
select has_column(
  'public', 'b2b_assembly_3pgs_requirements', 'fulfilled_qty',
  'census: P&A 3PGS requirement fulfilled_qty exists (factory lane — not duplicated here)'
);
select has_function(
  'public', 'can_verify_b2b_dispatch_finance',
  'census: finance clearance predicate exists for governed dispatch release'
);

-- =============================================================================
-- B. Fixtures — synthetic split-fulfilment order (30 units, two legs)
-- =============================================================================
insert into public.users (id, role) values
  ('76a00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('76a00000-0000-0000-0000-000000000002', 'OPERATIONS_MANAGER'),
  ('76a00000-0000-0000-0000-000000000003', 'SALES_EXECUTIVE');

insert into public.companies (id, business_name, phone)
values ('76b10000-0000-0000-0000-000000000001', 'Point76 Split Fulfil Test Co', '+91-9000000076');

insert into public.orders (
  id, order_number, tracking_token, company_id, sales_order_value, order_origin
) values (
  '76c30000-0000-0000-0000-000000000001', 'PGTAP-P76-ORD-1', 'pgtap-p76-token-1',
  '76b10000-0000-0000-0000-000000000001', 150000, 'SALES'
);

insert into public.products (id, name, category, sku, hsn_code)
values ('76d40000-0000-0000-0000-000000000001', 'Point76 Split Tray', 'sweets', 'P76-TRAY-1', '1905');

insert into public.order_items (id, order_id, product_id, quantity, carton_type)
values ('76e50000-0000-0000-0000-000000000001', '76c30000-0000-0000-0000-000000000001', '76d40000-0000-0000-0000-000000000001', 30, 'master_carton');

update public.orders set commercial_current_version = 0
where id = '76c30000-0000-0000-0000-000000000001';

insert into public.orders (
  id, order_number, tracking_token, company_id, sales_order_value, order_origin
) values (
  '76c30000-0000-0000-0000-000000000002', 'PGTAP-P76-ORD-2', 'pgtap-p76-token-2',
  '76b10000-0000-0000-0000-000000000001', 80000, 'SALES'
);
insert into public.order_items (id, order_id, product_id, quantity)
values ('76e50000-0000-0000-0000-000000000002', '76c30000-0000-0000-0000-000000000002', '76d40000-0000-0000-0000-000000000001', 25);
update public.orders set commercial_current_version = 0
where id = '76c30000-0000-0000-0000-000000000002';

insert into public.orders (
  id, order_number, tracking_token, company_id, sales_order_value, order_origin
) values (
  '76c30000-0000-0000-0000-000000000003', 'PGTAP-P76-ORD-3', 'pgtap-p76-token-3',
  '76b10000-0000-0000-0000-000000000001', 60000, 'SALES'
);
insert into public.order_items (id, order_id, product_id, quantity)
values ('76e50000-0000-0000-0000-000000000003', '76c30000-0000-0000-0000-000000000003', '76d40000-0000-0000-0000-000000000001', 20);
update public.orders set commercial_current_version = 0
where id = '76c30000-0000-0000-0000-000000000003';

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '76a00000-0000-0000-0000-000000000001';

-- =============================================================================
-- C. Multiple governed fulfilment legs — ordered vs committed vs residual
-- =============================================================================
select lives_ok(
  $$select public.create_b2b_dispatch_consignment(
    '76c30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '76e50000-0000-0000-0000-000000000001', 'selected_qty', 18)),
    'pgtap-p76-leg1'
  )$$,
  'split leg 1 (18 of 30) is created through governed RPC'
);
select is(
  (select selected_qty from public.b2b_dispatch_consignment_lines
   where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1')),
  18::numeric,
  'leg 1 records selected_qty 18 without mutating the commercial order line'
);
select is(
  (select original_order_qty from public.b2b_dispatch_consignment_lines
   where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1')),
  30::numeric,
  'leg 1 snapshots original_order_qty as the full immutable SO quantity (30), not the leg quantity'
);

select lives_ok(
  $$select public.create_b2b_dispatch_consignment(
    '76c30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '76e50000-0000-0000-0000-000000000001', 'selected_qty', 12)),
    'pgtap-p76-leg2'
  )$$,
  'split leg 2 (remaining 12 of 30) is created through governed RPC'
);

select is(
  (select original_order_qty::text || '|' || cumulative_dispatched_qty::text || '|' || residual_qty::text
   from public.b2b_dispatch_so_line_fulfilment
   where order_item_id = '76e50000-0000-0000-0000-000000000001'),
  '30|0|30',
  'before physical dispatch: ordered=30, fulfilled=0, residual=30 (commitment does not count as fulfilment)'
);

select is(
  (select quantity::numeric from public.order_items where id = '76e50000-0000-0000-0000-000000000001'),
  30::numeric,
  'commercial order_items.quantity is unchanged after split-leg commitment'
);

-- Simulate governed physical dispatch on leg 1 only (progress-chain respected).
update public.b2b_dispatch_consignment_lines
set accepted_ready_qty = 18, packed_qty = 18, loaded_qty = 18, dispatched_qty = 18
where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1');

select is(
  (select original_order_qty::text || '|' || cumulative_dispatched_qty::text || '|' || residual_qty::text
   from public.b2b_dispatch_so_line_fulfilment
   where order_item_id = '76e50000-0000-0000-0000-000000000001'),
  '30|18|12',
  'after partial physical dispatch: ordered=30, fulfilled=18, residual=12'
);

update public.b2b_dispatch_consignment_lines
set accepted_ready_qty = 12, packed_qty = 12, loaded_qty = 12, dispatched_qty = 12
where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg2');

select is(
  (select original_order_qty::text || '|' || cumulative_dispatched_qty::text || '|' || residual_qty::text
   from public.b2b_dispatch_so_line_fulfilment
   where order_item_id = '76e50000-0000-0000-0000-000000000001'),
  '30|30|0',
  'completion is only at zero residual once all legs are physically dispatched'
);

-- =============================================================================
-- D. Fail-closed guards — no double-count, no oversubscription, idempotent replay
-- =============================================================================
select throws_like(
  $$select public.create_b2b_dispatch_consignment(
    '76c30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '76e50000-0000-0000-0000-000000000001', 'selected_qty', 1)),
    'pgtap-p76-oversub'
  )$$,
  '%would exceed the remaining undispatched quantity%',
  'a third leg cannot oversubscribe the immutable ordered quantity'
);

select is(
  (select (public.create_b2b_dispatch_consignment(
    '76c30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '76e50000-0000-0000-0000-000000000001', 'selected_qty', 18)),
    'pgtap-p76-leg1'
  )).id),
  (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1'),
  'idempotent replay of leg 1 returns the same consignment without double-booking'
);

select throws_like(
  $$update public.b2b_dispatch_consignment_lines
    set original_order_qty = 25
    where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1')$$,
  '%immutable Sales Order line quantity%',
  'original_order_qty cannot be mutated to represent fulfilment'
);

select throws_like(
  $$update public.b2b_dispatch_consignment_lines
    set selected_qty = 17
    where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1')$$,
  '%selected quantity are immutable%',
  'selected_qty cannot be retroactively changed on an existing leg'
);

select throws_like(
  $$update public.b2b_dispatch_consignment_lines
    set dispatched_qty = 19
    where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-p76-leg1')
      and dispatched_qty = 18$$,
  '%progress_check%',
  'dispatched quantity cannot bypass the loaded-qty progress chain'
);

-- =============================================================================
-- E. Governed residual closure — finance/customer evidenced write-off path
-- =============================================================================

select lives_ok(
  $$select public.create_b2b_dispatch_consignment(
    '76c30000-0000-0000-0000-000000000002'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '76e50000-0000-0000-0000-000000000002', 'selected_qty', 25)),
    'pgtap-p76-residual-leg'
  )$$,
  'residual-closure fixture leg is created'
);

update public.b2b_dispatch_consignment_lines
set accepted_ready_qty = 15, packed_qty = 15, loaded_qty = 15, dispatched_qty = 15
where order_item_id = '76e50000-0000-0000-0000-000000000002';

select is(
  (select residual_qty from public.b2b_dispatch_so_line_fulfilment
   where order_item_id = '76e50000-0000-0000-0000-000000000002'),
  10::numeric,
  'partial dispatch leaves an exact 10-unit residual before closure'
);

set local request.jwt.claim.sub = '76a00000-0000-0000-0000-000000000002';
set local role authenticated;

select lives_ok(
  $$insert into public.b2b_dispatch_residual_closures (
    order_item_id, approved_closed_qty, reason, customer_evidence_ref,
    finance_adjustment_ref, approved_by, correlation_id
  ) values (
    '76e50000-0000-0000-0000-000000000002', 10,
    'Customer accepted short shipment with credit note',
    'cust-evidence-p76-1', 'finance-adj-p76-1',
    '76a00000-0000-0000-0000-000000000002', 'pgtap-p76-residual-close-1'
  )$$,
  'management can close residual demand with governed finance/customer evidence'
);

reset role;
set local request.jwt.claim.sub = '76a00000-0000-0000-0000-000000000001';

select is(
  (select approved_closed_qty::text || '|' || residual_qty::text
   from public.b2b_dispatch_so_line_fulfilment
   where order_item_id = '76e50000-0000-0000-0000-000000000002'),
  '10|0',
  'residual closure reduces residual to zero without mutating ordered quantity'
);

-- =============================================================================
-- F. Point75 separation — commercial amendment blocked once operations entered
-- =============================================================================
set local request.jwt.claim.sub = '76a00000-0000-0000-0000-000000000003';
set local role authenticated;

select throws_like(
  $$select * from public.amend_sales_order_commercial_v1(
    '76c30000-0000-0000-0000-000000000001'::uuid,
    0,
    jsonb_build_array(jsonb_build_object(
      'order_item_id', '76e50000-0000-0000-0000-000000000001',
      'product_id', '76d40000-0000-0000-0000-000000000001',
      'quantity', 28
    )),
    'attempted post-dispatch amendment',
    'pgtap-p76-amend-blocked',
    'pgtap-p76-amend-idem-1'
  )$$,
  '%SALES_ORDER_ALREADY_ENTERED_OPERATIONS%',
  'Point75 commercial amendment is blocked once split-fulfilment operations have started (Point76 preserves commercial source)'
);

-- =============================================================================
-- G. Cancelled legs do not consume allocation — residual demand is recoverable
-- =============================================================================
reset role;

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values (
  '76f60000-0000-0000-0000-000000000001', 'PGTAP-P76-ORD-3-DC-99', '76c30000-0000-0000-0000-000000000003',
  99, 'cancelled', 'road_transporter', 'pgtap-p76-cancelled-leg'
);
insert into public.b2b_dispatch_consignment_lines (
  consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty
) values (
  '76f60000-0000-0000-0000-000000000001', '76e50000-0000-0000-0000-000000000003',
  '76d40000-0000-0000-0000-000000000001', 'P76-TRAY-1', 'unit', 20, 20
);

set local request.jwt.claim.sub = '76a00000-0000-0000-0000-000000000001';
set local role authenticated;

select lives_ok(
  $$select public.create_b2b_dispatch_consignment(
    '76c30000-0000-0000-0000-000000000003'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '76e50000-0000-0000-0000-000000000003', 'selected_qty', 20)),
    'pgtap-p76-realloc-after-cancel'
  )$$,
  'cancelled legs do not consume allocation — full quantity remains available for a replacement leg'
);

select * from finish();
rollback;
