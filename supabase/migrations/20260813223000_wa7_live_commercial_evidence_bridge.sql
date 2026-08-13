-- WA-7 live closure: attach WA-4 evidence to the already-authoritative WA-1 intake.
-- Roll forward only; no source evidence or lifecycle row is removed.

create or replace function public.capture_whatsapp_commercial_fragment_for_potential(
  p_potential_order_id uuid,
  p_source_message_id uuid,
  p_media_count integer default 0,
  p_interpretation_failed boolean default false,
  p_evidence jsonb default '{}'::jsonb
) returns public.whatsapp_commercial_evidence
language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare
  v_po public.whatsapp_potential_orders%rowtype;
  v_message public.whatsapp_inbound_messages%rowtype;
  v_packet public.whatsapp_commercial_packets%rowtype;
begin
  if auth.uid() is not null then raise exception 'WA7_TRUSTED_INGRESS_REQUIRED' using errcode='P0001'; end if;
  select * into v_po from public.whatsapp_potential_orders where id=p_potential_order_id for update;
  if not found or v_po.disposition<>'ACTIVE_PENDING' then raise exception 'WA7_ACTIVE_POTENTIAL_REQUIRED'; end if;
  select * into v_message from public.whatsapp_inbound_messages where id=p_source_message_id;
  if not found then raise exception 'WA7_SOURCE_MESSAGE_NOT_FOUND'; end if;
  if lower(regexp_replace(v_message.sender_phone,'\D','','g'))<>v_po.sender_key then raise exception 'WA7_SENDER_BOUNDARY_MISMATCH'; end if;
  if not (v_po.source_message_id=v_message.id or v_po.source_evidence @> jsonb_build_array(jsonb_build_object('message_id',v_message.id))) then
    raise exception 'WA7_SOURCE_LINEAGE_MISMATCH';
  end if;

  select * into v_packet from public.whatsapp_commercial_packets where potential_order_id=v_po.id for update;
  if not found then
    insert into public.whatsapp_commercial_packets(
      potential_order_id,sender_key,conversation_key,status,processing_state,first_received_at,last_received_at
    ) values(
      v_po.id,v_po.sender_key,'potential:'||v_po.id::text,
      case when p_media_count>0 then 'AWAITING_MEDIA' else 'OPEN' end,
      case when p_media_count>0 then 'PENDING' else 'READY' end,
      v_po.first_received_at,v_message.received_at
    ) on conflict(potential_order_id) do nothing;
    select * into v_packet from public.whatsapp_commercial_packets where potential_order_id=v_po.id for update;
  end if;

  return public.capture_whatsapp_commercial_fragment(
    p_source_message_id,v_packet.id,v_packet.conversation_key,null,
    greatest(coalesce(p_media_count,0),0),p_interpretation_failed,coalesce(p_evidence,'{}')
  );
end $$;

revoke all on function public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb) to service_role;

comment on function public.capture_whatsapp_commercial_fragment_for_potential(uuid,uuid,integer,boolean,jsonb) is
'Trusted Central-to-Core WA-7 bridge. Adds immutable evidence to an existing WA-1 intake and reuses its unique commercial packet.';
