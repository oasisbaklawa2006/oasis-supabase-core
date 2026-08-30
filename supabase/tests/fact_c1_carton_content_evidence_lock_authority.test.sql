begin;
-- Contract coverage for 20260830110000_fact_c1_carton_content_evidence_lock_authority.sql.
select plan(29);

select has_function('public', 'record_b2b_dispatch_carton_item_scan', 'record_b2b_dispatch_carton_item_scan exists');
select has_function('public', 'record_b2b_dispatch_carton_evidence', 'record_b2b_dispatch_carton_evidence exists');
select has_function('public', 'lock_b2b_dispatch_carton', 'lock_b2b_dispatch_carton exists');

insert into public.users (id, role) values
  ('99d00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('99d00000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE');

insert into public.companies (id, business_name, phone)
values ('99d10000-0000-0000-0000-000000000001', 'FACT-C1 Test Co', '+91-9000000003');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value, order_origin)
values
  ('99d30000-0000-0000-0000-000000000001', 'PGTAP-FACTC1-ORD-1', 'pgtap-factc1-token-1', '99d10000-0000-0000-0000-000000000001', 100000, 'SALES'),
  ('99d30000-0000-0000-0000-000000000002', 'PGTAP-FACTC1-ORD-2', 'pgtap-factc1-token-2', '99d10000-0000-0000-0000-000000000001', 50000, 'SALES');

insert into public.products (id, name, category, sku, hsn_code, barcode_sku)
values
  ('99d40000-0000-0000-0000-000000000001', 'FACT-C1 Product A', 'sweets', 'SKU-FACTC1-A', '1905', 'BC-FACTC1-A'),
  ('99d40000-0000-0000-0000-000000000002', 'FACT-C1 Product B', 'sweets', 'SKU-FACTC1-B', '1905', 'BC-FACTC1-B'),
  ('99d40000-0000-0000-0000-000000000003', 'FACT-C1 Product C', 'sweets', 'SKU-FACTC1-C', '1905', 'BC-FACTC1-C');

insert into public.order_items (id, order_id, product_id, quantity)
values
  ('99d50000-0000-0000-0000-000000000001', '99d30000-0000-0000-0000-000000000001', '99d40000-0000-0000-0000-000000000001', 20),
  ('99d50000-0000-0000-0000-000000000002', '99d30000-0000-0000-0000-000000000001', '99d40000-0000-0000-0000-000000000002', 20),
  ('99d50000-0000-0000-0000-000000000003', '99d30000-0000-0000-0000-000000000002', '99d40000-0000-0000-0000-000000000003', 20);

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values
  ('99d60000-0000-0000-0000-000000000001', 'PGTAP-FACTC1-ORD-1-DC-01', '99d30000-0000-0000-0000-000000000001', 1, 'under_cartonisation', 'road_transporter', 'pgtap-factc1-cons-1'),
  ('99d60000-0000-0000-0000-000000000002', 'PGTAP-FACTC1-ORD-2-DC-01', '99d30000-0000-0000-0000-000000000002', 1, 'under_cartonisation', 'road_transporter', 'pgtap-factc1-cons-2');

insert into public.b2b_dispatch_consignment_lines (
  id, consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty, accepted_ready_qty
) values
  ('99d70000-0000-0000-0000-000000000001', '99d60000-0000-0000-0000-000000000001', '99d50000-0000-0000-0000-000000000001', '99d40000-0000-0000-0000-000000000001', 'SKU-FACTC1-A', 'PACK', 20, 20, 10),
  ('99d70000-0000-0000-0000-000000000002', '99d60000-0000-0000-0000-000000000001', '99d50000-0000-0000-0000-000000000002', '99d40000-0000-0000-0000-000000000002', 'SKU-FACTC1-B', 'PACK', 20, 20, 10),
  ('99d70000-0000-0000-0000-000000000003', '99d60000-0000-0000-0000-000000000002', '99d50000-0000-0000-0000-000000000003', '99d40000-0000-0000-0000-000000000003', 'SKU-FACTC1-C', 'PACK', 20, 20, 10);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';

select public.open_b2b_dispatch_carton('99d60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-FACTC1-CARTON-1');
select public.open_b2b_dispatch_carton('99d60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-FACTC1-CARTON-2');

-- carton1 = PGTAP-FACTC1-CARTON-1's id, carton2 = PGTAP-FACTC1-CARTON-2's id,
-- referenced throughout via inline subquery rather than a captured variable.

-- 4: unauthorised caller cannot scan.
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-A', 'BATCH-1', 5, 'pgtap-factc1-scan-unauth')$$,
  'Not authorised to record a dispatch carton scan', 'a non-dispatch role cannot record a carton scan'
);

-- 5: unauthorised caller cannot record evidence.
select throws_ok(
  $$select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 1.0, 1.2, 'photo-x', 'pgtap-factc1-evidence-unauth')$$,
  'Not authorised to record dispatch carton evidence', 'a non-dispatch role cannot record carton evidence'
);

-- 6: unauthorised caller cannot lock.
select throws_ok(
  $$select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 1, 'pgtap-factc1-lock-unauth')$$,
  'Not authorised to lock a dispatch carton', 'a non-dispatch role cannot lock a carton'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';

-- 7: cross-order/cross-consignment contamination is rejected (line3 belongs
-- to a different consignment than carton1).
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000003'::uuid, 'BC-FACTC1-C', 'BATCH-1', 5, 'pgtap-factc1-scan-wrongso')$$,
  '%different consignment%', 'a consignment line from a different consignment is rejected'
);
select is(
  (select scan_result from public.b2b_dispatch_product_scan_events where correlation_id = 'pgtap-factc1-scan-wrongso'),
  'blocked_wrong_so', 'the wrong-consignment attempt is logged as blocked_wrong_so'
);

-- 8: a barcode that resolves to a different product than the declared line
-- is rejected (server-side resolution, not the client-declared identity).
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-B', 'BATCH-1', 5, 'pgtap-factc1-scan-wrongproduct')$$,
  '%does not match the expected product%', 'a barcode resolving to the wrong product is rejected'
);
select is(
  (select scan_result from public.b2b_dispatch_product_scan_events where correlation_id = 'pgtap-factc1-scan-wrongproduct'),
  'blocked_wrong_product', 'the wrong-product attempt is logged as blocked_wrong_product'
);

-- 9: a blank batch/lot is rejected.
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-A', '  ', 5, 'pgtap-factc1-scan-nobatch')$$,
  '%batch/lot is required%', 'a blank batch/lot is rejected'
);

-- 10: an expired item is rejected.
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-A', 'BATCH-1', 5, 'pgtap-factc1-scan-expired', current_date - 1)$$,
  '%expiry date in the past%', 'an expired item is rejected'
);

-- 11,12: a valid scan succeeds and reconciles packed_qty.
select lives_ok(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-A', 'BATCH-1', 5, 'pgtap-factc1-scan-valid-1')$$,
  'a valid scan matching product/line/batch succeeds'
);
select is(
  (select packed_qty from public.b2b_dispatch_consignment_lines where id = '99d70000-0000-0000-0000-000000000001'),
  5::numeric, 'packed_qty reconciles to the scanned quantity'
);

-- 13: retrying the identical correlation id is idempotent (returns the same
-- item, does not double-count packed_qty).
select is(
  (select (public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-A', 'BATCH-1', 5, 'pgtap-factc1-scan-valid-1')).id),
  (select id from public.b2b_dispatch_carton_items where barcode_value = 'BC-FACTC1-A' and carton_id = (select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1')),
  'retrying the same correlation id is idempotent'
);
select is(
  (select packed_qty from public.b2b_dispatch_consignment_lines where id = '99d70000-0000-0000-0000-000000000001'),
  5::numeric, 'the idempotent retry did not double-apply packed_qty'
);

-- 14: a genuine duplicate scan of the same barcode (new correlation id) is
-- rejected -- the physical item was already recorded on this carton.
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC1-A', 'BATCH-1', 1, 'pgtap-factc1-scan-dup')$$,
  '%already been scanned%', 'a genuine duplicate scan of the same barcode is rejected'
);

-- 15: a scan that would push packed_qty past accepted_ready_qty (10) is
-- rejected -- a second physical unit (SKU as an alternate barcode) for the
-- same product/line, quantity 6 on top of the 5 already packed.
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, 'SKU-FACTC1-A', 'BATCH-1', 6, 'pgtap-factc1-scan-excess')$$,
  '%exceed the accepted-ready quantity%', 'scanning past accepted_ready_qty is rejected'
);

-- 16: direct table mutation remains closed even for an authorised dispatch
-- role -- this exercises the actual Postgres GRANT (REVOKE ... FROM
-- authenticated), not just the RLS predicate, so it must switch the real
-- session role, not merely the JWT claim GUC.
set local role authenticated;
select throws_ok(
  $$insert into public.b2b_dispatch_carton_items (carton_id, consignment_line_id, order_item_id, product_id, product_code, barcode_value, batch_lot, uom, quantity) values ((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000001'::uuid, '99d50000-0000-0000-0000-000000000001'::uuid, '99d40000-0000-0000-0000-000000000001'::uuid, 'SKU-FACTC1-A', 'BC-DIRECT-WRITE', 'BATCH-1', 'PACK', 1)$$,
  'a direct INSERT into carton_items is rejected regardless of role'
);
reset role;

-- 17: locking without evidence is rejected.
select throws_like(
  $$select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 1, 'pgtap-factc1-lock-noevidence')$$,
  '%missing required weight or photo evidence%', 'locking without weight/photo evidence is rejected'
);

-- 18: invalid weight (gross < net) is rejected.
select throws_like(
  $$select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 2.0, 1.0, 'photo-1', 'pgtap-factc1-evidence-badweight')$$,
  '%Gross weight cannot be less than net weight%', 'gross weight less than net weight is rejected'
);

-- 19: valid evidence is recorded.
select lives_ok(
  $$select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 1.0, 1.2, 'photo-1', 'pgtap-factc1-evidence-valid')$$,
  'valid weight and photo evidence is recorded'
);

-- 20: locking with a stale expected_version is rejected (optimistic
-- concurrency) -- carton1's real current_version is still 1 at this point
-- (evidence recording does not bump it), so 99 is deliberately wrong.
select throws_like(
  $$select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 99, 'pgtap-factc1-lock-staleversion')$$,
  '%has changed since it was loaded%', 'locking with a stale/wrong expected version is rejected'
);

-- 21,22: a valid lock succeeds with the correct expected_version, and the
-- version increments.
select lives_ok(
  $$select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 1, 'pgtap-factc1-lock-valid')$$,
  'a valid lock with matching evidence and version succeeds'
);
select is(
  (select status from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'),
  'locked', 'the carton is now locked'
);

-- 23: a second lock attempt (replay) is rejected, not silently accepted.
select throws_like(
  $$select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), 2, 'pgtap-factc1-lock-replay')$$,
  '%already locked%', 'locking an already-locked carton is rejected'
);

-- 24: mutation after lock -- scanning further contents into a locked carton
-- is rejected.
select throws_like(
  $$select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-1'), '99d70000-0000-0000-0000-000000000002'::uuid, 'BC-FACTC1-B', 'BATCH-1', 1, 'pgtap-factc1-scan-afterlock')$$,
  '%can no longer accept scanned contents%', 'scanning into a locked carton is rejected'
);

-- 25,26: an empty carton (no scanned items) cannot be locked, even with
-- evidence recorded.
select lives_ok(
  $$select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-2'), 0.5, 0.6, 'photo-2', 'pgtap-factc1-evidence-carton2')$$,
  'evidence can be recorded on a second, still-empty carton'
);
select throws_like(
  $$select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC1-CARTON-2'), 1, 'pgtap-factc1-lock-empty')$$,
  '%no scanned contents%', 'a carton with no scanned items cannot be locked'
);

select * from finish();
rollback;
