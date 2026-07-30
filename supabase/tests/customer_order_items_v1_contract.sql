-- Governed contract checks for the baseline customer order-item contract and
-- 20260730170000_customer_contract_privilege_hardening.sql.

begin;

select plan(10);

select has_function('public', 'customer_order_items_v1', array[]::text[], 'customer_order_items_v1 exists');
select ok((select prosecdef from pg_proc where oid = 'public.customer_order_items_v1()'::regprocedure), 'customer_order_items_v1 is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=pg_catalog, public, auth'] from pg_proc where oid = 'public.customer_order_items_v1()'::regprocedure), 'customer_order_items_v1 has fixed search_path');
select ok(has_function_privilege('authenticated', 'public.customer_order_items_v1()', 'EXECUTE'), 'authenticated can execute customer_order_items_v1');
select ok(not has_function_privilege('anon', 'public.customer_order_items_v1()', 'EXECUTE'), 'anon cannot execute customer_order_items_v1');
select ok(not has_function_privilege('public', 'public.customer_order_items_v1()', 'EXECUTE'), 'PUBLIC cannot execute customer_order_items_v1');
select ok(not exists (
  select 1
  from public.customer_order_items_v1()
  where order_id is null
     or item_id is null
     or product_name is null
     or btrim(product_name) = ''
), 'returned rows have complete customer identity fields');
select ok(not exists (
  select item_id
  from public.customer_order_items_v1()
  group by item_id
  having count(*) > 1
), 'projection returns at most one row per order item');
select ok(not exists (
  select 1
  from public.customer_order_items_v1()
  where quantity is null or quantity <= 0
), 'returned quantities are positive');
select ok(
  not (
    lower(pg_get_function_result('public.customer_order_items_v1()'::regprocedure))
    ~ '(cost_price|margin|internal_notes|production_notes|packing_operator|qc_notes|procurement_data|approval_metadata)'
  ),
  'customer contract exposes no internal operational or costing fields'
);

select * from finish();
rollback;
