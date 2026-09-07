begin;

-- Behavioral coverage for 20260907144000_macro_inventory_factory_runtime_completion.sql,
-- 20260907144001_macro_inventory_factory_runtime_authority_wiring.sql, and
-- 20260907144002_validate_macro_inventory_runtime_constraints.sql.

select plan(30);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

create or replace function public.can_receive_b2b_inventory(_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select _user_id is not null;
$$;

create or replace function public.can_manage_b2b_inventory(_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select _user_id is not null;
$$;

insert into public.users (id, email, role)
values (
  '10000000-0000-0000-0000-000000000002',
  'macro-inv-completion@example.invalid',
  'STORE_INCHARGE'
);

insert into public.b2b_inventory_store_assignments (user_id, store_code, authority)
values ('10000000-0000-0000-0000-000000000002', 'FINISHED_GOODS', 'receive');

insert into public.products (id, name, sku, category, hsn_code)
values (
  '20000000-0000-0000-0000-000000000020',
  'Macro completion product',
  'MACRO-COMPLETE-SKU',
  'test',
  '0000'
);

insert into public.b2b_inventory_bins (
  id, store_code, zone_code, rack_code, shelf_code, bin_code, storage_class
) values
  ('51000000-0000-0000-0000-000000000001', 'FINISHED_GOODS', 'Z1', 'R1', 'S1', 'MC-BIN-A', 'ambient'),
  ('51000000-0000-0000-0000-000000000002', 'FINISHED_GOODS', 'Z1', 'R1', 'S2', 'MC-BIN-B', 'ambient');

-- Cross-store isolation: scoped user denied for unassigned store.
select throws_ok(
  $$ select public.reserve_rgs_stock(
    'MC-RES-ISO', NULL,
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU',
    1, 'RGS', 'mc-iso-reserve', 'normal', 'B2B_RAW',
    NULL, NULL, 'internal', 'MC-ISO-REQ'
  ) $$,
  '42501',
  null,
  'cross-store reservation is denied when actor lacks store assignment'
);

select throws_ok(
  $$ select * from public.select_inventory_lot_candidates(
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'B2B_RAW', 'fifo', 1
  ) $$,
  '42501',
  null,
  'scoped user is denied store-unauthorised lot candidate reads'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';

insert into public.users (id, email, role)
values (
  '10000000-0000-0000-0000-000000000003',
  'macro-inv-manager@example.invalid',
  'INVENTORY_MANAGER'
);

-- FIFO fixture receipt lines and put-away tasks for direct lot seeding.
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '61000000-0000-0000-0000-000000000099',
  'MC-FIFO-FIXTURE',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'MC-FIFO',
  'mc-fifo-fixture',
  'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty, accepted_qty, received_qty
) values
  (
    '71000000-0000-0000-0000-000000000099',
    '61000000-0000-0000-0000-000000000099',
    '20000000-0000-0000-0000-000000000020',
    'MACRO-COMPLETE-SKU',
    'FIFO-OLD',
    current_date + 20,
    5, 5, 5
  ),
  (
    '71000000-0000-0000-0000-000000000098',
    '61000000-0000-0000-0000-000000000099',
    '20000000-0000-0000-0000-000000000020',
    'MACRO-COMPLETE-SKU',
    'FIFO-NEW',
    current_date + 20,
    5, 5, 5
  );

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values
  (
    '81000000-0000-0000-0000-000000000001',
    '71000000-0000-0000-0000-000000000099',
    '51000000-0000-0000-0000-000000000001',
    'accepted', 5, 5, 'completed'
  ),
  (
    '81000000-0000-0000-0000-000000000002',
    '71000000-0000-0000-0000-000000000098',
    '51000000-0000-0000-0000-000000000002',
    'accepted', 5, 5, 'completed'
  );

-- FIFO: same expiry, earlier created_at wins.
insert into public.inventory_lot_positions (
  id, product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, available_qty, position_status, created_at
) values
  (
    'a1000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS',
    '51000000-0000-0000-0000-000000000001', 'FIFO-OLD', current_date + 20,
    '71000000-0000-0000-0000-000000000099', '81000000-0000-0000-0000-000000000001',
    5, 'available', now() - interval '2 days'
  ),
  (
    'a1000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS',
    '51000000-0000-0000-0000-000000000002', 'FIFO-NEW', current_date + 20,
    '71000000-0000-0000-0000-000000000098', '81000000-0000-0000-0000-000000000002',
    5, 'available', now() - interval '1 day'
  );

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS', 10);

select is(
  (select batch_lot from public.select_inventory_lot_candidates(
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS', 'fifo', 1
  ) limit 1),
  'FIFO-OLD',
  'FIFO selects oldest created lot when expiry ties'
);

-- Reserve, allocate (fifo), release lot allocations.
select lives_ok(
  $$ select public.reserve_rgs_stock(
    'MC-RES-LIFE', NULL,
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU',
    3, 'RGS', 'mc-life-reserve', 'normal', 'FINISHED_GOODS',
    NULL, NULL, 'internal', 'MC-LIFE-REQ'
  ) $$,
  'creates reservation for lifecycle path'
);

select lives_ok(
  $$ select public.allocate_lots_to_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-life-reserve'),
    3, 'fifo', 'mc-life-alloc'
  ) $$,
  'allocates lots using FIFO'
);

select is(
  (select batch_lot from public.inventory_reservation_allocations a
   join public.inventory_lot_positions lp on lp.id = a.inventory_entity_id
   where a.reservation_id = (select id from public.inventory_reservations where correlation_id = 'mc-life-reserve')
   limit 1),
  'FIFO-OLD',
  'FIFO allocation consumes oldest lot first'
);

select lives_ok(
  $$ select public.release_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-life-reserve'),
    3, 'customer_cancel', 'mc-life-release'
  ) $$,
  'releases reservation and lot allocations'
);

select is(
  (select available_qty from public.inventory_lot_positions where batch_lot = 'FIFO-OLD'),
  5::numeric,
  'lot release restores available quantity on FIFO-OLD'
);

select is(
  (select count(*)::int from public.inventory_reservation_allocations
   where reservation_id = (select id from public.inventory_reservations where correlation_id = 'mc-life-reserve')
     and allocation_status = 'released'),
  1,
  'lot allocation marked released after reservation release'
);

-- Pick + issue consumes picked lot quantity.
select lives_ok(
  $$ select public.reserve_rgs_stock(
    'MC-RES-ISSUE', NULL,
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU',
    2, 'RGS', 'mc-issue-reserve', 'normal', 'FINISHED_GOODS',
    NULL, NULL, 'internal', 'MC-ISSUE-REQ'
  ) $$,
  'creates reservation for issue path'
);

select lives_ok(
  $$ select public.allocate_lots_to_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-issue-reserve'),
    2, 'fifo', 'mc-issue-alloc'
  ) $$,
  'allocates lots before pick/issue'
);

select lives_ok(
  $$ select public.pick_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-issue-reserve'),
    2, 'mc-issue-pick'
  ) $$,
  'picks reservation with lot fulfillment'
);

select lives_ok(
  $$ select public.issue_rgs_stock(
    (select id from public.inventory_reservations where correlation_id = 'mc-issue-reserve'),
    2, 'internal', 'MC-ISSUE-DEST', 'mc-issue-event'
  ) $$,
  'issues stock and consumes picked lot quantity'
);

select is(
  (select picked_qty from public.inventory_lot_positions where batch_lot = 'FIFO-OLD'),
  0::numeric,
  'issue consumes picked lot quantity'
);

select cmp_ok(
  (select count(*)::int from public.inventory_movements where movement_type = 'lot_consumed'),
  '>=',
  1,
  'lot_consumed movement recorded on issue'
);

-- inventory_command_facts surfaces shortage and allocation facts.
select is(
  (select shortage_qty from public.inventory_command_facts
   where reservation_id = (select id from public.inventory_reservations where correlation_id = 'mc-life-reserve')),
  0::numeric,
  'command facts report zero shortage after full release'
);

select has_view('public', 'inventory_command_facts', 'inventory_command_facts view exists');

-- Lot exception quarantine moves qty out of available.
select lives_ok(
  $$ select public.record_inventory_lot_exception(
    'a1000000-0000-0000-0000-000000000002',
    'quarantine', 1, 'qc sample', 'mc-lot-qh-001'
  ) $$,
  'records lot quarantine exception'
);

select is(
  (select position_status from public.inventory_lot_positions where id = 'a1000000-0000-0000-0000-000000000002'),
  'quarantine',
  'lot exception sets quarantine position status'
);

select is(
  (select quarantine_qty from public.inventory_lot_positions where id = 'a1000000-0000-0000-0000-000000000002'),
  1::numeric,
  'lot exception records quarantine quantity on lot position'
);

select throws_ok(
  $$ select public.record_inventory_lot_exception(
    'a1000000-0000-0000-0000-000000000002',
    'release_quarantine', 2, 'excess release', 'mc-lot-qh-excess'
  ) $$,
  'P0001',
  'Release quantity exceeds lot quarantine quantity',
  'release_quarantine rejects quantity above lot quarantine_qty'
);

select lives_ok(
  $$ select public.record_inventory_lot_exception(
    'a1000000-0000-0000-0000-000000000002',
    'release_quarantine', 1, 'qc cleared', 'mc-lot-qh-release'
  ) $$,
  'release_quarantine succeeds for valid partial quantity'
);

select is(
  (select quarantine_qty from public.inventory_lot_positions where id = 'a1000000-0000-0000-0000-000000000002'),
  0::numeric,
  'release_quarantine decrements lot quarantine_qty'
);

-- Hold-only production receipt creates aggregate quarantine when no balance row exists.
insert into public.production_jobs (
  id, product_id, department, status
) values (
  'c1000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000020',
  'arabic_sweets',
  'completed'
);

insert into public.production_rgs_transfers (
  id, job_id, product_id, sku, quantity, status, destination_store_code,
  received_qty, correlation_id, batch_number
) values (
  'c2000000-0000-0000-0000-000000000001',
  'c1000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000020',
  'MACRO-HOLD-ONLY-SKU',
  5,
  'received',
  'FINISHED_GOODS',
  5,
  'mc-hold-only-transfer',
  'BATCH-HOLD-ONLY'
);

delete from public.inventory_stock_balances
where product_id = '20000000-0000-0000-0000-000000000020'
  and sku = 'MACRO-HOLD-ONLY-SKU'
  and location_code = 'FINISHED_GOODS';

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
    'c2000000-0000-0000-0000-000000000001',
    0, 0, 5, NULL, 'mc-hold-only-accept'
  ) $$,
  'hold-only production receipt accepts without prior balance row'
);

select is(
  (select quarantine_qty from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000020'
     and sku = 'MACRO-HOLD-ONLY-SKU'
     and location_code = 'FINISHED_GOODS'),
  5::numeric,
  'hold-only production receipt inserts aggregate quarantine_qty'
);

-- Multi-allocation issue caps consumption per lot without negative picked_qty.
select lives_ok(
  $$ select public.reserve_rgs_stock(
    'MC-RES-MULTI', NULL,
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU',
    8, 'RGS', 'mc-multi-reserve', 'normal', 'FINISHED_GOODS',
    NULL, NULL, 'internal', 'MC-MULTI-REQ'
  ) $$,
  'creates reservation spanning multiple lots'
);

select lives_ok(
  $$ select public.allocate_lots_to_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-multi-reserve'),
    8, 'fifo', 'mc-multi-alloc'
  ) $$,
  'allocates multiple fifo lots for one reservation'
);

select is(
  (select count(*)::int from public.inventory_reservation_allocations
   where reservation_id = (select id from public.inventory_reservations where correlation_id = 'mc-multi-reserve')
     and allocation_status = 'active'),
  2,
  'multi-lot allocation creates two active lot rows'
);

select lives_ok(
  $$ select public.pick_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-multi-reserve'),
    8, 'mc-multi-pick'
  ) $$,
  'picks multi-lot reservation'
);

select lives_ok(
  $$ select public.issue_rgs_stock(
    (select id from public.inventory_reservations where correlation_id = 'mc-multi-reserve'),
    8, 'internal', 'MC-MULTI-DEST', 'mc-multi-issue'
  ) $$,
  'issues multi-lot reservation without over-consuming picked quantities'
);

select cmp_ok(
  (select min(picked_qty) from public.inventory_lot_positions
   where sku = 'MACRO-COMPLETE-SKU' and batch_lot in ('FIFO-OLD', 'FIFO-NEW')),
  '>=',
  0::numeric,
  'multi-lot issue leaves no negative picked_qty on consumed lots'
);

-- GRN reversal path with lot depletion (separate mini receipt).
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id
) values (
  '61000000-0000-0000-0000-000000000001',
  'MC-REV-RECEIPT',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'MC-REV-001',
  'mc-rev-receipt'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty
) values (
  '71000000-0000-0000-0000-000000000001',
  '61000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000020',
  'MACRO-COMPLETE-SKU',
  'REV-BATCH',
  current_date + 15,
  4
);

select public.record_b2b_inventory_receipt(
  '61000000-0000-0000-0000-000000000001',
  '[{"line_id":"71000000-0000-0000-0000-000000000001","received_qty":4}]'::jsonb,
  'mc-rev-receipt'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
      '61000000-0000-0000-0000-000000000001',
      jsonb_build_array(jsonb_build_object(
        'line_id', '71000000-0000-0000-0000-000000000001',
        'accepted_qty', 4,
        'damaged_qty', 0,
        'rejected_qty', 0,
        'expected_balance_version', (
          select version from public.inventory_stock_balances
          where product_id = '20000000-0000-0000-0000-000000000020'
            and sku = 'MACRO-COMPLETE-SKU'
            and location_code = 'FINISHED_GOODS'
        )
      )),
      'mc-rev-receipt'
    ) $$,
  'accepts reversal-path receipt against current balance version'
);

select lives_ok(
  $$ select public.allocate_b2b_inventory_putaway(
    '61000000-0000-0000-0000-000000000001',
    '[{"line_id":"71000000-0000-0000-0000-000000000001","bin_id":"51000000-0000-0000-0000-000000000001","quantity":4,"disposition":"accepted"}]'::jsonb,
    'mc-rev-putaway'
  ) $$,
  'allocates put-away for reversal-path receipt'
);

select lives_ok(
  $$ select public.confirm_b2b_inventory_putaway(
    (select id from public.b2b_inventory_putaway_tasks where receipt_line_id = '71000000-0000-0000-0000-000000000001'),
    'MC-BIN-A', 4, 'mc-rev-confirm'
  ) $$,
  'confirms put-away for reversal-path receipt'
);

select lives_ok(
  $$ select public.finalise_b2b_inventory_grn(
    '61000000-0000-0000-0000-000000000001',
    'MC-GRN-REV',
    'mc-rev-grn'
  ) $$,
  'finalises GRN for reversal path'
);

select lives_ok(
  $$ select public.reverse_b2b_inventory_grn(
    (select id from public.b2b_inventory_grns where grn_number = 'MC-GRN-REV'),
    'MC-GRN-REV-R1', 'test reversal', 'mc-rev-grn-reverse'
  ) $$,
  'GRN reversal depletes lot positions'
);

select is(
  (select count(*)::int from public.inventory_lot_positions
   where batch_lot = 'REV-BATCH' and position_status = 'depleted'),
  1,
  'GRN reversal marks lot position depleted'
);

select * from finish();
rollback;
