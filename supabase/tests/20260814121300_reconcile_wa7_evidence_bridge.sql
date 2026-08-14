-- Contract for forward-only WA-7 evidence bridge reconciliation.
begin;
select plan(4);
select has_function('public','capture_whatsapp_commercial_fragment_for_potential',array['uuid','uuid','integer','boolean','jsonb']);
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb)'::regprocedure and prosecdef$$,'bridge is security definer');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name='capture_whatsapp_commercial_fragment_for_potential' and grantee in ('PUBLIC','anon','authenticated') and privilege_type='EXECUTE'$$,'untrusted roles cannot execute bridge');
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%WA7_SOURCE_LINEAGE_MISMATCH%'$$,'source lineage is enforced');
select * from finish();
rollback;
