begin;

-- Focused regression coverage for 20260907144007_macro_inventory_production_lot_consistency.sql.
select plan(31);

set local request.jwt.claim.sub = '11000000-0000-0000-0000-000000000001';
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
  '11000000-0000-0000-0000-000000000001',
  'macro-lot-consistency@example.invalid',
  'INVENTORY_MANAGER'
);

insert into public.products (id, name, sku, category, hsn_code)
values
  ('21000000-0000-0000-0000-000000000001', 'Assembly component', 'LOT-COMPONENT', 'test', '0000'),
  ('21000000-0000-0000-0000-000000000002', 'Assembly output', 'LOT-OUTPUT', 'test', '0000'),
  ('21000000-0000-0000-0000-000000000003', 'Damaged receipt output', 'LOT-DAMAGED', 'test', '0000'),
  ('21000000-0000-0000-0000-000000000004', 'Expired receipt output', 'LOT-EXPIRED', 'test', '0000'),
  ('21000000-0000-0000-0000-000000000005', 'Mixed hold receipt output', 'LOT-MIXED', 'test', '0000');

insert into public.b2b_inventory_bins (
  id, store_code, zone_code, rack_code, shelf_code, bin_code, storage_class
) values
  ('52000000-0000-0000-0000-000000000001', 'FINISHED_GOODS', 'ZC', 'RC', 'S1', 'LOT-AMBIENT-A', 'ambient'),
  ('52000000-0000-0000-0000-000000000002', 'FINISHED_GOODS', 'ZC', 'RC', 'S2', 'LOT-AMBIENT-B', 'ambient'),
  ('52000000-0000-0000-0000-000000000003', 'FINISHED_GOODS', 'ZC', 'RC', 'S3', 'LOT-DAMAGED-BIN', 'damaged');

-- Receipt/put-away lineage used by the three assembly component lots.
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id, status
) values (
  '62000000-0000-0000-0000-000000000001',
  'LOT-CONSISTENCY-RECEIPT', 'opening_balance', 'FINISHED_GOODS',
  'opening_balance_sheet', 'LOT-CONSISTENCY', 'lot-consistency-receipt', 'accepted'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date,
  expected_qty, accepted_qty, received_qty
) values
  ('72000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000001', 'LOT-COMPONENT', 'ISSUED-A', current_date + 30, 3, 3, 3),
  ('72000000-0000-0000-0000-000000000002', '62000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000001', 'LOT-COMPONENT', 'ISSUED-B', current_date + 30, 4, 4, 4),
  ('72000000-0000-0000-0000-000000000003', '62000000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000001', 'LOT-COMPONENT', 'UNRELATED-C', current_date + 30, 5, 5, 5);

insert into public.b2b_inventory_putaway_tasks (
  id, receipt_line_id, bin_id, disposition, allocated_qty, placed_qty, status
) values
  ('82000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001',
   '52000000-0000-0000-0000-000000000001', 'accepted', 3, 3, 'completed'),
  ('82000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000002',
   '52000000-0000-0000-0000-000000000002', 'accepted', 4, 4, 'completed'),
  ('82000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000003',
   '52000000-0000-0000-0000-000000000002', 'accepted', 5, 5, 'completed');

insert into public.inventory_lot_positions (
  id, product_id, sku, location_code, bin_id, batch_lot, expiry_date,
  receipt_line_id, putaway_task_id, available_qty, position_status, created_at
) values
  ('aa000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
   'LOT-COMPONENT', 'FINISHED_GOODS', '52000000-0000-0000-0000-000000000001',
   'ISSUED-A', current_date + 30, '72000000-0000-0000-0000-000000000001',
   '82000000-0000-0000-0000-000000000001', 3, 'available', now() - interval '3 days'),
  ('aa000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001',
   'LOT-COMPONENT', 'FINISHED_GOODS', '52000000-0000-0000-0000-000000000002',
   'ISSUED-B', current_date + 30, '72000000-0000-0000-0000-000000000002',
   '82000000-0000-0000-0000-000000000002', 4, 'available', now() - interval '2 days'),
  ('aa000000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000001',
   'LOT-COMPONENT', 'FINISHED_GOODS', '52000000-0000-0000-0000-000000000002',
   'UNRELATED-C', current_date + 30, '72000000-0000-0000-0000-000000000003',
   '82000000-0000-0000-0000-000000000003', 5, 'available', now() - interval '1 day');

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('21000000-0000-0000-0000-000000000001', 'LOT-COMPONENT', 'FINISHED_GOODS', 12);

RESET request.jwt.claim.sub;
RESET request.jwt.claim.role;

insert into public.orders (id, order_number, tracking_token, order_origin)
values ('31000000-0000-0000-0000-000000000001', 'LOT-CONSISTENCY-ORDER', 'lot-consistency-token', 'MANUAL');

set local request.jwt.claim.sub = '11000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.create_assembly_job(
    'LOT-CONSISTENCY-JOB',
    '31000000-0000-0000-0000-000000000001',
    '21000000-0000-0000-0000-000000000002',
    'LOT-OUTPUT', 1,
    jsonb_build_array(jsonb_build_object(
      'product_id', '21000000-0000-0000-0000-000000000001',
      'sku', 'LOT-COMPONENT',
      'source_store_code', 'FINISHED_GOODS',
      'required_qty', 5
    )),
    'lot-consistency-job-create', '1A', 'retail_pack'
  ) $$,
  'creates assembly job for lineage regression'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
    (select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB'),
    'normal', 'lot-consistency-reserve'
  ) $$,
  'reserves assembly component across FIFO lots'
);

select lives_ok(
  $$ select public.issue_assembly_components(
    (select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB'),
    'lot-consistency-issue'
  ) $$,
  'issues assembly component with durable lot lineage'
);

select is(
  (select count(*)::int from public.b2b_assembly_component_lot_issues
   where assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB')
   )),
  2,
  'issue lineage records only the two lots actually issued'
);

select is(
  (select sum(issued_qty) from public.b2b_assembly_component_lot_issues
   where assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB')
   )),
  5::numeric,
  'issue lineage totals the issued component quantity'
);

-- Simulate a missing aggregate row before a legitimate return. The return path must
-- recreate the aggregate row but may only restore lots previously issued to this component.
delete from public.inventory_stock_balances
where product_id = '21000000-0000-0000-0000-000000000001'
  and sku = 'LOT-COMPONENT'
  and location_code = 'FINISHED_GOODS';

select lives_ok(
  $$ select public.record_assembly_consumption(
    (select id from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB')),
    1, 0, 4, 'lot-consistency-return'
  ) $$,
  'assembly return recreates missing aggregate balance and restores issued lots'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where product_id = '21000000-0000-0000-0000-000000000001'
     and sku = 'LOT-COMPONENT' and location_code = 'FINISHED_GOODS'),
  4::numeric,
  'missing aggregate balance is recreated with returned quantity'
);

select is(
  (select sum(returned_qty) from public.b2b_assembly_component_lot_issues
   where assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB')
   )),
  4::numeric,
  'lineage records returned quantity across issued lots'
);

select is(
  (select count(*)::int from public.b2b_assembly_component_lot_issues where returned_qty > issued_qty),
  0,
  'no lot return can exceed its issued quantity'
);

select is(
  (select lp.available_qty
   from public.b2b_assembly_component_lot_issues i
   join public.inventory_lot_positions lp on lp.id = i.lot_position_id
   where i.assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (
       select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB'
     )
   )
     and lp.batch_lot = 'ISSUED-A'),
  (select i.returned_qty
   from public.b2b_assembly_component_lot_issues i
   join public.inventory_lot_positions lp on lp.id = i.lot_position_id
   where i.assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (
       select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB'
     )
   )
     and lp.batch_lot = 'ISSUED-A'),
  'depleted issued lot available equals lineage returned quantity'
);

select is(
  (select lp.available_qty
   from public.b2b_assembly_component_lot_issues i
   join public.inventory_lot_positions lp on lp.id = i.lot_position_id
   where i.assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (
       select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB'
     )
   )
     and lp.batch_lot = 'ISSUED-B'),
  (select 4::numeric - i.issued_qty + i.returned_qty
   from public.b2b_assembly_component_lot_issues i
   join public.inventory_lot_positions lp on lp.id = i.lot_position_id
   where i.assembly_component_id = (
     select id from public.b2b_assembly_components
     where assembly_job_id = (
       select id from public.b2b_assembly_jobs where assembly_job_number = 'LOT-CONSISTENCY-JOB'
     )
   )
     and lp.batch_lot = 'ISSUED-B'),
  'partial lot restores return only on issued lineage and preserves residual shelf qty'
);

select is((select available_qty from public.inventory_lot_positions where batch_lot = 'UNRELATED-C'), 5::numeric,
  'unrelated matching lot is never used for assembly return');

-- Production bucket classification fixtures.
insert into public.production_jobs (id, product_id, department, status)
values
  ('c1100000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000003', 'arabic_sweets', 'completed'),
  ('c1100000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000004', 'arabic_sweets', 'completed'),
  ('c1100000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000005', 'arabic_sweets', 'completed');

insert into public.production_rgs_transfers (
  id, job_id, product_id, sku, quantity, status, destination_store_code,
  received_qty, correlation_id, batch_number, destination_bin_id,
  expiry_date, manufactured_date, best_before_date
) values
  ('c2100000-0000-0000-0000-000000000001', 'c1100000-0000-0000-0000-000000000001',
   '21000000-0000-0000-0000-000000000003', 'LOT-DAMAGED', 5, 'received', 'FINISHED_GOODS',
   5, 'lot-damaged-transfer', 'DAMAGED-BATCH', '52000000-0000-0000-0000-000000000003',
   current_date + 20, current_date - 1, current_date + 19),
  ('c2100000-0000-0000-0000-000000000002', 'c1100000-0000-0000-0000-000000000002',
   '21000000-0000-0000-0000-000000000004', 'LOT-EXPIRED', 2, 'received', 'FINISHED_GOODS',
   2, 'lot-expired-transfer', 'EXPIRED-BATCH', '52000000-0000-0000-0000-000000000001',
   current_date - 1, current_date - 10, current_date - 1),
  ('c2100000-0000-0000-0000-000000000003', 'c1100000-0000-0000-0000-000000000003',
   '21000000-0000-0000-0000-000000000005', 'LOT-MIXED', 5, 'received', 'FINISHED_GOODS',
   5, 'lot-mixed-transfer', 'MIXED-BATCH', '52000000-0000-0000-0000-000000000001',
   current_date + 20, current_date - 1, current_date + 19);

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
    'c2100000-0000-0000-0000-000000000001', 5, 0, 0, 0, 'lot-damaged-accept'
  ) $$,
  'damaged-bin production receipt is accepted into damaged bucket'
);
select is((select damaged_qty from public.inventory_stock_balances where sku = 'LOT-DAMAGED'), 5::numeric,
  'aggregate damaged bucket receives accepted damaged stock');
select is((select available_qty from public.inventory_stock_balances where sku = 'LOT-DAMAGED'), 0::numeric,
  'aggregate available bucket excludes accepted damaged stock');
select is((select damaged_qty from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000001'), 5::numeric,
  'lot damaged bucket receives accepted damaged stock');
select is((select available_qty from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000001'), 0::numeric,
  'lot available bucket excludes accepted damaged stock');
select is((select position_status from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000001'), 'damaged',
  'damaged-bin lot is classified damaged');
select is((select reconciliation_status from public.inventory_lot_aggregate_reconciliation where sku = 'LOT-DAMAGED'), 'reconciled',
  'damaged receipt reconciles across lot and aggregate layers');

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
    'c2100000-0000-0000-0000-000000000002', 2, 0, 0, 0, 'lot-expired-accept'
  ) $$,
  'expired production receipt is accepted into expired bucket'
);
select is((select expired_qty from public.inventory_stock_balances where sku = 'LOT-EXPIRED'), 2::numeric,
  'aggregate expired bucket receives accepted expired stock');
select is((select expired_qty from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000002'), 2::numeric,
  'lot expired bucket receives accepted expired stock');
select is((select position_status from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000002'), 'expired',
  'expired lot is classified expired');
select is((select reconciliation_status from public.inventory_lot_aggregate_reconciliation where sku = 'LOT-EXPIRED'), 'reconciled',
  'expired receipt reconciles across lot and aggregate layers');

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
    'c2100000-0000-0000-0000-000000000003', 3, 0, 2, 0, 'lot-mixed-accept'
  ) $$,
  'available production receipt with QC hold splits available and quarantine buckets'
);
select is((select available_qty from public.inventory_stock_balances where sku = 'LOT-MIXED'), 3::numeric,
  'aggregate available bucket receives accepted good quantity');
select is((select quarantine_qty from public.inventory_stock_balances where sku = 'LOT-MIXED'), 2::numeric,
  'aggregate quarantine bucket receives held quantity');
select is((select available_qty from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000003'), 3::numeric,
  'lot available bucket receives accepted good quantity');
select is((select quarantine_qty from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000003'), 2::numeric,
  'lot quarantine bucket receives held quantity');
select is((select position_status from public.inventory_lot_positions where production_rgs_transfer_id = 'c2100000-0000-0000-0000-000000000003'), 'available',
  'mixed accepted-plus-hold lot remains eligible only through its available bucket');
select is((select reconciliation_status from public.inventory_lot_aggregate_reconciliation where sku = 'LOT-MIXED'), 'reconciled',
  'mixed receipt reconciles available and quarantine buckets');

select * from finish();
rollback;
