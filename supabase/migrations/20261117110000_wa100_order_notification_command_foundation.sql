-- WA-100 #540: Core-owned outbound order notification COMMAND foundation.
-- Pre-provider, default-off. This migration intentionally performs zero network
-- calls, cannot mark delivery/acceptance and cannot make a command sendable.
-- No existing operator outbox or legacy sender is modified.
begin;

create table if not exists public.wa100_utility_template_registry (
  event_type text not null check (event_type in ('SO_CREATED','PAYMENT_VERIFIED')),
  template_name text not null check (template_name ~ '^[a-z][a-z0-9_]{1,63}$'),
  language_code text not null check (language_code ~ '^[a-z]{2}(_[A-Z]{2})?$'),
  provider_approval_reference text,
  approved_by uuid,
  approved_at timestamptz,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  constraint wa100_template_registry_pk
    primary key (event_type,template_name,language_code),
  -- Approved template metadata can be staged, but even an enabled template
  -- cannot send: all command statuses remain NOT_SENT_RELEASE_GATED.
  constraint wa100_template_approval_guard check (
    enabled = false or (
      nullif(btrim(provider_approval_reference), '') is not null
      and approved_by is not null and approved_at is not null
    )
  )
);

create table if not exists public.wa100_order_notification_commands (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  company_id uuid not null references public.companies(id),
  contact_id uuid not null references public.whatsapp_contacts(id),
  recipient_identity_id uuid not null references public.whatsapp_case_identities(id),
  recipient_phone_e164 text not null
    check (recipient_phone_e164 ~ '^\+[1-9][0-9]{9,14}$'),
  event_type text not null check (event_type in ('SO_CREATED','PAYMENT_VERIFIED')),
  event_revision integer not null default 1 check (event_revision between 1 and 1000000),
  template_name text not null,
  template_language text not null,
  command_key text not null unique,
  status text not null default 'NOT_SENT_RELEASE_GATED'
    check (status = 'NOT_SENT_RELEASE_GATED'),
  created_at timestamptz not null default now(),
  constraint wa100_order_event_revision_uniq unique (order_id,event_type,event_revision),
  constraint wa100_order_template_fk foreign key (event_type,template_name,template_language)
    references public.wa100_utility_template_registry
      (event_type,template_name,language_code)
);

create table if not exists public.wa100_order_notification_command_events (
  id bigint generated always as identity primary key,
  command_id uuid not null references public.wa100_order_notification_commands(id),
  event_type text not null
    check (event_type in ('CREATED_NOT_SENT','REPLAYED_NOT_SENT')),
  event_at timestamptz not null default now(),
  actor_role text not null,
  evidence jsonb not null default '{}'::jsonb
);

-- Explicit immutable ledger boundary, including privileged service-role updates.
-- Moving a recipient or editing an event after idempotency registration is unsafe
-- even while this release remains default-off.
create or replace function public.wa100_reject_outbound_ledger_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $wa100_immutable$
begin
  raise exception 'WA100_OUTBOUND_LEDGER_IMMUTABLE' using errcode='42501';
end;
$wa100_immutable$;

create trigger wa100_command_immutability
before update or delete on public.wa100_order_notification_commands
for each row execute function public.wa100_reject_outbound_ledger_mutation();

create trigger wa100_command_event_immutability
before update or delete on public.wa100_order_notification_command_events
for each row execute function public.wa100_reject_outbound_ledger_mutation();

revoke all on function public.wa100_reject_outbound_ledger_mutation()
from public, anon, authenticated;

alter table public.wa100_utility_template_registry enable row level security;
alter table public.wa100_order_notification_commands enable row level security;
alter table public.wa100_order_notification_command_events enable row level security;

revoke all on table public.wa100_utility_template_registry,
  public.wa100_order_notification_commands,
  public.wa100_order_notification_command_events
  from public, anon, authenticated;
grant select on public.wa100_utility_template_registry,
  public.wa100_order_notification_commands,
  public.wa100_order_notification_command_events to service_role;
grant insert on public.wa100_order_notification_commands,
  public.wa100_order_notification_command_events to service_role;
grant usage, select on sequence
  public.wa100_order_notification_command_events_id_seq to service_role;

-- A trusted Core service can construct an immutable NOT_SENT command. Caller
-- cannot submit phone, company, identity, body, commercial variables, provider
-- credentials, delivery claims or a custom idempotency string.
create or replace function public.enqueue_wa100_order_notification_v1(
  p_order_id uuid,
  p_event_type text,
  p_contact_id uuid,
  p_template_name text,
  p_language_code text,
  p_event_revision integer default 1
) returns public.wa100_order_notification_commands
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $wa100$
declare
  v_company_id uuid;
  v_phone text;
  v_identity_id uuid;
  v_identity_count integer;
  v_authority_count integer;
  v_preference record;
  v_command public.wa100_order_notification_commands%rowtype;
  v_existing public.wa100_order_notification_commands%rowtype;
  v_key text;
  v_now timestamptz := clock_timestamp();
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'WA100_SERVICE_ROLE_REQUIRED' using errcode='42501';
  end if;
  if p_order_id is null or p_contact_id is null
     or p_event_type not in ('SO_CREATED','PAYMENT_VERIFIED')
     or p_event_type is null
     or p_event_revision is null or p_event_revision < 1
     or p_event_revision > 1000000 then
    raise exception 'WA100_ORDER_EVENT_INVALID' using errcode='22023';
  end if;
  if p_template_name is null or p_template_name !~ '^[a-z][a-z0-9_]{1,63}$'
     or p_language_code is null
     or p_language_code !~ '^[a-z]{2}(_[A-Z]{2})?$' then
    raise exception 'WA100_TEMPLATE_INVALID' using errcode='22023';
  end if;

  select o.company_id into v_company_id
  from public.orders o where o.id = p_order_id for key share;
  if not found or v_company_id is null then
    raise exception 'WA100_ORDER_COMPANY_REQUIRED' using errcode='23503';
  end if;
  if not exists (
    select 1 from public.companies c
    where c.id=v_company_id and c.status='active' and c.is_frozen=false
  ) then
    raise exception 'WA100_COMPANY_NOT_ACTIVE' using errcode='42501';
  end if;

  -- Authority is bound to a real contact and this specific commercial company.
  select count(*) into v_authority_count
  from public.whatsapp_sender_commercial_authorizations a
  where a.company_id=v_company_id and a.contact_id=p_contact_id
    and a.status='ACTIVE' and a.valid_until>v_now
    and a.revoked_at is null and a.disclosure_scope @> array['sales_order']::text[];
  if v_authority_count <> 1 then
    raise exception 'WA100_CONTACT_AUTHORITY_MISSING_OR_AMBIGUOUS' using errcode='42501';
  end if;

  select '+'||regexp_replace(c.phone_number, '[^0-9]', '', 'g')
  into v_phone
  from public.whatsapp_contacts c where c.id=p_contact_id;
  if v_phone is null or v_phone !~ '^\+[1-9][0-9]{9,14}$' then
    raise exception 'WA100_RECIPIENT_PHONE_UNVERIFIED' using errcode='22023';
  end if;
  select (array_agg(i.id))[1],count(*) into v_identity_id,v_identity_count
  from public.whatsapp_case_identities i
  where i.phone_e164=v_phone and i.party_type='COMPANY'
    and i.party_id=v_company_id and i.resolution_status='CONFIRMED';
  if v_identity_count <> 1 then
    raise exception 'WA100_RECIPIENT_IDENTITY_UNVERIFIED' using errcode='42501';
  end if;

  select p.consent_status,p.effective_until,
         p.quiet_hours_start,p.quiet_hours_end,p.max_messages_per_day
    into v_preference
  from public.whatsapp_communication_preferences p
  where p.identity_id=v_identity_id and p.communication_class='TRANSACTIONAL'
    and p.effective_from<=v_now
  order by p.effective_from desc,p.created_at desc
  limit 1;
  if not found then
    raise exception 'WA100_TRANSACTIONAL_CONSENT_MISSING' using errcode='42501';
  end if;
  if v_preference.consent_status <> 'OPTED_IN'
     or (v_preference.effective_until is not null
         and v_preference.effective_until<=v_now)
     or v_preference.quiet_hours_start is not null
     or v_preference.quiet_hours_end is not null
     or v_preference.max_messages_per_day is not null then
    raise exception 'WA100_TRANSACTIONAL_CONSENT_OR_POLICY_NOT_VERIFIED'
      using errcode='42501';
  end if;

  -- No templates are pre-enabled by this migration. A separately approved
  -- metadata record is needed; any resulting command is still NOT SENT.
  if not exists (
    select 1 from public.wa100_utility_template_registry t
    where t.event_type=p_event_type
      and t.template_name=p_template_name
      and t.language_code=p_language_code
      and t.provider_approval_reference is not null
      and t.approved_by is not null and t.approved_at is not null
      and t.enabled=true
  ) then
    raise exception 'WA100_TEMPLATE_RELEASE_NOT_AUTHORIZED' using errcode='42501';
  end if;

  v_key := 'wa100:v1:'||p_order_id::text||':'||p_event_type||':'||p_event_revision::text;
  insert into public.wa100_order_notification_commands (
    order_id,company_id,contact_id,recipient_identity_id,recipient_phone_e164,
    event_type,event_revision,template_name,template_language,command_key
  ) values (
    p_order_id,v_company_id,p_contact_id,v_identity_id,v_phone,
    p_event_type,p_event_revision,p_template_name,p_language_code,v_key
  )
  on conflict (order_id,event_type,event_revision) do nothing
  returning * into v_command;

  if v_command.id is null then
    select * into v_existing
    from public.wa100_order_notification_commands
    where order_id=p_order_id and event_type=p_event_type
      and event_revision=p_event_revision;
    if v_existing.id is null then
      raise exception 'WA100_IDEMPOTENCY_LOOKUP_UNAVAILABLE';
    end if;
    if v_existing.company_id<>v_company_id or v_existing.contact_id<>p_contact_id
       or v_existing.recipient_identity_id<>v_identity_id
       or v_existing.recipient_phone_e164<>v_phone
       or v_existing.template_name<>p_template_name
       or v_existing.template_language<>p_language_code then
      raise exception 'WA100_IDEMPOTENCY_PAYLOAD_CONFLICT' using errcode='23505';
    end if;
    insert into public.wa100_order_notification_command_events
      (command_id,event_type,actor_role,evidence)
    values (v_existing.id,'REPLAYED_NOT_SENT','service_role','{}'::jsonb);
    return v_existing;
  end if;
  insert into public.wa100_order_notification_command_events
    (command_id,event_type,actor_role,evidence)
  values (v_command.id,'CREATED_NOT_SENT','service_role','{}'::jsonb);
  return v_command;
end;
$wa100$;

revoke all on function public.enqueue_wa100_order_notification_v1(
  uuid,text,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.enqueue_wa100_order_notification_v1(
  uuid,text,uuid,text,text,integer) to service_role;
commit;
