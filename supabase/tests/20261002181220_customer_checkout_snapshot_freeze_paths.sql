-- Contract for 20261002181220_customer_checkout_snapshot_freeze_paths.sql
begin;
select plan(5);

select ok(
  pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure)
    like '%checkout_snapshot%requested_dispatch_date%tracking_token%sales_order_value%advance_required%',
  'checkout persists frozen snapshot and financial values in the same order insert'
);

select ok(
  pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure)
    not like '%PERFORM public.recalculate_customer_app_order_financials(v_order_id)%',
  'checkout no longer reprices after order creation'
);

select ok(
  pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure)
    like '%v_order.order_origin=''CUSTOMER_APP''%'
  and pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure)
    like '%jsonb_array_elements(v_order.checkout_snapshot)%',
  'CUSTOMER_APP commercial version reads frozen checkout lines'
);

select ok(
  pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure)
    like '%customer_checkout_snapshot_total_v1%',
  'commercial freeze validates stored total against checkout snapshot authority'
);

select ok(
  has_function_privilege('authenticated','public.submit_customer_order_v1(text,date)','EXECUTE')
  and has_function_privilege('service_role','public.submit_customer_order_v1(text,date)','EXECUTE')
  and not has_function_privilege('anon','public.submit_customer_order_v1(text,date)','EXECUTE')
  and not has_function_privilege('authenticated','public.build_sales_order_commercial_snapshot_v1(uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.build_sales_order_commercial_snapshot_v1(uuid)','EXECUTE'),
  'SECURITY DEFINER checkout/build ACLs are explicit and least-privilege'
);

select * from finish();
rollback;
