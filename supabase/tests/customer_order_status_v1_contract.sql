-- Contract checks for customer_order_status_v1().

begin;

-- Function must not be executable by anonymous or PUBLIC roles.
select has_function_privilege('anon', 'public.customer_order_status_v1()', 'EXECUTE') = false as anon_execute_revoked;
select has_function_privilege('public', 'public.customer_order_status_v1()', 'EXECUTE') = false as public_execute_revoked;
select has_function_privilege('authenticated', 'public.customer_order_status_v1()', 'EXECUTE') = true as authenticated_execute_granted;

-- Function must remain SECURITY DEFINER.
select prosecdef = true as security_definer
from pg_proc
where oid = 'public.customer_order_status_v1()'::regprocedure;

-- Output must never expose tracking before dispatch.
select count(*) = 0 as no_pre_dispatch_tracking
from public.customer_order_status_v1()
where tracking_number is not null
  and customer_stage <> 'dispatched';

-- Identity and ordering fields must remain complete.
select count(*) = 0 as no_missing_order_numbers
from public.customer_order_status_v1()
where order_number is null;

rollback;
