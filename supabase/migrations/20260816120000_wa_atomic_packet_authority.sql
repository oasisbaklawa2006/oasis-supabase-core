-- WA runtime authority hardening: make packet stitching atomic and idempotent in Core.
-- No historical packet/evidence rows are rewritten by this migration.
begin;

-- Provider retries must not create a second raw message for the same provider event.
-- The provider is part of the key so independently-issued IDs cannot collide.
create unique index if not exists whatsapp_messages_provider_message_unique
  on public.whatsapp_messages (provider, btrim(provider_message_id))
  where provider_message_id is not null and btrim(provider_message_id) <> '';

create or replace function public.stitch_whatsapp_messages_atomic(
  p_contact_id uuid,
  p_message_ids uuid[],
  p_window_seconds integer default 300
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_ids uuid[];
  v_requested integer;
  v_found integer;
  v_existing_packet_count integer;
  v_existing_packet uuid;
  v_packet_id uuid;
  v_fragment_count integer;
  v_first_at timestamp without time zone;
  v_last_at timestamp without time zone;
  v_text text;
begin
  if p_contact_id is null then
    raise exception 'WA_PACKET_CONTACT_REQUIRED' using errcode = 'P0001';
  end if;
  if p_window_seconds < 1 or p_window_seconds > 3600 then
    raise exception 'WA_PACKET_WINDOW_INVALID' using errcode = 'P0001';
  end if;

  select coalesce(array_agg(distinct x order by x), '{}'::uuid[])
    into v_ids
  from unnest(coalesce(p_message_ids, '{}'::uuid[])) x
  where x is not null;
  v_requested := cardinality(v_ids);
  if v_requested = 0 then
    raise exception 'WA_PACKET_MESSAGES_REQUIRED' using errcode = 'P0001';
  end if;

  -- Serialize all packet mutation for one contact. This removes the Edge-function
  -- read/CAS/compensating-rollback race while still allowing different contacts
  -- to stitch concurrently.
  perform pg_advisory_xact_lock(hashtextextended(p_contact_id::text, 0));

  -- Lock the exact source rows for the duration of this transaction.
  perform 1
  from public.whatsapp_messages m
  where m.id = any(v_ids)
  order by m.id
  for update;

  select count(*), min(coalesce(m.message_timestamp,m.created_at)),
         max(coalesce(m.message_timestamp,m.created_at)),
         string_agg(coalesce(m.content,''), E'\n' order by coalesce(m.message_timestamp,m.created_at),m.created_at,m.id)
    into v_found, v_first_at, v_last_at, v_text
  from public.whatsapp_messages m
  where m.id = any(v_ids)
    and m.contact_id = p_contact_id
    and m.direction = 'inbound';

  if v_found <> v_requested then
    raise exception 'WA_PACKET_MESSAGE_SCOPE_MISMATCH' using errcode = 'P0001';
  end if;

  select count(distinct m.packet_id), min(m.packet_id)
    into v_existing_packet_count, v_existing_packet
  from public.whatsapp_messages m
  where m.id = any(v_ids) and m.packet_id is not null;

  -- Exact replay is idempotent. Mixed already/new or cross-packet batches fail
  -- closed so a retry can never silently double-count fragments.
  if v_existing_packet_count > 0 then
    if v_existing_packet_count = 1
       and not exists (select 1 from public.whatsapp_messages m where m.id=any(v_ids) and m.packet_id is null)
       and not exists (select 1 from public.whatsapp_messages m where m.id=any(v_ids) and m.packet_id <> v_existing_packet) then
      return v_existing_packet;
    end if;
    raise exception 'WA_PACKET_PARTIAL_OR_CONFLICTING_REPLAY' using errcode = 'P0001';
  end if;

  select p.id, p.fragment_count
    into v_packet_id, v_fragment_count
  from public.whatsapp_message_packets p
  where p.contact_id = p_contact_id
    and p.status = 'open'
    and p.last_message_at >= v_first_at - make_interval(secs => p_window_seconds)
    and p.first_message_at <= v_last_at + make_interval(secs => p_window_seconds)
  order by p.last_message_at desc, p.id
  limit 1
  for update;

  if v_packet_id is null then
    insert into public.whatsapp_message_packets(
      contact_id, stitched_content, fragment_count, first_message_at,
      last_message_at, status, created_at, updated_at
    ) values (
      p_contact_id,
      jsonb_build_object('summary', v_requested::text || ' messages stitched', 'text', coalesce(v_text,'')),
      v_requested, v_first_at, v_last_at, 'open', statement_timestamp(), statement_timestamp()
    ) returning id into v_packet_id;
    v_fragment_count := 0;
  else
    update public.whatsapp_message_packets p
    set fragment_count = p.fragment_count + v_requested,
        first_message_at = least(p.first_message_at, v_first_at),
        last_message_at = greatest(p.last_message_at, v_last_at),
        stitched_content = jsonb_build_object(
          'summary', (p.fragment_count + v_requested)::text || ' messages stitched',
          'text', concat_ws(E'\n', nullif(p.stitched_content->>'text',''), nullif(v_text,''))
        ),
        updated_at = statement_timestamp()
    where p.id = v_packet_id and p.status = 'open';
    if not found then
      raise exception 'WA_PACKET_CLOSED_DURING_STITCH' using errcode = 'P0001';
    end if;
  end if;

  with ranked as (
    select m.id,
           v_fragment_count + row_number() over(order by coalesce(m.message_timestamp,m.created_at),m.created_at,m.id) as seq
    from public.whatsapp_messages m
    where m.id = any(v_ids)
  )
  update public.whatsapp_messages m
  set packet_id = v_packet_id,
      packet_sequence = ranked.seq,
      packet_status = 'open',
      is_raw = false,
      stitched_at = statement_timestamp()
  from ranked
  where m.id = ranked.id and m.packet_id is null;

  if not found then
    raise exception 'WA_PACKET_FRAGMENT_LINK_FAILED' using errcode = 'P0001';
  end if;

  return v_packet_id;
end;
$$;

revoke all on function public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer) from public, anon, authenticated;
grant execute on function public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer) to service_role;

comment on function public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer) is
  'Core-owned atomic WhatsApp packet mutation. Serializes per contact, links all fragments in one transaction, and returns the existing packet on exact replay.';

commit;
