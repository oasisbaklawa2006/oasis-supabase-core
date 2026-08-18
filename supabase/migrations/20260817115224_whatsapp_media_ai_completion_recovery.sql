-- Recovered historical migration: reproduces the exact SQL applied to production
-- (tcxvcatsqqertcnycuop) under this version, fetched read-only via
-- the production migration ledger's statements column during the 2026-08-18
-- production migration lineage recovery. See
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv
-- for provenance. This is an intermediate historical definition of
-- complete_whatsapp_media_processing(), superseded in production by version
-- 20260817120220 and later by this recovery's own
-- 20260817213000_fwd_wa_packet_ai_release_hardening_delta.sql -- reproduced
-- here verbatim so a clean zero-state replay passes through the same
-- version sequence production did, rather than skipping straight to the
-- final state.

begin;

create or replace function public.complete_whatsapp_media_processing(
  p_provider_message_id text,
  p_state text,
  p_attempt_key text,
  p_detail jsonb default '{}'::jsonb
)
returns public.whatsapp_commercial_evidence
language plpgsql
security definer
set search_path to 'public','auth','pg_temp'
as $function$
declare
  v_row public.whatsapp_commercial_evidence%rowtype;
  v_packet_state text;
  v_only_media_bootstrap_failures boolean;
begin
  if auth.uid() is not null then raise exception 'WA4_TRUSTED_PROCESSOR_REQUIRED' using errcode='P0001'; end if;
  if p_state not in ('SUCCEEDED','UNSUPPORTED','CORRUPT','UNREADABLE','TIMED_OUT','FAILED') then raise exception 'WA4_INVALID_MEDIA_STATE'; end if;
  select * into v_row from public.whatsapp_commercial_evidence where provider_message_id=p_provider_message_id for update;
  if not found then raise exception 'WA4_EVIDENCE_NOT_FOUND'; end if;
  if nullif(btrim(p_attempt_key),'') is null then raise exception 'WA4_ATTEMPT_KEY_REQUIRED'; end if;
  insert into public.whatsapp_media_processing_events(evidence_id,attempt_key,state,detail)
  values(v_row.id,btrim(p_attempt_key),p_state,coalesce(p_detail,'{}')) on conflict(evidence_id,attempt_key) do nothing;
  update public.whatsapp_commercial_evidence
     set processing_state=p_state,
         processing_detail=coalesce(processing_detail,'{}'::jsonb)||coalesce(p_detail,'{}'::jsonb)||jsonb_build_object('attempt_key',btrim(p_attempt_key)),
         processed_at=now()
   where id=v_row.id returning * into v_row;
  v_packet_state:=case when p_state='SUCCEEDED' then 'READY' else 'HUMAN_REVIEW' end;
  update public.whatsapp_commercial_packets set status=case when p_state='SUCCEEDED' then 'OPEN' else 'FAILED_MEDIA' end,processing_state=v_packet_state,updated_at=now(),version=version+1 where id=v_row.packet_id;
  insert into public.whatsapp_packet_audit_log(packet_id,action,evidence) values(v_row.packet_id,'MEDIA_PROCESSING_'||p_state,jsonb_build_object('evidence_id',v_row.id,'detail',coalesce(p_detail,'{}')));
  if p_state<>'SUCCEEDED' then
    perform set_config('app.wa1_governed_mutation','on',true);
    update public.whatsapp_potential_orders set state='FAILED_INTERPRETATION',queue='WA_FAILED_INTERPRETATION',next_action='REVIEW_MEDIA_EVIDENCE',updated_at=now() where id=v_row.potential_order_id and disposition='ACTIVE_PENDING';
    perform set_config('app.wa1_governed_mutation','off',true);
  else
    select not exists (
      select 1 from public.whatsapp_commercial_evidence e
      where e.potential_order_id=v_row.potential_order_id
        and e.processing_state in ('FAILED','UNREADABLE','CORRUPT','UNSUPPORTED','TIMED_OUT')
        and coalesce(e.processing_detail->>'fail_open_media_review','false') <> 'true'
    ) into v_only_media_bootstrap_failures;
    if v_only_media_bootstrap_failures and not exists (
      select 1 from public.whatsapp_commercial_evidence e
      where e.potential_order_id=v_row.potential_order_id and e.media_count>0 and e.processing_state<>'SUCCEEDED'
    ) then
      perform set_config('app.wa1_governed_mutation','on',true);
      update public.whatsapp_potential_orders
         set state='UNASSIGNED',queue='WA_COMMERCIAL_UNASSIGNED',next_action='ASSIGN_OWNER',updated_at=now()
       where id=v_row.potential_order_id and disposition='ACTIVE_PENDING'
         and state='FAILED_INTERPRETATION' and queue='WA_FAILED_INTERPRETATION'
         and next_action in ('HUMAN_INTERPRETATION','REVIEW_MEDIA_EVIDENCE');
      perform set_config('app.wa1_governed_mutation','off',true);
    end if;
  end if;
  return v_row;
exception when others then
  perform set_config('app.wa1_governed_mutation','off',true);
  raise;
end
$function$;

revoke all on function public.complete_whatsapp_media_processing(text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.complete_whatsapp_media_processing(text,text,text,jsonb) to service_role;

commit;
