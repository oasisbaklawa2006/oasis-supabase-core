-- Formal, attributable clarification for canonical WhatsApp communication cases.
-- A generic question or an unscoped "yes" can never release commercial work.

begin;

create table public.whatsapp_case_recipient_authorizations (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  identity_id uuid not null references public.whatsapp_case_identities(id) on delete restrict,
  disclosure_scope text[] not null default '{}',
  may_receive_clarification boolean not null default false,
  may_confirm_commercial_scope boolean not null default false,
  verification_method text not null
    check (verification_method in ('CRM_MATCH', 'GST_MATCH', 'CALLBACK', 'OPERATOR_VERIFIED', 'CUSTOMER_NOMINATED')),
  verified_by uuid not null,
  verified_at timestamptz not null,
  revoked_by uuid,
  revoked_at timestamptz,
  revocation_reason text,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_recipient_authorizations_unique
    unique (case_id, identity_id, correlation_key),
  constraint whatsapp_case_recipient_authorizations_revocation_shape check (
    (revoked_by is null and revoked_at is null and revocation_reason is null)
    or (
      revoked_by is not null
      and revoked_at is not null
      and length(btrim(revocation_reason)) > 0
    )
  )
);

create table public.whatsapp_case_clarifications (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  requested_line_id uuid references public.whatsapp_case_requested_lines(id) on delete restrict,
  interpretation_id uuid references public.whatsapp_case_interpretations(id) on delete restrict,
  field_name text not null,
  unresolved_value jsonb,
  question text not null check (length(btrim(question)) >= 8),
  recipient_authorization_id uuid not null
    references public.whatsapp_case_recipient_authorizations(id) on delete restrict,
  status text not null default 'OPEN'
    check (status in ('OPEN', 'ANSWERED', 'CANCELLED', 'EXPIRED', 'SUPERSEDED')),
  due_at timestamptz not null,
  follow_up_count integer not null default 0 check (follow_up_count >= 0),
  next_follow_up_at timestamptz,
  asked_by uuid not null,
  asked_at timestamptz not null default statement_timestamp(),
  source_outbound_message_id uuid,
  answer_text text,
  answer_payload jsonb,
  answer_source_message_id uuid,
  answered_by_identity_id uuid references public.whatsapp_case_identities(id) on delete restrict,
  confirmed_by uuid,
  answered_at timestamptz,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_clarifications_open_field_unique
    unique nulls not distinct (case_id, requested_line_id, field_name, status),
  constraint whatsapp_case_clarifications_correlation_unique
    unique (case_id, correlation_key),
  constraint whatsapp_case_clarifications_targeted check (
    field_name <> 'UNSPECIFIED'
    and lower(btrim(question)) not in ('please clarify', 'kindly clarify', 'confirm', 'please confirm')
  ),
  constraint whatsapp_case_clarifications_answer_shape check (
    (
      status = 'ANSWERED'
      and answer_text is not null
      and length(btrim(answer_text)) > 0
      and answer_source_message_id is not null
      and answered_by_identity_id is not null
      and confirmed_by is not null
      and answered_at is not null
    )
    or (
      status <> 'ANSWERED'
      and answer_text is null
      and answer_source_message_id is null
      and answered_by_identity_id is null
      and confirmed_by is null
      and answered_at is null
    )
  ),
  constraint whatsapp_case_clarifications_no_ambiguous_affirmation check (
    status <> 'ANSWERED'
    or lower(btrim(answer_text)) not in ('yes', 'y', 'ok', 'okay', 'confirmed', 'haan', 'ha')
  )
);

create table public.whatsapp_case_clarification_followups (
  id uuid primary key default gen_random_uuid(),
  clarification_id uuid not null references public.whatsapp_case_clarifications(id) on delete restrict,
  sequence_number integer not null check (sequence_number > 0),
  action text not null check (action in ('REMINDER_SENT', 'OWNER_ESCALATED', 'RECIPIENT_CHANGED', 'EXPIRED')),
  recipient_authorization_id uuid references public.whatsapp_case_recipient_authorizations(id) on delete restrict,
  source_outbound_message_id uuid,
  performed_by uuid,
  performed_at timestamptz not null default statement_timestamp(),
  correlation_key text not null,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  constraint whatsapp_case_clarification_followups_sequence_unique
    unique (clarification_id, sequence_number),
  constraint whatsapp_case_clarification_followups_correlation_unique
    unique (clarification_id, correlation_key)
);

create index whatsapp_case_clarifications_queue_idx
  on public.whatsapp_case_clarifications (status, due_at, next_follow_up_at, case_id);

create or replace function public.guard_whatsapp_case_ready_for_draft()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.status = 'READY_FOR_DRAFT' and exists (
    select 1
    from public.whatsapp_case_clarifications clarification
    where clarification.case_id = new.id
      and clarification.status = 'OPEN'
  ) then
    raise exception 'case has unresolved formal clarifications';
  end if;

  if new.status = 'READY_FOR_DRAFT' and exists (
    select 1
    from public.whatsapp_case_interpretations interpretation
    join public.whatsapp_case_requested_lines requested
      on requested.id = interpretation.requested_line_id
    where requested.case_id = new.id
      and cardinality(interpretation.unresolved_fields) > 0
      and not exists (
        select 1
        from public.whatsapp_case_clarifications clarification
        where clarification.interpretation_id = interpretation.id
          and clarification.status = 'ANSWERED'
      )
  ) then
    raise exception 'case interpretation still contains unresolved fields';
  end if;

  return new;
end;
$$;

create trigger whatsapp_communication_cases_clarification_gate
  before update of status on public.whatsapp_communication_cases
  for each row execute function public.guard_whatsapp_case_ready_for_draft();

create or replace function public.prevent_whatsapp_clarification_followup_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'whatsapp_case_clarification_followups is append-only';
end;
$$;

create trigger whatsapp_case_clarification_followups_no_update
  before update or delete on public.whatsapp_case_clarification_followups
  for each row execute function public.prevent_whatsapp_clarification_followup_mutation();

alter table public.whatsapp_case_recipient_authorizations enable row level security;
alter table public.whatsapp_case_clarifications enable row level security;
alter table public.whatsapp_case_clarification_followups enable row level security;

do $$
declare
  relation_name text;
begin
  foreach relation_name in array array[
    'whatsapp_case_recipient_authorizations',
    'whatsapp_case_clarifications',
    'whatsapp_case_clarification_followups'
  ]
  loop
    execute format(
      'create policy %I on public.%I for all to service_role using (true) with check (true)',
      relation_name || '_service_role',
      relation_name
    );
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_whatsapp_inbox_reader(auth.uid()))',
      relation_name || '_reader',
      relation_name
    );
  end loop;
end;
$$;

revoke all on function public.guard_whatsapp_case_ready_for_draft() from public;
revoke all on function public.prevent_whatsapp_clarification_followup_mutation() from public;

comment on table public.whatsapp_case_clarifications is
  'Targeted unresolved-field questions with an authorised recipient, attributable answer, confirmer, and due follow-up.';
comment on function public.guard_whatsapp_case_ready_for_draft() is
  'Blocks Sales Order Draft readiness while formal clarification or unresolved interpretation fields remain.';

commit;
