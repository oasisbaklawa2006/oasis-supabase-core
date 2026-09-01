-- Contract for preview ledger compatibility stub 20260901005100_app_e2e_buyer_commercial_projections.sql
begin;

select plan(1);

select ok(
  exists(
    select 1
      from pg_proc
     where oid = 'public.customer_sales_order_commercial_facts_v1()'::regprocedure
  ),
  'preview compat stub leaves forward commercial projection patch applied by 20260901005500'
);

select * from finish();
rollback;
