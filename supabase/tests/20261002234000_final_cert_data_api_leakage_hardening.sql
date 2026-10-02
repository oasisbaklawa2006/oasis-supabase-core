-- Contract for migration 20261002234000_final_cert_data_api_leakage_hardening.sql.
select plan(12);

select ok(
  not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='products'
      and policyname='Authenticated read products'
  ),
  'raw products broad authenticated read policy is removed'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='products'
      and policyname='Internal staff read products'
      and cmd='SELECT'
      and qual ilike '%is_internal_staff%'
  ),
  'products raw read is internal-staff scoped'
);

select ok(
  not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='product_pricing_rules'
      and policyname='Authenticated read product_pricing_rules'
  ),
  'raw pricing broad authenticated read policy is removed'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='product_pricing_rules'
      and policyname='Internal staff read product_pricing_rules'
      and qual ilike '%is_internal_staff%'
  ),
  'pricing raw read is internal-staff scoped'
);

select ok(
  not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='product_moq_rules'
      and policyname='Authenticated read product_moq_rules'
  ),
  'raw MOQ broad authenticated read policy is removed'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='product_moq_rules'
      and policyname='Internal staff read product_moq_rules'
      and qual ilike '%is_internal_staff%'
  ),
  'MOQ raw read is internal-staff scoped'
);

select ok(
  not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels')
      and policyname='ols_auth_read'
  ),
  'permissive Trace ols_auth_read policies are removed'
);

select is(
  (
    select count(*)::int
    from pg_policies
    where schemaname='public'
      and tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels')
      and policyname='trace_internal_read'
      and qual ilike '%is_internal_staff%'
  ),
  4,
  'all four Trace target tables retain internal-staff read policies'
);

select ok(
  not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname in (
        'Allow authenticated full access on dispatches',
        'Users can view their dispatches',
        'Admin All Access Dispatches'
      )
  ),
  'legacy blanket/buyer dispatch policies are removed'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname='Internal staff read legacy dispatches'
      and qual ilike '%is_internal_staff%'
  ),
  'legacy dispatch read is internal-staff scoped'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname='Dispatch authority insert legacy dispatches'
      and with_check ilike '%DISPATCH_MANAGER%'
  )
  and exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname='Dispatch authority update legacy dispatches'
      and qual ilike '%OPERATIONS_MANAGER%'
  )
  and exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname='Dispatch authority delete legacy dispatches'
      and qual ilike '%ADMIN%'
  ),
  'legacy dispatch mutation is explicitly Dispatch/Operations/Admin scoped'
);

select ok(
  (select relrowsecurity from pg_class where oid='public.products'::regclass)
  and (select relrowsecurity from pg_class where oid='public.product_pricing_rules'::regclass)
  and (select relrowsecurity from pg_class where oid='public.product_moq_rules'::regclass)
  and (select relrowsecurity from pg_class where oid='public.dispatches'::regclass),
  'RLS remains enabled across the commercial and legacy dispatch targets'
);

select * from finish();
