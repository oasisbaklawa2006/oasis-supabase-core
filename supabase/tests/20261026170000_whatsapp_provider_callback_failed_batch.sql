-- 20261026170000_whatsapp_provider_callback_failed_batch.sql
-- Contract tests for provider status failure reconciliation; independent of customer/provider traffic.
begin;
select plan(12);
select has_function('public','persist_whatsapp_operator_reply_provider_status',array['text','text','jsonb'],'provider status RPC exists');
select ok(exists(select 1 from pg_constraint c where c.conrelid='public.whatsapp_operator_reply_outbox'::regclass
  and c.conname='whatsapp_operator_reply_outbox_provider_message_id_check'
  and pg_get_constraintdef(c.oid) like '%FAILED_FINAL%'), 'provider-linked terminal FAILED_FINAL is schema-legal');
select ok(not has_function_privilege('anon','public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)','EXECUTE'),'anon cannot persist callbacks');
select ok(not has_function_privilege('authenticated','public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)','EXECUTE'),'authenticated users cannot persist callbacks');
select ok(has_function_privilege('service_role','public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)','EXECUTE'),'service_role is permitted');
select ok(pg_get_functiondef('public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)'::regprocedure)
  ilike '%for update%', 'callback status row is locked atomically');
select ok(pg_get_functiondef('public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)'::regprocedure) like
  '%v_reply.status = ''FAILED_FINAL''%', 'terminal failure cannot regress to success');
select ok(pg_get_functiondef('public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)'::regprocedure) like
  '%''DELIVERED'',''READ''%', 'verified delivery/read immune to late failure');
select ok(pg_get_functiondef('public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)'::regprocedure) like
  '%WA_STATUS_PROVIDER_MESSAGE_AMBIGUOUS%', 'duplicate provider message IDs are rejected');
select ok(pg_get_functiondef('public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)'::regprocedure) like
  '%WA_STATUS_PROVIDER_ID_MISSING%', 'missing callback ID must fail closed');
select ok(pg_get_functiondef('public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb)'::regprocedure) like
  '%provider_error_code%', 'sanitized failure code persists');
select ok(exists (select 1 from pg_trigger
  where tgrelid='public.whatsapp_operator_reply_events'::regclass
    and tgname='wa5_reply_events_immutable' and not tgisinternal),'delivery evidence is immutable');
select * from finish();
rollback;
