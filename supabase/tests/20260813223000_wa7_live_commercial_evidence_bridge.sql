-- Contract test for 20260813223000_wa7_live_commercial_evidence_bridge.sql
begin;
select plan(6);
select has_function('public','capture_whatsapp_commercial_fragment_for_potential',array['uuid','uuid','integer','boolean','jsonb']);
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb)'::regprocedure and prosecdef$$,'bridge is security definer');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name='capture_whatsapp_commercial_fragment_for_potential' and grantee in ('PUBLIC','anon','authenticated')$$,'untrusted roles cannot execute bridge');
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%WA7_SENDER_BOUNDARY_MISMATCH%'$$,'cross-customer stitching fails closed');
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%WA7_SOURCE_LINEAGE_MISMATCH%'$$,'source must already belong to potential intake');
select isnt_empty($$select 1 from pg_proc where oid='public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%capture_whatsapp_commercial_fragment%'$$,'existing immutable WA-4 capture remains authoritative');
select * from finish();
rollback;
