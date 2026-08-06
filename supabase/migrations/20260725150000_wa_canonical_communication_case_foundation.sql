-- Canonical WhatsApp communication case foundation.
-- Separates customer requests, machine/operator interpretation, proposed changes,
-- and customer confirmation. Nothing here creates or mutates commercial truth.

begin;

create table public.whatsapp_communication_cases (
  id uuid primary key default gen_random_uuid(),
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  company_id uuid references public.companies(id) on delete restrict,
  sales_order_draft_id uuid references public.sales_order_drafts(id) on delete restrict,
  case_type text not null default 'UNCLASSIFIED'
    check (case_type in (
      'UNCLASSIFIED', 'ORDER', 'ORDER_CHANGE', 'CANCELLATION', 'ENQUIRY',
      'COMPLAINT', 'PAYMENT_ADVICE', 'ACCOUNT_QUERY', 'DISPATCH', 'SPECIFICATION'
    )),
  status text not null default 'OPEN'
    check (status in (
      'OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'AWAITING_CUSTOMER',
      'READY_FOR_DRAFT', 'DRAFTED', 'CLOSED', 'CANCELLED'
    )),
  accountable_team text,
  accountable_owner_id uuid,
  next_action text,
  next_action_due_at timestamptz,
  source_channel text not null default 'WHATSAPP',
  rule_version text not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  closed_at timestamptz,
  constraint whatsapp_communication_cases_packet_unique unique (packet_id),
  constraint whatsapp_communication_cases_owner_pair check (
    (accountable_owner_id is null and accountable_team is null)
    or accountable_team is not null
  ),
  constraint whatsapp_communication_cases_closed_state check (
    (status in ('CLOSED', 'CANCELLED') and closed_at is not null)
    or (status not in ('CLOSED', 'CANCELLED') and closed_at is null)
  )
);

create table public.whatsapp_case_identities (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  identity_role text not null
    check (identity_role in ('SUBMITTING_SENDER', 'ORIGINAL_COMMUNICATOR', 'COMMERCIAL_CUSTOMER')),
  party_type text not null
    check (party_type in ('EMPLOYEE', 'CUSTOMER', 'CONTACT', 'COMPANY', 'UNKNOWN')),
  party_id uuid,
  display_label text,
  phone_e164 text,
  resolution_status text not null default 'UNRESOLVED'
    check (resolution_status in ('UNRESOLVED', 'SUGGESTED', 'CONFIRMED', 'REJECTED')),
  confidence numeric(5,4) check (confidence between 0 and 1),
  resolved_by uuid,
  resolved_at timestamptz,
  evidence jsonb not null default '[]'::jsonb check (jsonb_typeof(evidence) = 'array'),
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_identities_role_unique unique (case_id, identity_role),
  constraint whatsapp_case_identities_resolution_pair check (
    (resolution_status = 'CONFIRMED' and resolved_by is not null and resolved_at is not null)
    or resolution_status <> 'CONFIRMED'
  )
);

create table public.whatsapp_case_requested_lines (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  line_number integer not null check (line_number > 0),
  source_message_ids uuid[] not null default '{}',
  verbatim_request text not null,
  product_text text,
  quantity_text text,
  unit_text text,
  packaging_text text,
  delivery_text text,
  correction_of_line_id uuid references public.whatsapp_case_requested_lines(id) on delete restrict,
  superseded_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_requested_lines_number_unique unique (case_id, line_number)
);

create table public.whatsapp_case_interpretations (
  id uuid primary key default gen_random_uuid(),
  requested_line_id uuid not null references public.whatsapp_case_requested_lines(id) on delete restrict,
  version integer not null check (version > 0),
  product_id uuid,
  quantity numeric check (quantity > 0),
  unit text,
  packaging text,
  required_date date,
  instructions text,
  unresolved_fields text[] not null default '{}',
  confidence numeric(5,4) not null check (confidence between 0 and 1),
  inference_source text not null check (inference_source in ('AI', 'RULE', 'OPERATOR')),
  model_or_rule_version text not null,
  evidence jsonb not null default '{}'::jsonb check (jsonb_typeof(evidence) = 'object'),
  created_by uuid,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_interpretations_version_unique unique (requested_line_id, version),
  constraint whatsapp_case_interpretations_unknown_quantity check (
    quantity is not null or 'quantity' = any(unresolved_fields)
  ),
  constraint whatsapp_case_interpretations_unknown_unit check (
    unit is not null or quantity is null or 'unit' = any(unresolved_fields)
  )
);

create table public.whatsapp_case_proposed_changes (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  interpretation_id uuid references public.whatsapp_case_interpretations(id) on delete restrict,
  change_type text not null
    check (change_type in (
      'PRODUCT_SUBSTITUTION', 'QUANTITY', 'UNIT', 'PACKAGING', 'PRICE',
      'DELIVERY_DATE', 'DELIVERY_LOCATION', 'OTHER'
    )),
  requested_value jsonb not null default 'null'::jsonb,
  proposed_value jsonb not null,
  reason text not null,
  authority_status text not null default 'REQUIRES_APPROVAL'
    check (authority_status in ('REQUIRES_APPROVAL', 'OPERATOR_APPROVED', 'CUSTOMER_APPROVED', 'REJECTED')),
  proposed_by uuid,
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_proposed_changes_decision_pair check (
    (authority_status in ('OPERATOR_APPROVED', 'CUSTOMER_APPROVED', 'REJECTED')
      and decided_by is not null and decided_at is not null)
    or authority_status = 'REQUIRES_APPROVAL'
  )
);

create table public.whatsapp_case_confirmations (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  version integer not null check (version > 0),
  confirmation_scope jsonb not null check (jsonb_typeof(confirmation_scope) = 'object'),
  status text not null default 'PENDING'
    check (status in ('PENDING', 'CONFIRMED', 'REJECTED', 'EXPIRED', 'SUPERSEDED')),
  recipient_identity_id uuid not null references public.whatsapp_case_identities(id) on delete restrict,
  source_message_id uuid,
  confirmed_at timestamptz,
  expires_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_confirmations_version_unique unique (case_id, version),
  constraint whatsapp_case_confirmations_confirmed_pair check (
    (status = 'CONFIRMED' and source_message_id is not null and confirmed_at is not null)
    or status <> 'CONFIRMED'
  )
);

create table public.whatsapp_case_events (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  event_type text not null,
  actor_id uuid,
  actor_type text not null check (actor_type in ('SYSTEM', 'OPERATOR', 'CUSTOMER', 'EMPLOYEE', 'PROVIDER')),
  correlation_key text not null,
  prior_state jsonb,
  resulting_state jsonb,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  occurred_at timestamptz not null default statement_timestamp(),
  recorded_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_events_correlation_unique unique (case_id, correlation_key)
);

create index whatsapp_communication_cases_work_queue_idx
  on public.whatsapp_communication_cases (status, next_action_due_at, created_at);
create index whatsapp_case_requested_lines_case_idx
  on public.whatsapp_case_requested_lines (case_id, line_number);
create index whatsapp_case_events_case_idx
  on public.whatsapp_case_events (case_id, occurred_at, id);

create or replace function public.prevent_whatsapp_case_event_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'whatsapp_case_events is append-only';
end;
$$;

create trigger whatsapp_case_events_no_update
  before update or delete on public.whatsapp_case_events
  for each row execute function public.prevent_whatsapp_case_event_mutation();

create or replace function public.touch_whatsapp_communication_case()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at := statement_timestamp();
  return new;
end;
$$;

create trigger whatsapp_communication_cases_touch
  before update on public.whatsapp_communication_cases
  for each row execute function public.touch_whatsapp_communication_case();

alter table public.whatsapp_communication_cases enable row level security;
alter table public.whatsapp_case_identities enable row level security;
alter table public.whatsapp_case_requested_lines enable row level security;
alter table public.whatsapp_case_interpretations enable row level security;
alter table public.whatsapp_case_proposed_changes enable row level security;
alter table public.whatsapp_case_confirmations enable row level security;
alter table public.whatsapp_case_events enable row level security;

do $$
declare
  relation_name text;
begin
  foreach relation_name in array array[
    'whatsapp_communication_cases',
    'whatsapp_case_identities',
    'whatsapp_case_requested_lines',
    'whatsapp_case_interpretations',
    'whatsapp_case_proposed_changes',
    'whatsapp_case_confirmations',
    'whatsapp_case_events'
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

revoke all on function public.prevent_whatsapp_case_event_mutation() from public;
revoke all on function public.touch_whatsapp_communication_case() from public;

comment on table public.whatsapp_communication_cases is
  'Canonical governed case for one reconstructed WhatsApp packet; never a live commercial order.';
comment on table public.whatsapp_case_requested_lines is
  'Immutable customer-request representation, separate from interpretation and Oasis-proposed changes.';
comment on table public.whatsapp_case_events is
  'Append-only, idempotent audit ledger for canonical communication-case lifecycle events.';

commit;
