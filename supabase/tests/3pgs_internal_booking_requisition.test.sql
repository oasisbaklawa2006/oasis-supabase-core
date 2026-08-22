begin;
-- Contract coverage for 20260822110000_3pgs_internal_booking_requisition.sql:
-- book_3pgs_packing_material_requisition must reserve against the 3PGS
-- store via the existing reserve_rgs_stock authority, record the requesting
-- department and an optional purpose note, replay idempotently, and refuse
-- a missing requesting department -- without requiring or fabricating a
-- real commercial order.
select plan(9);

select has_function('public', 'book_3pgs_packing_material_requisition', 'book_3pgs_packing_material_requisition exists');

insert into public.users (id, role) values
  ('97000000-0000-0000-0000-000000000001', 'PRODUCTION_MANAGER'),
  ('97000000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('97100000-0000-0000-0000-000000000001', 'Outer Carton Booking', 'packaging', 'CARTON-BOOK-1', '4823', null);
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', '3PGS', 40);

set local request.jwt.claim.sub = '97000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 10,
       'Packing & Assembly', 'corr-booking-1', 'Needed for hamper run 42'
     ) $$,
  'authorised manager can book available 3PGS packing material'
);
select is(
  (select reservation_status from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  'reserved', 'fully available quantity is reserved outright'
);
select is(
  (select source_department from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  'Packing & Assembly', 'requesting department is recorded'
);
select is(
  (select notes from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  'Needed for hamper run 42', 'purpose note is recorded'
);
select is(
  (select reserved_by from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  '97000000-0000-0000-0000-000000000001'::uuid, 'requester is recorded'
);
select is(
  (select count(*)::int from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  1, 'a retried booking with the same correlation_id does not create a second reservation'
);
select throws_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5, '   ', 'corr-booking-2'
     ) $$,
  'Requesting department is required for a 3PGS packing-material booking',
  'a blank requesting department is refused'
);

set local request.jwt.claim.sub = '97000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5, 'Sales', 'corr-booking-3'
     ) $$,
  'Not authorised to reserve RGS stock',
  'a role without inventory manage/receive authority is refused, delegated from reserve_rgs_stock'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
