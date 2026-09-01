begin;
-- Contract coverage for 20260822130000_3pgs_internal_booking_requisition.sql:
-- book_3pgs_packing_material_requisition must reserve against the 3PGS
-- store via the existing reserve_rgs_stock authority, record the requesting
-- department and an optional purpose note, replay idempotently, and refuse
-- a missing requesting department -- without requiring or fabricating a
-- real commercial order. An earlier revision satisfied reserve_rgs_stock's
-- (then-believed) NOT NULL order_id with a freshly generated random UUID;
-- that was rejected on review as a fabricated commercial-order identity.
-- The corrected version passes order_id := NULL and
-- demand_source_type := 'internal' -- the general non-order demand model
-- reserve_rgs_stock already carries (20260817160000). This file also proves
-- the ordinary commercial-order (b2b) path through the SAME shared
-- reserve_rgs_stock function is completely unaffected by that change, and
-- that the existing pick/issue/acknowledge fulfilment chain and the
-- priority view both work correctly against an 'internal' reservation.
select plan(33);

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
  (select order_id from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  null, 'order_id is genuinely null -- no fabricated commercial order identity is invented'
);
select is(
  (select demand_source_type from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  'internal', 'the reservation is honestly categorised as internal demand, not defaulted to b2b'
);
select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 10,
       'Packing & Assembly', 'corr-booking-1', 'A different note that must not overwrite the first'
     ) $$,
  'an actual retry with the same correlation_id succeeds (idempotent replay)'
);
select is(
  (select count(*)::int from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  1, 'the retried booking does not create a second reservation'
);
select is(
  (select notes from public.inventory_reservations where correlation_id = 'corr-booking-1'),
  'Needed for hamper run 42', 'the retry does not overwrite the original purpose note'
);
select throws_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5, '   ', 'corr-booking-2'
     ) $$,
  'Requesting department is required for a 3PGS packing-material booking',
  'a blank requesting department is refused'
);
select throws_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5, 'Packing & Assembly', '  '
     ) $$,
  'A correlation id is required',
  'a blank correlation id is refused before reservation_number is built'
);
select throws_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5, E'\t\n', 'corr-booking-tab-dept'
     ) $$,
  'Requesting department is required for a 3PGS packing-material booking',
  'a tab/newline-only requesting department is refused (btrim alone would miss this)'
);

-- CodeRabbit-flagged idempotency bug: a replay must never mutate an
-- existing reservation's notes, even when the original had no note and the
-- retry supplies one. Checking "notes IS NULL" instead of "was this call
-- the one that created the row" would incorrectly let this retry through.
select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 2,
       'Packing & Assembly', 'corr-booking-null-then-note'
     ) $$,
  'a booking created with no purpose note succeeds'
);
select is(
  (select notes from public.inventory_reservations where correlation_id = 'corr-booking-null-then-note'),
  null, 'the reservation is created with genuinely null notes'
);
select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 2,
       'Packing & Assembly', 'corr-booking-null-then-note', 'A note added on retry must not apply'
     ) $$,
  'a retry of the same correlation_id succeeds even when it newly supplies a note'
);
select is(
  (select notes from public.inventory_reservations where correlation_id = 'corr-booking-null-then-note'),
  null, 'the replay does NOT retroactively set notes -- idempotent replays are read-only'
);
select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 3,
       'Packing & Assembly', 'corr-booking-whitespace-note', '   '
     ) $$,
  'a whitespace-only purpose note is accepted'
);
select is(
  (select notes from public.inventory_reservations where correlation_id = 'corr-booking-whitespace-note'),
  null, 'a whitespace-only purpose note is stored as null, not as literal whitespace'
);

set local request.jwt.claim.sub = '97000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5, 'Sales', 'corr-booking-3'
     ) $$,
  'Not authorised to reserve RGS stock',
  'a role without inventory manage/receive authority is refused, delegated from reserve_rgs_stock'
);

-- =================================================================================
-- Regression: the ordinary commercial-order (b2b) path through the SAME
-- shared reserve_rgs_stock function must be completely unaffected by this
-- wrapper -- it still requires a real order_id and still records it, and
-- it still defaults demand_source_type to 'b2b'.
-- Synthetic fixture identity bypasses the canonical SO allocator explicitly;
-- production runtime never runs with session_replication_role=replica.
-- =================================================================================
set local request.jwt.claim.sub = '97000000-0000-0000-0000-000000000001';
set local session_replication_role = replica;
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('97200000-0000-0000-0000-000000000001', 'PGTAP-ORD-3PGS-BOOKING-1', 'pgtap-fixture-token-3pgs-booking-1', 'MANUAL');
set local session_replication_role = default;

select lives_ok(
  $$ select public.reserve_rgs_stock(
       'RGS-B2B-REGRESSION', '97200000-0000-0000-0000-000000000001',
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5,
       'B2B', 'corr-b2b-regression', 'normal', '3PGS'
     ) $$,
  'an ordinary commercial-order reservation through the shared RPC still succeeds'
);
select is(
  (select order_id from public.inventory_reservations where correlation_id = 'corr-b2b-regression'),
  '97200000-0000-0000-0000-000000000001'::uuid,
  'the ordinary commercial-order reservation carries the genuine order id, unaffected by this PR'
);
select is(
  (select demand_source_type from public.inventory_reservations where correlation_id = 'corr-b2b-regression'),
  'b2b', 'the ordinary commercial-order reservation still defaults to demand_source_type b2b'
);
select throws_ok(
  $$ select public.reserve_rgs_stock(
       'RGS-B2B-MISSING-ORDER', null,
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 5,
       'B2B', 'corr-b2b-missing-order', 'normal', '3PGS'
     ) $$,
  'order_id is required for a b2b demand source',
  'the shared RPC still refuses a null order_id for the default b2b demand source, unchanged by this PR'
);

-- =================================================================================
-- Downstream fulfilment chain (pick / issue / acknowledge) must work
-- unmodified against an 'internal' reservation exactly as it does for any
-- other reservation -- none of those RPCs reference order_id or
-- demand_source_type at all.
-- =================================================================================
select is(
  (select reservation_status from public.inventory_reservations where correlation_id = 'corr-booking-whitespace-note'),
  'reserved', 'sanity check: the reservation used for the fulfilment-chain smoke test is fully reserved'
);
select lives_ok(
  $$ select public.pick_rgs_reservation(
       (select id from public.inventory_reservations where correlation_id = 'corr-booking-whitespace-note'),
       3, 'corr-booking-whitespace-note:pick'
     ) $$,
  'picking stock against an internal reservation succeeds via the unmodified pick_rgs_reservation RPC'
);
select lives_ok(
  $$ select public.issue_rgs_stock(
       (select id from public.inventory_reservations where correlation_id = 'corr-booking-whitespace-note'),
       3, 'internal', 'Packing & Assembly', 'corr-booking-whitespace-note:issue'
     ) $$,
  'issuing stock against an internal reservation succeeds via the unmodified issue_rgs_stock RPC'
);
select is(
  (select reservation_status from public.inventory_reservations where correlation_id = 'corr-booking-whitespace-note'),
  'fulfilled', 'the internal reservation reaches fulfilled status through the unmodified fulfilment chain'
);
select lives_ok(
  $$ select public.acknowledge_rgs_issue(
       (select id from public.rgs_issue_events where correlation_id = 'corr-booking-whitespace-note:issue'),
       3, 'corr-booking-whitespace-note:ack'
     ) $$,
  'acknowledging the issue against an internal reservation succeeds via the unmodified acknowledge_rgs_issue RPC'
);

-- =================================================================================
-- The b2b_3pgs_pending_demand_priority view must correctly categorise a
-- partially-outstanding internal booking as demand_source_type 'internal'
-- at priority_rank 4 -- the exact categorisation the synthetic-order-id
-- version of this RPC would have silently defeated by defaulting to 'b2b'.
-- =================================================================================
select lives_ok(
  $$ select public.book_3pgs_packing_material_requisition(
       '97100000-0000-0000-0000-000000000001', 'CARTON-BOOK-1', 1000,
       'Packing & Assembly', 'corr-booking-partial'
     ) $$,
  'a booking exceeding available stock is accepted as a partial reservation'
);
select is(
  (select demand_source_type from public.b2b_3pgs_pending_demand_priority where demand_id = (
    select id from public.inventory_reservations where correlation_id = 'corr-booking-partial'
  )),
  'internal', 'the partially-outstanding internal booking appears in the priority view correctly categorised'
);
select is(
  (select priority_rank from public.b2b_3pgs_pending_demand_priority where demand_id = (
    select id from public.inventory_reservations where correlation_id = 'corr-booking-partial'
  )),
  4, 'internal demand is ranked at priority_rank 4, as designed'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
