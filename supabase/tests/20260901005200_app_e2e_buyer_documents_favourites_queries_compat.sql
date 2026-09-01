-- Contract for preview ledger compatibility stub 20260901005200_app_e2e_buyer_documents_favourites_queries.sql
begin;

select plan(1);

select ok(
  exists(
    select 1
      from pg_proc
     where oid = 'public.customer_documents_v1()'::regprocedure
  ),
  'preview compat stub leaves forward documents contract patch applied by 20260901005600'
);

select * from finish();
rollback;
