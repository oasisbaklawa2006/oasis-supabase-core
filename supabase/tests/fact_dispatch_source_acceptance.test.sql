begin;
-- Contract coverage for 20260901100000_fact_dispatch_source_acceptance.sql.
select plan(47);

select has_function('public', 'can_declare_b2b_dispatch_handoff', 'can_declare_b2b_dispatch_handoff exists');
select has_function('public', 'declare_b2b_dispatch_source_handoff', 'declare_b2b_dispatch_source_handoff exists');
select has_function('public', 'record_b2b_dispatch_handoff_receipt', 'record_b2b_dispatch_handoff_receipt exists');
select has_function('public', 'accept_b2b_dispatch_handoff', 'accept_b2b_dispatch_handoff exists');

insert into public.users (id, role) values
  ('facd0000-0000-0000-0000-000000000001', 'PRODUCTION_MANAGER'),
  ('facd0000-0000-0000-0000-000000000002', 'DISPATCH_MANAGER'),
  ('facd0000-0000-0000-0000-000000000003', 'SALES_EXECUTIVE'),
  ('facd0000-0000-0000-0000-000000000004', 'STORE_3RD_PARTY'),
  ('facd0000-0000-0000-0000-000000000005', 'SUPER_ADMIN');

insert into public.companies (id, business_name, phone)
values ('facd1000-0000-0000-0000-000000000001', 'FACT-DISPATCH Test Co', '+91-9000000004');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value, order_origin)
values ('facd3000-0000-0000-0000-000000000001', 'PGTAP-FACTDISP-ORD-1', 'pgtap-factdisp-token-1', 'facd1000-0000-0000-0000-000000000001', 100000, 'SALES');

insert into public.products (id, name, category, sku, hsn_code, barcode_sku)
values
  ('facd4000-0000-0000-0000-000000000001', 'FACT-DISPATCH Product A', 'sweets', 'SKU-FACTDISP-A', '1905', 'BC-FACTDISP-A'),
  ('facd4000-0000-0000-0000-000000000002', 'FACT-DISPATCH Product B', 'sweets', 'SKU-FACTDISP-B', '1905', 'BC-FACTDISP-B');

insert into public.order_items (id, order_id, product_id, quantity)
values
  ('facd5000-0000-0000-0000-000000000001', 'facd3000-0000-0000-0000-000000000001', 'facd4000-0000-0000-0000-000000000001', 5),
  ('facd5000-0000-0000-0000-000000000002', 'facd3000-0000-0000-0000-000000000001', 'facd4000-0000-0000-0000-000000000002', 10),
  ('facd5000-0000-0000-0000-000000000003', 'facd3000-0000-0000-0000-000000000001', 'facd4000-0000-0000-0000-000000000001', 2);

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values ('facd6000-0000-0000-0000-000000000001', 'PGTAP-FACTDISP-ORD-1-DC-01', 'facd3000-0000-0000-0000-000000000001', 1, 'under_cartonisation', 'road_transporter', 'pgtap-factdisp-cons-1');

insert into public.b2b_dispatch_consignment_lines (
  id, consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty
) values
  ('facd7000-0000-0000-0000-000000000001', 'facd6000-0000-0000-0000-000000000001', 'facd5000-0000-0000-0000-000000000001', 'facd4000-0000-0000-0000-000000000001', 'SKU-FACTDISP-A', 'PACK', 5, 5),
  ('facd7000-0000-0000-0000-000000000002', 'facd6000-0000-0000-0000-000000000001', 'facd5000-0000-0000-0000-000000000002', 'facd4000-0000-0000-0000-000000000002', 'SKU-FACTDISP-B', 'PACK', 10, 10),
  ('facd7000-0000-0000-0000-000000000003', 'facd6000-0000-0000-0000-000000000001', 'facd5000-0000-0000-0000-000000000003', 'facd4000-0000-0000-0000-000000000001', 'SKU-FACTDISP-A', 'PACK', 2, 2);

set local request.jwt.claim.role = 'authenticated';

-- unauthenticated / unknown actor cannot declare.
set local request.jwt.claim.sub = '00000000-0000-0000-0000-000000000000';
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","declared_qty":5}]'::jsonb, 'pgtap-factdisp-declare-unauth')$$,
  'Not authorised to declare a PRODUCTION dispatch handoff', 'an unknown actor cannot declare a handoff'
);

-- wrong-role actor cannot declare for PRODUCTION.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000003';
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","declared_qty":5}]'::jsonb, 'pgtap-factdisp-declare-wrongrole')$$,
  'Not authorised to declare a PRODUCTION dispatch handoff', 'a SALES_EXECUTIVE cannot declare a PRODUCTION handoff'
);

-- wrong-department actor cannot declare for 3PGS with a PRODUCTION_MANAGER credential.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000001';
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, '3PGS', 'THIRD_PARTY_STORE', '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","declared_qty":10}]'::jsonb, 'pgtap-factdisp-declare-wrongdept')$$,
  'Not authorised to declare a 3PGS dispatch handoff', 'a PRODUCTION_MANAGER cannot declare a 3PGS handoff'
);

-- a single declare call cannot carry two lines for the same order_item_id
-- (receipt/acceptance are looked up by (handoff_id, order_item_id), so a
-- second batch/lot line for the same item would be silently unreachable).
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","declared_qty":2,"batch_lot":"BATCH-DUP-1"},{"order_item_id":"facd5000-0000-0000-0000-000000000001","declared_qty":3,"batch_lot":"BATCH-DUP-2"}]'::jsonb, 'pgtap-factdisp-declare-dup-item')$$,
  'A single handoff may declare at most one line per order_item_id -- receipt and acceptance are looked up by (handoff_id, order_item_id), so a second batch/lot for the same order_item must go in a separate handoff',
  'a single declare call cannot carry two lines for the same order_item_id'
);

-- positive: PRODUCTION declares 5 for line 1 (full selected_qty).
select lives_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","declared_qty":5,"batch_lot":"BATCH-1"}]'::jsonb, 'pgtap-factdisp-declare-1')$$,
  'PRODUCTION_MANAGER can declare a PRODUCTION handoff'
);

-- idempotent replay of the same declaration returns the same handoff, not a second row.
select is(
  (select count(*)::int from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'),
  1, 'a replayed declare correlation id does not create a duplicate handoff'
);
select lives_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","declared_qty":5,"batch_lot":"BATCH-1"}]'::jsonb, 'pgtap-factdisp-declare-1')$$,
  'replaying the same declare correlation id is idempotent'
);

-- Self-acceptance separation, isolated on order_item 3 (facd7000-...-03) with
-- an actor (SUPER_ADMIN) who genuinely passes both the declare-side and the
-- Dispatch-side role gates -- so the failure below is provably the explicit
-- self-check, not merely the department/role gate that facd0000-...-001
-- (PRODUCTION_MANAGER, not a Dispatch role) would fail on anyway.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000005';
select lives_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000003","declared_qty":2,"batch_lot":"BATCH-SELF"}]'::jsonb, 'pgtap-factdisp-declare-self')$$,
  'SUPER_ADMIN can declare a handoff for the self-acceptance isolation fixture'
);
-- a second open (not-yet-reconciled) handoff cannot declare against room
-- already committed by the still-outstanding declare-self handoff above --
-- 2 of 2 selected_qty is already outstanding, so even 1 more is rejected.
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, 'PRODUCTION', 'PRODUCTION_FLOOR', '[{"order_item_id":"facd5000-0000-0000-0000-000000000003","declared_qty":1}]'::jsonb, 'pgtap-factdisp-declare-overlap')$$,
  'declared_qty 1 for order_item facd5000-0000-0000-0000-000000000003 exceeds the remaining declarable selection (0 of 2 already accepted-ready, 2 still outstanding on other open handoffs)',
  'an overlapping open handoff cannot declare against quantity already outstanding on another open handoff'
);

select throws_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-self'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000003","physically_received_qty":2}]'::jsonb, 'pgtap-factdisp-receipt-self')$$,
  'The declaring source actor cannot also record Dispatch''s physical receipt', 'the declaring actor cannot record its own receipt'
);
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-self'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000003","physically_received_qty":2}]'::jsonb, 'pgtap-factdisp-receipt-self-ok')$$,
  'a genuine Dispatch actor can record the receipt the declaring actor was blocked from recording'
);
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000005';
select throws_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-self'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000003","accepted_qty":2}]'::jsonb, 'pgtap-factdisp-accept-self')$$,
  'The declaring source actor cannot also accept their own handoff', 'the declaring actor cannot accept its own handoff'
);

-- wrong role cannot record receipt.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000003';
select throws_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","physically_received_qty":5}]'::jsonb, 'pgtap-factdisp-receipt-wrongrole')$$,
  'Not authorised to record a dispatch handoff receipt', 'a SALES_EXECUTIVE cannot record a handoff receipt'
);

-- Dispatch receives physically 5, then accepts 5: accepted_ready_qty becomes exactly 5.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","physically_received_qty":5}]'::jsonb, 'pgtap-factdisp-receipt-1')$$,
  'DISPATCH_MANAGER can record a physical receipt'
);

-- acceptance above the physically received quantity is rejected while the
-- handoff is still in 'receiving' state (tested before the valid full accept
-- below moves it to a terminal-ish 'accepted' state).
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","accepted_qty":6}]'::jsonb, 'pgtap-factdisp-accept-overselected')$$,
  'accepted_qty + held_qty + rejected_qty (6) exceeds physically_received_qty (5) for order_item facd5000-0000-0000-0000-000000000001',
  'accepting above physically_received_qty is rejected'
);

select lives_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","accepted_qty":5}]'::jsonb, 'pgtap-factdisp-accept-1')$$,
  'DISPATCH_MANAGER can accept a fully received handoff'
);

select is(
  (select accepted_ready_qty from public.b2b_dispatch_consignment_lines where id = 'facd7000-0000-0000-0000-000000000001'),
  5::numeric, 'accepted_ready_qty becomes exactly 5 after full acceptance'
);
select is(
  (select status from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'),
  'accepted', 'a fully reconciled, fully accepted handoff reaches status accepted'
);

-- replaying the exact same acceptance correlation id is idempotent and does
-- not re-apply the accepted delta a second time.
select lives_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-1'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","accepted_qty":5}]'::jsonb, 'pgtap-factdisp-accept-1')$$,
  'replaying the same acceptance correlation id is idempotent'
);
select is(
  (select accepted_ready_qty from public.b2b_dispatch_consignment_lines where id = 'facd7000-0000-0000-0000-000000000001'),
  5::numeric, 'accepted_ready_qty is unchanged by a replayed acceptance correlation id, not doubled to 10'
);

-- direct client UPDATE of accepted_ready_qty is denied at the grant level.
set local role authenticated;
select throws_like(
  $$update public.b2b_dispatch_consignment_lines set accepted_ready_qty = 999 where id = 'facd7000-0000-0000-0000-000000000001'$$,
  '%permission denied%', 'authenticated clients cannot directly UPDATE accepted_ready_qty'
);
reset role;

-- FACT-C1 integration: a scan at/below the newly accepted-ready quantity now succeeds.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select public.open_b2b_dispatch_carton('facd6000-0000-0000-0000-000000000001'::uuid, 'PGTAP-FACTDISP-CARTON-1');
select is(
  (select scan_result from public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTDISP-CARTON-1'), 'facd7000-0000-0000-0000-000000000001'::uuid, 'BC-FACTDISP-A', 'BATCH-1', 5, 'pgtap-factdisp-scan-ok')),
  'verified', 'a scan at the accepted-ready quantity succeeds once source-to-Dispatch custody is accepted'
);

-- PARTIAL: line 2 (selected_qty=10). Source declares 6; Dispatch receives 6;
-- Dispatch accepts 4 / holds 1 / rejects 1 -> accepted_ready_qty advances only by 4.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000004';
select lives_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, '3PGS', 'THIRD_PARTY_STORE', '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","declared_qty":6,"batch_lot":"BATCH-2"}]'::jsonb, 'pgtap-factdisp-declare-2')$$,
  'STORE_3RD_PARTY can declare a 3PGS handoff'
);

-- over-declaring above the line's remaining unaccepted selection is rejected.
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, '3PGS', 'THIRD_PARTY_STORE', '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","declared_qty":11}]'::jsonb, 'pgtap-factdisp-declare-overselected')$$,
  'declared_qty 11 for order_item facd5000-0000-0000-0000-000000000002 exceeds the remaining declarable selection (0 of 10 already accepted-ready, 0 still outstanding on other open handoffs)',
  'declaring above the remaining unaccepted selection is rejected'
);

set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-2'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","physically_received_qty":6}]'::jsonb, 'pgtap-factdisp-receipt-2')$$,
  'DISPATCH_MANAGER can record the 3PGS handoff receipt'
);

-- receiving above declared_qty is rejected.
select throws_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-2'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","physically_received_qty":7}]'::jsonb, 'pgtap-factdisp-receipt-overdeclared')$$,
  'physically_received_qty 7 for order_item facd5000-0000-0000-0000-000000000002 exceeds declared_qty 6',
  'receiving above declared_qty is rejected'
);

select lives_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-2'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","accepted_qty":4,"held_qty":1,"rejected_qty":1}]'::jsonb, 'pgtap-factdisp-accept-2')$$,
  'DISPATCH_MANAGER can partially accept/hold/reject the 3PGS handoff'
);
select is(
  (select accepted_ready_qty from public.b2b_dispatch_consignment_lines where id = 'facd7000-0000-0000-0000-000000000002'),
  4::numeric, 'accepted_ready_qty advances only by the accepted portion (4), not the full receipt (6)'
);
select is(
  (select status from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-2'),
  'partially_accepted', 'a handoff with a residual held/rejected unit stays partially_accepted, not a clean accepted'
);

-- a scan above the accepted-ready quantity remains blocked.
select is(
  (select scan_result from public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTDISP-CARTON-1'), 'facd7000-0000-0000-0000-000000000002'::uuid, 'BC-FACTDISP-B', 'BATCH-2', 5, 'pgtap-factdisp-scan-excess')),
  'blocked_excess', 'a scan above accepted-ready quantity remains blocked'
);

-- a later valid second handoff can cumulatively increase accepted_ready_qty without exceeding selected_qty.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000004';
select lives_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, '3PGS', 'THIRD_PARTY_STORE', '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","declared_qty":4,"batch_lot":"BATCH-3"}]'::jsonb, 'pgtap-factdisp-declare-3')$$,
  'STORE_3RD_PARTY can declare a second, residual 3PGS handoff'
);
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-3'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","physically_received_qty":4}]'::jsonb, 'pgtap-factdisp-receipt-3')$$,
  'DISPATCH_MANAGER can record the residual 3PGS receipt'
);
select lives_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-3'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","accepted_qty":4}]'::jsonb, 'pgtap-factdisp-accept-3')$$,
  'DISPATCH_MANAGER can accept the residual 3PGS handoff'
);
select is(
  (select accepted_ready_qty from public.b2b_dispatch_consignment_lines where id = 'facd7000-0000-0000-0000-000000000002'),
  8::numeric, 'accepted_ready_qty cumulatively reaches 8 (4 + 4) across two handoffs, still below selected_qty 10'
);

-- accepting further beyond the remaining declared/received room above selected_qty is still rejected.
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000004';
select throws_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, '3PGS', 'THIRD_PARTY_STORE', '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","declared_qty":3}]'::jsonb, 'pgtap-factdisp-declare-overcap')$$,
  'declared_qty 3 for order_item facd5000-0000-0000-0000-000000000002 exceeds the remaining declarable selection (8 of 10 already accepted-ready, 0 still outstanding on other open handoffs)',
  'declaring beyond the remaining room above selected_qty is rejected'
);

-- a fully HELD (not rejected) receipt must NOT become terminally 'rejected'
-- -- that would permanently strand it, since 'rejected' isn't an
-- accept-permitted status. It stays 'partially_accepted' so a later
-- accept_b2b_dispatch_handoff call (once the hold is cleared) can still
-- move it to a clean 'accepted', consuming the final remaining 2 of
-- selected_qty 10.
select lives_ok(
  $$select public.declare_b2b_dispatch_source_handoff('facd6000-0000-0000-0000-000000000001'::uuid, '3PGS', 'THIRD_PARTY_STORE', '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","declared_qty":2}]'::jsonb, 'pgtap-factdisp-declare-4')$$,
  'STORE_3RD_PARTY can declare the final residual 2 units'
);
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select lives_ok(
  $$select public.record_b2b_dispatch_handoff_receipt((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-4'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","physically_received_qty":2}]'::jsonb, 'pgtap-factdisp-receipt-4')$$,
  'DISPATCH_MANAGER can record the final residual receipt'
);
select lives_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-4'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","held_qty":2}]'::jsonb, 'pgtap-factdisp-accept-4-hold')$$,
  'DISPATCH_MANAGER can hold the entire receipt without accepting or rejecting'
);
select is(
  (select status from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-4'),
  'partially_accepted', 'a fully held (not rejected) receipt stays partially_accepted, not terminally rejected'
);
select lives_ok(
  $$select public.accept_b2b_dispatch_handoff((select id from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-4'), '[{"order_item_id":"facd5000-0000-0000-0000-000000000002","accepted_qty":2,"held_qty":0}]'::jsonb, 'pgtap-factdisp-accept-4-clear')$$,
  'the hold can later be cleared into a clean acceptance'
);
select is(
  (select accepted_ready_qty from public.b2b_dispatch_consignment_lines where id = 'facd7000-0000-0000-0000-000000000002'),
  10::numeric, 'accepted_ready_qty reaches the full selected_qty of 10 once the hold clears'
);
select is(
  (select status from public.b2b_dispatch_handoffs where correlation_id = 'pgtap-factdisp-declare-4'),
  'accepted', 'clearing the hold into a full acceptance reaches status accepted'
);

-- a terminal (rejected) handoff cannot be mutated further.
insert into public.b2b_dispatch_handoffs (
  id, handoff_number, order_id, consignment_id, source_department, source_location, status, issued_by, correlation_id
) values (
  'facd8000-0000-0000-0000-000000000099', 'PGTAP-FACTDISP-ORD-1-HO-99', 'facd3000-0000-0000-0000-000000000001',
  'facd6000-0000-0000-0000-000000000001', 'PRODUCTION', 'PRODUCTION_FLOOR', 'rejected', 'facd0000-0000-0000-0000-000000000001', 'pgtap-factdisp-terminal-fixture'
);
set local request.jwt.claim.sub = 'facd0000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.record_b2b_dispatch_handoff_receipt('facd8000-0000-0000-0000-000000000099'::uuid, '[{"order_item_id":"facd5000-0000-0000-0000-000000000001","physically_received_qty":1}]'::jsonb, 'pgtap-factdisp-receipt-terminal')$$,
  'Handoff facd8000-0000-0000-0000-000000000099 is rejected and cannot record a physical receipt',
  'a terminal rejected handoff cannot record a further physical receipt'
);

select * from finish();
rollback;
