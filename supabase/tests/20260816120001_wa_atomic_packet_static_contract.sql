-- Static authority checks complement the behavioural pgTAP contract.
-- Covers 20260816120100_wa_provider_message_unique_index.sql as the non-transactional index migration.
begin;
select plan(4);
select function_privs_are('public','stitch_whatsapp_messages_atomic',array['uuid','uuid[]','integer'],'service_role',array['EXECUTE'],'only service role executes packet mutation');
select ok((select prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='stitch_whatsapp_messages_atomic'),'packet mutation is security definer');
select ok(exists(select 1 from pg_indexes where schemaname='public' and tablename='whatsapp_messages' and indexname='whatsapp_messages_provider_message_unique'),'provider retry uniqueness is database enforced');
select ok(position('pg_advisory_xact_lock' in pg_get_functiondef('public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer)'::regprocedure))>0,'packet mutation serializes per contact in the transaction');
select * from finish();
rollback;
