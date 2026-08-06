-- Sensitive evidence, manual B2C/D2C queues, payment proof, and official-channel migration.

begin;

create table public.whatsapp_case_manual_assignments (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  customer_segment text not null check (customer_segment in ('B2C', 'D2C', 'UNRESOLVED')),
  reason text not null,
  assigned_sales_user_id uuid not null,
  status text not null default 'ASSIGNED'
    check (status in ('ASSIGNED', 'ACCEPTED', 'CONTACTED', 'RESOLVED', 'ESCALATED')),
  due_at timestamptz not null,
  accepted_at timestamptz,
  contacted_at timestamptz,
  resolved_at timestamptz,
  escalation_id uuid references public.whatsapp_case_escalations(id) on delete restrict,
  correlation_key text not null,
  created_by uuid not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_manual_assignments_correlation_unique unique (case_id, correlation_key),
  constraint whatsapp_case_manual_assignments_progress check (
    (status = 'ASSIGNED' and accepted_at is null and contacted_at is null and resolved_at is null)
    or (status = 'ACCEPTED' and accepted_at is not null and contacted_at is null and resolved_at is null)
    or (status = 'CONTACTED' and accepted_at is not null and contacted_at is not null and resolved_at is null)
    or (status = 'RESOLVED' and accepted_at is not null and contacted_at is not null and resolved_at is not null)
    or (status = 'ESCALATED' and escalation_id is not null)
  )
);

create table public.whatsapp_case_restricted_evidence (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  source_message_id uuid,
  evidence_type text not null
    check (evidence_type in ('HARMFUL_CONTENT', 'PAYMENT_PROOF', 'IDENTITY_DOCUMENT', 'FINANCIAL_DATA', 'OTHER')),
  storage_reference text not null,
  content_hash text not null,
  public_mask text not null,
  quarantine_status text not null default 'QUARANTINED'
    check (quarantine_status in ('QUARANTINED', 'REVIEWED', 'RELEASED', 'RETAINED', 'LEGAL_HOLD')),
  access_class text not null check (access_class in ('RESTRICTED', 'FINANCE_ONLY', 'SECURITY_ONLY', 'LEGAL_ONLY')),
  detected_by text not null check (detected_by in ('RULE', 'AI', 'OPERATOR', 'PROVIDER')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  release_reason text,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_restricted_evidence_hash_unique unique (case_id, content_hash),
  constraint whatsapp_case_restricted_evidence_correlation_unique unique (case_id, correlation_key),
  constraint whatsapp_case_restricted_evidence_review_shape check (
    (
      quarantine_status = 'QUARANTINED'
      and reviewed_by is null and reviewed_at is null and release_reason is null
    )
    or (
      quarantine_status in ('REVIEWED', 'RETAINED', 'LEGAL_HOLD')
      and reviewed_by is not null and reviewed_at is not null
      and release_reason is null
    )
    or (
      quarantine_status = 'RELEASED'
      and reviewed_by is not null and reviewed_at is not null
      and length(btrim(release_reason)) > 0
    )
  )
);

create table public.whatsapp_case_payment_proofs (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  restricted_evidence_id uuid not null
    references public.whatsapp_case_restricted_evidence(id) on delete restrict,
  claimed_amount numeric(14,2),
  claimed_reference text,
  receipt_status text not null default 'RECEIVED'
    check (receipt_status in ('RECEIVED', 'UNDER_REVIEW', 'VERIFIED', 'REJECTED', 'DUPLICATE')),
  received_at timestamptz not null,
  verified_amount numeric(14,2),
  verified_reference text,
  verified_by uuid,
  verified_at timestamptz,
  rejection_reason text,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_payment_proofs_correlation_unique unique (case_id, correlation_key),
  constraint whatsapp_case_payment_proofs_verification_shape check (
    (
      receipt_status = 'VERIFIED'
      and verified_amount is not null and verified_reference is not null
      and verified_by is not null and verified_at is not null
    )
    or (
      receipt_status = 'REJECTED' and length(btrim(rejection_reason)) > 0
      and verified_by is not null and verified_at is not null
    )
    or (
      receipt_status in ('RECEIVED', 'UNDER_REVIEW', 'DUPLICATE')
      and verified_amount is null and verified_reference is null
      and verified_by is null and verified_at is null
    )
  )
);

create table public.whatsapp_case_channel_migrations (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  from_phone_e164 text not null,
  official_phone_e164 text not null,
  status text not null default 'PROPOSED'
    check (status in ('PROPOSED', 'INVITED', 'CUSTOMER_ACKNOWLEDGED', 'MIGRATED', 'DECLINED')),
  invitation_outbound_decision_id uuid
    references public.whatsapp_case_outbound_decisions(id) on delete restrict,
  customer_ack_message_id uuid,
  migrated_at timestamptz,
  recorded_by uuid not null,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_channel_migrations_correlation_unique unique (case_id, correlation_key),
  constraint whatsapp_case_channel_migrations_completion_shape check (
    (status = 'MIGRATED' and customer_ack_message_id is not null and migrated_at is not null)
    or (
      status = 'CUSTOMER_ACKNOWLEDGED'
      and customer_ack_message_id is not null and migrated_at is null
    )
    or (
      status in ('PROPOSED', 'INVITED', 'DECLINED')
      and migrated_at is null
    )
  )
);

create index whatsapp_case_manual_assignments_queue_idx
  on public.whatsapp_case_manual_assignments (status, due_at, assigned_sales_user_id);
create index whatsapp_case_payment_proofs_queue_idx
  on public.whatsapp_case_payment_proofs (receipt_status, received_at);

create or replace function public.guard_whatsapp_payment_proof()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.receipt_status in ('RECEIVED', 'UNDER_REVIEW', 'DUPLICATE') and (
    new.verified_amount is not null or new.verified_reference is not null
    or new.verified_by is not null or new.verified_at is not null
  ) then
    raise exception 'payment proof receipt is not finance verification';
  end if;
  return new;
end;
$$;

create trigger whatsapp_case_payment_proofs_guard
  before insert or update on public.whatsapp_case_payment_proofs
  for each row execute function public.guard_whatsapp_payment_proof();

create or replace function public.prevent_whatsapp_sensitive_evidence_delete()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  raise exception 'restricted WhatsApp evidence cannot be deleted';
end;
$$;

create trigger whatsapp_case_restricted_evidence_no_delete
  before delete on public.whatsapp_case_restricted_evidence
  for each row execute function public.prevent_whatsapp_sensitive_evidence_delete();

create trigger whatsapp_case_payment_proofs_no_delete
  before delete on public.whatsapp_case_payment_proofs
  for each row execute function public.prevent_whatsapp_sensitive_evidence_delete();

alter table public.whatsapp_case_manual_assignments enable row level security;
alter table public.whatsapp_case_restricted_evidence enable row level security;
alter table public.whatsapp_case_payment_proofs enable row level security;
alter table public.whatsapp_case_channel_migrations enable row level security;

create policy whatsapp_case_manual_assignments_service_role
  on public.whatsapp_case_manual_assignments for all to service_role using (true) with check (true);
create policy whatsapp_case_manual_assignments_reader
  on public.whatsapp_case_manual_assignments for select to authenticated
  using (public.is_whatsapp_inbox_reader(auth.uid()));
create policy whatsapp_case_channel_migrations_service_role
  on public.whatsapp_case_channel_migrations for all to service_role using (true) with check (true);
create policy whatsapp_case_channel_migrations_reader
  on public.whatsapp_case_channel_migrations for select to authenticated
  using (public.is_whatsapp_inbox_reader(auth.uid()));
create policy whatsapp_case_restricted_evidence_service_role
  on public.whatsapp_case_restricted_evidence for all to service_role using (true) with check (true);
create policy whatsapp_case_payment_proofs_service_role
  on public.whatsapp_case_payment_proofs for all to service_role using (true) with check (true);

revoke all on function public.guard_whatsapp_payment_proof() from public;
revoke all on function public.prevent_whatsapp_sensitive_evidence_delete() from public;

commit;
