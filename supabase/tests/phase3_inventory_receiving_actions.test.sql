begin;

-- Contract coverage for 20260805120000_phase3_inventory_receiving_actions.sql.

select plan(8);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- Isolate action behavior from the staff-directory fixture. Authorization is
-- covered separately by the TypeScript contract test and remains bound to
-- auth.uid() in the production function.
create or replace function public.can_receive_b2b_inventory(_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select _user_id is not null $$;

insert into public.products (id, name, sku, category, hsn_code)
values (
  '20000000-0000-0000-0000-000000000001',
  'Phase 3 receiving test product',
  'PHASE3-RECEIVING-TEST',
  'test',
  '0000'
);

insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id
)
values (
  '30000000-0000-0000-0000-000000000001',
  'PHASE3-RECEIPT-001',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'PHASE3-TEST-001',
  'phase3-test-001'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expected_qty
)
values
  (
    '40000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001',
    'PHASE3-RECEIVING-TEST',
    'BATCH-A',
    2
  ),
  (
    '40000000-0000-0000-0000-000000000002',
    '30000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001',
    'PHASE3-RECEIVING-TEST',
    'BATCH-B',
    3
  );

select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
    '30000000-0000-0000-0000-000000000001',
    '[{"line_id":"40000000-0000-0000-0000-000000000001","received_qty":2},{"line_id":"40000000-0000-0000-0000-000000000002","received_qty":3}]'::jsonb,
    'phase3-test-001'
  ) $$,
  'records every physical receipt line'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
    '30000000-0000-0000-0000-000000000001',
    '[{"line_id":"40000000-0000-0000-0000-000000000001","accepted_qty":2,"damaged_qty":0,"rejected_qty":0,"expected_balance_version":0},{"line_id":"40000000-0000-0000-0000-000000000002","accepted_qty":3,"damaged_qty":0,"rejected_qty":0,"expected_balance_version":0}]'::jsonb,
    'phase3-test-001'
  ) $$,
  'accepts two batches sharing one stock balance at one expected version'
);

select is(
  (select available_qty from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000001'
     and sku = 'PHASE3-RECEIVING-TEST' and location_code = 'FINISHED_GOODS'),
  5::numeric,
  'aggregates accepted quantities into one balance update'
);

select is(
  (select version from public.inventory_stock_balances
   where product_id = '20000000-0000-0000-0000-000000000001'
     and sku = 'PHASE3-RECEIVING-TEST' and location_code = 'FINISHED_GOODS'),
  1,
  'creates the shared balance once instead of incrementing per receipt line'
);

select is(
  (select count(*) from public.inventory_movements
   where correlation_id like 'phase3-test-001:%'),
  2::bigint,
  'preserves one append-only movement per accepted batch line'
);

select is(
  (select sum(quantity) from public.inventory_movements
   where correlation_id like 'phase3-test-001:%'),
  5::numeric,
  'ledger quantity reconciles to the materialized balance increase'
);

insert into public.b2b_inventory_receipts (
  id, receipt_number, receipt_source, destination_store_code,
  source_document_type, source_document_reference, correlation_id
)
values (
  '30000000-0000-0000-0000-000000000002',
  'PHASE3-RECEIPT-002',
  'opening_balance',
  'FINISHED_GOODS',
  'opening_balance_sheet',
  'PHASE3-TEST-002',
  'phase3-test-002'
);

insert into public.b2b_inventory_receipt_lines (
  id, receipt_id, product_id, sku, oasis_batch_lot, expected_qty
)
values (
  '40000000-0000-0000-0000-000000000003',
  '30000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000001',
  'PHASE3-RECEIVING-TEST',
  'BATCH-REJECTED',
  4
);

select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
    '30000000-0000-0000-0000-000000000002',
    '[{"line_id":"40000000-0000-0000-0000-000000000003","received_qty":4}]'::jsonb,
    'phase3-test-002'
  ) $$,
  'records a rejected-only physical receipt'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
    '30000000-0000-0000-0000-000000000002',
    '[{"line_id":"40000000-0000-0000-0000-000000000003","accepted_qty":0,"damaged_qty":1,"rejected_qty":3}]'::jsonb,
    'phase3-test-002'
  ) $$,
  'does not require a balance version when no stock is accepted'
);

select * from finish();
rollback;
