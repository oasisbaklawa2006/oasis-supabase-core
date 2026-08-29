-- Stage 1B media certification repair.
-- The packet AI worker processes all governed WhatsApp packets, including
-- non-order media such as complaints and payment advice. Commercial media
-- completion remains mandatory for commercial-eligible evidence, but an
-- explicitly noncommercial inbound message must not fail with
-- WA4_EVIDENCE_NOT_FOUND merely because no whatsapp_commercial_evidence row
-- should exist for it.

create or replace function public.complete_whatsapp_media_processing(
  p_provider_message_id text,
  p_state text,
  p_attempt_key text,
  p_detail jsonb default '{}'::jsonb
)
returns public.whatsapp_commercial_evidence
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  v_row public.whatsapp_commercial_evidence%rowtype;
  v_event_id bigint;
  v_packet_state text;
  v_bootstrap_media_total integer;
  v_bootstrap_media_succeeded integer;
  v_non_bootstrap_media integer;
  v_inbound_raw_payload jsonb;
  v_has_terminal_event boolean;
begin
  if auth.uid() is not null then
    raise exception 'WA4_TRUSTED_PROCESSOR_REQUIRED' using errcode='P0001';
  end if;
  if p_state is null
     or p_state not in ('SUCCEEDED','UNSUPPORTED','CORRUPT','UNREADABLE','TIMED_OUT','FAILED') then
    raise exception 'WA4_INVALID_MEDIA_STATE';
  end if;
  if nullif(btrim(p_attempt_key),'') is null then
    raise exception 'WA4_ATTEMPT_KEY_REQUIRED';
  end if;

  -- Serialize explicit completion for one immutable evidence row. Capture-time
  -- processing_state may be provisional; authoritative terminality is the
  -- first append-only whatsapp_media_processing_events row.
  select * into v_row
    from public.whatsapp_commercial_evidence
   where provider_message_id=p_provider_message_id
   for update;

  if not found then
    -- Studio fan-out records commercial_eligible on the authoritative inbound
    -- payload. Only the JSON boolean false is accepted as proof that commercial
    -- evidence is intentionally absent. Missing, stringly-typed, or ambiguous
    -- provenance remains fail-closed so a broken commercial capture cannot
    -- become silent loss.
    select raw_payload into v_inbound_raw_payload
      from public.whatsapp_inbound_messages
     where provider_message_id=p_provider_message_id
     order by received_at desc
     limit 1;

    if jsonb_typeof(v_inbound_raw_payload->'commercial_eligible')='boolean'
       and v_inbound_raw_payload->'commercial_eligible'='false'::jsonb then
      return null;
    end if;

    raise exception 'WA4_EVIDENCE_NOT_FOUND';
  end if;

  select exists(
    select 1
      from public.whatsapp_media_processing_events mpe
     where mpe.evidence_id=v_row.id
       and mpe.state in ('SUCCEEDED','UNSUPPORTED','CORRUPT','UNREADABLE','TIMED_OUT','FAILED')
  ) into v_has_terminal_event;

  -- First explicit terminal event owns the result. A different retry key must
  -- not reverse an already-completed success/failure. The evidence row itself
  -- remains immutable; the append-only event is the authority record.
  if v_has_terminal_event then
    return v_row;
  end if;

  insert into public.whatsapp_media_processing_events(evidence_id,attempt_key,state,detail)
  values(v_row.id,btrim(p_attempt_key),p_state,coalesce(p_detail,'{}'))
  on conflict(evidence_id,attempt_key) do nothing
  returning id into v_event_id;

  if v_event_id is null then
    return v_row;
  end if;

  perform 1
    from public.whatsapp_commercial_packets
   where id=v_row.packet_id
   for update;
  if not found then raise exception 'WA4_PACKET_NOT_FOUND'; end if;

  v_packet_state:=case when p_state='SUCCEEDED' then 'READY' else 'HUMAN_REVIEW' end;
  update public.whatsapp_commercial_packets
     set status=case when p_state='SUCCEEDED' then 'OPEN' else 'FAILED_MEDIA' end,
         processing_state=v_packet_state,
         updated_at=now(),
         version=version+1
   where id=v_row.packet_id;

  insert into public.whatsapp_packet_audit_log(packet_id,action,evidence)
  values(
    v_row.packet_id,
    'MEDIA_PROCESSING_'||p_state,
    jsonb_build_object(
      'evidence_id',v_row.id,
      'attempt_key',btrim(p_attempt_key),
      'detail',coalesce(p_detail,'{}')
    )
  );

  if p_state<>'SUCCEEDED' then
    perform set_config('app.wa1_governed_mutation','on',true);
    update public.whatsapp_potential_orders
       set state='FAILED_INTERPRETATION',
           queue='WA_FAILED_INTERPRETATION',
           next_action='REVIEW_MEDIA_EVIDENCE',
           updated_at=now()
     where id=v_row.potential_order_id
       and disposition='ACTIVE_PENDING';
    perform set_config('app.wa1_governed_mutation','off',true);
    return v_row;
  end if;

  select
    count(*) filter (
      where e.media_count>0
        and coalesce(e.processing_detail->>'fail_open_media_review','false')='true'
    ),
    count(*) filter (
      where e.media_count>0
        and coalesce(e.processing_detail->>'fail_open_media_review','false')<>'true'
    ),
    count(*) filter (
      where e.media_count>0
        and coalesce(e.processing_detail->>'fail_open_media_review','false')='true'
        and exists (
          select 1
            from public.whatsapp_media_processing_events mpe
           where mpe.evidence_id=e.id
             and mpe.state='SUCCEEDED'
        )
    )
  into v_bootstrap_media_total,v_non_bootstrap_media,v_bootstrap_media_succeeded
  from public.whatsapp_commercial_evidence e
  where e.potential_order_id=v_row.potential_order_id;

  if v_bootstrap_media_total>0
     and v_non_bootstrap_media=0
     and v_bootstrap_media_succeeded=v_bootstrap_media_total then
    perform set_config('app.wa1_governed_mutation','on',true);
    update public.whatsapp_potential_orders
       set state='UNASSIGNED',
           queue='WA_COMMERCIAL_UNASSIGNED',
           next_action='ASSIGN_OWNER',
           updated_at=now()
     where id=v_row.potential_order_id
       and disposition='ACTIVE_PENDING'
       and state='FAILED_INTERPRETATION'
       and queue='WA_FAILED_INTERPRETATION'
       and next_action in ('HUMAN_INTERPRETATION','REVIEW_MEDIA_EVIDENCE');
    perform set_config('app.wa1_governed_mutation','off',true);
  end if;

  return v_row;
exception when others then
  perform set_config('app.wa1_governed_mutation','off',true);
  raise;
end
$function$;

comment on function public.complete_whatsapp_media_processing(text,text,text,jsonb) is
  'Trusted first-terminal-wins media completion using append-only events. Explicit noncommercial inbound media may have no commercial evidence; commercial or unproven missing evidence remains fail-closed.';

-- SECURITY DEFINER execution is service-only. Keep the explicit grant boundary
-- in the migration so clean replay cannot inherit PostgreSQL's PUBLIC EXECUTE.
revoke all on function public.complete_whatsapp_media_processing(text,text,text,jsonb) from public;
revoke all on function public.complete_whatsapp_media_processing(text,text,text,jsonb) from anon;
revoke all on function public.complete_whatsapp_media_processing(text,text,text,jsonb) from authenticated;
grant execute on function public.complete_whatsapp_media_processing(text,text,text,jsonb) to service_role;
