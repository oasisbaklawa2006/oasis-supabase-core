begin;
-- Contract coverage for 20260822140000_dispatch_consignment_creation_rpc.sql.
-- Proves create_b2b_dispatch_consignment is the correct, minimal, additive
-- "start a dispatch" command: authorised-only, idempotent, order/company
-- validated, and it cannot oversubscribe an order_item's quantity across
-- multiple consignments (the exact protection a partial-dispatch-leg
-- workflow needs).
select plan(18);

select has_function('public', 'create_b2b_dispatch_consignment', 'create_b2b_dispatch_consignment exists');

insert into public.users (id, role) values
  ('99b00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE'),
  ('99b00000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE');

insert into public.companies (id, business_name, phone)
values ('99b10000-0000-0000-0000-000000000001', 'Consignment RPC Test Co', '+91-9000000001');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value)
values ('99b30000-0000-0000-0000-000000000001', 'PGTAP-CONSRPC-ORD-1', 'pgtap-consrpc-token-1', '99b10000-0000-0000-0000-000000000001', 100000);

-- An order with no company_id at all, to prove the domain-model guard.
insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value)
values ('99b30000-0000-0000-0000-000000000002', 'PGTAP-CONSRPC-ORD-2', 'pgtap-consrpc-token-2', null, 50000);

insert into public.products (id, name, category, sku, hsn_code)
values ('99b40000-0000-0000-0000-000000000001', 'Consignment RPC Test Tray', 'sweets', 'CONSRPC-TRAY-1', '1905');

insert into public.order_items (id, order_id, product_id, quantity, carton_type)
values ('99b50000-0000-0000-0000-000000000001', '99b30000-0000-0000-0000-000000000001', '99b40000-0000-0000-0000-000000000001', 20, 'master_carton');

insert into public.order_items (id, order_id, product_id, quantity)
values ('99b50000-0000-0000-0000-000000000002', '99b30000-0000-0000-0000-000000000002', '99b40000-0000-0000-0000-000000000001', 10);

set local request.jwt.claim.role = 'authenticated';

-- 1: unauthorised caller is rejected.
set local request.jwt.claim.sub = '99b00000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000001', 'selected_qty', 20)),
    'pgtap-consrpc-1'
  )$$,
  'Not authorised to create a dispatch consignment', 'a non-dispatch role cannot create a consignment'
);

set local request.jwt.claim.sub = '99b00000-0000-0000-0000-000000000001';

-- 2: an order with no company_id is rejected (the domain-model guard).
select throws_like(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000002'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000002', 'selected_qty', 10)),
    'pgtap-consrpc-nocompany'
  )$$,
  '%not eligible for the governed B2B dispatch flow%', 'an order with no company_id is rejected, not silently mis-modelled'
);

-- 3: a non-positive selected_qty is rejected.
select throws_like(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000001', 'selected_qty', 0)),
    'pgtap-consrpc-zeroqty'
  )$$,
  '%selected_qty must be a positive number%', 'a zero/negative selected_qty is rejected'
);

-- 4,5: a valid partial-leg call succeeds and creates the consignment + line.
select lives_ok(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000001', 'selected_qty', 12)),
    'pgtap-consrpc-leg1'
  )$$,
  'a valid partial dispatch leg is created successfully'
);
select is(
  (select count(*) from public.b2b_dispatch_consignments where order_id = '99b30000-0000-0000-0000-000000000001'),
  1::bigint, 'exactly one consignment now exists for the order'
);

-- 6: sequence_number and consignment_number are set correctly for the first leg.
select is(
  (select sequence_number from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg1'),
  1, 'the first consignment for this order gets sequence_number 1'
);
select is(
  (select consignment_number from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg1'),
  'PGTAP-CONSRPC-ORD-1-DC-01', 'consignment_number is derived from the order number and sequence'
);

-- 7: the line carries the correct snapshot values, uom defaulted from carton_type.
select is(
  (select selected_qty from public.b2b_dispatch_consignment_lines where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg1')),
  12::numeric, 'the line records the requested selected_qty'
);
select is(
  (select uom from public.b2b_dispatch_consignment_lines where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg1')),
  'master_carton', 'uom defaults from the order_item carton_type when not explicitly supplied'
);
select is(
  (select product_code from public.b2b_dispatch_consignment_lines where consignment_id = (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg1')),
  'CONSRPC-TRAY-1', 'product_code is snapshotted from the product sku'
);

-- 8: a second partial leg for the SAME order_item, within the remaining
-- quantity (20 - 12 = 8), succeeds and gets sequence_number 2.
select lives_ok(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000001', 'selected_qty', 8)),
    'pgtap-consrpc-leg2'
  )$$,
  'a second partial leg within the remaining quantity succeeds'
);
select is(
  (select sequence_number from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg2'),
  2, 'the second consignment for this order gets sequence_number 2'
);

-- 9: a third leg that would oversubscribe the order_item (only 0 remaining
-- of 20) is rejected -- this is the double-booking protection.
select throws_like(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000001', 'selected_qty', 1)),
    'pgtap-consrpc-oversub'
  )$$,
  '%would exceed the remaining undispatched quantity%', 'a third leg that would oversubscribe the order_item is rejected'
);
select is(
  (select count(*) from public.b2b_dispatch_consignments where order_id = '99b30000-0000-0000-0000-000000000001'),
  2::bigint, 'the rejected oversubscription attempt created no new consignment'
);

-- 10: retrying the SAME correlation_id as leg1 returns the SAME consignment,
-- not a duplicate (idempotency).
select is(
  (select (public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000001', 'selected_qty', 12)),
    'pgtap-consrpc-leg1'
  )).id),
  (select id from public.b2b_dispatch_consignments where correlation_id = 'pgtap-consrpc-leg1'),
  'retrying the same correlation_id is idempotent, returns the existing consignment'
);
select is(
  (select count(*) from public.b2b_dispatch_consignments where order_id = '99b30000-0000-0000-0000-000000000001'),
  2::bigint, 'the idempotent retry created no additional consignment'
);

-- 11: an order_item that does not belong to the given order is rejected.
select throws_like(
  $$select public.create_b2b_dispatch_consignment(
    '99b30000-0000-0000-0000-000000000001'::uuid, 'road_transporter',
    jsonb_build_array(jsonb_build_object('order_item_id', '99b50000-0000-0000-0000-000000000002', 'selected_qty', 1)),
    'pgtap-consrpc-wrongitem'
  )$$,
  '%does not belong to order%', 'an order_item from a different order is rejected'
);

select * from finish();
rollback;
