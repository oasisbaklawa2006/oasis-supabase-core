begin;

select plan(13);

select has_function(
  'public', 'customer_order_items_v1', array[]::text[],
  'customer order items projection exists'
);
select has_function(
  'public', 'customer_order_status_v1', array[]::text[],
  'customer order status projection exists'
);
select has_function(
  'public', 'customer_support_tickets_v1', array[]::text[],
  'customer support tickets projection exists'
);

select ok(
  position(
    'customer_buyer_eligible_company_id()'
    in pg_get_functiondef('public.customer_order_items_v1()'::regprocedure)
  ) > 0,
  'order items projection uses canonical eligible Buyer authority'
);
select ok(
  position(
    'customer_buyer_eligible_company_id()'
    in pg_get_functiondef('public.customer_order_status_v1()'::regprocedure)
  ) > 0,
  'order status projection uses canonical eligible Buyer authority'
);
select ok(
  position(
    'customer_buyer_eligible_company_id()'
    in pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
  ) > 0,
  'support tickets projection uses canonical eligible Buyer authority for profile buyers'
);

select ok(
  position(
    'auth_buyer_company_id()'
    in pg_get_functiondef('public.customer_order_items_v1()'::regprocedure)
  ) = 0,
  'order items projection does not regress to weak legacy helper'
);
select ok(
  position(
    'auth_buyer_company_id()'
    in pg_get_functiondef('public.customer_order_status_v1()'::regprocedure)
  ) = 0,
  'order status projection does not regress to weak legacy helper'
);
select ok(
  position(
    'auth_buyer_company_id()'
    in pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
  ) = 0,
  'support tickets projection does not regress to weak legacy helper'
);

select ok(
  position(
    '''customer_user'', ''customer_admin'', ''buyer'', ''b2b_customer'''
    in pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
  ) > 0,
  'support tickets preserves the pre-existing legacy customer-user compatibility branch'
);

select is(
  has_function_privilege('anon', 'public.customer_order_items_v1()', 'EXECUTE'),
  false,
  'anonymous callers cannot invoke customer order items'
);
select is(
  has_function_privilege('anon', 'public.customer_order_status_v1()', 'EXECUTE'),
  false,
  'anonymous callers cannot invoke customer order status'
);
select is(
  has_function_privilege('anon', 'public.customer_support_tickets_v1()', 'EXECUTE'),
  false,
  'anonymous callers cannot invoke customer support tickets'
);

select * from finish();
rollback;
