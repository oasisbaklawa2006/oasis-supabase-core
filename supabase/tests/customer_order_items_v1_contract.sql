-- Contract checks for customer_order_items_v1().

begin;

select has_function_privilege('anon', 'public.customer_order_items_v1()', 'EXECUTE') = false as anon_execute_revoked;
select has_function_privilege('public', 'public.customer_order_items_v1()', 'EXECUTE') = false as public_execute_revoked;
select has_function_privilege('authenticated', 'public.customer_order_items_v1()', 'EXECUTE') = true as authenticated_execute_granted;

select prosecdef = true as security_definer
from pg_proc
where oid = 'public.customer_order_items_v1()'::regprocedure;

select count(*) = 0 as no_missing_identity
from public.customer_order_items_v1()
where order_id is null
   or item_id is null
   or product_name is null
   or btrim(product_name) = '';

rollback;
