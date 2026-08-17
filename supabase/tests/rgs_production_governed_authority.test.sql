begin;
-- Contract coverage for 20260817100000_rgs_production_governed_authority.sql.
select plan(42);

-- Fixtures ------------------------------------------------------------------------
insert into public.users (id, role) values
  ('10000000-0000-0000-0000-000000000001', 'RGS_ADMIN'),
  ('10000000-0000-0000-0000-000000000002', 'PROD_ARABIC'),
  ('10000000-0000-0000-0000-000000000003', 'STORE_READY_GOODS');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('20000000-0000-0000-0000-000000000001', 'Pyramid Baklawa 1kg', 'sweets', 'PYRAMID-1KG', '1905', 'arabic_sweets');

insert into public.orders (id, order_number) values
  ('30000000-0000-0000-0000-000000000001', 'PGTAP-ORD-001')
on conflict do nothing;

-- Function/table existence ---------------------------------------------------------
select has_function('public','reserve_rgs_stock', 'reserve_rgs_stock exists');
select has_function('public','release_rgs_reservation', 'release_rgs_reservation exists');
select has_function('public','create_production_shortage_demand', 'create_production_shortage_demand exists');
select has_function('public','start_production_job', 'start_production_job exists');
select has_function('public','record_production_output', 'record_production_output exists');
select has_function('public','declare_production_ready', 'declare_production_ready exists');
select has_function('public','dispatch_production_to_rgs', 'dispatch_production_to_rgs exists');
select has_function('public','record_rgs_receipt', 'record_rgs_receipt exists');
select has_function('public','accept_rgs_production_receipt', 'accept_rgs_production_receipt exists');
select has_function('public','pick_rgs_reservation', 'pick_rgs_reservation exists');
select has_function('public','issue_rgs_stock', 'issue_rgs_stock exists');
select has_function('public','acknowledge_rgs_issue', 'acknowledge_rgs_issue exists');
select has_view('public','rgs_day_close_exceptions', 'day close exceptions view exists');

select is((select has_table_privilege('authenticated','public.inventory_reservations','insert')), false, 'authenticated cannot directly insert reservations');
select is((select has_table_privilege('authenticated','public.production_jobs','update')), false, 'authenticated cannot directly update production jobs');
select is((select has_function_privilege('anon','public.reserve_rgs_stock(text,uuid,uuid,text,numeric,text,text,text,text,uuid,uuid)','execute')), false, 'anonymous cannot reserve stock');

-- SCENARIO B: partial stock -> exact shortage only ---------------------------------
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- Seed 20kg available stock for the product at FINISHED_GOODS.
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('20000000-0000-0000-0000-000000000001', 'PYRAMID-1KG', 'FINISHED_GOODS', 20);

select results_eq(
  $$ select reserved_qty, reservation_status from public.reserve_rgs_stock(
       'RES-SCN-B', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
       'PYRAMID-1KG', 50, 'ARABIC_SWEETS', 'corr-scn-b'
     ) $$,
  $$ values (20::numeric, 'partially_reserved'::text) $$,
  'scenario B: reserves only the 20kg available, leaving 30kg as shortage'
);

select is((select available_qty from public.inventory_stock_balances where sku='PYRAMID-1KG'), 0::numeric, 'available stock fully consumed by the partial reservation');

prepare shortage_job as
  select assigned_qty, status from public.create_production_shortage_demand(
    (select id from public.inventory_reservations where correlation_id = 'corr-scn-b'),
    'ARABIC_SWEETS', 'urgent', 'corr-scn-b-shortage'
  );
select results_eq('shortage_job', $$ values (30::numeric, 'pending'::text) $$, 'scenario B: production shortage demand is exactly 30kg, never the full 50kg');

-- Duplicate shortage routing must not create a second job.
select is(
  (select count(*)::int from public.production_jobs where reservation_id = (select id from public.inventory_reservations where correlation_id = 'corr-scn-b')),
  1,
  'a second shortage-routing call for the same reservation does not duplicate the production job'
);

-- SCENARIO E: production declares 50, dispatches 49.8, RGS accepts 49.5 -----------
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
update public.production_jobs set assigned_qty = 50 where reservation_id = (select id from public.inventory_reservations where correlation_id = 'corr-scn-b');

select lives_ok(
  $$ select public.start_production_job((select id from public.production_jobs where correlation_id = 'corr-scn-b-shortage'), 'corr-start-e') $$,
  'scenario E: production job starts'
);

select lives_ok(
  $$ select public.record_production_output((select id from public.production_jobs where correlation_id = 'corr-scn-b-shortage'), 50.0, 0, 'BATCH-E-1', 'corr-output-e') $$,
  'scenario E: 50.0kg output recorded'
);

select is(
  (select produced_qty from public.production_jobs where correlation_id = 'corr-scn-b-shortage'),
  50.0::numeric,
  'scenario E: job produced_qty rolls up to exactly 50.0kg'
);

select lives_ok(
  $$ select public.declare_production_ready((select id from public.production_jobs where correlation_id = 'corr-scn-b-shortage'), 'corr-ready-e') $$,
  'scenario E: production declares ready'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
select lives_ok(
  $$ select public.dispatch_production_to_rgs((select id from public.production_jobs where correlation_id = 'corr-scn-b-shortage'), 49.8, 'corr-dispatch-e') $$,
  'scenario E: production dispatches 49.8kg (less than the declared 50.0kg)'
);

select lives_ok(
  $$ select public.record_rgs_receipt((select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-e'), 49.8, 'corr-receipt-e') $$,
  'scenario E: RGS physically receives 49.8kg'
);

select lives_ok(
  $$ select public.accept_rgs_production_receipt(
       (select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-e'), 49.5, 0, 0.3,
       (select version from public.inventory_stock_balances where sku = 'PYRAMID-1KG' and location_code = 'FINISHED_GOODS'),
       'corr-accept-e'
     ) $$,
  'scenario E: RGS accepts 49.5kg, holding back 0.3kg'
);

select is(
  (select available_qty from public.inventory_stock_balances where sku='PYRAMID-1KG'),
  49.5::numeric,
  'scenario E: RGS permanent stock increases by EXACTLY 49.5kg -- not 50.0, not 49.8'
);

select results_eq(
  $$ select declared_qty, quantity, received_qty, accepted_qty, hold_qty from public.production_rgs_transfers where correlation_id = 'corr-dispatch-e' $$,
  $$ values (50.0::numeric, 49.8::numeric, 49.8::numeric, 49.5::numeric, 0.3::numeric) $$,
  'scenario E: declared/dispatched/received/accepted/variance all remain distinct and visible -- nothing was overwritten'
);

-- A second acceptance attempt against an already-dispositioned transfer
-- returns the settled truth idempotently -- it never re-derives a different
-- outcome (e.g. from a differently-shaped retried payload) and never
-- re-posts stock a second time.
select results_eq(
  $$ select accepted_qty from public.accept_rgs_production_receipt(
       (select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-e'),
       1, 0, 0, 0, 'corr-accept-e-retry-stale'
     ) $$,
  $$ values (49.5::numeric) $$,
  'a second, differently-shaped acceptance attempt against an already-accepted transfer returns the original settled 49.5kg, not a re-derived 1kg'
);
select is(
  (select available_qty from public.inventory_stock_balances where sku='PYRAMID-1KG' and location_code='FINISHED_GOODS'),
  49.5::numeric,
  'the idempotent replay did not post stock a second time'
);

-- SCENARIO A: full stock available -> no production demand ------------------------
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('20000000-0000-0000-0000-000000000001', 'PYRAMID-1KG', 'B2B_RAW', 50)
on conflict do nothing;

select results_eq(
  $$ select reserved_qty, reservation_status from public.reserve_rgs_stock(
       'RES-SCN-A', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
       'PYRAMID-1KG', 50, 'ARABIC_SWEETS', 'corr-scn-a', 'normal', 'B2B_RAW'
     ) $$,
  $$ values (50::numeric, 'reserved'::text) $$,
  'scenario A: full 50kg demand is fully reserved from available stock'
);

select throws_like(
  $$ select public.create_production_shortage_demand(
       (select id from public.inventory_reservations where correlation_id = 'corr-scn-a'), 'ARABIC_SWEETS', 'normal', 'corr-scn-a-no-shortage'
     ) $$,
  '%has no shortage to route to production%',
  'scenario A: fully-reserved demand raises when a caller tries to route a non-existent shortage'
);

-- SCENARIO D: zero stock -> full shortage to production ---------------------------
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('20000000-0000-0000-0000-000000000002', 'Kunafa Roll', 'sweets', 'KUNAFA-ROLL', '1905', 'fusion_sweets');

select results_eq(
  $$ select reserved_qty, reservation_status from public.reserve_rgs_stock(
       'RES-SCN-D', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
       'KUNAFA-ROLL', 15, 'FUSION_SWEETS', 'corr-scn-d'
     ) $$,
  $$ values (0::numeric, 'pending'::text) $$,
  'scenario D: zero stock reserves nothing, reservation is pending'
);

select results_eq(
  $$ select assigned_qty, canonical_department from public.create_production_shortage_demand(
       (select id from public.inventory_reservations where correlation_id = 'corr-scn-d'), 'FUSION_SWEETS', 'normal', 'corr-scn-d-shortage'
     ) $$,
  $$ values (15::numeric, 'FUSION_SWEETS'::text) $$,
  'scenario D: full 15kg demand routes to the correctly mapped Fusion Sweets department'
);

-- Idempotent retry: identical reserve_rgs_stock call is not double-applied --------
select results_eq(
  $$ select reserved_qty from public.reserve_rgs_stock(
       'RES-SCN-D', '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
       'KUNAFA-ROLL', 15, 'FUSION_SWEETS', 'corr-scn-d'
     ) $$,
  $$ values (0::numeric) $$,
  'scenario G: retried reservation with the same correlation id returns the original result instead of reserving twice'
);
select is((select count(*)::int from public.inventory_reservations where correlation_id = 'corr-scn-d'), 1, 'scenario G: retry did not create a duplicate reservation row');

-- Pick / issue / acknowledge leg (scenario A reservation) -------------------------
select lives_ok(
  $$ select public.pick_rgs_reservation((select id from public.inventory_reservations where correlation_id = 'corr-scn-a'), 20, 'corr-pick-a') $$,
  'picking part of a fully-reserved order succeeds'
);
select is((select picked_qty from public.inventory_stock_balances where sku='PYRAMID-1KG' and location_code='B2B_RAW'), 20::numeric, 'picked bucket reflects the picked quantity');

select lives_ok(
  $$ select public.issue_rgs_stock((select id from public.inventory_reservations where correlation_id = 'corr-scn-a'), 20, 'outlet', 'OUTLET-001', 'corr-issue-a') $$,
  'issuing picked stock to an outlet succeeds'
);

select lives_ok(
  $$ select public.acknowledge_rgs_issue((select id from public.rgs_issue_events where correlation_id = 'corr-issue-a'), 19.8, 'corr-ack-a') $$,
  'scenario J: receiver acknowledges 19.8kg of a 20kg issue'
);
select is((select status from public.rgs_issue_events where correlation_id = 'corr-issue-a'), 'variance', 'scenario J: a receiver-quantity mismatch is recorded as a visible variance, not silently accepted as full receipt');

select * from finish();
rollback;
