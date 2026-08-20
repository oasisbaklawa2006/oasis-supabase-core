-- Bridge communication cases (stitcher packet authority) to WA1 potential orders when
-- commercial evidence was captured under the separate WA4 commercial packet id before
-- stitch_whatsapp_messages_atomic assigned the governed stitcher packet.

create or replace function public.whatsapp_case_potential_order_id(p_case_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_packet_id uuid;
  v_ids uuid[];
begin
  select packet_id into v_packet_id
  from public.whatsapp_communication_cases
  where id = p_case_id;

  if v_packet_id is null then
    return null;
  end if;

  select coalesce(array_agg(distinct evidence.potential_order_id), '{}'::uuid[])
  into v_ids
  from public.whatsapp_commercial_evidence evidence
  where evidence.potential_order_id is not null
    and (
      evidence.packet_id = v_packet_id
      or evidence.provider_message_id in (
        select m.provider_message_id
        from public.whatsapp_messages m
        where m.packet_id = v_packet_id
          and m.direction = 'inbound'
          and m.provider_message_id is not null
      )
    );

  if cardinality(v_ids) > 1 then
    raise exception 'multiple potential orders are linked to this communication case';
  end if;

  return case when cardinality(v_ids) = 1 then v_ids[1] else null end;
end;
$$;

comment on function public.whatsapp_case_potential_order_id(uuid) is
  'Internal fail-closed resolver for the single governed potential order linked to a communication case. Matches commercial evidence by stitcher packet id or by inbound provider_message_id on that packet.';

revoke all on function public.whatsapp_case_potential_order_id(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_case_potential_order_id(uuid) to service_role;
