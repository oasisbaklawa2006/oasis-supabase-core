-- Contract checks for migrations:
-- 20260722210000_buyer_product_prices_v1.sql
-- 20260722223000_buyer_product_prices_v1_add_moq.sql

begin;

select plan(10);

select has_function(
  'public',
  'buyer_product_prices_v1',
  array[]::text[],
  'buyer_product_prices_v1 exists'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.buyer_product_prices_v1()'::regprocedure),
  'buyer_product_prices_v1 is SECURITY DEFINER'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog, public, auth']
   from pg_proc
   where oid = 'public.buyer_product_prices_v1()'::regprocedure),
  'buyer_product_prices_v1 has fixed search_path'
);

select ok(
  not has_function_privilege('anon', 'public.buyer_product_prices_v1()', 'EXECUTE'),
  'anon cannot execute buyer_product_prices_v1'
);

select ok(
  has_function_privilege('authenticated', 'public.buyer_product_prices_v1()', 'EXECUTE'),
  'authenticated can execute buyer_product_prices_v1'
);

select ok(
  not has_function_privilege('public', 'public.buyer_product_prices_v1()', 'EXECUTE'),
  'PUBLIC cannot execute buyer_product_prices_v1'
);

select ok(
  (select count(*) = 0 from public.buyer_product_prices_v1()),
  'no JWT identity receives no buyer pricing rows'
);

select ok(
  not exists (
    select product_id
    from public.buyer_product_prices_v1()
    group by product_id
    having count(*) > 1
  ),
  'buyer pricing returns at most one row per product'
);

select ok(
  not exists (
    select 1
    from public.buyer_product_prices_v1()
    where selling_price <= 0
       or nullif(btrim(currency), '') is null
       or minimum_order_quantity is null
       or minimum_order_quantity <= 0
       or order_increment is null
       or order_increment <= 0
  ),
  'returned prices and quantity rules are complete and positive'
);

select ok(
  not exists (
    select 1
    from information_schema.routine_columns
    where specific_schema = 'public'
      and routine_name = 'buyer_product_prices_v1'
      and column_name in (
        'base_price',
        'calculated_price',
        'approval_status',
        'approved_by',
        'pricing_notes',
        'notes',
        'cost_per_kg',
        'cost_per_pc'
      )
  ),
  'buyer pricing contract excludes internal pricing and approval fields'
);

select * from finish();
rollback;