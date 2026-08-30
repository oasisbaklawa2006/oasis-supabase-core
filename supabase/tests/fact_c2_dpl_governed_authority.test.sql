begin;
-- Contract coverage for 20260830120000_fact_c2_dpl_governed_authority.sql.
select plan(32);

select has_function('public', 'create_b2b_dispatch_packing_list', 'create_b2b_dispatch_packing_list exists');
select has_function('public', 'supersede_b2b_dispatch_packing_list', 'supersede_b2b_dispatch_packing_list exists');
select has_function('public', 'submit_b2b_dispatch_packing_list_to_finance', 'submit_b2b_dispatch_packing_list_to_finance exists');

insert into public.users (id, role) values
  ('99e00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('99e00000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE');

insert into public.companies (id, business_name, phone)
values ('99e10000-0000-0000-0000-000000000001', 'FACT-C2 Test Co', '+91-9000000004');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value, order_origin)
values ('99e30000-0000-0000-0000-000000000001', 'PGTAP-FACTC2-ORD-1', 'pgtap-factc2-token-1', '99e10000-0000-0000-0000-000000000001', 100000, 'SALES');

insert into public.products (id, name, category, sku, hsn_code, barcode_sku)
values
  ('99e40000-0000-0000-0000-000000000001', 'FACT-C2 Product A', 'sweets', 'SKU-FACTC2-A', '1905', 'BC-FACTC2-A'),
  ('99e40000-0000-0000-0000-000000000002', 'FACT-C2 Product B', 'sweets', 'SKU-FACTC2-B', '1905', 'BC-FACTC2-B'),
  ('99e40000-0000-0000-0000-000000000004', 'FACT-C2 Product D', 'sweets', 'SKU-FACTC2-D', '1905', 'BC-FACTC2-D'),
  ('99e40000-0000-0000-0000-000000000005', 'FACT-C2 Product E', 'sweets', 'SKU-FACTC2-E', '1905', 'BC-FACTC2-E');

insert into public.order_items (id, order_id, product_id, quantity)
values
  ('99e50000-0000-0000-0000-000000000001', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000001', 10),
  ('99e50000-0000-0000-0000-000000000002', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000002', 5),
  ('99e50000-0000-0000-0000-000000000004', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000004', 5),
  ('99e50000-0000-0000-0000-000000000005', '99e30000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000005', 8);

-- cons1: primary happy-path consignment. cons2: secondary, used for
-- cross-consignment contamination checks. cons3: zero cartons (empty
-- rejection). cons4: one carton, deliberately left unlocked (unlocked
-- rejection). cons5: fully locked but its packed_qty is tampered directly
-- after locking, to prove reconciliation is re-validated at DPL time, not
-- merely trusted from FACT-C1's own bookkeeping.
insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values
  ('99e60000-0000-0000-0000-000000000001', 'PGTAP-FACTC2-ORD-1-DC-01', '99e30000-0000-0000-0000-000000000001', 1, 'under_cartonisation', 'road_transporter', 'pgtap-factc2-cons-1'),
  ('99e60000-0000-0000-0000-000000000002', 'PGTAP-FACTC2-ORD-1-DC-02', '99e30000-0000-0000-0000-000000000001', 2, 'under_cartonisation', 'road_transporter', 'pgtap-factc2-cons-2'),
  ('99e60000-0000-0000-0000-000000000003', 'PGTAP-FACTC2-ORD-1-DC-03', '99e30000-0000-0000-0000-000000000001', 3, 'under_cartonisation', 'road_transporter', 'pgtap-factc2-cons-3'),
  ('99e60000-0000-0000-0000-000000000004', 'PGTAP-FACTC2-ORD-1-DC-04', '99e30000-0000-0000-0000-000000000001', 4, 'under_cartonisation', 'road_transporter', 'pgtap-factc2-cons-4'),
  ('99e60000-0000-0000-0000-000000000005', 'PGTAP-FACTC2-ORD-1-DC-05', '99e30000-0000-0000-0000-000000000001', 5, 'under_cartonisation', 'road_transporter', 'pgtap-factc2-cons-5');

insert into public.b2b_dispatch_consignment_lines (
  id, consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty, accepted_ready_qty
) values
  ('99e70000-0000-0000-0000-000000000001', '99e60000-0000-0000-0000-000000000001', '99e50000-0000-0000-0000-000000000001', '99e40000-0000-0000-0000-000000000001', 'SKU-FACTC2-A', 'PACK', 10, 10, 10),
  ('99e70000-0000-0000-0000-000000000002', '99e60000-0000-0000-0000-000000000002', '99e50000-0000-0000-0000-000000000002', '99e40000-0000-0000-0000-000000000002', 'SKU-FACTC2-B', 'PACK', 5, 5, 5),
  ('99e70000-0000-0000-0000-000000000004', '99e60000-0000-0000-0000-000000000004', '99e50000-0000-0000-0000-000000000004', '99e40000-0000-0000-0000-000000000004', 'SKU-FACTC2-D', 'PACK', 5, 5, 5),
  ('99e70000-0000-0000-0000-000000000005', '99e60000-0000-0000-0000-000000000005', '99e50000-0000-0000-0000-000000000005', '99e40000-0000-0000-0000-000000000005', 'SKU-FACTC2-E', 'PACK', 8, 8, 8);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000001';

-- Bring cons1 and cons2 to a fully locked, fully-reconciled single-carton
-- state via the existing FACT-C1 authority (open -> scan -> evidence -> lock).
select public.open_b2b_dispatch_carton('99e60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-FACTC2-CARTON-1');
select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-1'), '99e70000-0000-0000-0000-000000000001'::uuid, 'BC-FACTC2-A', 'BATCH-1', 10, 'pgtap-factc2-scan-1');
select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-1'), 5.0, 5.5, 'photo-1', 'pgtap-factc2-ev-1');
select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-1'), 1, 'pgtap-factc2-lock-1');

select public.open_b2b_dispatch_carton('99e60000-0000-0000-0000-000000000002'::uuid, 'PGTAP-FACTC2-CARTON-2');
select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-2'), '99e70000-0000-0000-0000-000000000002'::uuid, 'BC-FACTC2-B', 'BATCH-1', 5, 'pgtap-factc2-scan-2');
select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-2'), 2.0, 2.5, 'photo-2', 'pgtap-factc2-ev-2');
select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-2'), 1, 'pgtap-factc2-lock-2');

-- cons4: a carton is opened and scanned but never locked (still 'under_packing').
select public.open_b2b_dispatch_carton('99e60000-0000-0000-0000-000000000004'::uuid, 'PGTAP-FACTC2-CARTON-4');
select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-4'), '99e70000-0000-0000-0000-000000000004'::uuid, 'BC-FACTC2-D', 'BATCH-1', 5, 'pgtap-factc2-scan-4');

-- cons5: fully locked and reconciled, then tampered directly (bypassing all
-- governed RPCs, as only a privileged test/service role could) to simulate
-- data corruption that the DPL layer must itself catch, not merely trust.
select public.open_b2b_dispatch_carton('99e60000-0000-0000-0000-000000000005'::uuid, 'PGTAP-FACTC2-CARTON-5');
select public.record_b2b_dispatch_carton_item_scan((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-5'), '99e70000-0000-0000-0000-000000000005'::uuid, 'BC-FACTC2-E', 'BATCH-1', 8, 'pgtap-factc2-scan-5');
select public.record_b2b_dispatch_carton_evidence((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-5'), 3.0, 3.5, 'photo-5', 'pgtap-factc2-ev-5');
select public.lock_b2b_dispatch_carton((select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-FACTC2-CARTON-5'), 1, 'pgtap-factc2-lock-5');
update public.b2b_dispatch_consignment_lines set packed_qty = packed_qty - 1 where id = '99e70000-0000-0000-0000-000000000005';

-- 4,5,6: unauthorised caller cannot create, correct or submit a DPL.
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, 'pgtap-factc2-create-unauth')$$,
  'Not authorised to create a dispatch packing list', 'a non-dispatch role cannot create a DPL'
);
select throws_ok(
  $$select public.supersede_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, gen_random_uuid(), 'reason', 'pgtap-factc2-supersede-unauth')$$,
  'Not authorised to correct a dispatch packing list', 'a non-dispatch role cannot supersede a DPL'
);
select throws_ok(
  $$select public.submit_b2b_dispatch_packing_list_to_finance('99e60000-0000-0000-0000-000000000001'::uuid, gen_random_uuid(), 'pgtap-factc2-submit-unauth')$$,
  'Not authorised to submit a dispatch packing list to Finance', 'a non-dispatch role cannot submit a DPL to Finance'
);
set local request.jwt.claim.sub = '99e00000-0000-0000-0000-000000000001';

-- 7: a consignment with zero cartons cannot generate a DPL.
select throws_like(
  $$select public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000003'::uuid, 'pgtap-factc2-create-nocartons')$$,
  '%has no cartons%', 'a consignment with no cartons cannot generate a DPL'
);

-- 8: a consignment with an unlocked carton cannot generate a DPL.
select throws_like(
  $$select public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000004'::uuid, 'pgtap-factc2-create-unlocked')$$,
  '%unlocked carton%', 'a consignment with an unlocked carton cannot generate a DPL'
);

-- 9,10: a valid creation from fully-locked carton truth succeeds with a
-- deterministic initial version number, and is idempotent on correlation_id.
select is(
  (select version_number from public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, 'pgtap-factc2-create-1')),
  1, 'the first DPL version for a consignment is deterministically version 1'
);
select is(
  (select status from public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, 'pgtap-factc2-create-1')),
  'generated', 'retrying the same create correlation id is idempotent and returns the same generated version'
);

-- 11: a second, non-replay creation attempt is rejected while a current
-- version already exists.
select throws_like(
  $$select public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, 'pgtap-factc2-create-1-again')$$,
  '%already has a current packing list version%', 'creating a second version while a current one exists is rejected'
);

-- 12: cons2 gets its own independent first version, used below for
-- cross-consignment contamination checks.
select is(
  (select version_number from public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000002'::uuid, 'pgtap-factc2-create-2')),
  1, 'cons2 has its own independently versioned DPL'
);

-- 13: a correction with no reason is rejected.
select throws_ok(
  $$select public.supersede_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-1'), '  ', 'pgtap-factc2-supersede-noreason')$$,
  'A reason is required to correct or supersede a packing list version', 'a correction with a blank reason is rejected'
);

-- 14: superseding a nonexistent version id is rejected.
select throws_ok(
  $$select public.supersede_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, gen_random_uuid(), 'correction', 'pgtap-factc2-supersede-notfound')$$,
  'Packing list version not found', 'superseding a nonexistent version id is rejected'
);

-- 15: superseding a version that belongs to a different consignment is
-- rejected (cross-consignment contamination).
select throws_like(
  $$select public.supersede_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-2'), 'correction', 'pgtap-factc2-supersede-crossconsignment')$$,
  '%does not belong to consignment%', 'superseding a version from a different consignment is rejected'
);

-- 16,17,18,19: a valid, reasoned correction supersedes the current version,
-- creates version 2, and the superseded version is preserved with its
-- supersession pointer -- permanently auditable, not deleted or overwritten.
select lives_ok(
  $$select public.supersede_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-1'), 'corrected packed weight', 'pgtap-factc2-supersede-1')$$,
  'a valid, reasoned correction succeeds'
);
select is(
  (select version_number from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'),
  2, 'the correction is recorded as version 2'
);
select is(
  (select status from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-1'),
  'superseded', 'the prior current version is marked superseded, not deleted'
);
select is(
  (select superseded_by from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-1'),
  (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'),
  'the superseded version points to its replacement'
);

-- 20: superseding the now-stale (already-superseded) version again is
-- rejected.
select throws_like(
  $$select public.supersede_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-1'), 'another correction', 'pgtap-factc2-supersede-stale')$$,
  '%already been superseded%', 'superseding an already-superseded (stale) version is rejected'
);

-- 21: submitting a version that belongs to a different consignment is
-- rejected.
select throws_like(
  $$select public.submit_b2b_dispatch_packing_list_to_finance('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-2'), 'pgtap-factc2-submit-crossconsignment')$$,
  '%does not belong to consignment%', 'submitting a version from a different consignment is rejected'
);

-- 22: submitting the superseded (no longer current) version is rejected --
-- only the final active version is eligible for Finance submission.
select throws_like(
  $$select public.submit_b2b_dispatch_packing_list_to_finance('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-1'), 'pgtap-factc2-submit-superseded')$$,
  '%superseded%', 'submitting a superseded version is rejected'
);

-- 23,24,25,26: a valid submission of the current version is explicit and
-- auditable.
select lives_ok(
  $$select public.submit_b2b_dispatch_packing_list_to_finance('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'), 'pgtap-factc2-submit-1')$$,
  'submitting the current version to Finance succeeds'
);
select is(
  (select status from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'),
  'submitted_to_finance', 'the submitted version status reflects submission'
);
select isnt(
  (select submitted_to_finance_at from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'),
  NULL, 'submitted_to_finance_at is recorded'
);
select is(
  (select finance_check_state from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'),
  'pending', 'finance_check_state is set to pending on submission; Finance verification is a separate, later authority'
);

-- 27: attempting to submit the already-submitted version again (a fresh
-- correlation id, not a replay) is rejected -- mutation after submission.
select throws_like(
  $$select public.submit_b2b_dispatch_packing_list_to_finance('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'), 'pgtap-factc2-submit-again')$$,
  '%already been submitted to Finance%', 'submitting an already-submitted version again is rejected'
);

-- 28: retrying the original submission correlation id is idempotent.
select is(
  (select (public.submit_b2b_dispatch_packing_list_to_finance('99e60000-0000-0000-0000-000000000001'::uuid, (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'), 'pgtap-factc2-submit-1')).id),
  (select id from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-supersede-1'),
  'retrying the same submission correlation id is idempotent'
);

-- 29,30,31: direct table mutation remains closed even for an authorised
-- dispatch role, for all three DML verbs -- exercises the actual Postgres
-- GRANT, not just the RLS predicate.
set local role authenticated;
select throws_ok(
  $$insert into public.b2b_dispatch_packing_list_versions (consignment_id, version_number, status, correlation_id) values ('99e60000-0000-0000-0000-000000000003'::uuid, 1, 'draft', 'pgtap-factc2-direct-write')$$,
  42501, NULL, 'a direct INSERT into packing_list_versions is rejected regardless of role'
);
select throws_ok(
  $$update public.b2b_dispatch_packing_list_versions set status = 'draft' where correlation_id = 'pgtap-factc2-create-2'$$,
  42501, NULL, 'a direct UPDATE of packing_list_versions is rejected regardless of role'
);
select throws_ok(
  $$delete from public.b2b_dispatch_packing_list_versions where correlation_id = 'pgtap-factc2-create-2'$$,
  42501, NULL, 'a direct DELETE of packing_list_versions is rejected regardless of role'
);
reset role;

-- 32: a consignment whose scanned carton contents no longer reconcile with
-- consignment_line.packed_qty (simulated corruption) cannot generate a DPL --
-- reconciliation is re-validated at DPL time, not merely trusted.
select throws_like(
  $$select public.create_b2b_dispatch_packing_list('99e60000-0000-0000-0000-000000000005'::uuid, 'pgtap-factc2-create-mismatch')$$,
  '%does not reconcile with scanned carton contents%', 'a packed_qty/scanned-contents mismatch is rejected'
);

select * from finish();
rollback;
