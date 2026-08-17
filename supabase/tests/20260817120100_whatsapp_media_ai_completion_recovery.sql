-- Contract assertions for 20260817120100_whatsapp_media_ai_completion_recovery.
begin;

select plan(1);

do $$
declare
  fn text;
begin
  if to_regprocedure('public.complete_whatsapp_media_processing(text,text,text,jsonb)') is null then
    raise exception 'complete_whatsapp_media_processing(text,text,text,jsonb) is missing';
  end if;

  if has_function_privilege('anon','public.complete_whatsapp_media_processing(text,text,text,jsonb)','EXECUTE') then
    raise exception 'anon can execute complete_whatsapp_media_processing';
  end if;
  if has_function_privilege('authenticated','public.complete_whatsapp_media_processing(text,text,text,jsonb)','EXECUTE') then
    raise exception 'authenticated can execute complete_whatsapp_media_processing';
  end if;
  if not has_function_privilege('service_role','public.complete_whatsapp_media_processing(text,text,text,jsonb)','EXECUTE') then
    raise exception 'service_role cannot execute complete_whatsapp_media_processing';
  end if;

  select pg_get_functiondef(p.oid) into fn
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='complete_whatsapp_media_processing'
    and pg_get_function_identity_arguments(p.oid)='p_provider_message_id text, p_state text, p_attempt_key text, p_detail jsonb';

  if fn is null then raise exception 'media completion function definition unavailable'; end if;
  if position('update public.whatsapp_commercial_evidence' in lower(fn)) = 0 then
    raise exception 'media completion does not persist evidence processing state';
  end if;
  if position('processed_at=now()' in replace(lower(fn),' ','')) = 0 then
    raise exception 'media completion does not persist processed_at';
  end if;
  if position('fail_open_media_review' in fn) = 0 then
    raise exception 'legacy media-bootstrap recovery guard is missing';
  end if;
  if position('state=''FAILED_INTERPRETATION''' in fn) = 0 then
    raise exception 'failed media fail-closed state is missing';
  end if;
end $$;

select ok(true, '20260817120100 media AI completion recovery remains service-only and fail-closed');
select * from finish();
rollback;
