begin;
-- Contract coverage for 20260927120000_b2b_read_grant_uat52_repair.sql:
-- UAT #52 grant drift (FAIL-GRANT-0098/0060/0093), Sales satellite projection,
-- and inventory_stock_balances product FK for RGS low-stock embed (FAIL-QUERY-0087).
select plan(33);

-- =================================================================================
-- TEST 1 — authenticated SELECT grants exist on repaired surfaces
-- =================================================================================
select ok(
  has_table_privilege('authenticated', 'public.b2b_assembly_3pgs_requirements', 'SELECT'),
  'TEST 1a: authenticated has SELECT on b2b_assembly_3pgs_requirements'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_procurement_requirements', 'SELECT'),
  'TEST 1b: authenticated has SELECT on b2b_procurement_requirements'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_inventory_receipts', 'SELECT'),
  'TEST 1c: authenticated has SELECT on b2b_inventory_receipts'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_assembly_jobs', 'SELECT'),
  'TEST 1d: authenticated has SELECT on b2b_assembly_jobs'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_dispatch_consignments', 'SELECT'),
  'TEST 1e: authenticated has SELECT on b2b_dispatch_consignments'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_dispatch_shipment_execution_view', 'SELECT'),
  'TEST 1f: authenticated retains SELECT on b2b_dispatch_shipment_execution_view'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_3pgs_sales_satellite_demand', 'SELECT'),
  'TEST 1g: authenticated has SELECT on b2b_3pgs_sales_satellite_demand'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_3pgs_sales_satellite_stock_summary', 'SELECT'),
  'TEST 1i: authenticated has SELECT on b2b_3pgs_sales_satellite_stock_summary'
);

-- Write grants remain revoked.
select ok(
  not has_table_privilege('authenticated', 'public.b2b_assembly_jobs', 'INSERT')
  and not has_table_privilege('authenticated', 'public.b2b_procurement_requirements', 'INSERT'),
  'TEST 1h: authenticated still cannot directly insert repaired tables'
);

-- =================================================================================
-- Fixtures
-- =================================================================================
insert into public.companies (id, business_name, phone) values
  ('a5200000-0000-0000-0000-000000000001', 'Grant Repair Test Co', '+91-9000000520');

insert into public.users (id, role, company_id, is_active) values
  ('a5100000-0000-0000-0000-000000000001', 'STORE_3RD_PARTY', null, true),
  ('a5100000-0000-0000-0000-000000000002', 'HOD_ASSEMBLY', null, true),
  ('a5100000-0000-0000-0000-000000000003', 'DISPATCH_INCHARGE', null, true),
  ('a5100000-0000-0000-0000-000000000004', 'SALES_EXECUTIVE', null, true),
  ('a5100000-0000-0000-0000-000000000005', 'buyer', 'a5200000-0000-0000-0000-000000000001', true),
  ('a5100000-0000-0000-0000-000000000006', 'OPERATIONS_MANAGER', null, true),
  ('a5100000-0000-0000-0000-000000000007', 'FINANCE_HEAD', null, true);

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('a5200000-0000-0000-0000-000000000010', 'Low Stock RGS SKU', 'sweets', 'LOW-STOCK-RGS-1', '1905', 'arabic_sweets'),
  ('a5200000-0000-0000-0000-000000000011', '3PGS Ribbon', 'packaging', 'RIBBON-GRANT-1', '4823', null);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('a5200000-0000-0000-0000-000000000010', 'LOW-STOCK-RGS-1', 'FINISHED_GOODS', 3),
  ('a5200000-0000-0000-0000-000000000011', 'RIBBON-GRANT-1', '3PGS', 25);

insert into public.orders (id, order_number, tracking_token, company_id, order_origin) values
  ('a5300000-0000-0000-0000-000000000001', 'PGTAP-520-ORD-1', 'pgtap-520-fixture-token-1', 'a5200000-0000-0000-0000-000000000001', 'SALES');

insert into public.b2b_assembly_jobs (
  id, assembly_job_number, order_id, output_product_id, output_sku, planned_qty, status, correlation_id
) values (
  'a5400000-0000-0000-0000-000000000001',
  'ASM-GRANT-520-1',
  'a5300000-0000-0000-0000-000000000001',
  'a5200000-0000-0000-0000-000000000011',
  'RIBBON-GRANT-1',
  10,
  'planned',
  'corr-grant-520-asm-1'
);

insert into public.b2b_assembly_components (
  id, assembly_job_id, product_id, sku, source_store_code, required_qty
) values (
  'a5420000-0000-0000-0000-000000000001',
  'a5400000-0000-0000-0000-000000000001',
  'a5200000-0000-0000-0000-000000000011',
  'RIBBON-GRANT-1',
  '3PGS',
  5
);

insert into public.b2b_assembly_3pgs_requirements (
  id, requirement_number, assembly_job_id, assembly_component_id, product_id, sku,
  source_store_code, requested_qty, fulfilled_qty, status, correlation_id
) values (
  'a5410000-0000-0000-0000-000000000001',
  '3PGS-REQ-GRANT-520-1',
  'a5400000-0000-0000-0000-000000000001',
  'a5420000-0000-0000-0000-000000000001',
  'a5200000-0000-0000-0000-000000000011',
  'RIBBON-GRANT-1',
  '3PGS',
  5,
  0,
  'open',
  'corr-grant-520-3pgs-1'
);

insert into public.b2b_procurement_requirements (
  id, requirement_number, source_type, source_reference, product_id, sku,
  destination_store_code, shortage_qty, status, correlation_id
) values (
  'a5430000-0000-0000-0000-000000000001',
  'PROC-GRANT-520-1',
  'manual',
  'PGTAP-520',
  'a5200000-0000-0000-0000-000000000011',
  'RIBBON-GRANT-1',
  '3PGS',
  10,
  'open',
  'corr-grant-520-proc-1'
);

insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, status, correlation_id
) values (
  'a5440000-0000-0000-0000-000000000001',
  'RCPT-GRANT-520-1',
  'opening_balance',
  '3PGS',
  'opening_balance_sheet',
  'PGTAP-520-OB',
  'expected',
  'corr-grant-520-rcpt-1'
);

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, destination_snapshot, correlation_id
) values (
  'a5450000-0000-0000-0000-000000000001',
  'CONS-GRANT-520-1',
  'a5300000-0000-0000-0000-000000000001',
  1,
  'ready_to_load',
  'road_transporter',
  jsonb_build_object('consignee_name', 'Grant Repair Test Co', 'city', 'Chennai'),
  'corr-grant-520-cons-1'
);

insert into public.inventory_reservations (
  id, reservation_number, product_id, sku, location_code, order_id,
  demand_source_type, demand_reference, requested_qty, reservation_status, correlation_id
) values
  (
    'a5460000-0000-0000-0000-000000000001',
    'RES-B2B-GRANT-520-1',
    'a5200000-0000-0000-0000-000000000011',
    'RIBBON-GRANT-1',
    '3PGS',
    'a5300000-0000-0000-0000-000000000001',
    'b2b',
    'B2B-ADV-520-1',
    12,
    'pending',
    'corr-grant-520-res-b2b'
  ),
  (
    'a5460000-0000-0000-0000-000000000002',
    'RES-OUTLET-GRANT-520-1',
    'a5200000-0000-0000-0000-000000000011',
    'RIBBON-GRANT-1',
    '3PGS',
    null,
    'outlet',
    'OUTLET-520-1',
    8,
    'pending',
    'corr-grant-520-res-outlet'
  );

-- =================================================================================
-- TEST 2 — authorized operator roles can read governed rows (no 42501)
-- =================================================================================
set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select count(*) >= 1 from public.b2b_procurement_requirements where requirement_number = 'PROC-GRANT-520-1'),
  'TEST 2a: STORE_3RD_PARTY can read procurement requirements under RLS'
);
select ok(
  (select count(*) >= 1 from public.b2b_inventory_receipts where receipt_number = 'RCPT-GRANT-520-1'),
  'TEST 2b: STORE_3RD_PARTY can read inventory receipts under RLS'
);

set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select assembly_job_number from public.b2b_assembly_jobs where id = 'a5400000-0000-0000-0000-000000000001'),
  'ASM-GRANT-520-1',
  'TEST 2c: HOD_ASSEMBLY can read assembly jobs under RLS'
);

set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select consignee_name from public.b2b_dispatch_shipment_execution_view where consignment_id = 'a5450000-0000-0000-0000-000000000001'),
  'Grant Repair Test Co',
  'TEST 2d: DISPATCH_INCHARGE can query dispatch execution view through base-table grants'
);

-- =================================================================================
-- TEST 3 — Sales reads only the dedicated projection; operator tables stay blocked
-- =================================================================================
set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000004';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select count(*)::int from public.b2b_3pgs_sales_satellite_demand) = 1,
  'TEST 3a: SALES_EXECUTIVE can read B2B demand through the sales satellite projection'
);
select is(
  (select demand_reference from public.b2b_3pgs_sales_satellite_demand limit 1),
  'B2B-ADV-520-1',
  'TEST 3b: sales projection exposes only the B2B advance-order demand row'
);
select is(
  (select count(*)::int from public.b2b_procurement_requirements),
  0,
  'TEST 3c: SALES_EXECUTIVE cannot read procurement requirements directly'
);
select is(
  (select count(*)::int from public.b2b_assembly_3pgs_requirements),
  0,
  'TEST 3d: SALES_EXECUTIVE cannot read assembly 3PGS requirements directly'
);
select is(
  (select count(*)::int from public.b2b_inventory_receipts),
  0,
  'TEST 3e: SALES_EXECUTIVE cannot read inventory receipts directly'
);
select is(
  (select count(*)::int from public.b2b_assembly_jobs),
  0,
  'TEST 3f: SALES_EXECUTIVE cannot read assembly jobs directly'
);
select is(
  (select count(*)::int from public.inventory_stock_balances where location_code = '3PGS'),
  0,
  'TEST 3g: SALES_EXECUTIVE cannot read 3PGS stock balances directly'
);
select is(
  (select count(*)::int from public.b2b_3pgs_pending_demand_priority where demand_source_type = 'outlet'),
  0,
  'TEST 3h: SALES_EXECUTIVE cannot read outlet demand through the operator priority view'
);

select throws_ok(
  $$ select public.create_b2b_inventory_receipt(
       'RCPT-SALES-BLOCK', 'supplier', '3PGS', 'manual', 'BLOCK',
       '[]'::jsonb, 'corr-sales-block'
     ) $$,
  '42501',
  null,
  'TEST 3i: SALES_EXECUTIVE cannot execute create_b2b_inventory_receipt'
);
select is(
  (select available_qty::int from public.b2b_3pgs_sales_satellite_stock_summary),
  25,
  'TEST 3j: SALES_EXECUTIVE reads aggregate 3PGS available stock through sales stock summary'
);
select is(
  (select count(*)::int from public.inventory_reservations),
  0,
  'TEST 3k: SALES_EXECUTIVE cannot read inventory_reservations directly after legacy policy consolidation'
);

-- =================================================================================
-- TEST 4 — unrelated buyer cannot read restricted operator rows
-- =================================================================================
set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000005';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select count(*)::int from public.b2b_assembly_jobs),
  0,
  'TEST 4a: buyer cannot read assembly jobs'
);
select is(
  (select count(*)::int from public.b2b_dispatch_shipment_execution_view),
  0,
  'TEST 4b: buyer cannot read dispatch execution view rows'
);
select is(
  (select count(*)::int from public.b2b_3pgs_sales_satellite_demand),
  0,
  'TEST 4c: buyer cannot read sales satellite projection'
);

reset role;

-- =================================================================================
-- TEST 6 — legacy "Staff read inventory reservations" consolidation
-- =================================================================================
select ok(
  not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'inventory_reservations'
      and policyname = 'Staff read inventory reservations'
  ),
  'TEST 6a: legacy Staff read inventory reservations policy is removed'
);
select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'inventory_reservations'
      and policyname = 'inventory_reservations_internal_read'
  ),
  'TEST 6b: inventory_reservations_internal_read remains the sole SELECT policy'
);

set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000006';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select count(*) >= 1 from public.inventory_reservations where reservation_number = 'RES-B2B-GRANT-520-1'),
  'TEST 6c: OPERATIONS_MANAGER retains inventory_reservations read after legacy policy drop'
);

set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000007';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select count(*) >= 1 from public.inventory_reservations where reservation_number = 'RES-OUTLET-GRANT-520-1'),
  'TEST 6d: FINANCE_HEAD retains inventory_reservations read after legacy policy drop'
);

reset role;

-- =================================================================================
-- TEST 5 — low-stock embed FK exists (PostgREST relationship prerequisite)
-- =================================================================================
select ok(
  exists (
    select 1
    from pg_constraint
    where conname = 'inventory_stock_balances_product_id_fkey'
      and conrelid = 'public.inventory_stock_balances'::regclass
      AND confrelid = 'public.products'::regclass
  ),
  'TEST 5: inventory_stock_balances.product_id FK to products exists for PostgREST embed'
);

set local request.jwt.claim.sub = 'a5100000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (
    select p.name
    from public.inventory_stock_balances b
    join public.products p on p.id = b.product_id
    where b.sku = 'LOW-STOCK-RGS-1'
      and b.location_code = 'FINISHED_GOODS'
      and b.available_qty < 10
  ) = 'Low Stock RGS SKU',
  'TEST 5b: low-stock join path returns product name for FINISHED_GOODS balances under RLS'
);

reset role;

select * from finish();
rollback;
