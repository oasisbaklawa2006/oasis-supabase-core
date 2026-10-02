-- Contract for 20261002180929_launch_blocker_data_api_leakage_lockdown.sql
begin;
select plan(3);

select is(
  (select count(*)::integer from pg_policies
   where schemaname='public'
     and tablename in ('products','product_pricing_rules','product_moq_rules')
     and policyname like 'Internal staff read %'
     and cmd='SELECT'
     and qual like '%is_internal_staff(auth.uid())%'),
  3,
  '20261002180929 replaces broad product master reads with internal-staff reads'
);

select is(
  (select count(*)::integer from pg_policies
   where schemaname='public'
     and tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels')
     and policyname='ols_auth_read'),
  0,
  '20261002180929 removes permissive Trace ols_auth_read policies'
);

select ok(
  not exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename='dispatches'
      and policyname='Allow authenticated full access on dispatches'
  ),
  '20261002180929 removes blanket authenticated dispatch access'
);

select * from finish();
rollback;
