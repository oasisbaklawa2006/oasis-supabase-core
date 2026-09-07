begin;

-- Behavioral coverage for 20260907143000_macro_inventory_lot_position_runtime.sql
-- and 20260907144002_validate_macro_inventory_runtime_constraints.sql,
-- 20260907144005_macro_inventory_production_lot_runtime.sql, and
-- 20260907144006_validate_macro_inventory_production_lot_runtime.sql.

select plan(29);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

create or replace function public.can_receive_b2b_inventory(_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select _user_id is not null;
$$;

create or replace function public.can_manage_b2b_inventory(_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select _user_id is not null;
$$;

create or replace function public.can_access_b2b_inventory_store(
  p_user_id uuid, p_store_code text, p_required_authority text
) returns boolean language sql stable security definer set search_path = '' as $$
  select p_user_id is not null;
$$;

insert into public.users (id, email, role)
values (
  '10000000-0000-0000-0000-000000000001',
  'lot-runtime-test@example.invalid',
  'INVENTORY_MANAGER'
);

insert into public.products (id, name, sku, category, hsn_code)
values
  (
    '20000000-0000-0000-0000-000000000010',
    'Lot runtime test product',
    'LOT-RUNTIME-TEST',
    'test',
    '0000'
  ),
  (
    '20000000-0000-0000-0000-000000000011',
    'Lot exclusion test product',
    'LOT-EXCLUSION-TEST',
    'test',
    '0000'
  );

insert into public.b2b_inventory_bins (
  id, store_code, zone_code, rack_code, shelf_code, bin_code, storage_class
) values
  ('50000000-0000-0000-0000-000000000001', 'FINISHED_GOODS', 'Z1', 'R1', 'S1', 'BIN-A', 'ambient'),
  ('50000000-0000-0000-0000-000000000002', 'FINISHED_GOODS', 'Z1', 'R1', 'S2', 'BIN-B', 'ambient'),
  ('50000000-0000-0000-0000-000000000003', 'FINISHED_GOODS', 'Z2', 'R2', 'S1', 'BIN-Q', 'quarantine'),
  ('50000000-0000-0000-0000-000000000004', 'FINISHED_GOODS', 'Z3', 'R3', 'S1', 'BIN-REJ', 'rejected'),
  ('50000000-0000-0000-0000-000000000005', 'FINISHED_GOODS', 'Z3', 'R3', 'S2', 'BIN-RTV', 'return_to_vendor');

-- Receipt with two batches: earlier expiry and later expiry.
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id
) values (
  '60000000-0000-0000-0000-000000000001',
  'LOT-RECEIPT-001',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'LOT-TEST-001',
  'lot-runtime-receipt-001'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date,
  manufactured_date, best_before_date, expected_qty
) values
  (
    '70000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000010',
    'LOT-RUNTIME-TEST',
    'BATCH-EARLY',
    current_date + 10,
    current_date - 5,
    current_date + 8,
    5
  ),
  (
    '70000000-0000-0000-0000-000000000002',
    '60000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000010',
    'LOT-RUNTIME-TEST',
    'BATCH-LATE',
    current_date + 30,
    5
  );

select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
    '60000000-0000-0000-0000-000000000001',
    '[{"line_id":"70000000-0000-0000-0000-000000000001","received_qty":5},{"line_id":"70000000-0000-0000-0000-000000000002","received_qty":5}]'::jsonb,
    'lot-runtime-receipt-001'
  ) $$,
  'records receipt lines for lot runtime golden path'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
    '60000000-0000-0000-0000-000000000001',
    '[{"line_id":"70000000-0000-0000-0000-000000000001","accepted_qty":5,"damaged_qty":0,"rejected_qty":0,"expected_balance_version":0},{"line_id":"70000000-0000-0000-0000-000000000002","accepted_qty":5,"damaged_qty":0,"rejected_qty":0,"expected_balance_version":0}]'::jsonb,
    'lot-runtime-receipt-001'
  ) $$,
  'accepts receipt and holds aggregate stock until GRN'
);

-- Put-away allocations and confirmations.
select lives_ok(
  $$ select public.allocate_b2b_inventory_putaway(
    '60000000-0000-0000-0000-000000000001',
    '[{"line_id":"70000000-0000-0000-0000-000000000001","bin_id":"50000000-0000-0000-0000-000000000001","quantity":5,"disposition":"accepted"},{"line_id":"70000000-0000-0000-0000-000000000002","bin_id":"50000000-0000-0000-0000-000000000002","quantity":5,"disposition":"accepted"}]'::jsonb,
    'lot-runtime-putaway-001'
  ) $$,
  'allocates put-away to two bins'
);

select lives_ok(
  $$ select public.confirm_b2b_inventory_putaway(
    (select id from public.b2b_inventory_putaway_tasks where receipt_line_id = '70000000-0000-0000-0000-000000000001'),
    'BIN-A', 5, 'lot-runtime-confirm-a'
  ) $$,
  'confirms early-expiry batch put-away'
);

select lives_ok(
  $$ select public.confirm_b2b_inventory_putaway(
    (select id from public.b2b_inventory_putaway_tasks where receipt_line_id = '70000000-0000-0000-0000-000000000002'),
    'BIN-B', 5, 'lot-runtime-confirm-b'
  ) $$,
  'confirms late-expiry batch put-away'
);

select lives_ok(
  $$ select public.finalise_b2b_inventory_grn(
    '60000000-0000-0000-0000-000000000001',
    'GRN-LOT-001',
    'lot-runtime-grn-001'
  ) $$,
  'finalises GRN and posts lot positions'
);

select is(
  (select count(*)::int from public.inventory_lot_positions
   where sku = 'LOT-RUNTIME-TEST' and position_status = 'available'),
  2,
  'creates two available lot positions after GRN'
);

select is(
  (select sum(available_qty) from public.inventory_lot_positions
   where sku = 'LOT-RUNTIME-TEST'),
  10::numeric,
  'lot position available quantity reconciles to accepted quantity'
);

select is(
  (select manufactured_date from public.inventory_lot_positions where batch_lot = 'BATCH-EARLY'),
  current_date - 5,
  'GRN lot posting propagates manufactured_date lineage'
);

select is(
  (select best_before_date from public.inventory_lot_positions where batch_lot = 'BATCH-EARLY'),
  current_date + 8,
  'GRN lot posting propagates best_before_date lineage'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where sku = 'LOT-RUNTIME-TEST' and location_code = 'FINISHED_GOODS'),
  10::numeric,
  'aggregate balance available after GRN matches lot total'
);

-- FEFO selection: earliest expiry first.
select is(
  (select batch_lot from public.select_inventory_lot_candidates(
    '20000000-0000-0000-0000-000000000010', 'LOT-RUNTIME-TEST', 'FINISHED_GOODS', 'fefo', 1
  ) limit 1),
  'BATCH-EARLY',
  'FEFO selects earliest-expiry batch first'
);

-- Reserve and allocate lots atomically.
select lives_ok(
  $$ select public.reserve_rgs_stock(
    'LOT-RES-001', NULL,
    '20000000-0000-0000-0000-000000000010', 'LOT-RUNTIME-TEST',
    7, 'RGS', 'lot-runtime-reserve-001', 'normal', 'FINISHED_GOODS',
    NULL, NULL, 'internal', 'LOT-INTERNAL-REQ-001'
  ) $$,
  'creates aggregate reservation for lot allocation'
);

select lives_ok(
  $$ select public.allocate_lots_to_reservation(
    (select id from public.inventory_reservations where correlation_id = 'lot-runtime-reserve-001'),
    7, 'fefo', 'lot-runtime-alloc-001'
  ) $$,
  'atomically allocates lots to reservation using FEFO'
);

select is(
  (select sum(allocated_qty) from public.inventory_reservation_allocations
   where reservation_id = (select id from public.inventory_reservations where correlation_id = 'lot-runtime-reserve-001')
     and allocation_status = 'active'),
  7::numeric,
  'active lot allocations sum to requested allocate quantity'
);

select is(
  (select batch_lot from public.inventory_reservation_allocations a
   join public.inventory_lot_positions lp on lp.id = a.inventory_entity_id
   where a.reservation_id = (select id from public.inventory_reservations where correlation_id = 'lot-runtime-reserve-001')
     and a.allocated_qty = 5),
  'BATCH-EARLY',
  'FEFO allocation consumes entire early-expiry lot first'
);

-- Idempotent replay of allocation.
select is(
  (select count(*)::int from public.allocate_lots_to_reservation(
    (select id from public.inventory_reservations where correlation_id = 'lot-runtime-reserve-001'),
    7, 'fefo', 'lot-runtime-alloc-001'
  )),
  2,
  'idempotent allocation replay returns existing allocations without duplicating'
);

-- Fail-closed: expired lot excluded from candidates.
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '60000000-0000-0000-0000-000000000002',
  'LOT-RECEIPT-EXPIRED',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'LOT-TEST-EXPIRED',
  'lot-runtime-expired',
  'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty, accepted_qty, received_qty
) values (
  '70000000-0000-0000-0000-000000000003',
  '60000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000011',
  'LOT-EXCLUSION-TEST',
  'BATCH-EXPIRED',
  current_date - 1,
  3, 3, 3
);

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values (
  '80000000-0000-0000-0000-000000000001',
  '70000000-0000-0000-0000-000000000003',
  '50000000-0000-0000-0000-000000000001',
  'accepted', 3, 3, 'completed'
);

insert into public.b2b_inventory_grns (
  id, grn_number, receipt_id, status, correlation_id, stock_posted_at, stock_posted_by
) values (
  '90000000-0000-0000-0000-000000000001',
  'GRN-EXPIRED',
  '60000000-0000-0000-0000-000000000002',
  'finalised',
  'lot-runtime-grn-expired',
  now(),
  '10000000-0000-0000-0000-000000000001'
);

insert into public.inventory_lot_positions (
  product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, grn_id, available_qty, position_status
) values (
  '20000000-0000-0000-0000-000000000011', 'LOT-EXCLUSION-TEST', 'FINISHED_GOODS',
  '50000000-0000-0000-0000-000000000001', 'BATCH-EXPIRED', current_date - 1,
  '70000000-0000-0000-0000-000000000003', '80000000-0000-0000-0000-000000000001',
  '90000000-0000-0000-0000-000000000001', 3, 'available'
);

select is(
  (select count(*)::int from public.select_inventory_lot_candidates(
    '20000000-0000-0000-0000-000000000011', 'LOT-EXCLUSION-TEST', 'FINISHED_GOODS', 'fefo', NULL
  ) where batch_lot = 'BATCH-EXPIRED'),
  0,
  'expired lot positions are excluded from FEFO/FIFO candidates'
);

-- Quarantine bin exclusion (separate SKU so reconciliation is unaffected).
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '60000000-0000-0000-0000-000000000003',
  'LOT-RECEIPT-QH',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'LOT-TEST-QH',
  'lot-runtime-qh',
  'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty, accepted_qty, received_qty
) values (
  '70000000-0000-0000-0000-000000000004',
  '60000000-0000-0000-0000-000000000003',
  '20000000-0000-0000-0000-000000000011',
  'LOT-EXCLUSION-TEST',
  'BATCH-QH',
  current_date + 60,
  2, 2, 2
);

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values (
  '80000000-0000-0000-0000-000000000002',
  '70000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000003',
  'accepted', 2, 2, 'completed'
);

insert into public.inventory_lot_positions (
  product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, available_qty, storage_class, position_status
) values (
  '20000000-0000-0000-0000-000000000011', 'LOT-EXCLUSION-TEST', 'FINISHED_GOODS',
  '50000000-0000-0000-0000-000000000003', 'BATCH-QH', current_date + 60,
  '70000000-0000-0000-0000-000000000004',
  '80000000-0000-0000-0000-000000000002',
  2, 'quarantine', 'available'
);

select is(
  (select count(*)::int from public.select_inventory_lot_candidates(
    '20000000-0000-0000-0000-000000000011', 'LOT-EXCLUSION-TEST', 'FINISHED_GOODS', 'fefo', NULL
  ) where batch_lot = 'BATCH-QH'),
  0,
  'quarantine storage class is fail-closed from candidate selection'
);

-- Pick fulfills lot allocations.
select lives_ok(
  $$ select public.pick_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'lot-runtime-reserve-001'),
    7, 'lot-runtime-pick-001'
  ) $$,
  'pick fulfills lot allocations and moves aggregate reserved to picked'
);

select is(
  (select sum(picked_qty) from public.inventory_lot_positions
   where sku = 'LOT-RUNTIME-TEST' and batch_lot in ('BATCH-EARLY', 'BATCH-LATE')),
  7::numeric,
  'lot picked quantities reconcile to pick quantity'
);

select is(
  (select count(*)::int from public.inventory_reservation_allocations
   where reservation_id = (select id from public.inventory_reservations where correlation_id = 'lot-runtime-reserve-001')
     and allocation_status = 'fulfilled'),
  2,
  'all lot allocations marked fulfilled after pick'
);

-- Reconciliation view.
select is(
  (select reconciliation_status from public.inventory_lot_aggregate_reconciliation
   where sku = 'LOT-RUNTIME-TEST' and location_code = 'FINISHED_GOODS'
   limit 1),
  'reconciled',
  'lot aggregate reconciliation view reports reconciled state'
);

-- rejected/return_to_vendor storage classes map to quarantine position_status on GRN post.
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '60000000-0000-0000-0000-000000000004',
  'LOT-RECEIPT-RTV',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'LOT-TEST-RTV',
  'lot-runtime-rtv',
  'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty, accepted_qty, received_qty
) values
  (
    '70000000-0000-0000-0000-000000000005',
    '60000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000011',
    'LOT-EXCLUSION-TEST',
    'BATCH-REJ',
    current_date + 30,
    2, 2, 2
  ),
  (
    '70000000-0000-0000-0000-000000000006',
    '60000000-0000-0000-0000-000000000004',
    '20000000-0000-0000-0000-000000000011',
    'LOT-EXCLUSION-TEST',
    'BATCH-RTV',
    current_date + 30,
    1, 1, 1
  );

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values
  (
    '80000000-0000-0000-0000-000000000003',
    '70000000-0000-0000-0000-000000000005',
    '50000000-0000-0000-0000-000000000004',
    'accepted', 2, 2, 'completed'
  ),
  (
    '80000000-0000-0000-0000-000000000004',
    '70000000-0000-0000-0000-000000000006',
    '50000000-0000-0000-0000-000000000005',
    'accepted', 1, 1, 'completed'
  );

insert into public.b2b_inventory_grns (
  id, grn_number, receipt_id, status, correlation_id, stock_posted_at, stock_posted_by
) values (
  '90000000-0000-0000-0000-000000000002',
  'GRN-RTV-MAP',
  '60000000-0000-0000-0000-000000000004',
  'finalised',
  'lot-runtime-grn-rtv',
  now(),
  '10000000-0000-0000-0000-000000000001'
);

select lives_ok(
  $$ select public.post_grn_inventory_lot_positions(
    '90000000-0000-0000-0000-000000000002',
    'lot-runtime-rtv-post'
  ) $$,
  'posts lot positions for rejected/return_to_vendor bins'
);

select is(
  (select position_status from public.inventory_lot_positions where batch_lot = 'BATCH-REJ'),
  'quarantine',
  'rejected storage_class maps to quarantine position_status'
);

select is(
  (select position_status from public.inventory_lot_positions where batch_lot = 'BATCH-RTV'),
  'quarantine',
  'return_to_vendor storage_class maps to quarantine position_status'
);

select has_function('public', 'allocate_lots_to_reservation', 'allocate_lots_to_reservation RPC exists');
select has_function('public', 'select_inventory_lot_candidates', 'select_inventory_lot_candidates RPC exists');
select has_view('public', 'inventory_lot_aggregate_reconciliation', 'reconciliation view exists');

select * from finish();
rollback;
