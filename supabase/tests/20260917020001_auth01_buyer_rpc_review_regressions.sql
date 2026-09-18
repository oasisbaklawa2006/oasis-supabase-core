-- Regression coverage for PR #326 review blockers.
begin;

select plan(10);

-- SECURITY DEFINER functions keep a fixed, minimal search_path. auth.* calls are
-- schema-qualified and therefore do not require auth in search_path.
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.auth_buyer_company_id()'::regprocedure),
  'auth_buyer_company_id has fixed minimal search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.buyer_product_prices_v1()'::regprocedure),
  'buyer_product_prices_v1 has fixed minimal search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.customer_order_items_v1()'::regprocedure),
  'customer_order_items_v1 has fixed minimal search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.customer_order_status_v1()'::regprocedure),
  'customer_order_status_v1 has fixed minimal search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.customer_support_tickets_v1()'::regprocedure),
  'customer_support_tickets_v1 has fixed minimal search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)'::regprocedure),
  'submit_customer_support_ticket_v1 has fixed minimal search_path'
);
select ok(
  (select proconfig @> array['search_path=pg_catalog, public']
   from pg_proc where oid = 'public.support_ticket_set_customer_context()'::regprocedure),
  'support_ticket_set_customer_context has fixed minimal search_path'
);

-- Malformed legacy/service-role order_id text must never be cast outside a CASE
-- guard where PostgreSQL could reorder predicates and raise 22P02.
select ok(
  pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
    like '%CASE%st.order_id::uuid%',
  'customer support projection guards order_id UUID cast with CASE'
);
select ok(
  pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
    not like '%AND o.id = st.order_id::uuid%',
  'customer support projection has no plan-order-dependent raw UUID cast predicate'
);

-- The RPC must persist resolved Buyer identity itself because service_role trigger
-- execution intentionally returns early. Match structure while ignoring formatter
-- whitespace/newlines from pg_get_functiondef().
select ok(
  pg_get_functiondef('public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)'::regprocedure)
    ~ 'INSERT INTO public[.]support_tickets[[:space:]]*[(][[:space:]]*order_id[[:space:]]*,[[:space:]]*company_id[[:space:]]*,[[:space:]]*created_by[[:space:]]*,[[:space:]]*user_id[[:space:]]*,',
  'support submit RPC explicitly persists company_id, created_by and user_id'
);

select * from finish();
rollback;
