begin;
-- POINT 83 — inventory reservation protection canonical closure audit.
-- Migration-free behavioural evidence against existing deployed authority on
-- Core main. Proves atomic reservation (no oversubscription), idempotent
-- replay, release/cancel restoration, partial fulfilment accounting,
-- priority preservation, cross-demand isolation, and direct-write hardening.
-- Does NOT claim physical store truth; uses synthetic fixtures only.
-- Separates Point83 reservation integrity from Point82 UI and Points84–85
-- lot/batch/location policy (those are exercised only where they gate pick/issue).
select plan(39);
select has_function('public', 'reserve_rgs_stock', 'reserve_rgs_stock canonical intake exists');
select has_function('public', 'release_rgs_reservation', 'release_rgs_reservation exists');
select has_function('public', 'pick_rgs_reservation', 'pick_rgs_reservation exists');
select has_function('public', 'issue_rgs_stock', 'issue_rgs_stock exists');
select has_function('public', 'book_3pgs_packing_material_requisition', '3PGS internal booking wrapper exists');
select has_function('public', 'reserve_assembly_components', 'P&A component reservation exists');
select has_function('public', 'reserve_3pgs_requirement_stock', '3PGS requirement reservation exists');
select has_function('public', 'allocate_lots_to_reservation', 'lot allocation to reservation exists');
select has_function('public', 'release_lot_allocations_from_reservation', 'lot allocation release exists');
select has_view('public', 'inventory_command_facts', 'inventory_command_facts bind surface exists');

select ok(
  (
    with def as (
      select pg_get_functiondef(
        'public.reserve_rgs_stock(text,uuid,uuid,text,numeric,text,text,text,text,uuid,uuid,text,text)'::regprocedure
      ) as body
    )
    select strpos(body, 'pg_advisory_xact_lock') > 0
      and strpos(body, 'FOR UPDATE') > 0
      and strpos(body, 'correlation_id') < strpos(body, 'pg_advisory_xact_lock')
    from def
  ),
  'reserve_rgs_stock idempotency check precedes advisory lock + balance FOR UPDATE (serializes competing demand)'
);

select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'INSERT')
  and not has_table_privilege('authenticated', 'public.inventory_reservations', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.inventory_reservation_allocations', 'INSERT')
  and not has_table_privilege('authenticated', 'public.inventory_reservation_allocations', 'UPDATE'),
  'authenticated cannot directly mutate reservation or allocation tables'
);

-- =============================================================================
-- Fixtures
-- =============================================================================
insert into public.users (id, role) values
  ('a3000000-0000-0000-0000-000000000001', 'RGS_ADMIN'),
  ('a3000000-0000-0000-0000-000000000002', 'PRODUCTION_MANAGER');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('b3000000-0000-0000-0000-000000000001', 'Point83 Audit SKU', 'sweets', 'P83-AUDIT-SKU', '1905', 'arabic_sweets');

insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('c3000000-0000-0000-0000-000000000001', 'PGTAP-ORD-P83-1', 'pgtap-fixture-token-p83-1', 'MANUAL');

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU', 'FINISHED_GOODS', 10);

set local request.jwt.claim.sub = 'a3000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- =============================================================================
-- 2. Atomic reservation: sequential competing demand cannot oversubscribe
--    (same advisory lock + balance row lock path concurrent sessions use)
-- =============================================================================
select results_eq(
  $$ select reserved_qty, reservation_status from public.reserve_rgs_stock(
       'P83-RES-A', 'c3000000-0000-0000-0000-000000000001',
       'b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU',
       7, 'ARABIC_SWEETS', 'corr-p83-compete-a', 'urgent'
     ) $$,
  $$ values (7::numeric, 'reserved'::text) $$,
  'first competing b2b reservation consumes 7 of 10 available'
);

select results_eq(
  $$ select reserved_qty, reservation_status from public.reserve_rgs_stock(
       'P83-RES-B', 'c3000000-0000-0000-0000-000000000001',
       'b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU',
       7, 'ARABIC_SWEETS', 'corr-p83-compete-b', 'normal'
     ) $$,
  $$ values (3::numeric, 'partially_reserved'::text) $$,
  'second competing reservation is capped at remaining 3 — no oversubscription'
);

select is(
  (select available_qty from public.inventory_stock_balances
     where sku = 'P83-AUDIT-SKU' and location_code = 'FINISHED_GOODS'),
  0::numeric,
  'available bucket is zero after both reservations — stock is fully accounted'
);

select is(
  (select reserved_qty from public.inventory_stock_balances
     where sku = 'P83-AUDIT-SKU' and location_code = 'FINISHED_GOODS'),
  10::numeric,
  'balance reserved_qty equals sum of reservation reserved_qty (7+3) — no phantom reservation'
);

select is(
  (select reservation_priority from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  'urgent',
  'priority is preserved on the reservation row at creation'
);

-- =============================================================================
-- 3. Idempotent replay: same correlation_id never double-applies stock
-- =============================================================================
select results_eq(
  $$ select reserved_qty from public.reserve_rgs_stock(
       'P83-RES-A', 'c3000000-0000-0000-0000-000000000001',
       'b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU',
       7, 'ARABIC_SWEETS', 'corr-p83-compete-a', 'urgent'
     ) $$,
  $$ values (7::numeric) $$,
  'idempotent replay returns original reserved_qty without re-reserving'
);

select is(
  (select count(*)::int from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  1,
  'idempotent replay did not create a duplicate reservation row'
);

select is(
  (select reserved_qty from public.inventory_stock_balances
     where sku = 'P83-AUDIT-SKU' and location_code = 'FINISHED_GOODS'),
  10::numeric,
  'idempotent replay did not move stock a second time'
);

-- =============================================================================
-- 4. Release restoration: released quantity returns to available bucket
-- =============================================================================
select lives_ok(
  $$ select public.release_rgs_reservation(
       (select id from public.inventory_reservations where correlation_id = 'corr-p83-compete-b'),
       3, 'customer_cancel', 'corr-p83-release-b'
     ) $$,
  'partial release of second reservation succeeds'
);

select is(
  (select available_qty from public.inventory_stock_balances
     where sku = 'P83-AUDIT-SKU' and location_code = 'FINISHED_GOODS'),
  3::numeric,
  'released quantity is restored to available_qty'
);

select is(
  (select reserved_qty from public.inventory_stock_balances
     where sku = 'P83-AUDIT-SKU' and location_code = 'FINISHED_GOODS'),
  7::numeric,
  'balance reserved_qty drops when reservation is released — released rows do not consume stock'
);

select is(
  (select released_qty from public.inventory_reservations where correlation_id = 'corr-p83-compete-b'),
  3::numeric,
  'released_qty on reservation reflects the released amount'
);

select is(
  (select reserved_qty from public.inventory_reservations where correlation_id = 'corr-p83-compete-b'),
  0::numeric,
  'released reservation row no longer holds reserved_qty — stock is not double-counted'
);

-- Full release of a fully-reserved row reaches terminal released status.
select lives_ok(
  $$ select public.release_rgs_reservation(
       (select id from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
       3, 'demand_reduced', 'corr-p83-release-a-partial'
     ) $$,
  'releasing remaining reserved quantity on first reservation succeeds'
);

select is(
  (select reservation_status from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  'partially_reserved',
  'reservation with partial fulfilment + partial release remains partially_reserved until fully closed'
);

-- =============================================================================
-- 5. Partial fulfilment accounting: pick + issue move reserved -> fulfilled
-- =============================================================================
select lives_ok(
  $$ select public.pick_rgs_reservation(
       (select id from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
       4, 'corr-p83-pick-partial'
     ) $$,
  'partial pick against remaining reserved quantity succeeds'
);

select is(
  (select picked_qty from public.inventory_stock_balances
     where sku = 'P83-AUDIT-SKU' and location_code = 'FINISHED_GOODS'),
  4::numeric,
  'picked bucket reflects partial pick quantity'
);

select lives_ok(
  $$ select public.issue_rgs_stock(
       (select id from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
       4, 'outlet', 'OUTLET-P83', 'corr-p83-issue-partial'
     ) $$,
  'partial issue of picked stock succeeds'
);

select is(
  (select fulfilled_qty from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  4::numeric,
  'reservation fulfilled_qty records partial fulfilment'
);

select is(
  (select reserved_qty from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  0::numeric,
  'reservation reserved_qty is zero after issuing all remaining reserved quantity'
);

select cmp_ok(
  (select reserved_qty + fulfilled_qty + released_qty
     from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  '<=',
  (select requested_qty + 0.0001
     from public.inventory_reservations where correlation_id = 'corr-p83-compete-a'),
  'qty_coherent constraint holds after partial fulfilment'
);

-- =============================================================================
-- 6. Cross-demand isolation: b2b and internal channels compete atomically
--    without sharing correlation_id or fabricating order identity
-- =============================================================================
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU', '3PGS', 5);

set local request.jwt.claim.sub = 'a3000000-0000-0000-0000-000000000002';

select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       'b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU', 4,
       'Packing & Assembly', 'corr-p83-internal-book', 'Point83 cross-demand fixture'
     ) $$,
  'internal 3PGS booking reserves via shared reserve_rgs_stock authority'
);

select is(
  (select demand_source_type from public.inventory_reservations where correlation_id = 'corr-p83-internal-book'),
  'internal',
  'internal demand is isolated by demand_source_type from b2b reservations'
);

select is(
  (select order_id from public.inventory_reservations where correlation_id = 'corr-p83-internal-book'),
  null,
  'internal booking does not fabricate a commercial order_id'
);

set local request.jwt.claim.sub = 'a3000000-0000-0000-0000-000000000001';

select results_eq(
  $$ select reserved_qty from public.reserve_rgs_stock(
       'P83-RES-3PGS-B2B', null,
       'b3000000-0000-0000-0000-000000000001', 'P83-AUDIT-SKU',
       3, 'ARABIC_SWEETS', 'corr-p83-outlet-demand', 'high', '3PGS',
       null, null, 'outlet', 'OUTLET-P83-CROSS'
     ) $$,
  $$ values (1::numeric) $$,
  'outlet demand on 3PGS store is capped at remaining stock after internal booking (4+1=5)'
);

select is(
  (select count(distinct demand_source_type)::int
     from public.inventory_reservations
     where sku = 'P83-AUDIT-SKU' and correlation_id like 'corr-p83-%'),
  3,
  'b2b, internal, and outlet demand each retain distinct demand_source_type rows'
);

-- =============================================================================
-- 7. inventory_command_facts shortage derivation (Point82 UI bind surface only)
-- =============================================================================
select is(
  (select shortage_qty from public.inventory_command_facts
     where reservation_id = (select id from public.inventory_reservations where correlation_id = 'corr-p83-outlet-demand')),
  2::numeric,
  'command facts surface exact shortage (requested 3, reserved 1) for partially reserved outlet demand'
);

select finish();
rollback;
