begin;
-- Contract coverage for 20260820100000_3pgs_governed_fulfilment_authority.sql
-- (3PGS-B): the missing create-receipt step ahead of the ALREADY-GOVERNED
-- record_b2b_inventory_receipt / accept_b2b_inventory_receipt (20260805120000,
-- reused unmodified here -- see the migration's file header for why they are
-- NOT reimplemented), the minimal procurement/vendor-shortage bridge, and the
-- bridge connecting P&A's b2b_assembly_3pgs_requirements into the existing,
-- unmodified reserve_rgs_stock / issue_rgs_stock / acknowledge_rgs_issue
-- pipeline.
select plan(71);

select has_function('public', 'create_b2b_inventory_receipt', 'create_b2b_inventory_receipt exists');
select has_function('public', 'record_b2b_inventory_receipt', 'the pre-existing record_b2b_inventory_receipt is reused, not duplicated');
select has_function('public', 'accept_b2b_inventory_receipt', 'the pre-existing accept_b2b_inventory_receipt is reused, not duplicated');
select has_function('public', 'create_procurement_requirement', 'create_procurement_requirement exists');
select has_function('public', 'assign_procurement_vendor', 'assign_procurement_vendor exists');
select has_function('public', 'link_procurement_receipt', 'link_procurement_receipt exists');
select has_function('public', 'reserve_3pgs_requirement_stock', 'reserve_3pgs_requirement_stock exists');
select has_function('public', 'issue_3pgs_requirement_stock', 'issue_3pgs_requirement_stock exists');
select has_function('public', 'acknowledge_3pgs_requirement_receipt', 'acknowledge_3pgs_requirement_receipt exists');

-- Direct table writes are governed, not open.
select is(
  (select has_table_privilege('authenticated', 'public.b2b_inventory_receipts', 'INSERT')),
  false, 'authenticated cannot directly insert b2b_inventory_receipts'
);
select is(
  (select has_table_privilege('authenticated', 'public.b2b_inventory_receipt_lines', 'UPDATE')),
  false, 'authenticated cannot directly update b2b_inventory_receipt_lines'
);
select is(
  (select has_table_privilege('anon', 'public.b2b_procurement_requirements', 'SELECT')),
  false, 'anon has no privilege at all on b2b_procurement_requirements'
);
select is(
  (select has_table_privilege('authenticated', 'public.b2b_procurement_requirements', 'INSERT')),
  false, 'authenticated cannot directly insert b2b_procurement_requirements'
);

-- =================================================================================
-- Fixtures
-- =================================================================================
-- Dispatcher is INVENTORY_MANAGER (not STORE_INCHARGE): accept_b2b_inventory_receipt
-- (Phase 4, 20260805140000) additionally requires can_access_b2b_inventory_store,
-- which is satisfied globally for SUPER_ADMIN/ADMIN/OPERATIONS_MANAGER/
-- INVENTORY_MANAGER and otherwise requires a per-store b2b_inventory_store_assignments
-- row -- out of scope for this bridge/procurement test, so the global-role path is used.
insert into public.users (id, role) values
  ('57000000-0000-0000-0000-000000000001', 'INVENTORY_MANAGER'),   -- dispatcher: manage + receive + store-assignment-exempt
  ('57000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS'),   -- distinct receiver: manage + receive authority
  ('57000000-0000-0000-0000-000000000003', 'SALES_EXECUTIVE');     -- staff, no inventory authority at all
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('67000000-0000-0000-0000-000000000001', 'Ribbon Packaging 3PGS', 'packaging', 'RIBBON-3PGS-1', '4823', null),
  ('67000000-0000-0000-0000-000000000002', 'Gift Box Inward 3PGS', 'packaging', 'GIFTBOX-3PGS-1', '4823', null),
  ('67000000-0000-0000-0000-000000000003', 'Never-Stocked 3PGS Item', 'packaging', 'EMPTY-3PGS-1', '4823', null);
insert into public.orders (id, order_number, tracking_token) values
  ('77000000-0000-0000-0000-000000000001', 'PGTAP-ORD-3PGSB-1', 'pgtap-fixture-token-3pgsb-1');

set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- =================================================================================
-- The one missing inward step: opening the receipt. Everything downstream
-- (record_b2b_inventory_receipt / accept_b2b_inventory_receipt) is the
-- EXISTING, unmodified Phase 3 governed authority -- both require the SAME
-- correlation_id the receipt was created with (a mismatch is refused).
-- =================================================================================
select lives_ok(
  $$ select public.create_b2b_inventory_receipt(
       'PGTAP-RCPT-1', 'opening_balance', '3PGS', 'manual_count', 'PGTAP-RCPT-1-REF',
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000002', 'sku', 'GIFTBOX-3PGS-1', 'expected_qty', 20)),
       'corr-rcpt-1'
     ) $$,
  'create_b2b_inventory_receipt opens a receipt with its expected line'
);
select is(
  (select status from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
  'expected', 'new receipt starts expected'
);
select is(
  (select count(*)::int from public.b2b_inventory_receipt_lines l
     join public.b2b_inventory_receipts r on r.id = l.receipt_id
     where r.receipt_number = 'PGTAP-RCPT-1'),
  1, 'exactly one expected line was created'
);
select lives_ok(
  $$ select public.create_b2b_inventory_receipt(
       'PGTAP-RCPT-1-REPLAY', 'opening_balance', '3PGS', 'manual_count', 'PGTAP-RCPT-1-REF',
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000002', 'sku', 'GIFTBOX-3PGS-1', 'expected_qty', 999)),
       'corr-rcpt-1'
     ) $$,
  'a replayed create correlation id does not error'
);
select is(
  (select receipt_number from public.b2b_inventory_receipts where correlation_id = 'corr-rcpt-1'),
  'PGTAP-RCPT-1', 'the replay returned the ORIGINAL receipt, not a second one with the different number/qty'
);
select is(
  (select count(*)::int from public.b2b_inventory_receipts where correlation_id = 'corr-rcpt-1'),
  1, 'idempotent replay created no duplicate receipt row'
);
select throws_like(
  $$ select public.create_b2b_inventory_receipt(
       'PGTAP-RCPT-BAD', 'opening_balance', '3PGS', 'manual_count', 'PGTAP-RCPT-BAD-REF',
       '[]'::jsonb, 'corr-rcpt-bad-1'
     ) $$,
  '%At least one receipt line is required%',
  'a receipt with zero lines is refused'
);

-- record_b2b_inventory_receipt / accept_b2b_inventory_receipt require the
-- SAME correlation_id the receipt carries (their own mismatch guard) -- this
-- is the pre-existing contract, exercised here, not altered.
select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id = (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1')),
         'received_qty', 20
       )),
       'corr-rcpt-1'
     ) $$,
  'the existing record_b2b_inventory_receipt transitions our new receipt to received'
);
select is(
  (select status from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
  'received', 'receipt is now received'
);
select throws_like(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id = (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1')),
         'received_qty', 20
       )),
       'corr-rcpt-1'
     ) $$,
  '%already been recorded or closed%',
  're-recording an already-received receipt is refused, not silently repeated'
);

-- Partial acceptance: 20 received, 14 accepted, 3 damaged, 3 rejected --
-- the existing RPC requires every received unit dispositioned in one call.
select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id = (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1')),
         'accepted_qty', 14, 'damaged_qty', 3, 'rejected_qty', 3, 'expected_balance_version', 0
       )),
       'corr-rcpt-1'
     ) $$,
  'the existing accept_b2b_inventory_receipt records a partial disposition'
);
select is(
  (select status from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
  'partially_accepted', 'receipt is partially_accepted (damaged/rejected qty exists)'
);
select is(
  (select coalesce(sum(quantity), 0) from public.inventory_movements
     where movement_type = 'inventory_hold' and correlation_id like 'corr-rcpt-1:grn-hold:%'
       and product_id = '67000000-0000-0000-0000-000000000002' and sku = 'GIFTBOX-3PGS-1'),
  14::numeric, 'the accepted 14 units are held pending GRN put-away/finalisation (Phase 4), not yet posted to available stock'
);
select is(
  (select available_qty from public.inventory_stock_balances where product_id = '67000000-0000-0000-0000-000000000002' and sku = 'GIFTBOX-3PGS-1' and location_code = '3PGS'),
  0::numeric, 'available stock is net zero immediately after acceptance -- Phase 4 credits then immediately holds the accepted quantity until finalise_b2b_inventory_grn'
);
select throws_like(
  $$ select public.accept_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id = (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-1')),
         'accepted_qty', 999, 'damaged_qty', 0, 'rejected_qty', 0, 'expected_balance_version', 1
       )),
       'corr-rcpt-1'
     ) $$,
  '%not awaiting acceptance%',
  're-accepting an already partially_accepted receipt is refused outright -- accept is a single-shot disposition, not incremental'
);

set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000003';
select throws_like(
  $$ select public.create_b2b_inventory_receipt(
       'PGTAP-RCPT-DENIED', 'opening_balance', '3PGS', 'manual_count', 'X',
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000002', 'sku', 'GIFTBOX-3PGS-1', 'expected_qty', 1)),
       'corr-rcpt-denied-1'
     ) $$,
  '%Not authorised%',
  'a staff member without inventory receive authority cannot create an inventory receipt'
);
set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000001';

-- =================================================================================
-- Procurement / vendor-shortage bridge
-- =================================================================================
select lives_ok(
  $$ select public.create_procurement_requirement(
       'manual', 'PGTAP-PROC-SRC-1', '67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1',
       '3PGS', 25, 'corr-proc-create-1'
     ) $$,
  'create_procurement_requirement opens a shortage-to-vendor record'
);
select is(
  (select status from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
  'open', 'new procurement requirement starts open'
);
select throws_like(
  $$ select public.create_procurement_requirement(
       'manual', 'PGTAP-PROC-SRC-BAD', '67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1',
       '3PGS', 0, 'corr-proc-create-bad'
     ) $$,
  '%Shortage quantity must be positive%',
  'a non-positive shortage quantity is refused'
);
select lives_ok(
  $$ select public.assign_procurement_vendor(
       (select id from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
       'Acme Packaging Supplier', now() + interval '5 days', 'corr-proc-vendor-1'
     ) $$,
  'assign_procurement_vendor records a vendor reference and ETA'
);
select is(
  (select status from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
  'vendor_assigned', 'procurement requirement is now vendor_assigned'
);

-- Fully receive + accept an inward receipt for RIBBON-3PGS-1 at 3PGS via the
-- SAME reused governed pipeline, then link it (bookkeeping only -- no double
-- stock movement, acceptance already credited it). This is also what stocks
-- 3PGS with the RIBBON-3PGS-1 the bridge section below reserves against.
select lives_ok(
  $$ select public.create_b2b_inventory_receipt(
       'PGTAP-RCPT-PROC-1', 'supplier', '3PGS', 'purchase_order', 'PGTAP-PROC-SRC-1',
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000001', 'sku', 'RIBBON-3PGS-1', 'expected_qty', 25)),
       'corr-rcpt-proc-1', '57000000-0000-0000-0000-000000000001'::uuid
     ) $$,
  'a supplier receipt is opened against the procurement shortage'
);
select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-PROC-1'),
       jsonb_build_array(jsonb_build_object('line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id = (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-PROC-1')), 'received_qty', 25)),
       'corr-rcpt-proc-1'
     ) $$, 'the procurement receipt is recorded as received'
);
select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-PROC-1'),
       jsonb_build_array(jsonb_build_object('line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id = (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-PROC-1')), 'accepted_qty', 25, 'damaged_qty', 0, 'rejected_qty', 0, 'expected_balance_version', 0)),
       'corr-rcpt-proc-1'
     ) $$, 'the procurement receipt is fully accepted (Phase 4 holds the 25 units pending GRN put-away/finalisation -- out of scope here; link_procurement_receipt only needs the receipt status, not credited stock)'
);
select lives_ok(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-PROC-1'),
       25, 'corr-proc-link-1'
     ) $$,
  'link_procurement_receipt records the fulfilment linkage'
);
select is(
  (select status || '|' || fulfilled_qty::text from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
  'received|25', 'the procurement requirement is fully received and fulfilled_qty matches exactly'
);
select lives_ok(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
       (select id from public.b2b_inventory_receipts where receipt_number = 'PGTAP-RCPT-PROC-1'),
       1, 'corr-proc-link-overshoot'
     ) $$,
  'linking further fulfilment onto an already-received procurement requirement is a no-op, not an error'
);
select is(
  (select status || '|' || fulfilled_qty::text from public.b2b_procurement_requirements where correlation_id = 'corr-proc-create-1'),
  'received|25', 'the no-op left status and fulfilled_qty unchanged -- fulfilment was never double-counted'
);

-- =================================================================================
-- Bridge: P&A 3PGS requirement -> reserve_rgs_stock / issue_rgs_stock /
-- acknowledge_rgs_issue -> fulfil_assembly_3pgs_requirement
-- =================================================================================

-- Scenario A: full availability. The procurement receipt above only proved
-- link_procurement_receipt's bookkeeping (its 25 units are held pending GRN,
-- not available -- see Phase 4 above; GRN put-away/finalisation is out of
-- scope for this bridge test). Seed available stock directly as a fixture.
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1', '3PGS', 25)
  on conflict (product_id, sku, location_code) do update set available_qty = excluded.available_qty;
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-3PGSB-BRIDGE-1', '77000000-0000-0000-0000-000000000001',
       '67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1', 5,
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000001', 'sku', 'RIBBON-3PGS-1', 'source_store_code', '3PGS', 'required_qty', 12)),
       'corr-3pgsb-job-1'
     ) $$,
  'a P&A assembly job with a fully-stocked 3PGS-sourced component is created'
);
select lives_ok(
  $$ select public.create_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSB-BRIDGE-1')),
       10, 'high', 'corr-3pgsb-req-full-1'
     ) $$,
  'a 3PGS requirement (full-availability scenario) is raised'
);
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-full-1'),
       'high', 'corr-3pgsb-reserve-full-1'
     ) $$,
  'reserve_3pgs_requirement_stock reserves against the existing reserve_rgs_stock pipeline'
);
select is(
  (select reserved_qty || '|' || reservation_status || '|' || demand_source_type from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-full-1'),
  '10|reserved|pna', 'full stock reserves the full requested quantity, tagged as a pna demand source'
);
select lives_ok(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-full-1'),
       (select id from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-full-1'),
       10, 'corr-3pgsb-issue-full-1'
     ) $$,
  'issue_3pgs_requirement_stock dispatches against the explicit reservation supplied by the caller'
);
select is(
  (select destination_type from public.rgs_issue_events where correlation_id = 'corr-3pgsb-issue-full-1'),
  'pna', 'the issue event is tagged as a pna destination'
);

-- Self-acknowledgement (dispatcher = receiver) must fail closed.
select throws_like(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-3pgsb-issue-full-1'),
       10, 'corr-3pgsb-ack-self-1'
     ) $$,
  '%must be a different actor than whoever issued it%',
  'the same actor who dispatched the stock cannot acknowledge its own receipt (P&A cannot self-fulfil)'
);

set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-3pgsb-issue-full-1'),
       10, 'corr-3pgsb-ack-full-1'
     ) $$,
  'a genuinely distinct receiver can acknowledge the receipt'
);
select is(
  (select status || '|' || fulfilled_qty::text from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-full-1'),
  'fulfilled|10', 'the P&A 3PGS requirement is fulfilled via the SAME acknowledge_rgs_issue + fulfil_assembly_3pgs_requirement path -- neither RPC was altered by this migration'
);
set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000001';

-- An already-fulfilled requirement cannot be reserved against again.
select throws_like(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-full-1'),
       'high', 'corr-3pgsb-reserve-refulfilled-1'
     ) $$,
  '%already%',
  'a fulfilled 3PGS requirement cannot be reserved against again'
);

-- Scenario B/C use a NEVER-STOCKED product so stock genuinely stays at
-- zero -- ASM-3PGSB-BRIDGE-1's component above now carries real remaining
-- stock (15 units) and would falsify a "zero availability" claim.
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-3PGSB-BRIDGE-2', '77000000-0000-0000-0000-000000000001',
       '67000000-0000-0000-0000-000000000003', 'EMPTY-3PGS-1', 3,
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000003', 'sku', 'EMPTY-3PGS-1', 'source_store_code', '3PGS', 'required_qty', 7)),
       'corr-3pgsb-job-2'
     ) $$,
  'a second P&A assembly job with a genuinely never-stocked 3PGS component is created'
);

-- Scenario B: zero availability -- the reservation stays pending and issue
-- must refuse (nothing was ever reserved to issue).
select lives_ok(
  $$ select public.create_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSB-BRIDGE-2')),
       7, 'normal', 'corr-3pgsb-req-zero-1'
     ) $$,
  'a 3PGS requirement (zero-availability scenario) is raised'
);
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-zero-1'),
       'normal', 'corr-3pgsb-reserve-zero-1'
     ) $$,
  'reserve_3pgs_requirement_stock does not error even when no stock is available'
);
select is(
  (select reserved_qty || '|' || reservation_status from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-zero-1'),
  '0|pending', 'zero available stock reserves nothing and leaves the reservation pending -- no stock is fabricated'
);
select throws_like(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-zero-1'),
       (select id from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-zero-1'),
       1, 'corr-3pgsb-issue-zero-1'
     ) $$,
  '%cannot exceed reserved quantity%',
  'nothing can be issued against a requirement with zero reserved stock'
);

-- Scenario C: issue_3pgs_requirement_stock must refuse a reservation that
-- does not belong to the requirement it is invoked against -- an operator
-- (or a bug) cannot issue requirement X's stock by pointing at requirement
-- Y's reservation. Also proves a bogus/nonexistent reservation id is refused.
select lives_ok(
  $$ select public.create_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSB-BRIDGE-2')),
       3, 'normal', 'corr-3pgsb-req-noreserve-1'
     ) $$,
  'a third 3PGS requirement (never reserved) is raised'
);
select throws_like(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-noreserve-1'),
       '00000000-0000-0000-0000-000000000000'::uuid,
       1, 'corr-3pgsb-issue-noreserve-1'
     ) $$,
  '%Reservation not found%',
  'issuing against a nonexistent reservation id is refused'
);
select throws_like(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-noreserve-1'),
       (select id from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-zero-1'),
       1, 'corr-3pgsb-issue-wrongreservation-1'
     ) $$,
  '%does not belong to 3PGS requirement%',
  'issuing a DIFFERENT requirement''s reservation against this one is refused (no cross-requirement stock diversion)'
);

-- acknowledge_3pgs_requirement_receipt must refuse an issue event that was
-- never dispatched against a P&A 3PGS requirement (a plain b2b issue).
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1', 'FINISHED_GOODS', 5)
  on conflict do nothing;
select public.reserve_rgs_stock(
  'PGTAP-B2B-RESV-1', '77000000-0000-0000-0000-000000000001', '67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1',
  5, 'PACKING_ASSEMBLY', 'corr-3pgsb-nonpna-reserve-1', 'normal', 'FINISHED_GOODS'
);
select public.issue_rgs_stock(
  (select id from public.inventory_reservations where correlation_id = 'corr-3pgsb-nonpna-reserve-1'),
  5, 'b2b', 'PGTAP-ORD-3PGSB-1', 'corr-3pgsb-nonpna-issue-1'
);
set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000002';
select throws_like(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-3pgsb-nonpna-issue-1'),
       5, 'corr-3pgsb-nonpna-ack-1'
     ) $$,
  '%was not dispatched against a P&A 3PGS requirement%',
  'the 3PGS bridge acknowledgement refuses an issue event that was never a pna-destination dispatch'
);
set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000001';

-- Unauthorized role is blocked on the bridge RPCs.
set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000003';
select throws_like(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-noreserve-1'),
       'normal', 'corr-3pgsb-reserve-denied-1'
     ) $$,
  '%Not authorised%',
  'a staff member without inventory manage authority cannot reserve 3PGS requirement stock'
);
select throws_like(
  $$ select public.create_procurement_requirement(
       'manual', 'PGTAP-PROC-DENIED', '67000000-0000-0000-0000-000000000001', 'RIBBON-3PGS-1',
       '3PGS', 5, 'corr-proc-denied-1'
     ) $$,
  '%Not authorised%',
  'a staff member without inventory manage authority cannot raise a procurement requirement'
);
set local request.jwt.claim.sub = '57000000-0000-0000-0000-000000000001';

-- =================================================================================
-- Read-only deterministic priority view: P&A(1) < Outlet(2) < B2B(3) < Internal(4);
-- read-only, never allocates or preempts anything itself.
-- =================================================================================
select is(
  (select priority_rank from public.b2b_3pgs_pending_demand_priority
     where demand_reference = (select requirement_number from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-noreserve-1')),
  1, 'an open P&A 3PGS requirement carries priority_rank 1 in the view'
);
-- A genuinely outstanding, non-pna (outlet) 3PGS-family reservation ranks
-- below P&A (2, not 1) and reports the correct remaining outstanding_qty.
select public.reserve_rgs_stock(
  p_reservation_number := 'PGTAP-OUTLET-RESV-1', p_order_id := NULL,
  p_product_id := '67000000-0000-0000-0000-000000000003', p_sku := 'EMPTY-3PGS-1',
  p_requested_qty := 5, p_source_department := 'OUTLET',
  p_correlation_id := 'corr-3pgsb-outlet-reserve-1', p_priority := 'normal',
  p_location_code := '3PGS', p_demand_source_type := 'outlet',
  p_demand_reference := 'PGTAP-OUTLET-DEMAND-1'
);
select is(
  (select priority_rank || '|' || outstanding_qty::text from public.b2b_3pgs_pending_demand_priority
     where demand_reference = 'PGTAP-OUTLET-DEMAND-1'),
  '2|5', 'an outlet demand at a 3PGS-family location ranks below P&A (2) and reports its full unreserved quantity as outstanding -- no stock existed to allocate any of it'
);
select is(
  (select count(*)::int from public.b2b_3pgs_pending_demand_priority
     where demand_reference = (select requirement_number from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-full-1')),
  0, 'a fulfilled P&A 3PGS requirement no longer appears in the pending priority view'
);

-- =================================================================================
-- reserve_3pgs_requirement_stock must not over-allocate when reserved against
-- more than once: a second reservation attempt (once more stock arrives)
-- must request only the OUTSTANDING remainder, not the full original amount
-- on top of what an earlier, still-active reservation already holds.
-- =================================================================================
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('67000000-0000-0000-0000-000000000004', 'Double-Reserve 3PGS Item', 'packaging', 'DBLRSV-3PGS-1', '4823', null);
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-3PGSB-BRIDGE-3', '77000000-0000-0000-0000-000000000001',
       '67000000-0000-0000-0000-000000000004', 'DBLRSV-3PGS-1', 4,
       jsonb_build_array(jsonb_build_object('product_id', '67000000-0000-0000-0000-000000000004', 'sku', 'DBLRSV-3PGS-1', 'source_store_code', '3PGS', 'required_qty', 20)),
       'corr-3pgsb-job-3'
     ) $$,
  'a third P&A assembly job is created for the double-reservation proof'
);
select lives_ok(
  $$ select public.create_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSB-BRIDGE-3')),
       20, 'normal', 'corr-3pgsb-req-dblrsv-1'
     ) $$,
  'a 20-unit 3PGS requirement is raised for the double-reservation proof'
);
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('67000000-0000-0000-0000-000000000004', 'DBLRSV-3PGS-1', '3PGS', 8);
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-dblrsv-1'),
       'normal', 'corr-3pgsb-reserve-dblrsv-first-1'
     ) $$,
  'the first reservation attempt reserves the 8 units currently available'
);
select is(
  (select reserved_qty::text || '|' || reservation_status from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-dblrsv-first-1'),
  '8|partially_reserved', 'the first reservation holds 8 of the 20 required, leaving 12 outstanding'
);
update public.inventory_stock_balances set available_qty = available_qty + 12
  where product_id = '67000000-0000-0000-0000-000000000004' and sku = 'DBLRSV-3PGS-1' and location_code = '3PGS';
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where correlation_id = 'corr-3pgsb-req-dblrsv-1'),
       'normal', 'corr-3pgsb-reserve-dblrsv-second-1'
     ) $$,
  'a second reservation attempt succeeds once the remainder of stock arrives'
);
select is(
  (select requested_qty::text || '|' || reserved_qty::text || '|' || reservation_status from public.inventory_reservations where correlation_id = 'corr-3pgsb-reserve-dblrsv-second-1'),
  '12|12|reserved', 'the second reservation targeted only the 12-unit OUTSTANDING remainder, not the full 20 again -- the 8 already held by the first reservation was correctly subtracted'
);

select * from finish();
rollback;
