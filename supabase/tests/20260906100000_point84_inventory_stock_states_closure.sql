-- Point 84 — canonical inventory stock states closure audit.
-- Evidence-only: census of governed quantity surfaces + synthetic behavioral
-- invariants. No migration SQL; reservation concurrency (Point 83) and
-- batch/FEFO/location policy (Point 85) are explicitly out of scope here.
begin;

select plan(48);

-- =============================================================================
-- A. Census — canonical quantity/state surfaces on Core main
-- =============================================================================

select has_table(
  'public', 'inventory_stock_balances',
  'inventory_stock_balances is the canonical per-store quantity ledger'
);

select has_column(
  'public', 'inventory_stock_balances', 'available_qty',
  'available bucket: sellable/unallocated stock at a location'
);

select has_column(
  'public', 'inventory_stock_balances', 'reserved_qty',
  'reserved bucket: stock allocated to demand but not yet picked/issued'
);

select has_column(
  'public', 'inventory_stock_balances', 'picked_qty',
  'picked bucket: stock picked for issue but not yet acknowledged out'
);

select has_column(
  'public', 'inventory_stock_balances', 'damaged_qty',
  'damaged bucket: excluded from B2B availability, reported separately'
);

select has_column(
  'public', 'inventory_stock_balances', 'expired_qty',
  'expired bucket: excluded from B2B availability, reported separately'
);

select has_column(
  'public', 'inventory_stock_balances', 'quarantine_qty',
  'quarantine/blocked bucket: QC hold stock excluded from sellable availability'
);

select ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'inventory_stock_balances'
      and column_name = 'on_hand_qty'
  ),
  'on_hand is derived (available+reserved+picked custody), not a persisted duplicate column'
);

select has_view(
  'public', 'b2b_order_availability',
  'b2b_order_availability is the governed B2B read model over stock balances'
);

select has_table(
  'public', 'inventory_reservations',
  'inventory_reservations tracks booked demand and fulfilment/release quantities'
);

select has_table(
  'public', 'production_rgs_transfers',
  'production_rgs_transfers holds expected/in-transit production receipts before posting'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.inventory_stock_balances'::regclass
      and conname = 'inventory_stock_balances_available_qty_check'
      and contype = 'c'
  ),
  'available_qty is guarded by a non-negative check constraint'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.inventory_reservations'::regclass
      and conname = 'inventory_reservations_qty_coherent'
      and contype = 'c'
  ),
  'reservation rows enforce reserved+fulfilled+released <= requested'
);

select ok(
  not has_table_privilege('authenticated', 'public.inventory_stock_balances', 'UPDATE'),
  'stock balance mutations are RPC-governed, not direct authenticated UPDATE'
);

select ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'inventory_stock_balances'
      and column_name = 'batch_lot'
  ),
  'batch/lot identity is out of Point 84 scope (Point 85 location/FEFO policy)'
);

-- =============================================================================
-- Fixtures
-- =============================================================================

insert into public.users (id, role) values
  ('84000000-0000-0000-0000-000000000001', 'RGS_ADMIN'),
  ('84000000-0000-0000-0000-000000000002', 'PROD_ARABIC'),
  ('84000000-0000-0000-0000-000000000003', 'STORE_READY_GOODS'),
  ('84000000-0000-0000-0000-000000000004', 'ADMIN');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('84100000-0000-0000-0000-000000000001', 'Point84 Baklawa Tray', 'sweets', 'P84-TRAY', '1905', 'arabic_sweets'),
  ('84100000-0000-0000-0000-000000000002', 'Point84 Carton', 'packaging', 'P84-CARTON', '4823', null),
  ('84100000-0000-0000-0000-000000000003', 'Point84 Non-B2B Item', 'packaging', 'P84-NONB2B', '4823', null);

insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('84200000-0000-0000-0000-000000000001', 'PGTAP-P84-ORD-1', 'pgtap-p84-token-1', 'MANUAL'),
  ('84200000-0000-0000-0000-000000000002', 'PGTAP-P84-ORD-2', 'pgtap-p84-token-2', 'MANUAL');

insert into public.b2b_inventory_item_profiles (
  product_id, sku, item_class, primary_store_code, provenance_required, b2b_relevant, b2b_saleable
) values
  ('84100000-0000-0000-0000-000000000001', 'P84-TRAY', 'sourced_ready_product', 'FINISHED_GOODS', true, true, true),
  ('84100000-0000-0000-0000-000000000002', 'P84-CARTON', 'packaging_material', '3PGS', false, true, true),
  ('84100000-0000-0000-0000-000000000003', 'P84-NONB2B', 'packaging_material', '3PGS', false, false, false);

insert into public.inventory_stock_balances (
  product_id, sku, location_code, available_qty, reserved_qty, picked_qty,
  damaged_qty, expired_qty, quarantine_qty
) values
  ('84100000-0000-0000-0000-000000000001', 'P84-TRAY', 'FINISHED_GOODS', 10, 5, 2, 1, 0, 1),
  ('84100000-0000-0000-0000-000000000001', 'P84-TRAY', '3PGS', 25, 0, 0, 0, 0, 0),
  ('84100000-0000-0000-0000-000000000002', 'P84-CARTON', '3PGS', 8, 0, 0, 2, 1, 1);

insert into public.factory_inventory (product_id, quantity)
values ('84100000-0000-0000-0000-000000000001', 100);

-- =============================================================================
-- B. State arithmetic / non-negative invariants (synthetic)
-- =============================================================================

select is(
  (
    select (available_qty + reserved_qty + picked_qty)::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '17',
  'custody on-hand at a location is available+reserved+picked (17 = 10+5+2)'
);

select is(
  (
    select (available_qty + reserved_qty + picked_qty + damaged_qty + expired_qty + quarantine_qty)::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '19',
  'physical total includes exclusion buckets without double-deducting available (19 = 17+1+0+1)'
);

select throws_ok(
  $$
  insert into public.inventory_stock_balances (
    product_id, sku, location_code, available_qty
  ) values (
    '84100000-0000-0000-0000-000000000002', 'P84-CARTON', 'B2B_RAW', -1
  )
  $$,
  23514,
  NULL,
  'negative available_qty is rejected by the balance check constraint'
);

select ok(
  (
    select count(*) = 2
    from public.inventory_stock_balances
    where sku = 'P84-TRAY'
  ),
  'the same SKU at FINISHED_GOODS and 3PGS is stored as isolated balance rows'
);

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = '3PGS'
  ),
  '25',
  '3PGS balance is independent of FINISHED_GOODS mutations on the same SKU'
);

-- =============================================================================
-- C. B2B availability read model — exclusion buckets, non-replenishable filter
-- =============================================================================

select results_eq(
  $$
  select available_qty::text, available_for_b2b_qty::text, unavailable_qty::text
  from public.b2b_order_availability
  where sku = 'P84-CARTON' and store_code = '3PGS'
  $$,
  $$ values ('8', '8', '4') $$,
  'B2B availability reports damaged+expired+quarantine in unavailable_qty without subtracting them twice from available_for_b2b'
);

select is(
  (
    select count(*)::int
    from public.b2b_order_availability
    where sku = 'P84-NONB2B'
  ),
  0,
  'non-b2b-relevant items are excluded from the governed availability view (non-replenishable to B2B)'
);

update public.factory_inventory
set quantity = 999
where product_id = '84100000-0000-0000-0000-000000000001';

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '10',
  'legacy factory_inventory projection changes do not mutate canonical inventory_stock_balances'
);

-- =============================================================================
-- D. Reservation / release / pick / issue quantity effects (Point 84 truth)
-- =============================================================================

set local request.jwt.claim.sub = '84000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

update public.inventory_stock_balances
set available_qty = 20, reserved_qty = 0, picked_qty = 0, version = version + 1
where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS';

select results_eq(
  $$
  select reserved_qty::text, reservation_status
  from public.reserve_rgs_stock(
    'RES-P84-A', '84200000-0000-0000-0000-000000000001', '84100000-0000-0000-0000-000000000001',
    'P84-TRAY', 12, 'ARABIC_SWEETS', 'corr-p84-reserve-a'
  )
  $$,
  $$ values ('12', 'reserved') $$,
  'reservation moves stock from available into reserved when fully covered'
);

select is(
  (
    select available_qty::text || '|' || reserved_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '8|12',
  'after reserve: available decreases and reserved increases by the reserved amount'
);

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = '3PGS'
  ),
  '25',
  'reserving at FINISHED_GOODS does not debit an isolated 3PGS balance for the same SKU'
);

select results_eq(
  $$
  select reserved_qty::text, released_qty::text
  from public.release_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'corr-p84-reserve-a'),
    4, 'order_amended', 'corr-p84-release-a'
  )
  $$,
  $$ values ('8', '4') $$,
  'release returns quantity from reserved to available without double-counting'
);

select is(
  (
    select available_qty::text || '|' || reserved_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '12|8',
  'released quantity is credited back to available (12 = 8+4) while reserved drops to 8'
);

select results_eq(
  $$
  select reserved_qty::text, released_qty::text
  from public.release_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'corr-p84-reserve-a'),
    4, 'order_amended', 'corr-p84-release-a'
  )
  $$,
  $$ values ('8', '4') $$,
  'idempotent release retry preserves settled reservation quantities (Point 83 concurrency tested elsewhere)'
);

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '12',
  'idempotent release retry does not credit available stock a second time'
);

select lives_ok(
  $$
  select public.pick_rgs_reservation(
    (select id from public.inventory_reservations where correlation_id = 'corr-p84-reserve-a'),
    3, 'corr-p84-pick-a'
  )
  $$,
  'pick transfers quantity from reserved into picked without leaving custody'
);

select is(
  (
    select reserved_qty::text || '|' || picked_qty::text ||
      '|' || (available_qty + reserved_qty + picked_qty)::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '5|3|20',
  'pick reduces reserved and increases picked while custody on-hand stays at 20'
);

select lives_ok(
  $$
  select public.issue_rgs_stock(
    (select id from public.inventory_reservations where correlation_id = 'corr-p84-reserve-a'),
    3, 'outlet', 'OUTLET-P84-1', 'corr-p84-issue-a'
  )
  $$,
  'issue consumes picked/reserved custody and records fulfilment on the reservation'
);

select is(
  (
    select (b.available_qty + b.reserved_qty + b.picked_qty)::text || '|' ||
      r.fulfilled_qty::text
    from public.inventory_stock_balances b
    join public.inventory_reservations r
      on r.product_id = b.product_id
     and r.sku = b.sku
     and r.location_code = b.location_code
    where r.correlation_id = 'corr-p84-reserve-a'
  ),
  '17|3',
  'issue reduces store custody by the issued quantity and increments reservation fulfilled_qty'
);

select is(
  (
    select (
      requested_qty - reserved_qty - fulfilled_qty - released_qty
    )::text
    from public.inventory_reservations
    where correlation_id = 'corr-p84-reserve-a'
  ),
  '0',
  'after reserve+release+issue the reservation open gap is zero (all quantity is reserved, released, or fulfilled)'
);

-- =============================================================================
-- E. Expected / in-transit production stock is separated from on-hand balances
-- =============================================================================

update public.inventory_stock_balances
set available_qty = 0, reserved_qty = 0, picked_qty = 0, version = version + 1
where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS';

set local request.jwt.claim.sub = '84000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select results_eq(
  $$
  select reserved_qty::text, reservation_status
  from public.reserve_rgs_stock(
    'RES-P84-INTRANSIT', '84200000-0000-0000-0000-000000000002', '84100000-0000-0000-0000-000000000001',
    'P84-TRAY', 6, 'ARABIC_SWEETS', 'corr-p84-intransit'
  )
  $$,
  $$ values ('0', 'pending') $$,
  'with zero available stock the reservation stays pending and posts no on-hand movement'
);

select is(
  (
    select (
      requested_qty - reserved_qty - fulfilled_qty - released_qty
    )::text
    from public.inventory_reservations
    where correlation_id = 'corr-p84-intransit'
  ),
  '6',
  'derived open shortage on a pending reservation equals the full unmet requested quantity'
);

select results_eq(
  $$
  select assigned_qty::text, status
  from public.create_production_shortage_demand(
    (select id from public.inventory_reservations where correlation_id = 'corr-p84-intransit'),
    'ARABIC_SWEETS', 'normal', 'corr-p84-intransit-shortage'
  )
  $$,
  $$ values ('6', 'pending') $$,
  'expected production demand routes the exact 6kg shortage, not on-hand stock'
);

set local request.jwt.claim.sub = '84000000-0000-0000-0000-000000000002';

select lives_ok(
  $$ select public.start_production_job(
       (select id from public.production_jobs where correlation_id = 'corr-p84-intransit-shortage'),
       'corr-p84-intransit-start'
     ) $$,
  'production job enters in_production without posting to inventory_stock_balances'
);

select lives_ok(
  $$ select public.record_production_output(
       (select id from public.production_jobs where correlation_id = 'corr-p84-intransit-shortage'),
       6, 0, 'BATCH-P84-1', 'corr-p84-intransit-output'
     ) $$,
  'production output is recorded on the job ledger only'
);

select lives_ok(
  $$ select public.declare_production_ready(
       (select id from public.production_jobs where correlation_id = 'corr-p84-intransit-shortage'),
       'corr-p84-intransit-ready'
     ) $$,
  'declaring ready does not post accepted stock to the store balance'
);

set local request.jwt.claim.sub = '84000000-0000-0000-0000-000000000003';

select lives_ok(
  $$ select public.dispatch_production_to_rgs(
       (select id from public.production_jobs where correlation_id = 'corr-p84-intransit-shortage'),
       5.8, 'corr-p84-intransit-dispatch'
     ) $$,
  'dispatch creates an in-transit transfer without increasing available on-hand stock'
);

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '0',
  'in-transit dispatch leaves store available_qty unchanged (expected stock is not on-hand yet)'
);

select is(
  (
    select status || '|' || quantity::text
    from public.production_rgs_transfers
    where correlation_id = 'corr-p84-intransit-dispatch'
  ),
  'in_transit|5.8',
  'expected/in-transit quantity is visible on production_rgs_transfers, not merged into balances'
);

select lives_ok(
  $$ select public.record_rgs_receipt(
       (select id from public.production_rgs_transfers where correlation_id = 'corr-p84-intransit-dispatch'),
       5.8, 'corr-p84-intransit-receipt'
     ) $$,
  'RGS receipt records physical arrival while still separate from permanent stock posting'
);

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '0',
  'physical receipt alone still does not post permanent on-hand stock'
);

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
       (select id from public.production_rgs_transfers where correlation_id = 'corr-p84-intransit-dispatch'),
       5.5, 0, 0.3,
       (select version from public.inventory_stock_balances where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'),
       'corr-p84-intransit-accept'
     ) $$,
  'acceptance posts exactly the accepted quantity to permanent store stock'
);

select is(
  (
    select available_qty::text
    from public.inventory_stock_balances
    where sku = 'P84-TRAY' and location_code = 'FINISHED_GOODS'
  ),
  '5.5',
  'accepted production receipt increases available on-hand by exactly 5.5kg, not dispatch/received figures'
);

select finish();
rollback;
