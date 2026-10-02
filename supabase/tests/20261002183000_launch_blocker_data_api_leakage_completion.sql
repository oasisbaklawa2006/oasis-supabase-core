-- Contract for 20261002183000_launch_blocker_data_api_leakage_completion.sql
begin;
select plan(8);

select ok(
  not exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename in ('products','product_pricing_rules','product_moq_rules')
      and policyname like 'Authenticated read %'
  ),
  'no generic authenticated product/pricing/MOQ read policy remains'
);

select ok(
  not exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels')
      and policyname='ols_auth_read'
  ),
  'no permissive Trace ols_auth_read policy remains'
);

select is(
  (select count(*)::integer from pg_policies
   where schemaname='public'
     and tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels')
     and policyname='trace_internal_read'
     and cmd='SELECT'
     and roles='{authenticated}'
     and qual like '%is_internal_staff(auth.uid())%'),
  4,
  'all four Trace raw tables expose only the internal-staff read policy'
);

select ok(
  not exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname in (
        'Allow authenticated full access on dispatches',
        'Users can view their dispatches',
        'Admin All Access Dispatches'
      )
  ),
  'legacy dispatch blanket and Buyer-direct policies are absent'
);

select is(
  (select count(*)::integer from pg_policies
   where schemaname='public' and tablename='dispatches'
     and policyname in (
       'Internal staff read legacy dispatches',
       'Dispatch authority insert legacy dispatches',
       'Dispatch authority update legacy dispatches',
       'Dispatch authority delete legacy dispatches'
     )),
  4,
  'dispatch has exactly the four governed read/mutation policies'
);

select ok(
  exists(select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname='Internal staff read legacy dispatches'
      and cmd='SELECT'
      and qual like '%is_internal_staff(auth.uid())%')
  and exists(select 1 from pg_policies
    where schemaname='public' and tablename='dispatches'
      and policyname='Dispatch authority update legacy dispatches'
      and upper(coalesce(qual,'')) like '%DISPATCH_MANAGER%'
      and upper(coalesce(qual,'')) like '%OPERATIONS_MANAGER%'
      and upper(coalesce(qual,'')) like '%ADMIN%'),
  'dispatch effective policies are internal/role scoped rather than generic authenticated access'
);

select ok(
  not has_table_privilege('anon','public.products','SELECT')
  and not has_table_privilege('anon','public.product_pricing_rules','SELECT')
  and not has_table_privilege('anon','public.product_moq_rules','SELECT')
  and not has_table_privilege('anon','public.dispatches','SELECT')
  and not has_table_privilege('anon','public.ols_orders_cache','SELECT')
  and not has_table_privilege('anon','public.ols_products_cache','SELECT')
  and not has_table_privilege('anon','public.ols_production_batches','SELECT')
  and not has_table_privilege('anon','public.ols_production_labels','SELECT'),
  'anonymous raw-table SELECT is revoked across all Target 1 relations'
);

select ok(
  (select bool_and(c.relrowsecurity)
   from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public'
     and c.relname in (
       'products','product_pricing_rules','product_moq_rules','dispatches',
       'ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels'
     )),
  'RLS is enabled on every Target 1 raw relation'
);

select * from finish();
rollback;
