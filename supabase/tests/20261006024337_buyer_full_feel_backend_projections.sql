-- Contract test for migration 20261006024337_buyer_full_feel_backend_projections.sql
begin;

create extension if not exists pgtap;
select plan(33);

-- Function existence.
select has_function('public','customer_delivery_addresses_v1',array[]::text[],
  'customer_delivery_addresses_v1 exists');
select has_function('public','customer_shipping_preferences_v1',array[]::text[],
  'customer_shipping_preferences_v1 exists');
select has_function('public','customer_private_label_products_v1',array[]::text[],
  'customer_private_label_products_v1 exists');
select has_function('public','customer_packaging_offers_v1',array[]::text[],
  'customer_packaging_offers_v1 exists');
select has_function('public','connect_staff_readiness_v1',array[]::text[],
  'connect_staff_readiness_v1 exists');

-- Browser privilege boundary: Buyer projections require authenticated sessions.
select ok(
  has_function_privilege('authenticated','public.customer_delivery_addresses_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_delivery_addresses_v1()','EXECUTE'),
  'delivery address projection is authenticated-only'
);
select ok(
  has_function_privilege('authenticated','public.customer_shipping_preferences_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_shipping_preferences_v1()','EXECUTE'),
  'shipping preference projection is authenticated-only'
);
select ok(
  has_function_privilege('authenticated','public.customer_private_label_products_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_private_label_products_v1()','EXECUTE'),
  'private-label projection is authenticated-only'
);
select ok(
  has_function_privilege('authenticated','public.customer_packaging_offers_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_packaging_offers_v1()','EXECUTE'),
  'packaging offer projection is authenticated-only'
);
select ok(
  has_function_privilege('authenticated','public.connect_staff_readiness_v1()','EXECUTE')
  and not has_function_privilege('anon','public.connect_staff_readiness_v1()','EXECUTE'),
  'Connect readiness projection is authenticated-only'
);

-- Canonical buyer-tenant scoping.
select ok(
  pg_get_functiondef('public.customer_delivery_addresses_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'delivery addresses derive company from canonical Buyer gate'
);
select ok(
  pg_get_functiondef('public.customer_delivery_addresses_v1()'::regprocedure)
    like '%da.company_id = e.company_id%',
  'delivery addresses are company scoped'
);

-- Runtime tenant-isolation proof: an approved Buyer may only receive addresses
-- belonging to its canonical eligible company.
insert into public.companies (id, business_name, status) values
  ('d1000000-0000-0000-0000-000000000201', 'Projection Buyer A', 'active'),
  ('d1000000-0000-0000-0000-000000000202', 'Projection Buyer B', 'active');

insert into auth.users (id, email) values
  ('d1000000-0000-0000-0000-000000000101', 'projection-buyer-a@example.com');

insert into public.profiles (id, company_id, role, is_approved, status, email) values
  (
    'd1000000-0000-0000-0000-000000000101',
    'd1000000-0000-0000-0000-000000000201',
    'b2b_buyer',
    true,
    'approved',
    'projection-buyer-a@example.com'
  );

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values
  (
    'd1000000-0000-0000-0000-000000000211',
    'd1000000-0000-0000-0000-000000000201',
    'Buyer A address', '1 Buyer A Street', 'Bengaluru', 'Karnataka', '560001', true
  ),
  (
    'd1000000-0000-0000-0000-000000000221',
    'd1000000-0000-0000-0000-000000000202',
    'Buyer B address', '2 Buyer B Street', 'Bengaluru', 'Karnataka', '560002', true
  );

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', 'd1000000-0000-0000-0000-000000000101',
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (
    select array_agg(address_id order by address_id)
    from public.customer_delivery_addresses_v1()
  ),
  array['d1000000-0000-0000-0000-000000000211']::uuid[],
  'buyer receives only addresses from the eligible company'
);

reset role;
select set_config('request.jwt.claims', null, true);
select ok(
  pg_get_functiondef('public.customer_shipping_preferences_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'shipping preference derives company from canonical Buyer gate'
);
select ok(
  pg_get_functiondef('public.customer_private_label_products_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'private-label projection requires canonical Buyer gate'
);
select ok(
  pg_get_functiondef('public.customer_packaging_offers_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'packaging projection requires canonical Buyer gate'
);

-- Publication and commercial authority.
select ok(
  pg_get_functiondef('public.customer_private_label_products_v1()'::regprocedure)
    like '%published_products_v1%',
  'private-label products must already be published'
);
select ok(
  pg_get_functiondef('public.customer_private_label_products_v1()'::regprocedure)
    like '%private_label_allowed IS TRUE%',
  'private-label eligibility is explicit'
);
select ok(
  pg_get_functiondef('public.customer_packaging_offers_v1()'::regprocedure)
    like '%published_products_v1%',
  'packaging offers must already be published'
);
select ok(
  pg_get_functiondef('public.customer_packaging_offers_v1()'::regprocedure)
    like '%buyer_product_prices_v1%',
  'packaging price/MOQ comes from governed Buyer pricing'
);
select ok(
  pg_get_functiondef('public.customer_packaging_offers_v1()'::regprocedure)
    not like '%p.price_b2b%',
  'packaging projection does not bypass governed pricing with legacy product price'
);

-- Sensitive product truth must never leave the Buyer projection.
select ok(
  pg_get_functiondef('public.customer_private_label_products_v1()'::regprocedure)
    not like '%private_label_cost_per_unit%',
  'private-label internal unit cost is not exposed'
);
select ok(
  pg_get_functiondef('public.customer_private_label_products_v1()'::regprocedure)
    not like '%private_label_upfront_cost%',
  'private-label internal upfront cost is not exposed'
);
select ok(
  pg_get_functiondef('public.customer_private_label_products_v1()'::regprocedure)
    not like '%cost_per_%',
  'private-label projection does not expose generic cost fields'
);

-- Studio/Connect readiness is staff-gated and aggregate-only.
select ok(
  pg_get_functiondef('public.connect_staff_readiness_v1()'::regprocedure)
    like '%is_admin()%'
  and pg_get_functiondef('public.connect_staff_readiness_v1()'::regprocedure)
    like '%is_catalogue_reviewer()%',
  'Connect readiness requires admin or catalogue-reviewer authority'
);
select ok(
  pg_get_functiondef('public.connect_staff_readiness_v1()'::regprocedure)
    not like '%token_hash%',
  'Connect readiness never returns token hashes'
);
select ok(
  pg_get_functiondef('public.connect_staff_readiness_v1()'::regprocedure)
    not like '%token_prefix%',
  'Connect readiness never returns token prefixes'
);
select ok(
  pg_get_functiondef('public.connect_staff_readiness_v1()'::regprocedure)
    not like '%business_name%',
  'Connect readiness never returns customer PII'
);

-- All five projections are SECURITY DEFINER with explicit safe search paths.
select ok(
  (select prosecdef from pg_proc where oid='public.customer_delivery_addresses_v1()'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public, auth']
       from pg_proc where oid='public.customer_delivery_addresses_v1()'::regprocedure),
  'delivery address projection is security-definer with fixed search_path'
);
select ok(
  (select prosecdef from pg_proc where oid='public.customer_shipping_preferences_v1()'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public, auth']
       from pg_proc where oid='public.customer_shipping_preferences_v1()'::regprocedure),
  'shipping preference projection is security-definer with fixed search_path'
);
select ok(
  (select prosecdef from pg_proc where oid='public.customer_private_label_products_v1()'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public, auth']
       from pg_proc where oid='public.customer_private_label_products_v1()'::regprocedure),
  'private-label projection is security-definer with fixed search_path'
);
select ok(
  (select prosecdef from pg_proc where oid='public.customer_packaging_offers_v1()'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public, auth']
       from pg_proc where oid='public.customer_packaging_offers_v1()'::regprocedure),
  'packaging projection is security-definer with fixed search_path'
);
select ok(
  (select prosecdef from pg_proc where oid='public.connect_staff_readiness_v1()'::regprocedure)
  and (select proconfig @> array['search_path=pg_catalog, public, auth']
       from pg_proc where oid='public.connect_staff_readiness_v1()'::regprocedure),
  'Connect readiness is security-definer with fixed search_path'
);

select * from finish();
rollback;
