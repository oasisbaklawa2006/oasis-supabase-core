begin;
-- POINT85 — batch / shelf / FEFO / FIFO / location authority census + evidence.
-- Core main SHA at authoring: 50660644056a7a9c6bf5488264ad87595c706c58
-- Test-only closure: no migration SQL. Proves existing authority and gaps.

select plan(47);

-- =============================================================================
-- A. Census — receipt-line batch / expiry surfaces
-- =============================================================================
select has_column('public', 'b2b_inventory_receipt_lines', 'oasis_batch_lot', 'receipt lines carry oasis batch identity');
select has_column('public', 'b2b_inventory_receipt_lines', 'supplier_batch_lot', 'receipt lines carry supplier batch identity');
select has_column('public', 'b2b_inventory_receipt_lines', 'expiry_date', 'receipt lines carry expiry date');
select hasnt_column('public', 'b2b_inventory_receipt_lines', 'mfg_date', 'receipt lines do not yet carry mfg_date (Point85 gap)');
select hasnt_column('public', 'b2b_inventory_receipt_lines', 'best_before', 'receipt lines do not yet carry best_before (Point85 gap)');

-- =============================================================================
-- B. Census — shelf / bin / rack location model
-- =============================================================================
select has_table('public', 'b2b_inventory_bins', 'canonical bin registry exists');
select has_column('public', 'b2b_inventory_bins', 'zone_code', 'bins are zone-scoped, not free-text only');
select has_column('public', 'b2b_inventory_bins', 'rack_code', 'bins carry rack_code');
select has_column('public', 'b2b_inventory_bins', 'shelf_code', 'bins carry shelf_code');
select has_column('public', 'b2b_inventory_bins', 'bin_code', 'bins carry bin_code');
select has_column('public', 'b2b_inventory_bins', 'storage_class', 'bins carry governed storage_class including quarantine');

-- =============================================================================
-- C. Census — stock balance vs movement batch authority
-- =============================================================================
select has_column('public', 'inventory_movements', 'batch_lot', 'append-only ledger preserves batch_lot');
select has_column('public', 'inventory_movements', 'expiry_date', 'append-only ledger preserves expiry_date');
select hasnt_column('public', 'inventory_stock_balances', 'batch_lot', 'materialized balances are SKU+location only (batch gap)');
select hasnt_column('public', 'inventory_stock_balances', 'bin_id', 'materialized balances are not bin-bound (location gap)');
select hasnt_column('public', 'inventory_stock_balances', 'expiry_date', 'materialized balances do not carry expiry (FEFO gap)');

-- =============================================================================
-- D. Census — FEFO / FIFO / pick-candidate policy RPCs are absent
-- =============================================================================
select is(
  (select count(*)::int from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname ilike '%fefo%'),
  0,
  'no public FEFO selection RPC exists yet'
);
select is(
  (select count(*)::int from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname ilike '%fifo%'),
  0,
  'no public FIFO selection RPC exists yet'
);
select is(
  (select count(*)::int from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname ilike '%pick_candidate%'),
  0,
  'no public pick_candidate RPC exists yet'
);

-- =============================================================================
-- E. Census — governed put-away / GRN / exception surfaces
-- =============================================================================
select has_function('public', 'allocate_b2b_inventory_putaway', array['uuid','jsonb','text'], 'put-away allocation RPC exists');
select has_function('public', 'confirm_b2b_inventory_putaway', array['uuid','text','numeric','text'], 'put-away scan confirmation RPC exists');
select has_function('public', 'finalise_b2b_inventory_grn', array['uuid','text','text'], 'GRN finalisation RPC exists');
select has_function(
  'public',
  'record_b2b_3pgs_inventory_exception',
  array['uuid','text','text','text','numeric','text','text','jsonb'],
  '3PGS quarantine/damage exception RPC exists'
);
select has_column('public', 'inventory_stock_balances', 'quarantine_qty', 'quarantine bucket exists on balances');
select has_column('public', 'inventory_stock_balances', 'expired_qty', 'expired bucket exists on balances');

-- =============================================================================
-- F. Boundary — Point83 reservation / Point84 quantity truth (exist, not owned)
-- =============================================================================
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'reserve_rgs_stock'
  ),
  'Point83 reservation intake RPC is present'
);
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pick_rgs_reservation'
  ),
  'Point83 pick RPC is present'
);
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'accept_rgs_production_receipt'
  ),
  'Point84 quantity-custody RPC is present'
);

-- =============================================================================
-- Fixtures
-- =============================================================================
set local request.jwt.claim.sub = '85000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

create or replace function public.can_receive_b2b_inventory(_user_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select _user_id is not null $$;

create or replace function public.can_manage_b2b_inventory(_user_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select _user_id is not null $$;

insert into public.users (id, email, role, name)
values (
  '85000000-0000-0000-0000-000000000001',
  'point85-census@example.invalid',
  'INVENTORY_MANAGER',
  'Point85 census fixture'
);

insert into public.products (id, name, sku, category, hsn_code)
values (
  '85000000-0000-0000-0000-000000000010',
  'Point85 census product',
  'P85-CENSUS-SKU',
  'test',
  '0000'
);

-- Reservation fixtures use internal demand to avoid fabricated commercial order identity.
-- =============================================================================
-- G. Behavioral — multiple receipt batches collapse to one SKU/location balance
-- =============================================================================
insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id
)
values (
  '85000000-0000-0000-0000-000000000030',
  'P85-RECEIPT-BATCH',
  'opening_balance',
  '3PGS',
  'opening_balance_sheet',
  'P85-BATCH-CENSUS',
  'p85-batch-census'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expiry_date, expected_qty
)
values
  (
    '85000000-0000-0000-0000-000000000031',
    '85000000-0000-0000-0000-000000000030',
    '85000000-0000-0000-0000-000000000010',
    'P85-CENSUS-SKU',
    'P85-BATCH-EARLY',
    '2026-01-15',
    4
  ),
  (
    '85000000-0000-0000-0000-000000000032',
    '85000000-0000-0000-0000-000000000030',
    '85000000-0000-0000-0000-000000000010',
    'P85-CENSUS-SKU',
    'P85-BATCH-LATE',
    '2026-06-15',
    6
  );

select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
    '85000000-0000-0000-0000-000000000030',
    '[{"line_id":"85000000-0000-0000-0000-000000000031","received_qty":4},{"line_id":"85000000-0000-0000-0000-000000000032","received_qty":6}]'::jsonb,
    'p85-batch-census'
  ) $$,
  'records both batch lines on one receipt'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
    '85000000-0000-0000-0000-000000000030',
    '[{"line_id":"85000000-0000-0000-0000-000000000031","accepted_qty":4,"damaged_qty":0,"rejected_qty":0,"expected_balance_version":0},{"line_id":"85000000-0000-0000-0000-000000000032","accepted_qty":6,"damaged_qty":0,"rejected_qty":0,"expected_balance_version":0}]'::jsonb,
    'p85-batch-census'
  ) $$,
  'accepts both batches against one expected balance version'
);

select is(
  (select count(*)::int from public.inventory_stock_balances
   where product_id = '85000000-0000-0000-0000-000000000010'
     and sku = 'P85-CENSUS-SKU' and location_code = '3PGS'),
  1,
  'two receipt batches materialize as one SKU/location balance row'
);

select is(
  (select array_agg(batch_lot order by batch_lot)
   from public.inventory_movements
   where correlation_id like 'p85-batch-census:%' and movement_type = 'inventory_hold'),
  array['P85-BATCH-EARLY', 'P85-BATCH-LATE'],
  'hold ledger preserves per-batch lineage even though balance is aggregated'
);

select is(
  (select array_agg(expiry_date::text order by expiry_date)
   from public.inventory_movements
   where correlation_id like 'p85-batch-census:%' and movement_type = 'inventory_hold'),
  array['2026-01-15', '2026-06-15'],
  'hold ledger preserves per-batch expiry even without FEFO selection policy'
);

-- =============================================================================
-- H. Behavioral — put-away bin binding, disposition guard, scan confirm
-- =============================================================================
insert into public.b2b_inventory_bins (
  id, store_code, zone_code, rack_code, shelf_code, bin_code, storage_class
)
values
  (
    '85000000-0000-0000-0000-000000000040',
    '3PGS', 'Z1', 'R1', 'S1', 'P85-AMB-01', 'ambient'
  ),
  (
    '85000000-0000-0000-0000-000000000041',
    '3PGS', 'Z9', 'R9', 'S9', 'P85-QUA-01', 'quarantine'
  );

select throws_like(
  $$ select public.allocate_b2b_inventory_putaway(
    '85000000-0000-0000-0000-000000000030',
    jsonb_build_array(
      jsonb_build_object(
        'line_id', '85000000-0000-0000-0000-000000000031',
        'bin_id', '85000000-0000-0000-0000-000000000041',
        'quantity', 4,
        'disposition', 'accepted'
      ),
      jsonb_build_object(
        'line_id', '85000000-0000-0000-0000-000000000032',
        'bin_id', '85000000-0000-0000-0000-000000000040',
        'quantity', 6,
        'disposition', 'accepted'
      )
    ),
    'p85-putaway-alloc-1'
  ) $$,
  '%Disposition and bin storage class mismatch%',
  'accepted disposition cannot target a quarantine storage_class bin'
);

select lives_ok(
  $$ select public.allocate_b2b_inventory_putaway(
    '85000000-0000-0000-0000-000000000030',
    jsonb_build_array(
      jsonb_build_object(
        'line_id', '85000000-0000-0000-0000-000000000031',
        'bin_id', '85000000-0000-0000-0000-000000000040',
        'quantity', 4,
        'disposition', 'accepted'
      ),
      jsonb_build_object(
        'line_id', '85000000-0000-0000-0000-000000000032',
        'bin_id', '85000000-0000-0000-0000-000000000040',
        'quantity', 6,
        'disposition', 'accepted'
      )
    ),
    'p85-putaway-alloc-1'
  ) $$,
  'allocates accepted quantity to ambient bin'
);

select lives_ok(
  $$ select public.allocate_b2b_inventory_putaway(
    '85000000-0000-0000-0000-000000000030',
    jsonb_build_array(
      jsonb_build_object(
        'line_id', '85000000-0000-0000-0000-000000000031',
        'bin_id', '85000000-0000-0000-0000-000000000040',
        'quantity', 4,
        'disposition', 'accepted'
      ),
      jsonb_build_object(
        'line_id', '85000000-0000-0000-0000-000000000032',
        'bin_id', '85000000-0000-0000-0000-000000000040',
        'quantity', 6,
        'disposition', 'accepted'
      )
    ),
    'p85-putaway-alloc-1'
  ) $$,
  're-allocating with the same receipt/bin/disposition is idempotent'
);

select throws_like(
  $$ select public.confirm_b2b_inventory_putaway(
    (select id from public.b2b_inventory_putaway_tasks
     where receipt_line_id = '85000000-0000-0000-0000-000000000031' limit 1),
    'P85-WRONG-BIN',
    4,
    'p85-putaway-confirm-wrong'
  ) $$,
  '%Scanned bin does not match allocation%',
  'scan confirmation fails closed on bin mismatch'
);

select lives_ok(
  $$ select public.confirm_b2b_inventory_putaway(
    (select id from public.b2b_inventory_putaway_tasks
     where receipt_line_id = '85000000-0000-0000-0000-000000000031' limit 1),
    'P85-AMB-01',
    4,
    'p85-putaway-confirm-a'
  ) $$,
  'first batch line is scan-confirmed into the allocated ambient bin'
);

select lives_ok(
  $$ select public.confirm_b2b_inventory_putaway(
    (select id from public.b2b_inventory_putaway_tasks
     where receipt_line_id = '85000000-0000-0000-0000-000000000032' limit 1),
    'P85-AMB-01',
    6,
    'p85-putaway-confirm-b'
  ) $$,
  'second batch line is scan-confirmed into the same ambient bin'
);

select lives_ok(
  $$ select public.finalise_b2b_inventory_grn(
    '85000000-0000-0000-0000-000000000030',
    'P85-GRN-001',
    'p85-grn-finalise'
  ) $$,
  'GRN finalises after all put-away tasks complete'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where product_id = '85000000-0000-0000-0000-000000000010'
     and sku = 'P85-CENSUS-SKU' and location_code = '3PGS'),
  10::numeric,
  'GRN finalisation restores aggregate available quantity after governed put-away'
);

select is(
  (select count(*)::int from public.b2b_inventory_putaway_tasks t
   join public.b2b_inventory_receipt_lines l on l.id = t.receipt_line_id
   where l.receipt_id = '85000000-0000-0000-0000-000000000030'
     and t.status = 'completed'),
  2,
  'both batch put-away tasks reach completed status'
);

-- =============================================================================
-- I. Behavioral — cross-location isolation (Point85 vs Point83 location_code)
-- =============================================================================
insert into public.products (id, name, sku, category, hsn_code)
values (
  '85000000-0000-0000-0000-000000000011',
  'Point85 cross-location product',
  'P85-CROSS-LOC-SKU',
  'test',
  '0000'
)
on conflict do nothing;

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty, quarantine_qty)
values
  ('85000000-0000-0000-0000-000000000010', 'P85-CENSUS-SKU', 'FINISHED_GOODS', 12, 0),
  ('85000000-0000-0000-0000-000000000011', 'P85-CROSS-LOC-SKU', 'B2B_RAW', 8, 0)
on conflict (product_id, sku, location_code) do update
set available_qty = excluded.available_qty,
    quarantine_qty = excluded.quarantine_qty,
    reserved_qty = 0,
    picked_qty = 0,
    version = inventory_stock_balances.version + 1,
    updated_at = now();

select results_eq(
  $$ select reserved_qty from public.reserve_rgs_stock(
       'P85-RES-FG', null,
       '85000000-0000-0000-0000-000000000010', 'P85-CENSUS-SKU',
       5, 'RGS', 'p85-cross-fg', 'normal', 'FINISHED_GOODS',
       null, null, 'internal', 'P85-CROSS-FG'
     ) $$,
  $$ values (5::numeric) $$,
  'reservation consumes only FINISHED_GOODS available stock'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where sku = 'P85-CENSUS-SKU' and location_code = '3PGS'),
  10::numeric,
  'reserving FINISHED_GOODS does not leak into the 3PGS store balance'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where sku = 'P85-CROSS-LOC-SKU' and location_code = 'B2B_RAW'),
  8::numeric,
  'reserving FINISHED_GOODS does not leak into B2B_RAW'
);

-- =============================================================================
-- J. Behavioral — quarantine bucket is not allocatable by reserve_rgs_stock
-- =============================================================================
update public.inventory_stock_balances
set available_qty = 0,
    quarantine_qty = 20,
    reserved_qty = 5,
    version = version + 1,
    updated_at = now()
where sku = 'P85-CENSUS-SKU' and location_code = 'FINISHED_GOODS';

select results_eq(
  $$ select reserved_qty from public.reserve_rgs_stock(
       'P85-RES-QUAR', null,
       '85000000-0000-0000-0000-000000000010', 'P85-CENSUS-SKU',
       10, 'RGS', 'p85-quarantine-bucket', 'normal', 'FINISHED_GOODS',
       null, null, 'internal', 'P85-QUAR-BUCKET'
     ) $$,
  $$ values (0::numeric) $$,
  'reserve_rgs_stock does not allocate quarantine_qty when available_qty is zero'
);

select is(
  (select quarantine_qty from public.inventory_stock_balances
   where sku = 'P85-CENSUS-SKU' and location_code = 'FINISHED_GOODS'),
  20::numeric,
  'quarantine bucket remains untouched by reservation intake'
);

select * from finish();
rollback;
