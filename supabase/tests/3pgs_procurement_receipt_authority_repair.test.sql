begin;
-- Contract coverage for 20260828002000_3pgs_procurement_receipt_authority_repair.sql.

select plan(34);

-- R4 repair fixtures. STORE_3RD_PARTY intentionally has no explicit
-- b2b_inventory_store_assignments row: the repair must scope that role to 3PGS
-- by role identity alone, while preserving explicit assignments for others.
insert into public.users (id, role) values
  ('58000000-0000-0000-0000-000000000001', 'STORE_3RD_PARTY'),
  ('58000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('68000000-0000-0000-0000-000000000001', 'R4 Procurement Ribbon', 'packaging', 'R4-RIBBON-1', '4823', null);

insert into public.b2b_inventory_store_assignments (user_id, store_code, authority)
values ('58000000-0000-0000-0000-000000000002', 'FINISHED_GOODS', 'manage');

set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select is(
  public.can_access_b2b_inventory_store(
    '58000000-0000-0000-0000-000000000001', '3PGS', 'manage'
  ),
  true,
  'STORE_3RD_PARTY implicitly manages the canonical 3PGS store'
);

select is(
  public.can_access_b2b_inventory_store(
    '58000000-0000-0000-0000-000000000001', '3pgs', 'manage'
  ),
  true,
  '3PGS implicit scope is case-insensitive at the authority boundary'
);

select is(
  public.can_access_b2b_inventory_store(
    '58000000-0000-0000-0000-000000000001', 'FINISHED_GOODS', 'receive'
  ),
  false,
  'STORE_3RD_PARTY does not gain implicit access to other stores'
);

select is(
  public.can_access_b2b_inventory_store(
    '58000000-0000-0000-0000-000000000002', 'FINISHED_GOODS', 'manage'
  ),
  true,
  'pre-existing explicit store assignments retain their authority semantics'
);

select is(
  (select convalidated from pg_constraint
   where conrelid = 'public.b2b_inventory_receipts'::regclass
     and conname = 'b2b_inventory_receipts_source_reference_check'),
  true,
  'replacement receipt provenance constraint is fully validated after lower-lock validation pass'
);

select throws_like(
  $$ select public.create_b2b_inventory_receipt(
       'R4-RCPT-BAD-SUPPLIER', 'supplier', '3PGS', 'delivery_challan', 'DC-WITHOUT-SUPPLIER',
       jsonb_build_array(jsonb_build_object(
         'product_id', '68000000-0000-0000-0000-000000000001',
         'sku', 'R4-RIBBON-1', 'expected_qty', 1
       )),
       'r4-bad-supplier-correlation'
     ) $$,
  '%violates check constraint "b2b_inventory_receipts_source_reference_check"%',
  'ordinary supplier receipt still requires supplier identity'
);

select lives_ok(
  $$ select public.create_procurement_requirement(
       'manual', 'R4-PROC-SOURCE-1',
       '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1',
       '3PGS', 6, 'r4-proc-create-1'
     ) $$,
  'STORE_3RD_PARTY can open the governed 3PGS procurement requirement'
);

select lives_ok(
  $$ select public.create_b2b_inventory_receipt(
       'R4-RCPT-PROC-1', 'supplier', '3PGS', 'procurement_requirement',
       (select requirement_number from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
       jsonb_build_array(jsonb_build_object(
         'product_id', '68000000-0000-0000-0000-000000000001',
         'sku', 'R4-RIBBON-1', 'expected_qty', 6,
         'supplier_batch_lot', 'SUP-LOT-R4', 'expiry_date', '2027-08-28'
       )),
       'r4-receipt-correlation'
     ) $$,
  'procurement-backed supplier receipt can open without inventing a supplier UUID'
);

select is(
  (select receipt_source from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
  'supplier',
  'procurement inward retains canonical supplier receipt source'
);

select is(
  (select supplier_id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
  null::uuid,
  'procurement inward does not fabricate a supplier UUID'
);

select is(
  (select source_document_type from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
  'procurement_requirement',
  'receipt provenance identifies its governed procurement source document'
);

select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id=(select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1')),
         'received_qty', 6,
         'supplier_batch_lot', 'SUP-LOT-R4',
         'expiry_date', '2027-08-28',
         'notes', 'R4 partial disposition fixture'
       )),
       'r4-receipt-correlation'
     ) $$,
  'record uses the exact receipt correlation id and records physical arrival'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id', (select id from public.b2b_inventory_receipt_lines where receipt_id=(select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1')),
         'accepted_qty', 4,
         'damaged_qty', 1,
         'rejected_qty', 1,
         'expected_balance_version', 0
       )),
       'r4-receipt-correlation'
     ) $$,
  'accept uses the same correlation id and records a truthful partial disposition'
);

select is(
  (select status from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
  'partially_accepted',
  'damaged/rejected units keep the receipt partially accepted'
);

select is(
  (select coalesce(sum(quantity),0) from public.inventory_movements
   where movement_type='supplier_receipt_accepted'
     and product_id='68000000-0000-0000-0000-000000000001'
     and sku='R4-RIBBON-1'
     and correlation_id like 'r4-receipt-correlation:%'),
  4::numeric,
  'only the accepted quantity is posted as supplier receipt movement'
);

select is(
  (select coalesce(sum(quantity),0) from public.inventory_movements
   where movement_type='inventory_hold'
     and product_id='68000000-0000-0000-0000-000000000001'
     and sku='R4-RIBBON-1'
     and correlation_id like 'r4-receipt-correlation:grn-hold:%'),
  4::numeric,
  'accepted quantity is held pending governed put-away and GRN'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where product_id='68000000-0000-0000-0000-000000000001'
     and sku='R4-RIBBON-1' and location_code='3PGS'),
  0::numeric,
  'accepted stock is not falsely available before GRN finalisation'
);

select is(
  (select coalesce(sum(quantity),0) from public.b2b_supplier_discrepancies
   where discrepancy_type='damaged'
     and receipt_line_id=(select id from public.b2b_inventory_receipt_lines where receipt_id=(select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'))),
  1::numeric,
  'damaged quantity creates governed supplier discrepancy evidence'
);

select is(
  (select coalesce(sum(quantity),0) from public.b2b_supplier_discrepancies
   where discrepancy_type='rejected'
     and receipt_line_id=(select id from public.b2b_inventory_receipt_lines where receipt_id=(select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'))),
  1::numeric,
  'rejected quantity creates governed supplier discrepancy evidence'
);

select throws_like(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       5, 'r4-link-too-much'
     ) $$,
  '%exceeds%accepted%receipt quantity%',
  'procurement linkage cannot credit received-but-not-accepted quantity'
);

select lives_ok(
  $$ select public.create_procurement_requirement(
       'manual', 'R4-PROC-SOURCE-2',
       '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1',
       '3PGS', 6, 'r4-proc-create-2'
     ) $$,
  'second requirement fixture is created for provenance mismatch testing'
);

select throws_like(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-create-2'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       4, 'r4-link-wrong-requirement'
     ) $$,
  '%Receipt provenance does not match the procurement requirement%',
  'a null-supplier procurement receipt cannot be credited to a different requirement'
);

select lives_ok(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       4, 'r4-link-correct'
     ) $$,
  'accepted matching quantity links to the exact procurement requirement'
);

select is(
  (select fulfilled_qty from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
  4::numeric,
  'procurement fulfilled quantity advances by accepted quantity only'
);

select is(
  (select status from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
  'partially_received',
  'procurement remains partial when accepted quantity is below shortage'
);

-- Idempotent replay is checked after row locks and must preserve material qty.
select lives_ok(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       4, 'r4-link-correct-replay'
     ) $$,
  'same receipt/requirement replay with the same quantity is a safe no-op'
);

select is(
  (select fulfilled_qty from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
  4::numeric,
  'same-quantity replay does not double-count procurement fulfilment'
);

select throws_like(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-create-1'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-PROC-1'),
       3, 'r4-link-conflicting-replay'
     ) $$,
  '%replay quantity mismatch%',
  'same receipt/requirement replay with a changed quantity fails closed'
);

-- Supplier-identity compatibility can legitimately lack exact procurement
-- source-document provenance. Use that path to prove one physical accepted
-- receipt cannot be spent across two procurement requirements beyond its qty.
insert into public.b2b_procurement_requirements (
  requirement_number, source_type, source_reference, product_id, sku,
  destination_store_code, shortage_qty, fulfilled_qty, status, correlation_id
) values
  ('R4-PROC-AGG-A', 'manual', 'R4-AGG-A', '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1', '3PGS', 3, 0, 'open', 'r4-proc-agg-a'),
  ('R4-PROC-AGG-B', 'manual', 'R4-AGG-B', '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1', '3PGS', 3, 0, 'open', 'r4-proc-agg-b');

insert into public.b2b_inventory_receipts (
  receipt_number, receipt_source, destination_store_code, source_document_type,
  source_document_reference, supplier_id, status, correlation_id
) values (
  'R4-RCPT-SUPPLIER-AGG', 'supplier', '3PGS', 'purchase_order', 'R4-PO-AGG',
  'aaaaaaaa-0000-0000-0000-000000000001'::uuid, 'accepted', 'r4-receipt-agg'
);

insert into public.b2b_inventory_receipt_lines (
  receipt_id, product_id, sku, expected_qty, received_qty, accepted_qty
) values (
  (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-SUPPLIER-AGG'),
  '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1', 4, 4, 4
);

select lives_ok(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-agg-a'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-SUPPLIER-AGG'),
       3, 'r4-link-agg-a'
     ) $$,
  'first requirement may consume three of four accepted supplier-receipt units'
);

select throws_like(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-agg-b'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-SUPPLIER-AGG'),
       2, 'r4-link-agg-over'
     ) $$,
  '%exceeds remaining accepted matching receipt quantity%',
  'second requirement cannot double-spend more than the one accepted unit left on the receipt'
);

select lives_ok(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-agg-b'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-SUPPLIER-AGG'),
       1, 'r4-link-agg-b'
     ) $$,
  'second requirement may consume exactly the one accepted unit remaining'
);

select is(
  (select coalesce(sum(fulfilled_qty),0)
   from public.b2b_procurement_requirement_receipts
   where receipt_id=(select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-SUPPLIER-AGG')),
  4::numeric,
  'aggregate procurement links equal but never exceed the four physically accepted receipt units'
);

-- Store-scoped authority must still govern link mutation even though
-- STORE_3RD_PARTY is present in the coarse can_manage_b2b_inventory role set.
insert into public.b2b_procurement_requirements (
  requirement_number, source_type, source_reference, product_id, sku,
  destination_store_code, shortage_qty, fulfilled_qty, status, correlation_id
) values (
  'R4-PROC-OTHER-STORE', 'manual', 'R4-OTHER-STORE',
  '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1',
  'FINISHED_GOODS', 1, 0, 'open', 'r4-proc-other-store'
);

insert into public.b2b_inventory_receipts (
  receipt_number, receipt_source, destination_store_code, source_document_type,
  source_document_reference, supplier_id, status, correlation_id
) values (
  'R4-RCPT-OTHER-STORE', 'supplier', 'FINISHED_GOODS', 'purchase_order', 'R4-PO-OTHER',
  'aaaaaaaa-0000-0000-0000-000000000002'::uuid, 'accepted', 'r4-receipt-other-store'
);

insert into public.b2b_inventory_receipt_lines (
  receipt_id, product_id, sku, expected_qty, received_qty, accepted_qty
) values (
  (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-OTHER-STORE'),
  '68000000-0000-0000-0000-000000000001', 'R4-RIBBON-1', 1, 1, 1
);

select throws_like(
  $$ select public.link_procurement_receipt(
       (select id from public.b2b_procurement_requirements where correlation_id='r4-proc-other-store'),
       (select id from public.b2b_inventory_receipts where receipt_number='R4-RCPT-OTHER-STORE'),
       1, 'r4-link-other-store'
     ) $$,
  '%Not authorised to link a procurement receipt for store FINISHED_GOODS%',
  'STORE_3RD_PARTY cannot use coarse inventory authority to mutate another store'
);

select is(
  (select has_table_privilege('authenticated','public.b2b_inventory_receipts','INSERT')),
  false,
  'authenticated still cannot bypass governed receipt creation with direct inserts'
);

select * from finish();
rollback;
