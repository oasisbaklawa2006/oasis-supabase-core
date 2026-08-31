-- Contract for preview ledger compatibility stub 20260830101500_wa_stage1b_unclear_clarification_autonomy.sql
begin;

select plan(1);

select ok(
  exists(
    select 1
      from pg_proc
     where oid = 'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure
  ),
  'preview compat stub leaves forward autonomy patch applied by 20260831101900'
);

select * from finish();
rollback;
