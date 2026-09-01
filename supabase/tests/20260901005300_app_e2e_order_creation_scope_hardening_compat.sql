-- Contract for preview ledger compatibility stub 20260901005300_app_e2e_order_creation_scope_hardening.sql
begin;

select plan(1);

select ok(
  exists(
    select 1
      from pg_class
     where oid = 'public.sales_order_creation_scopes'::regclass
  ),
  'preview compat stub leaves forward SO scope hardening patch applied by 20260901005700'
);

select * from finish();
rollback;
