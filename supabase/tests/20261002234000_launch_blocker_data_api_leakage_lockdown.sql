-- Contract: 20261002234000_launch_blocker_data_api_leakage_lockdown
begin;
select plan(2);
select is(
  (select count(*)::bigint from pg_policies where schemaname='public' and (
    (tablename in ('products','product_pricing_rules','product_moq_rules') and policyname like 'Authenticated read %')
    or (tablename='dispatches' and policyname='Allow authenticated full access on dispatches')
    or (tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels') and policyname='ols_auth_read')
  )),
  0::bigint,
  '20261002234000 removes generic authenticated raw-data policies'
);
select is(
  (select count(*)::bigint from pg_policies where schemaname='public' and (
    (tablename in ('products','product_pricing_rules','product_moq_rules') and policyname like 'Internal staff read %')
    or (tablename in ('ols_orders_cache','ols_products_cache','ols_production_batches','ols_production_labels') and policyname='trace_internal_read')
  )),
  7::bigint,
  '20261002234000 preserves internal-staff read boundaries'
);
select * from finish();
rollback;
