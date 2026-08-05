-- Canonical SQL body attached to production-recorded version 20260727070140.
-- Original reviewed version: 20260725200000.
-- Governed outbound communication for canonical WhatsApp cases.
-- An acknowledgement is not a commercial confirmation, and no provider send may
-- occur without recipient authority, disclosure review, quality validation, and
-- an idempotent release decision.

begin;

create table public.whatsapp_case_outbound_decisions (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  recipient_authorization_id uuid not null
    references public.whatsapp_case_recipient_authorizations(id) on delete restrict,
  message_purpose text not null
    check (message_purpose in (
      'RECEIPT_ACKNOWLEDGEMENT',
      'CLARIFICATION',
      'CUSTOMER_CONFIRMATION_REQUEST',
      'OPERATIONAL_MILESTONE',
      'CASE_UPDATE',
      'CASE_CLOSURE'
    )),
  disclosure_scope text[] not null default '{}',
  message_body text not null check (length(btrim(message_body)) > 0),
  template_name text,
  template_language text,
  related_clarification_id uuid
    references public.whatsapp_case_clarifications(id) on delete restrict,
  related_confirmation_id uuid
    references public.whatsapp_case_confirmations(id) on delete restrict,
  status text not null default 'DRAFT'
    check (status in ('DRAFT', 'VALIDATED', 'RELEASED', 'REJECTED', 'CANCELLED')),
  idempotency_key text not null,
  rule_version text not null,
  created_by uuid not null,
  created_at timestamptz not null default statement_timestamp(),
  validated_at timestamptz,
  released_by uuid,
  released_at timestamptz,
  rejected_by uuid,
  rejected_at timestamptz,
  rejection_reason text,
  constraint whatsapp_case_outbound_decisions_idempotency_unique
    unique (case_id, idempotency_key),
  constraint whatsapp_case_outbound_decisions_purpose_link check (
    (message_purpose = 'CLARIFICATION' and related_clarification_id is not null)
    or (message_purpose <> 'CLARIFICATION' and related_clarification_id is null)
  ),
  constraint whatsapp_case_outbound_decisions_confirmation_link check (
    (
      message_purpose = 'CUSTOMER_CONFIRMATION_REQUEST'
      and related_confirmation_id is not null
    )
    or (
      message_purpose <> 'CUSTOMER_CONFIRMATION_REQUEST'
      and related_confirmation_id is null
    )
  ),
  constraint whatsapp_case_outbound_decisions_terminal_shape check (
    (
      status = 'RELEASED'
      and validated_at is not null
      and released_by is not null
      and released_at is not null
      and rejected_by is null
      and rejected_at is null
      and rejection_reason is null
    )
    or (
      status = 'REJECTED'
      and rejected_by is not null
      and rejected_at is not null
      and length(btrim(rejection_reason)) > 0
      and released_by is null
      and released_at is null
    )
    or status in ('DRAFT', 'VALIDATED', 'CANCELLED')
  )
);

create table public.whatsapp_case_reply_validations (
  id uuid primary key default gen_random_uuid(),
  outbound_decision_id uuid not null
    references public.whatsapp_case_outbound_decisions(id) on delete restrict,
  validation_version integer not null check (validation_version > 0),
  factual_consistency_status text not null
    check (factual_consistency_status in ('PASS', 'FAIL', 'REVIEW_REQUIRED')),
  recipient_authority_status text not null
    check (recipient_authority_status in ('PASS', 'FAIL')),
  disclosure_status text not null
    check (disclosure_status in ('PASS', 'FAIL')),
  ambiguity_status text not null
    check (ambiguity_status in ('PASS', 'FAIL', 'REVIEW_REQUIRED')),
  commercial_commitment_status text not null
    check (commercial_commitment_status in ('NONE', 'AUTHORISED', 'UNAUTHORISED')),
  validator_type text not null
    check (validator_type in ('RULE', 'AI', 'OPERATOR')),
  validator_version text not null,
  findings jsonb not null default '[]'::jsonb check (jsonb_typeof(findings) = 'array'),
  validated_by uuid,
  validated_at timestamptz not null default statement_timestamp(),
  correlation_key text not null,
  constraint whatsapp_case_reply_validations_version_unique
    unique (outbound_decision_id, validation_version),
  constraint whatsapp_case_reply_validations_correlation_unique
    unique (outbound_decision_id, correlation_key)
);

create table public.whatsapp_case_outbound_attempts (
  id uuid primary key default gen_random_uuid(),
  outbound_decision_id uuid not null
    references public.whatsapp_case_outbound_decisions(id) on delete restrict,
  attempt_number integer not null check (attempt_number > 0),
  provider text not null,
  provider_message_id text,
  status text not null
    check (status in ('QUEUED', 'ACCEPTED', 'DELIVERED', 'READ', 'FAILED')),
  failure_code text,
  failure_detail text,
  attempted_at timestamptz not null default statement_timestamp(),
  status_at timestamptz not null default statement_timestamp(),
  idempotency_key text not null,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  constraint whatsapp_case_outbound_attempts_number_unique
    unique (outbound_decision_id, attempt_number),
  constraint whatsapp_case_outbound_attempts_failure_shape check (
    (status = 'FAILED' and failure_code is not null)
    or (status <> 'FAILED' and failure_code is null and failure_detail is null)
  )
);

create index whatsapp_case_outbound_decisions_release_queue_idx
  on public.whatsapp_case_outbound_decisions (status, created_at, case_id);
create index whatsapp_case_outbound_attempts_status_idx
  on public.whatsapp_case_outbound_attempts (status, status_at, outbound_decision_id);
create unique index whatsapp_case_outbound_attempts_provider_message_unique
  on public.whatsapp_case_outbound_attempts (provider, provider_message_id)
  where provider_message_id is not null;

create or replace function public.guard_whatsapp_outbound_decision()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  recipient_authorization public.whatsapp_case_recipient_authorizations%rowtype;
begin
  select *
    into recipient_authorization
  from public.whatsapp_case_recipient_authorizations
  where id = new.recipient_authorization_id
  for share;

  if recipient_authorization.case_id <> new.case_id then
    raise exception 'outbound recipient authorization belongs to another case';
  end if;

  if recipient_authorization.revoked_at is not null then
    raise exception 'outbound recipient authorization has been revoked';
  end if;

  if not new.disclosure_scope <@ recipient_authorization.disclosure_scope then
    raise exception 'outbound disclosure exceeds recipient authority';
  end if;

  if new.message_purpose = 'CLARIFICATION'
     and not recipient_authorization.may_receive_clarification then
    raise exception 'recipient is not authorised for clarification';
  end if;

  if new.message_purpose = 'CUSTOMER_CONFIRMATION_REQUEST'
     and not recipient_authorization.may_confirm_commercial_scope then
    raise exception 'recipient is not authorised for commercial confirmation';
  end if;

  if new.message_purpose = 'RECEIPT_ACKNOWLEDGEMENT'
     and new.related_confirmation_id is not null then
    raise exception 'receipt acknowledgement cannot confirm commercial scope';
  end if;

  if new.status = 'RELEASED' and not exists (
    select 1
    from public.whatsapp_case_reply_validations validation
    where validation.outbound_decision_id = new.id
      and validation.factual_consistency_status = 'PASS'
      and validation.recipient_authority_status = 'PASS'
      and validation.disclosure_status = 'PASS'
      and validation.ambiguity_status = 'PASS'
      and validation.commercial_commitment_status <> 'UNAUTHORISED'
  ) then
    raise exception 'outbound reply has not passed every release validation';
  end if;

  return new;
end;
$$;

create trigger whatsapp_case_outbound_decisions_guard
  before insert or update on public.whatsapp_case_outbound_decisions
  for each row execute function public.guard_whatsapp_outbound_decision();

create or replace function public.guard_whatsapp_outbound_attempt()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if not exists (
    select 1
    from public.whatsapp_case_outbound_decisions decision
    where decision.id = new.outbound_decision_id
      and decision.status = 'RELEASED'
      and new.idempotency_key =
        decision.idempotency_key || ':attempt:' || new.attempt_number::text
  ) then
    raise exception 'provider attempt requires a decision-scoped attempt idempotency key';
  end if;

  return new;
end;
$$;

create trigger whatsapp_case_outbound_attempts_guard
  before insert on public.whatsapp_case_outbound_attempts
  for each row execute function public.guard_whatsapp_outbound_attempt();

create or replace function public.prevent_whatsapp_reply_validation_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'whatsapp_case_reply_validations is append-only';
end;
$$;

create trigger whatsapp_case_reply_validations_no_update
  before update or delete on public.whatsapp_case_reply_validations
  for each row execute function public.prevent_whatsapp_reply_validation_mutation();

create or replace function public.prevent_whatsapp_outbound_attempt_delete()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'whatsapp_case_outbound_attempts cannot be deleted';
end;
$$;

create trigger whatsapp_case_outbound_attempts_no_delete
  before delete on public.whatsapp_case_outbound_attempts
  for each row execute function public.prevent_whatsapp_outbound_attempt_delete();

alter table public.whatsapp_case_outbound_decisions enable row level security;
alter table public.whatsapp_case_reply_validations enable row level security;
alter table public.whatsapp_case_outbound_attempts enable row level security;

do $$
declare
  relation_name text;
begin
  foreach relation_name in array array[
    'whatsapp_case_outbound_decisions',
    'whatsapp_case_reply_validations',
    'whatsapp_case_outbound_attempts'
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

revoke all on function public.guard_whatsapp_outbound_decision() from public;
revoke all on function public.guard_whatsapp_outbound_attempt() from public;
revoke all on function public.prevent_whatsapp_reply_validation_mutation() from public;
revoke all on function public.prevent_whatsapp_outbound_attempt_delete() from public;

comment on table public.whatsapp_case_outbound_decisions is
  'Governed outbound message decision; a receipt acknowledgement is explicitly distinct from customer confirmation.';
comment on table public.whatsapp_case_reply_validations is
  'Append-only factual, authority, disclosure, ambiguity, and commercial-commitment release evidence.';
comment on table public.whatsapp_case_outbound_attempts is
  'Idempotent provider attempts and delivery-status evidence for one released outbound decision.';

commit;
