begin;
-- Contract coverage for 20260823120000_dispatch_shipment_creation_rpc.sql.
select plan(14);

select has_function('public', 'create_b2b_dispatch_shipment', 'create_b2b_dispatch_shipment exists');

insert into public.users (id, role) values
  ('99d00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('99d00000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE');

insert into public.companies (id, business_name, phone)
values ('99d10000-0000-0000-0000-000000000001', 'Shipment RPC Test Co', '+91-9000000003');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value, order_origin)
values ('99d30000-0000-0000-0000-000000000001', 'PGTAP-SHIPRPC-ORD-1', 'pgtap-shiprpc-token-1', '99d10000-0000-0000-0000-000000000001', 100000, 'SALES');

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id
) values (
  '99d60000-0000-0000-0000-000000000001', 'PGTAP-SHIPRPC-ORD-1-DC-01', '99d30000-0000-0000-0000-000000000001', 1, 'draft', 'road_transporter', 'pgtap-shiprpc-cons-1'
);

set local request.jwt.claim.role = 'authenticated';

-- 1: unauthorised caller is rejected.
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000001'::uuid, 'Acme Transport', 'LR-0001', 'pgtap-ship-corr-1')$$,
  'Not authorised to create a dispatch shipment', 'a non-dispatch role cannot create a shipment'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';

-- 2: a blank transporter name is rejected.
select throws_ok(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000001'::uuid, '   ', 'LR-0001', 'pgtap-ship-corr-2')$$,
  'A transporter name is required', 'a blank transporter name is rejected'
);

-- 3: a blank tracking number is rejected.
select throws_ok(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000001'::uuid, 'Acme Transport', '   ', 'pgtap-ship-corr-3')$$,
  'A tracking / LR / AWB number is required', 'a blank tracking number is rejected'
);

-- 4: a blank correlation id is rejected.
select throws_ok(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000001'::uuid, 'Acme Transport', 'LR-0001', '   ')$$,
  'A correlation id is required', 'a blank correlation id is rejected'
);

-- 5: a nonexistent consignment is rejected.
select throws_ok(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000099'::uuid, 'Acme Transport', 'LR-0001', 'pgtap-ship-corr-5')$$,
  'Consignment not found', 'creating a shipment against a nonexistent consignment fails'
);

-- 6,7,8: a valid call succeeds and records the real evidence fields.
select lives_ok(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000001'::uuid, 'Acme Transport', 'LR-0001', 'pgtap-ship-corr-6', 'MH-01-AB-1234', 'Ramesh Kumar', '+91-9111111111')$$,
  'a valid shipment-creation call succeeds'
);
select is(
  (select transporter_name from public.b2b_dispatch_shipments where consignment_id = '99d60000-0000-0000-0000-000000000001'),
  'Acme Transport', 'the transporter name is recorded'
);
select is(
  (select tracking_lr_awb from public.b2b_dispatch_shipments where consignment_id = '99d60000-0000-0000-0000-000000000001'),
  'LR-0001', 'the tracking LR/AWB number is recorded'
);
select is(
  (select shipment_number from public.b2b_dispatch_shipments where consignment_id = '99d60000-0000-0000-0000-000000000001'),
  'PGTAP-SHIPRPC-ORD-1-DC-01-SHP', 'the shipment number is derived from the consignment number'
);

-- 9: consignment.status is left completely untouched by shipment creation.
select is(
  (select status from public.b2b_dispatch_consignments where id = '99d60000-0000-0000-0000-000000000001'),
  'draft', 'creating a shipment does not transition the consignment status'
);

-- 10,11: retrying for the SAME consignment is idempotent, returns the
-- existing row rather than erroring on the UNIQUE constraint or creating a
-- duplicate -- even with different evidence values on the retry payload.
select is(
  (select (public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000001'::uuid, 'Different Transport', 'LR-9999', 'pgtap-ship-corr-11')).id),
  (select id from public.b2b_dispatch_shipments where consignment_id = '99d60000-0000-0000-0000-000000000001'),
  'retrying for the same consignment is idempotent, returns the existing shipment'
);
select is(
  (select count(*) from public.b2b_dispatch_shipments where consignment_id = '99d60000-0000-0000-0000-000000000001'),
  1::bigint, 'the idempotent retry created no additional shipment'
);

-- 12: a consignment that has already moved to a terminal state (dispatched)
-- can no longer have a new shipment created against it.
insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, actual_departure_at, correlation_id
) values (
  '99d60000-0000-0000-0000-000000000002', 'PGTAP-SHIPRPC-ORD-1-DC-02', '99d30000-0000-0000-0000-000000000001', 2, 'dispatched', 'road_transporter', now(), 'pgtap-shiprpc-cons-2'
);
select throws_like(
  $$select public.create_b2b_dispatch_shipment('99d60000-0000-0000-0000-000000000002'::uuid, 'Acme Transport', 'LR-0002', 'pgtap-ship-corr-12')$$,
  '%can no longer have a shipment created against it%', 'a dispatched consignment cannot have a new shipment created against it'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;
