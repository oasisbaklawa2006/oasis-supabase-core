-- Point 20: shared immutable operational event ledger
-- Extends the existing operational_events authority instead of creating a parallel ledger.

alter table public.operational_events
  add column if not exists source_application text,
  add column if not exists event_version integer,
  add column if not exists command_name text,
  add column if not exists command_id text,
  add column if not exists causation_id text,
  add column if not exists occurred_at timestamptz,
  add column if not exists payload_fingerprint text;

-- Existing rows predate the canonical envelope. Temporarily disable only the
-- two append-only guards inside this migration transaction for the one-time backfill.
alter table public.operational_events disable trigger trg_operational_events_no_update;
alter table public.operational_events disable trigger trg_operational_events_no_delete;

update public.operational_events
set source_application = coalesce(source_application, 'legacy'),
    event_version = coalesce(event_version, 1),
    occurred_at = coalesce(occurred_at, created_at),
    payload_fingerprint = coalesce(payload_fingerprint, md5(concat_ws('|', event_type, entity_type, entity_id::text, correlation_id, metadata::text)))
where source_application is null or event_version is null or occurred_at is null or payload_fingerprint is null;

alter table public.operational_events enable trigger trg_operational_events_no_update;
alter table public.operational_events enable trigger trg_operational_events_no_delete;

alter table public.operational_events
  alter column source_application set default 'unknown', alter column source_application set not null,
  alter column event_version set default 1, alter column event_version set not null,
  alter column occurred_at set default now(), alter column occurred_at set not null,
  alter column payload_fingerprint set not null;

alter table public.operational_events
  drop constraint if exists operational_events_event_version_positive,
  add constraint operational_events_event_version_positive check (event_version > 0),
  drop constraint if exists operational_events_source_application_nonempty,
  add constraint operational_events_source_application_nonempty check (btrim(source_application) <> ''),
  drop constraint if exists operational_events_payload_fingerprint_nonempty,
  add constraint operational_events_payload_fingerprint_nonempty check (btrim(payload_fingerprint) <> '');

create unique index if not exists operational_events_source_idempotency_uidx on public.operational_events (source_application, idempotency_key) where idempotency_key is not null;
create index if not exists operational_events_correlation_idx on public.operational_events (correlation_id, occurred_at desc);
create index if not exists operational_events_causation_idx on public.operational_events (causation_id) where causation_id is not null;
create index if not exists operational_events_entity_timeline_idx on public.operational_events (entity_type, entity_id, occurred_at desc);

create or replace function public.append_operational_event_v1(
  p_event_type text, p_entity_type text, p_entity_id uuid, p_title text,
  p_source_application text, p_correlation_id text, p_metadata jsonb default '{}'::jsonb,
  p_order_id uuid default null, p_customer_id uuid default null, p_queue_item_id uuid default null,
  p_actor_id uuid default null, p_actor_role text default null, p_actor_department text default null,
  p_visibility text default 'internal', p_severity text default 'info', p_message text default null,
  p_reason_code text default null, p_reason_text text default null, p_idempotency_key text default null,
  p_event_version integer default 1, p_command_name text default null, p_command_id text default null,
  p_causation_id text default null, p_occurred_at timestamptz default now()
) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor_id uuid := coalesce(p_actor_id, auth.uid());
  v_fingerprint text; v_existing_id uuid; v_existing_fingerprint text;
begin
  if auth.role() <> 'service_role' then
    if auth.uid() is null then raise exception 'authentication required'; end if;
    if v_actor_id is distinct from auth.uid() then raise exception 'actor identity mismatch'; end if;
    if not public.is_internal_staff(auth.uid()) then raise exception 'internal staff authority required'; end if;
  end if;

  if nullif(btrim(p_event_type), '') is null or nullif(btrim(p_entity_type), '') is null or p_entity_id is null
     or nullif(btrim(p_title), '') is null or nullif(btrim(p_source_application), '') is null
     or nullif(btrim(p_correlation_id), '') is null then
    raise exception 'event_type, entity_type, entity_id, title, source_application and correlation_id are required';
  end if;
  if p_event_version < 1 then raise exception 'event_version must be positive'; end if;

  v_fingerprint := md5(concat_ws('|', p_event_type, p_entity_type, p_entity_id::text, p_title,
    p_source_application, p_correlation_id, coalesce(p_metadata, '{}'::jsonb)::text,
    coalesce(p_order_id::text, ''), coalesce(p_customer_id::text, ''), coalesce(p_queue_item_id::text, ''),
    coalesce(v_actor_id::text, ''), coalesce(p_visibility, ''), coalesce(p_severity, ''),
    coalesce(p_command_name, ''), coalesce(p_command_id, ''), coalesce(p_causation_id, ''), p_event_version::text));

  if p_idempotency_key is not null then
    select id, payload_fingerprint into v_existing_id, v_existing_fingerprint
    from public.operational_events where source_application=p_source_application and idempotency_key=p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_fingerprint <> v_fingerprint then raise exception 'idempotency key conflict'; end if;
      return v_existing_id;
    end if;
  end if;

  begin
    insert into public.operational_events (
      event_type,entity_type,entity_id,order_id,customer_id,queue_item_id,actor_id,actor_role,actor_department,
      visibility,severity,title,message,reason_code,reason_text,metadata,correlation_id,idempotency_key,
      source_application,event_version,command_name,command_id,causation_id,occurred_at,payload_fingerprint
    ) values (
      p_event_type,p_entity_type,p_entity_id,p_order_id,p_customer_id,p_queue_item_id,v_actor_id,p_actor_role,p_actor_department,
      p_visibility,p_severity,p_title,p_message,p_reason_code,p_reason_text,coalesce(p_metadata,'{}'::jsonb),p_correlation_id,p_idempotency_key,
      p_source_application,p_event_version,p_command_name,p_command_id,p_causation_id,p_occurred_at,v_fingerprint
    ) returning id into v_existing_id;
    return v_existing_id;
  exception when unique_violation then
    if p_idempotency_key is null then raise; end if;
    select id,payload_fingerprint into v_existing_id,v_existing_fingerprint from public.operational_events
      where source_application=p_source_application and idempotency_key=p_idempotency_key;
    if v_existing_id is null or v_existing_fingerprint<>v_fingerprint then raise exception 'idempotency key conflict'; end if;
    return v_existing_id;
  end;
end; $$;

revoke all on function public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz) from public, anon;
grant execute on function public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz) to authenticated, service_role;

comment on function public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz)
is 'Canonical append-only operational event writer with caller binding, correlation, causation, versioning and idempotent replay protection.';
