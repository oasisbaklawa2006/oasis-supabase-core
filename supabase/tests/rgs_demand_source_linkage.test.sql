begin;
-- Contract coverage for 20260817160000_rgs_demand_source_linkage.sql:
-- reserve_rgs_stock accepting pna/outlet/internal demand sources alongside
-- the original b2b/order_id path.
select plan(10);

insert into public.users (id, role) values
  ('16000000-0000-0000-0000-000000000001', 'STORE_READY_GOODS');
insert into public.products (id, name, sku) values
  ('26000000-0000-0000-0000-000000000001', 'Kunafa Roll HD', 'KUNAFA-ROLL-HD');
insert into public.orders (id, order_number) values
  ('36000000-0000-0000-0000-000000000001', 'PGTAP-ORD-DEMAND-1');
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 'FINISHED_GOODS', 100);

set local request.jwt.claim.sub = '16000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- b2b demand source still requires order_id (unchanged behaviour).
select lives_ok(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-B2B', '36000000-0000-0000-0000-000000000001',
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 10, 'B2B', 'corr-demand-b2b-1') $$,
  'b2b demand source with order_id succeeds'
);
select throws_like(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-B2B-BAD', null,
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 5, 'B2B', 'corr-demand-b2b-bad') $$,
  '%order_id is required for a b2b demand source%',
  'b2b demand source without order_id is rejected'
);

-- pna/outlet/internal demand sources require order_id to be null and use
-- p_demand_reference instead.
select lives_ok(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-PNA', null,
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 15, 'PNA', 'corr-demand-pna-1',
       'normal', 'FINISHED_GOODS', null, null, 'pna', 'PNA-PLAN-Q3-014') $$,
  'pna demand source with order_id null and a demand_reference succeeds'
);
select is(
  (select demand_source_type from public.inventory_reservations where correlation_id = 'corr-demand-pna-1'),
  'pna', 'reservation persisted with demand_source_type = pna'
);
select is(
  (select demand_reference from public.inventory_reservations where correlation_id = 'corr-demand-pna-1'),
  'PNA-PLAN-Q3-014', 'reservation persisted the demand_reference'
);

select lives_ok(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-OUTLET', null,
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 10, 'OUTLET', 'corr-demand-outlet-1',
       'normal', 'FINISHED_GOODS', null, null, 'outlet', 'OUTLET-042') $$,
  'outlet demand source succeeds'
);
select lives_ok(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-INTERNAL', null,
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 5, 'INTERNAL', 'corr-demand-internal-1',
       'normal', 'FINISHED_GOODS', null, null, 'internal', 'REQ-INTERNAL-9') $$,
  'internal demand source succeeds'
);

select throws_like(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-BAD-TYPE', null,
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 5, 'X', 'corr-demand-bad-type',
       'normal', 'FINISHED_GOODS', null, null, 'not_a_real_type', null) $$,
  '%Unknown demand source type%',
  'an unrecognised demand source type is rejected'
);
select throws_like(
  $$ select public.reserve_rgs_stock('RGS-DEMAND-PNA-WITH-ORDER', '36000000-0000-0000-0000-000000000001',
       '26000000-0000-0000-0000-000000000001', 'KUNAFA-ROLL-HD', 5, 'PNA', 'corr-demand-pna-with-order',
       'normal', 'FINISHED_GOODS', null, null, 'pna', null) $$,
  '%order_id must be null for a non-b2b demand source%',
  'a non-b2b demand source with a non-null order_id is rejected'
);

-- Existing b2b reservations default demand_source_type = 'b2b' (backward compatible).
select is(
  (select demand_source_type from public.inventory_reservations where correlation_id = 'corr-demand-b2b-1'),
  'b2b', 'pre-existing/default reservation call defaults to demand_source_type = b2b'
);

select finish();
rollback;
