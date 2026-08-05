-- Canonical SQL body attached to production-recorded version 20260727070148.
-- Original reviewed version: 20260725210000.
-- Governed lifecycle communication, consent, quiet hours, and case closure.

begin;

create table public.whatsapp_communication_preferences (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.whatsapp_case_identities(id) on delete restrict,
  communication_class text not null
    check (communication_class in ('TRANSACTIONAL', 'SERVICE', 'PROMOTIONAL')),
  consent_status text not null
    check (consent_status in ('UNKNOWN', 'OPTED_IN', 'OPTED_OUT', 'LEGITIMATE_SERVICE')),
  preferred_language text,
  timezone_name text not null default 'Asia/Kolkata',
  quiet_hours_start time,
  quiet_hours_end time,
  max_messages_per_day integer check (max_messages_per_day is null or max_messages_per_day > 0),
  effective_from timestamptz not null,
  effective_until timestamptz,
  source_message_id uuid,
  recorded_by uuid,
  reason text not null,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_communication_preferences_correlation_unique
    unique (identity_id, correlation_key),
  constraint whatsapp_communication_preferences_window check (
    effective_until is null or effective_until > effective_from
  ),
  constraint whatsapp_communication_preferences_quiet_pair check (
    (quiet_hours_start is null and quiet_hours_end is null)
    or (quiet_hours_start is not null and quiet_hours_end is not null)
  )
);

create table public.whatsapp_case_milestone_events (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  milestone_type text not null
    check (milestone_type in (
      'REQUEST_RECEIVED', 'CLARIFICATION_REQUIRED', 'DRAFT_PREPARED',
      'CUSTOMER_CONFIRMED', 'PAYMENT_PROOF_RECEIVED', 'PAYMENT_VERIFIED',
      'PRODUCTION_STARTED', 'READY_FOR_DISPATCH', 'DISPATCHED',
      'DELIVERED', 'EXCEPTION', 'CANCELLED', 'CLOSED'
    )),
  business_object_type text,
  business_object_id uuid,
  occurred_at timestamptz not null,
  customer_relevance text not null
    check (customer_relevance in ('SILENT', 'OPTIONAL', 'REQUIRED')),
  source text not null check (source in ('SYSTEM', 'OPERATOR', 'PROVIDER', 'CUSTOMER')),
  source_event_key text not null,
  facts jsonb not null default '{}'::jsonb check (jsonb_typeof(facts) = 'object'),
  recorded_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_milestone_events_source_unique
    unique (case_id, source_event_key)
);

alter table public.whatsapp_case_outbound_decisions
  add column related_milestone_event_id uuid
    references public.whatsapp_case_milestone_events(id) on delete restrict,
  add column scheduled_for timestamptz;

alter table public.whatsapp_case_outbound_decisions
  add constraint whatsapp_case_outbound_milestone_link check (
    (message_purpose = 'OPERATIONAL_MILESTONE' and related_milestone_event_id is not null)
    or (message_purpose <> 'OPERATIONAL_MILESTONE' and related_milestone_event_id is null)
  );

create table public.whatsapp_case_closures (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  closure_type text not null check (closure_type in ('RESOLVED', 'CANCELLED', 'DUPLICATE', 'NO_RESPONSE')),
  resolution_summary text not null check (length(btrim(resolution_summary)) >= 10),
  unresolved_items jsonb not null default '[]'::jsonb check (jsonb_typeof(unresolved_items) = 'array'),
  customer_notified boolean not null,
  closure_outbound_decision_id uuid
    references public.whatsapp_case_outbound_decisions(id) on delete restrict,
  closed_by uuid not null,
  closed_at timestamptz not null,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_closures_case_unique unique (case_id),
  constraint whatsapp_case_closures_correlation_unique unique (correlation_key),
  constraint whatsapp_case_closures_notification_shape check (
    (customer_notified and closure_outbound_decision_id is not null)
    or (not customer_notified and closure_outbound_decision_id is null)
  )
);

create index whatsapp_communication_preferences_active_idx
  on public.whatsapp_communication_preferences
  (identity_id, communication_class, effective_from, effective_until);
create index whatsapp_case_milestone_events_case_idx
  on public.whatsapp_case_milestone_events (case_id, occurred_at, id);

create or replace function public.guard_whatsapp_lifecycle_outbound()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  recipient_identity uuid;
  preference public.whatsapp_communication_preferences%rowtype;
  local_send_time timestamp;
  sent_today integer;
begin
  if new.status <> 'RELEASED' then
    return new;
  end if;

  select authz.identity_id
    into recipient_identity
  from public.whatsapp_case_recipient_authorizations authz
  where authz.id = new.recipient_authorization_id;

  select *
    into preference
  from public.whatsapp_communication_preferences candidate
  where candidate.identity_id = recipient_identity
    and candidate.communication_class = case
      when new.message_purpose = 'OPERATIONAL_MILESTONE' then 'TRANSACTIONAL'
      else 'SERVICE'
    end
    and candidate.effective_from <= statement_timestamp()
    and (candidate.effective_until is null or candidate.effective_until > statement_timestamp())
  order by candidate.effective_from desc
  limit 1;

  if found and preference.consent_status = 'OPTED_OUT' then
    raise exception 'recipient has opted out of this communication class';
  end if;

  if found and preference.quiet_hours_start is not null then
    local_send_time := statement_timestamp() at time zone preference.timezone_name;
    if (
      preference.quiet_hours_start < preference.quiet_hours_end
      and local_send_time::time >= preference.quiet_hours_start
      and local_send_time::time < preference.quiet_hours_end
    ) or (
      preference.quiet_hours_start > preference.quiet_hours_end
      and (
        local_send_time::time >= preference.quiet_hours_start
        or local_send_time::time < preference.quiet_hours_end
      )
    ) then
      raise exception 'outbound release falls within recipient quiet hours';
    end if;
  end if;

  if found and preference.max_messages_per_day is not null then
    select count(*)
      into sent_today
    from public.whatsapp_case_outbound_decisions decision
    join public.whatsapp_case_recipient_authorizations authz
      on authz.id = decision.recipient_authorization_id
    where authz.identity_id = recipient_identity
      and decision.status = 'RELEASED'
      and decision.id <> new.id
      and decision.released_at >= date_trunc('day', statement_timestamp());
    if sent_today >= preference.max_messages_per_day then
      raise exception 'recipient daily communication frequency limit reached';
    end if;
  end if;

  return new;
end;
$$;

create trigger whatsapp_case_outbound_lifecycle_guard
  before insert or update on public.whatsapp_case_outbound_decisions
  for each row execute function public.guard_whatsapp_lifecycle_outbound();

create or replace function public.guard_whatsapp_case_closure()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if exists (
    select 1 from public.whatsapp_case_clarifications
    where case_id = new.case_id and status = 'OPEN'
  ) then
    raise exception 'case cannot close with open clarification';
  end if;
  if exists (
    select 1 from public.whatsapp_case_department_tasks
    where case_id = new.case_id and status in ('OPEN', 'IN_PROGRESS', 'BLOCKED')
  ) then
    raise exception 'case cannot close with open departmental work';
  end if;
  if exists (
    select 1 from public.whatsapp_case_escalations
    where case_id = new.case_id and resolved_at is null
  ) then
    raise exception 'case cannot close with unresolved escalation';
  end if;
  return new;
end;
$$;

create trigger whatsapp_case_closures_guard
  before insert on public.whatsapp_case_closures
  for each row execute function public.guard_whatsapp_case_closure();

create or replace function public.prevent_whatsapp_lifecycle_evidence_mutation()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  raise exception 'WhatsApp lifecycle evidence is append-only';
end;
$$;

create trigger whatsapp_communication_preferences_no_mutation
  before update or delete on public.whatsapp_communication_preferences
  for each row execute function public.prevent_whatsapp_lifecycle_evidence_mutation();
create trigger whatsapp_case_milestone_events_no_mutation
  before update or delete on public.whatsapp_case_milestone_events
  for each row execute function public.prevent_whatsapp_lifecycle_evidence_mutation();
create trigger whatsapp_case_closures_no_mutation
  before update or delete on public.whatsapp_case_closures
  for each row execute function public.prevent_whatsapp_lifecycle_evidence_mutation();

alter table public.whatsapp_communication_preferences enable row level security;
alter table public.whatsapp_case_milestone_events enable row level security;
alter table public.whatsapp_case_closures enable row level security;

do $$
declare relation_name text;
begin
  foreach relation_name in array array[
    'whatsapp_communication_preferences',
    'whatsapp_case_milestone_events',
    'whatsapp_case_closures'
  ] loop
    execute format(
      'create policy %I on public.%I for all to service_role using (true) with check (true)',
      relation_name || '_service_role', relation_name
    );
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_whatsapp_inbox_reader(auth.uid()))',
      relation_name || '_reader', relation_name
    );
  end loop;
end;
$$;

revoke all on function public.guard_whatsapp_lifecycle_outbound() from public;
revoke all on function public.guard_whatsapp_case_closure() from public;
revoke all on function public.prevent_whatsapp_lifecycle_evidence_mutation() from public;

commit;
