-- Contract for migration 20261002001800_customer_checkout_snapshot_financial_truth.sql.
begin;
select plan(8);

select has_function(
  'public','recalculate_customer_app_order_financials',array['uuid'],
  'customer checkout financial recalculator exists'
);

select ok(
  (select prosecdef from pg_proc
   where oid='public.recalculate_customer_app_order_financials(uuid)'::regprocedure),
  'customer checkout financial recalculator remains SECURITY DEFINER'
);

select ok(
  pg_get_functiondef('public.recalculate_customer_app_order_financials(uuid)'::regprocedure)
    like '%checkout_snapshot%',
  'recalculator consumes immutable checkout_snapshot'
);

select ok(
  pg_get_functiondef('public.recalculate_customer_app_order_financials(uuid)'::regprocedure)
    like '%CHECKOUT_SNAPSHOT_INVALID%',
  'malformed authoritative snapshots fail closed'
);

select ok(
  not has_function_privilege('authenticated',
    'public.recalculate_customer_app_order_financials(uuid)','execute')
  and has_function_privilege('service_role',
    'public.recalculate_customer_app_order_financials(uuid)','execute'),
  'execute ACL remains service-role only'
);

set local session_replication_role = replica;

insert into public.companies(id,business_name,status,price_tier,discount_percentage)
values (
  '92300000-0000-0000-0000-000000000001',
  'Checkout Snapshot Truth Co',
  'active',
  'B2B',
  0
);

insert into public.products(
  id,sku,product_name,name,category,hsn_code,is_active,visible_in_catalog,is_catalogue_ready,
  moq_value,increment_value,base_price,price_b2b
) values (
  '92300000-0000-0000-0000-000000000002',
  'SNAP-TRUTH-1','Snapshot Truth Product','Snapshot Truth Product','Bakery','19059090',
  true,true,true,1,1,999,999
);

insert into public.product_pricing_rules(
  product_id,price_channel,approval_status,base_price,calculated_price,currency,uom,gst_rate,tax_inclusive
) values (
  '92300000-0000-0000-0000-000000000002',
  'b2b','approved',999,999,'INR','kg',18,false
);

insert into public.orders(
  id,company_id,status,order_origin,order_number,tracking_token,checkout_snapshot,
  sales_order_value,advance_required
) values (
  '92300000-0000-0000-0000-000000000003',
  '92300000-0000-0000-0000-000000000001',
  'submitted','CUSTOMER_APP','SO-SNAPSHOT-TRUTH-1',md5(random()::text),
  jsonb_build_array(jsonb_build_object(
    'product_id','92300000-0000-0000-0000-000000000002',
    'quantity',2,
    'selling_price',100,
    'currency','INR',
    'uom','kg',
    'gst_rate',18,
    'tax_inclusive',false,
    'sku','SNAP-TRUTH-1',
    'product_name','Snapshot Truth Product',
    'minimum_order_quantity',1,
    'order_increment',1,
    'min_carton_qty',1
  )),
  0,0
);

insert into public.order_items(order_id,product_id,quantity,pack_size)
values (
  '92300000-0000-0000-0000-000000000003',
  '92300000-0000-0000-0000-000000000002',
  2,'kg'
);

set local session_replication_role = default;

select is(
  public.recalculate_customer_app_order_financials(
    '92300000-0000-0000-0000-000000000003'
  ),
  236.00::numeric,
  'order value is derived from frozen checkout price 100 + 18% GST, not current price 999'
);

select is(
  (select sales_order_value
   from public.orders
   where id='92300000-0000-0000-0000-000000000003'),
  236.00::numeric,
  'stored Sales Order value matches immutable checkout snapshot'
);

select is(
  (select advance_required
   from public.orders
   where id='92300000-0000-0000-0000-000000000003'),
  500.00::numeric,
  'advance is calculated from frozen checkout value using canonical 30%-rounded-to-500 rule'
);

select * from finish();
rollback;
