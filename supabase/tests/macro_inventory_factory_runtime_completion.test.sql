begin;

-- Behavioral coverage for 20260907144000_macro_inventory_factory_runtime_completion.sql,
-- 20260907144001_macro_inventory_factory_runtime_authority_wiring.sql,
-- 20260907144002_validate_macro_inventory_runtime_constraints.sql,
-- 20260907144003_macro_inventory_factory_runtime_gaps.sql,
-- 20260907144004_validate_macro_inventory_movement_type_extension.sql,
-- 20260907144005_macro_inventory_production_lot_runtime.sql, and
-- 20260907144006_validate_macro_inventory_production_lot_runtime.sql.

select plan(68);

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

insert into public.users (id, email, role)
values (
  '10000000-0000-0000-0000-000000000004',
  'macro-inv-rgs-admin@example.invalid',
  'RGS_ADMIN'
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

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000004';

select cmp_ok(
  (select count(*)::int from public.inventory_lot_positions where sku = 'MACRO-COMPLETE-SKU'),
  '>=',
  1,
  'RGS_ADMIN without store assignment can read lot positions via role-restricted RLS fallback'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';

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

delete from public.inventory_stock_balances
where product_id = '20000000-0000-0000-0000-000000000020'
  and sku = 'MACRO-COMPLETE-SKU'
  and location_code = 'FINISHED_GOODS';

select throws_ok(
  $$ select public.record_inventory_lot_exception(
    'a1000000-0000-0000-0000-000000000002',
    'release_quarantine', 1, 'missing balance', 'mc-lot-qh-no-bal'
  ) $$,
  'P0001',
  'Aggregate stock balance not found for quarantine release',
  'release_quarantine fails closed when aggregate balance row is missing'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty, quarantine_qty)
values ('20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS', 9, 1);

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

-- Partial reserve surfaces positive shortage_qty in command facts.
insert into public.products (id, name, sku, category, hsn_code)
values (
  '20000000-0000-0000-0000-000000000030',
  'Macro shortage product',
  'MACRO-SHORT-SKU',
  'test',
  '0000'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('20000000-0000-0000-0000-000000000030', 'MACRO-SHORT-SKU', 'FINISHED_GOODS', 2);

select lives_ok(
  $$ select public.reserve_rgs_stock(
    'MC-RES-SHORT', NULL,
    '20000000-0000-0000-0000-000000000030', 'MACRO-SHORT-SKU',
    5, 'RGS', 'mc-short-reserve', 'normal', 'FINISHED_GOODS',
    NULL, NULL, 'internal', 'MC-SHORT-REQ'
  ) $$,
  'partial reserve succeeds when available stock is insufficient'
);

select is(
  (select shortage_qty from public.inventory_command_facts
   where reservation_id = (select id from public.inventory_reservations where correlation_id = 'mc-short-reserve')),
  3::numeric,
  'command facts report positive shortage after partial reserve'
);

-- Assembly products required by fixture receipt lines below.
insert into public.products (id, name, sku, category, hsn_code, production_department)
values (
  '20000000-0000-0000-0000-000000000040',
  'Macro assembly output',
  'MACRO-ASM-OUT',
  'test',
  '0000',
  null
);

insert into public.products (id, name, sku, category, hsn_code, production_department)
values (
  '20000000-0000-0000-0000-000000000041',
  'Macro assembly component',
  'MACRO-ASM-COMP',
  'test',
  '0000',
  'arabic_sweets'
);

-- Fixture receipt lines for ad-hoc lot position inserts (receipt_line_id / putaway_task_id required).
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '61000000-0000-0000-0000-000000000003',
  'MC-LOT-FIXTURE',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'MC-LOT-FIX',
  'mc-lot-fixture',
  'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty, accepted_qty, received_qty
) values
  (
    '71100000-0000-0000-0000-000000000001',
    '61000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000020',
    'MACRO-COMPLETE-SKU',
    'BATCH-NOALLOC',
    current_date + 30,
    5, 5, 5
  ),
  (
    '71100000-0000-0000-0000-000000000002',
    '61000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000020',
    'MACRO-COMPLETE-SKU',
    'BATCH-DAMAGE',
    current_date + 30,
    4, 4, 4
  ),
  (
    '71100000-0000-0000-0000-000000000003',
    '61000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000020',
    'MACRO-COMPLETE-SKU',
    'BATCH-EXPIRE',
    current_date - 1,
    3, 3, 3
  ),
  (
    '71100000-0000-0000-0000-000000000004',
    '61000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000041',
    'MACRO-ASM-COMP',
    'BATCH-ASM',
    current_date + 25,
    6, 6, 6
  );

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values
  (
    '81100000-0000-0000-0000-000000000001',
    '71100000-0000-0000-0000-000000000001',
    '51000000-0000-0000-0000-000000000001',
    'accepted', 5, 5, 'completed'
  ),
  (
    '81100000-0000-0000-0000-000000000002',
    '71100000-0000-0000-0000-000000000002',
    '51000000-0000-0000-0000-000000000001',
    'accepted', 4, 4, 'completed'
  ),
  (
    '81100000-0000-0000-0000-000000000003',
    '71100000-0000-0000-0000-000000000003',
    '51000000-0000-0000-0000-000000000002',
    'accepted', 3, 3, 'completed'
  ),
  (
    '81100000-0000-0000-0000-000000000004',
    '71100000-0000-0000-0000-000000000004',
    '51000000-0000-0000-0000-000000000001',
    'accepted', 6, 6, 'completed'
  );

-- Pick/issue fail closed when lot positions exist without lot allocations.
insert into public.inventory_lot_positions (
  id, product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, available_qty, position_status
) values (
  'a1000000-0000-0000-0000-000000000012',
  '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS',
  '51000000-0000-0000-0000-000000000001', 'BATCH-NOALLOC', current_date + 30,
  '71100000-0000-0000-0000-000000000001', '81100000-0000-0000-0000-000000000001',
  5, 'available'
);

update public.inventory_stock_balances
set available_qty = available_qty + 5
where product_id = '20000000-0000-0000-0000-000000000020'
  and sku = 'MACRO-COMPLETE-SKU'
  and location_code = 'FINISHED_GOODS';

select lives_ok(
  $$ select public.reserve_rgs_stock(
    'MC-RES-NOALLOC', NULL,
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU',
    1, 'RGS', 'mc-noalloc-reserve', 'normal', 'FINISHED_GOODS',
    NULL, NULL, 'internal', 'MC-NOALLOC-REQ'
  ) $$,
  'creates reservation without lot allocation for fail-closed pick test'
);

select throws_ok(
  $$ select public.pick_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'mc-noalloc-reserve'),
    1, 'mc-noalloc-pick'
  ) $$,
  'P0001',
  'Lot-tracked stock requires active lot allocations covering pick quantity',
  'pick fails closed without lot allocations when lots exist'
);

select throws_ok(
  $$ select public.issue_rgs_stock(
    (select id from public.inventory_reservations where correlation_id = 'mc-noalloc-reserve'),
    1, 'internal', 'MC-NOALLOC-DEST', 'mc-noalloc-issue'
  ) $$,
  'P0001',
  'Lot-tracked stock requires lot allocations covering issue quantity',
  'issue fails closed without lot allocations when lots exist'
);

-- damage_writeoff and expire_writeoff lot exception paths.
insert into public.inventory_lot_positions (
  id, product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, available_qty, position_status
) values
  (
    'a1000000-0000-0000-0000-000000000010',
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS',
    '51000000-0000-0000-0000-000000000001', 'BATCH-DAMAGE', current_date + 30,
    '71100000-0000-0000-0000-000000000002', '81100000-0000-0000-0000-000000000002',
    4, 'available'
  ),
  (
    'a1000000-0000-0000-0000-000000000011',
    '20000000-0000-0000-0000-000000000020', 'MACRO-COMPLETE-SKU', 'FINISHED_GOODS',
    '51000000-0000-0000-0000-000000000002', 'BATCH-EXPIRE', current_date - 1,
    '71100000-0000-0000-0000-000000000003', '81100000-0000-0000-0000-000000000003',
    3, 'available'
  );

update public.inventory_stock_balances
set available_qty = available_qty + 7,
    damaged_qty = 0,
    expired_qty = 0
where product_id = '20000000-0000-0000-0000-000000000020'
  and sku = 'MACRO-COMPLETE-SKU'
  and location_code = 'FINISHED_GOODS';

select lives_ok(
  $$ select public.record_inventory_lot_exception(
    'a1000000-0000-0000-0000-000000000010',
    'damage_writeoff', 2, 'damaged in transit', 'mc-lot-damage-001'
  ) $$,
  'records damage_writeoff lot exception'
);

select is(
  (select damaged_qty from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000020'
     and sku = 'MACRO-COMPLETE-SKU'
     and location_code = 'FINISHED_GOODS'),
  2::numeric,
  'damage_writeoff increments aggregate damaged_qty'
);

select lives_ok(
  $$ select public.record_inventory_lot_exception(
    'a1000000-0000-0000-0000-000000000011',
    'expire_writeoff', 1, 'expired stock', 'mc-lot-expire-001'
  ) $$,
  'records expire_writeoff lot exception'
);

select is(
  (select expired_qty from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000020'
     and sku = 'MACRO-COMPLETE-SKU'
     and location_code = 'FINISHED_GOODS'),
  1::numeric,
  'expire_writeoff increments aggregate expired_qty'
);

-- qc_hold GRN posting syncs aggregate quarantine_qty.
insert into public.products (id, name, sku, category, hsn_code)
values (
  '20000000-0000-0000-0000-000000000031',
  'Macro qc hold product',
  'MACRO-QH-SKU',
  'test',
  '0000'
);

insert into public.b2b_inventory_bins (
  id, store_code, zone_code, rack_code, shelf_code, bin_code, storage_class
) values (
  '51000000-0000-0000-0000-000000000003', 'FINISHED_GOODS', 'Z1', 'R1', 'S3', 'MC-BIN-QH', 'quarantine'
);

insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '61000000-0000-0000-0000-000000000002',
  'MC-QH-RECEIPT',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'MC-QH',
  'mc-qh-receipt',
  'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty, accepted_qty, received_qty
) values (
  '71000000-0000-0000-0000-000000000002',
  '61000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000031',
  'MACRO-QH-SKU',
  'BATCH-QH-GRN',
  current_date + 45,
  3, 0, 3
);

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values (
  '81000000-0000-0000-0000-000000000003',
  '71000000-0000-0000-0000-000000000002',
  '51000000-0000-0000-0000-000000000003',
  'qc_hold', 3, 3, 'completed'
);

insert into public.b2b_inventory_grns (
  id, grn_number, receipt_id, status, correlation_id, stock_posted_at, stock_posted_by
) values (
  '90000000-0000-0000-0000-000000000001',
  'MC-GRN-QH',
  '61000000-0000-0000-0000-000000000002',
  'finalised',
  'mc-qh-grn',
  now(),
  '10000000-0000-0000-0000-000000000003'
);

select lives_ok(
  $$ select public.post_grn_inventory_lot_positions(
    '90000000-0000-0000-0000-000000000001',
    'mc-qh-grn-post'
  ) $$,
  'posts qc_hold lot positions from GRN put-away'
);

select is(
  (select quarantine_qty from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000031'
     and sku = 'MACRO-QH-SKU'
     and location_code = 'FINISHED_GOODS'),
  3::numeric,
  'qc_hold GRN posting syncs aggregate quarantine_qty'
);

select lives_ok(
  $$ select public.post_grn_inventory_lot_positions(
    '90000000-0000-0000-0000-000000000001',
    'mc-qh-grn-post'
  ) $$,
  'qc_hold GRN post replay is idempotent'
);

select is(
  (select quarantine_qty from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000031'
     and sku = 'MACRO-QH-SKU'
     and location_code = 'FINISHED_GOODS'),
  3::numeric,
  'qc_hold GRN replay does not double-count aggregate quarantine_qty'
);

-- P&A reserve/issue keeps lot positions coherent with aggregate balances.
RESET request.jwt.claim.sub;
RESET request.jwt.claim.role;

insert into public.orders (id, order_number, tracking_token, order_origin)
values (
  '30000000-0000-0000-0000-000000000001',
  'MC-ASM-ORD-1',
  'mc-asm-fixture-token',
  'MANUAL'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';

insert into public.inventory_lot_positions (
  id, product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, available_qty, position_status, created_at
) values (
  'a1000000-0000-0000-0000-000000000020',
  '20000000-0000-0000-0000-000000000041', 'MACRO-ASM-COMP', 'FINISHED_GOODS',
  '51000000-0000-0000-0000-000000000001', 'BATCH-ASM', current_date + 25,
  '71100000-0000-0000-0000-000000000004', '81100000-0000-0000-0000-000000000004',
  6, 'available', now() - interval '3 days'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('20000000-0000-0000-0000-000000000041', 'MACRO-ASM-COMP', 'FINISHED_GOODS', 6);

select lives_ok(
  $$ select public.create_assembly_job(
    'MC-ASM-JOB-1',
    '30000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000040',
    'MACRO-ASM-OUT',
    1,
    jsonb_build_array(jsonb_build_object(
      'product_id', '20000000-0000-0000-0000-000000000041',
      'sku', 'MACRO-ASM-COMP',
      'source_store_code', 'FINISHED_GOODS',
      'required_qty', 2
    )),
    'mc-asm-create',
    '1A',
    'retail_pack'
  ) $$,
  'creates assembly job for lot-tracked component path'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
    (select id from public.b2b_assembly_jobs where assembly_job_number = 'MC-ASM-JOB-1'),
    'normal', 'mc-asm-reserve'
  ) $$,
  'reserve_assembly_components succeeds on lot-tracked SKU'
);

select is(
  (select reserved_qty from public.inventory_lot_positions where batch_lot = 'BATCH-ASM'),
  2::numeric,
  'assembly reserve syncs lot reserved_qty'
);

select lives_ok(
  $$ select public.issue_assembly_components(
    (select id from public.b2b_assembly_jobs where assembly_job_number = 'MC-ASM-JOB-1'),
    'mc-asm-issue'
  ) $$,
  'issue_assembly_components succeeds on lot-tracked SKU'
);

select is(
  (select reserved_qty from public.inventory_lot_positions where batch_lot = 'BATCH-ASM'),
  0::numeric,
  'assembly issue clears lot reserved_qty'
);

-- Production receipt acceptance posts bin-bound lot positions with lineage.
insert into public.products (id, name, sku, category, hsn_code)
values (
  '20000000-0000-0000-0000-000000000050',
  'Macro production lot product',
  'MACRO-PROD-LOT-SKU',
  'test',
  '0000'
);

insert into public.production_jobs (
  id, product_id, department, status
) values (
  'c1000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000050',
  'arabic_sweets',
  'completed'
);

insert into public.production_rgs_transfers (
  id, job_id, product_id, sku, quantity, status, destination_store_code,
  received_qty, correlation_id, batch_number, destination_bin_id,
  expiry_date, manufactured_date, best_before_date
) values (
  'c2000000-0000-0000-0000-000000000002',
  'c1000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000050',
  'MACRO-PROD-LOT-SKU',
  8,
  'received',
  'FINISHED_GOODS',
  8,
  'mc-prod-lot-transfer',
  'BATCH-PROD-LOT',
  '51000000-0000-0000-0000-000000000001',
  current_date + 20,
  current_date - 2,
  current_date + 18
);

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
    'c2000000-0000-0000-0000-000000000002',
    8, 0, 0, 0, 'mc-prod-lot-accept'
  ) $$,
  'production receipt with destination bin posts lot layer'
);

select is(
  (select available_qty from public.inventory_lot_positions
   where production_rgs_transfer_id = 'c2000000-0000-0000-0000-000000000002'),
  8::numeric,
  'production receipt creates lot position bound to transfer'
);

select is(
  (select manufactured_date from public.inventory_lot_positions
   where production_rgs_transfer_id = 'c2000000-0000-0000-0000-000000000002'),
  current_date - 2,
  'production receipt lot propagates manufactured_date'
);

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
    'c2000000-0000-0000-0000-000000000002',
    8, 0, 0, 0, 'mc-prod-lot-accept'
  ) $$,
  'production receipt lot post replay is idempotent'
);

select is(
  (select count(*)::int from public.inventory_lot_positions
   where production_rgs_transfer_id = 'c2000000-0000-0000-0000-000000000002'),
  1,
  'production receipt replay does not duplicate lot rows'
);

-- Assembly consumption return restores depleted lot available_qty.
select lives_ok(
  $$ select public.record_assembly_consumption(
    (select id from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'MC-ASM-JOB-1')),
    1, 0, 1, 'mc-asm-return-lot'
  ) $$,
  'record_assembly_consumption with return succeeds on lot-tracked component'
);

select is(
  (select available_qty from public.inventory_lot_positions where batch_lot = 'BATCH-ASM'),
  5::numeric,
  'assembly return syncs lot available_qty after issue residue'
);

-- 3PGS component shortfall raises governed requirement, not production job.
insert into public.products (id, name, sku, category, hsn_code)
values (
  '20000000-0000-0000-0000-000000000051',
  'Macro 3PGS ribbon',
  'MACRO-3PGS-RIBBON',
  'test',
  '0000'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('20000000-0000-0000-0000-000000000051', 'MACRO-3PGS-RIBBON', '3PGS', 0);

RESET request.jwt.claim.sub;
RESET request.jwt.claim.role;

insert into public.orders (id, order_number, tracking_token, order_origin)
values (
  '30000000-0000-0000-0000-000000000002',
  'MC-3PGS-ORD-1',
  'mc-3pgs-fixture-token',
  'MANUAL'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.create_assembly_job(
    'MC-3PGS-JOB-1',
    '30000000-0000-0000-0000-000000000002',
    '20000000-0000-0000-0000-000000000040',
    'MACRO-ASM-OUT',
    1,
    jsonb_build_array(jsonb_build_object(
      'product_id', '20000000-0000-0000-0000-000000000051',
      'sku', 'MACRO-3PGS-RIBBON',
      'source_store_code', '3PGS',
      'required_qty', 4
    )),
    'mc-3pgs-create'
  ) $$,
  'creates assembly job with 3PGS-sourced component'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
    (select id from public.b2b_assembly_jobs where assembly_job_number = 'MC-3PGS-JOB-1'),
    'normal', 'mc-3pgs-reserve'
  ) $$,
  'reserve_assembly_components raises 3PGS requirement instead of production shortage'
);

select is(
  (select count(*)::int from public.b2b_assembly_3pgs_requirements
   where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'MC-3PGS-JOB-1')),
  1,
  '3PGS shortfall creates governed b2b_assembly_3pgs_requirements row'
);

select is(
  (select count(*)::int from public.production_jobs
   where product_id = '20000000-0000-0000-0000-000000000051'),
  0,
  '3PGS component shortfall does not route to production_jobs'
);

select * from finish();
rollback;
