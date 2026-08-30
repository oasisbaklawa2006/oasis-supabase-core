-- Contract for migration 20260830120001_wa_stage1b_unclear_clarification_autonomy.sql
begin;

select plan(1);

select isnt_empty(
  $$select 1
    from pg_proc
   where oid = 'public.whatsapp_evaluate_and_materialize_order_autonomy(uuid,uuid,uuid,uuid,bigint)'::regprocedure
     and pg_get_functiondef(oid) like '%unclear_intent_requires_clarification%'$$,
  'autonomy evaluator maps advisory unclear clarification to CLARIFICATION_REQUIRED'
);

select * from finish();
rollback;
