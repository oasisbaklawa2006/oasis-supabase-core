-- Contract for migration 20260814121200_reconcile_trace_gate3_authority_closure.
begin;
select plan(17);

select has_function('public','trace_role_allowed_v1',array['text']);
select has_function('public','trace_create_production_v1',array['jsonb','jsonb','text']);
select has_function('public','trace_finalize_carton_v1',array['uuid','numeric','numeric','boolean','text']);
select has_function('public','trace_create_dpl_v1',array['jsonb','uuid[]','text']);
select has_function('public','trace_add_carton_to_pi_v1',array['uuid','uuid','text','text']);
select has_function('public','trace_clear_pi_v1',array['uuid','text','jsonb','text']);
select has_function('public','trace_create_shipping_label_v1',array['jsonb','text']);
select ok(to_regclass('public.ols_trace_mutation_receipts') is not null,'mutation receipt table exists');
select is((select count(*) from pg_indexes where schemaname='public' and tablename='ols_trace_mutation_receipts' and indexdef like '%UNIQUE%idempotency_key%'),1::bigint,'idempotency key is unique');
select ok(exists(select 1 from pg_trigger where tgrelid='public.ols_audit_logs'::regclass and tgname='trg_ols_audit_logs_immutable' and not tgisinternal),'audit immutability trigger exists');
select ok(exists(select 1 from pg_trigger where tgrelid='public.ols_trace_mutation_receipts'::regclass and tgname='trg_ols_trace_receipts_immutable' and not tgisinternal),'receipt immutability trigger exists');
select isnt_empty($$select 1 from pg_proc where oid='public.trace_create_dpl_v1(jsonb,uuid[],text)'::regprocedure and prosecdef$$,'DPL mutation is a guarded definer transaction');
select isnt_empty($$select 1 from pg_proc where oid='public.trace_add_carton_to_pi_v1(uuid,uuid,text,text)'::regprocedure and pg_get_functiondef(oid) like '%UNLINKED_DPL_CARTON_REJECTED%'$$,'PI membership fails closed');
select isnt_empty($select 1 from pg_proc where oid='public.trace_create_shipping_label_v1(jsonb,text)'::regprocedure and pg_get_functiondef(oid) like '%UNPROVEN_PI_CARTON_MEMBERSHIP%'$,'shipping membership fails closed');
select isnt_empty($select 1 from pg_proc where oid='public.trace_create_dpl_v1(jsonb,uuid[],text)'::regprocedure and pg_get_functiondef(oid) like '%sum(c.gross_weight)%' and pg_get_functiondef(oid) like '%DPL_CARTON_WEIGHTS_REQUIRED%'$,'DPL totals derive from packed carton weights');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and grantee in ('PUBLIC','anon') and routine_name like 'trace_%_v1' and privilege_type='EXECUTE'$$,'anonymous roles cannot execute Trace authority functions');
select is_empty($$select 1 from pg_policies where schemaname='public' and tablename like 'ols\_%' escape '\' and cmd in ('INSERT','UPDATE','DELETE','ALL') and (roles && array['authenticated','public']::name[])$,'direct mutation policies are removed for authenticated/public');

select * from finish();
rollback;
