-- Contract checks for customer_order_status_v1().

begin;

select plan(8);

select has_function(
  'public',
  'customer_order_status_v1',
  array[]::text[],
  'customer_order_status_v1 exists'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.customer_order_status_v1()'::regprocedure),
  'customer_order_status_v1 is SECURITY DEFINER'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc
   where oid = 'public.customer_order_status_v1()'::regprocedure),
  'customer_order_status_v1 has fixed search_path'
);

select ok(
  not has_function_privilege('anon', 'public.customer_order_status_v1()', 'EXECUTE'),
  'anon cannot execute customer_order_status_v1'
);

select ok(
  not has_function_privilege('public', 'public.customer_order_status_v1()', 'EXECUTE'),
  'PUBLIC cannot execute customer_order_status_v1'
);

select ok(
  has_function_privilege('authenticated', 'public.customer_order_status_v1()', 'EXECUTE'),
  'authenticated can execute customer_order_status_v1'
);

select ok(
  not exists (
    select 1
    from public.customer_order_status_v1()
    where tracking_number is not null
      and customer_stage <> 'dispatched'
  ),
  'tracking information is never exposed before dispatch'
);

select ok(
  not exists (
    select 1
    from public.customer_order_status_v1()
    where order_id is null
       or nullif(btrim(order_number), '') is null
  ),
  'returned orders have complete customer identifiers'
);

select * from finish();
rollback;
