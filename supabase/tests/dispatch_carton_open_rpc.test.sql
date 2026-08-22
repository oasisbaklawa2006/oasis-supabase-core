begin;
-- Contract coverage for 20260822150000_dispatch_carton_open_rpc.sql.
select plan(11);

select has_function('public', 'open_b2b_dispatch_carton', 'open_b2b_dispatch_carton exists');

insert into public.users (id, role) values
  ('99c00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('99c00000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE');

insert into public.companies (id, business_name, phone)
values ('99c10000-0000-0000-0000-000000000001', 'Carton RPC Test Co', '+91-9000000002');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value)
values ('99c30000-0000-0000-0000-000000000001', 'PGTAP-CARTONRPC-ORD-1', 'pgtap-cartonrpc-token-1', '99c10000-0000-0000-0000-000000000001', 100000);

insert into public.products (id, name, category, sku, hsn_code)
values ('99c40000-0000-0000-0000-000000000001', 'Carton RPC Test Tray', 'sweets', 'CARTONRPC-TRAY-1', '1905');

insert into public.order_items (id, order_id, product_id, quantity)
values ('99c50000-0000-0000-0000-000000000001', '99c30000-0000-0000-0000-000000000001', '99c40000-0000-0000-0000-000000000001', 20);

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values (
  '99c60000-0000-0000-0000-000000000001', 'PGTAP-CARTONRPC-ORD-1-DC-01', '99c30000-0000-0000-0000-000000000001', 1, 'ready_to_load', 'road_transporter', 'pgtap-cartonrpc-cons-1'
);

set local request.jwt.claim.role = 'authenticated';

-- 1: unauthorised caller is rejected.
set local request.jwt.claim.sub = '99c00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-CARTON-A')$$,
  'Not authorised to open a dispatch carton', 'a non-dispatch role cannot open a carton'
);

set local request.jwt.claim.sub = '99c00000-0000-0000-0000-000000000001';

-- 2: a blank carton code is rejected.
select throws_ok(
  $$select public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000001'::uuid, '   ')$$,
  'A carton code is required', 'a blank carton code is rejected'
);

-- 3: a nonexistent consignment is rejected.
select throws_ok(
  $$select public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000099'::uuid, 'PGTAP-CARTON-NOPE')$$,
  'Consignment not found', 'opening a carton against a nonexistent consignment fails'
);

-- 4,5: a valid open succeeds, carton starts in status=open with sequence 1.
select lives_ok(
  $$select public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-CARTON-A')$$,
  'a valid carton-open call succeeds'
);
select is(
  (select status from public.b2b_dispatch_cartons where carton_code = 'PGTAP-CARTON-A'),
  'open', 'a newly opened carton starts in status=open'
);
select is(
  (select carton_sequence from public.b2b_dispatch_cartons where carton_code = 'PGTAP-CARTON-A'),
  1, 'the first carton for this consignment gets carton_sequence 1'
);

-- 6: a second carton for the same consignment gets sequence 2.
select lives_ok(
  $$select public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-CARTON-B')$$,
  'a second carton for the same consignment can be opened'
);
select is(
  (select carton_sequence from public.b2b_dispatch_cartons where carton_code = 'PGTAP-CARTON-B'),
  2, 'the second carton for this consignment gets carton_sequence 2'
);

-- 7: retrying the SAME carton_code is idempotent, returns the existing row
-- rather than erroring on the UNIQUE constraint or creating a duplicate.
select is(
  (select (public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000001'::uuid, 'PGTAP-CARTON-A')).id),
  (select id from public.b2b_dispatch_cartons where carton_code = 'PGTAP-CARTON-A'),
  'retrying the same carton_code is idempotent, returns the existing carton'
);
select is(
  (select count(*) from public.b2b_dispatch_cartons where consignment_id = '99c60000-0000-0000-0000-000000000001'),
  2::bigint, 'the idempotent retry created no additional carton'
);

-- 8: reusing the same carton_code against a DIFFERENT consignment is
-- rejected (carton_code is a global identifier, never silently rebound).
insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values (
  '99c60000-0000-0000-0000-000000000002', 'PGTAP-CARTONRPC-ORD-1-DC-02', '99c30000-0000-0000-0000-000000000001', 2, 'draft', 'road_transporter', 'pgtap-cartonrpc-cons-2'
);
select throws_like(
  $$select public.open_b2b_dispatch_carton('99c60000-0000-0000-0000-000000000002'::uuid, 'PGTAP-CARTON-A')$$,
  '%already in use by a different consignment%', 'a carton_code already bound to another consignment cannot be reused'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
