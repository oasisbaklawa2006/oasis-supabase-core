-- Final WhatsApp reconciliation, replay, governed learning, and legacy retirement evidence.

begin;

create table public.whatsapp_replay_runs (
  id uuid primary key default gen_random_uuid(),
  run_type text not null check (run_type in ('GOLDEN_FIXTURE', 'HISTORICAL_SAMPLE', 'INCIDENT_REPLAY')),
  source_scope jsonb not null check (jsonb_typeof(source_scope) = 'object'),
  ruleset_version text not null,
  started_by uuid not null,
  started_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  status text not null default 'RUNNING'
    check (status in ('RUNNING', 'PASSED', 'FAILED', 'BLOCKED')),
  expected_case_count integer not null check (expected_case_count >= 0),
  actual_case_count integer check (actual_case_count is null or actual_case_count >= 0),
  commercial_writes_observed integer not null default 0
    check (commercial_writes_observed = 0),
  result_summary jsonb not null default '{}'::jsonb
    check (jsonb_typeof(result_summary) = 'object'),
  correlation_key text not null unique,
  constraint whatsapp_replay_runs_completion check (
    (status = 'RUNNING' and completed_at is null)
    or (status <> 'RUNNING' and completed_at is not null)
  )
);

create table public.whatsapp_replay_results (
  id uuid primary key default gen_random_uuid(),
  replay_run_id uuid not null references public.whatsapp_replay_runs(id) on delete restrict,
  fixture_key text not null,
  source_packet_id uuid references public.whatsapp_message_packets(id) on delete restrict,
  input_sha256 text not null check (input_sha256 ~ '^[0-9a-f]{64}$'),
  expected_outcome jsonb not null check (jsonb_typeof(expected_outcome) = 'object'),
  actual_outcome jsonb not null check (jsonb_typeof(actual_outcome) = 'object'),
  stitch_result text not null
    check (stitch_result in ('MATCHED', 'MISMATCH', 'NOT_APPLICABLE')),
  dedup_result text not null
    check (dedup_result in ('UNIQUE', 'RETRY_DUPLICATE', 'CROSS_FORWARD_DUPLICATE', 'AMBIGUOUS')),
  identity_result text not null
    check (identity_result in ('RESOLVED', 'UNRESOLVED', 'CONFLICT')),
  intent_result text not null
    check (intent_result in ('MATCHED', 'MISMATCH', 'UNRESOLVED')),
  quantity_result text not null
    check (quantity_result in ('RESOLVED', 'UNRESOLVED', 'NOT_APPLICABLE')),
  passed boolean not null,
  failure_reasons jsonb not null default '[]'::jsonb
    check (jsonb_typeof(failure_reasons) = 'array'),
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_replay_results_fixture_unique unique (replay_run_id, fixture_key)
);

create table public.whatsapp_reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  window_start timestamptz not null,
  window_end timestamptz not null,
  shift_code text not null,
  raw_message_count integer not null check (raw_message_count >= 0),
  packet_fragment_count integer not null check (packet_fragment_count >= 0),
  case_source_count integer not null check (case_source_count >= 0),
  orphan_message_count integer not null check (orphan_message_count >= 0),
  duplicate_count integer not null check (duplicate_count >= 0),
  unresolved_count integer not null check (unresolved_count >= 0),
  status text not null check (status in ('ALIGNED', 'EXCEPTIONS_OPEN', 'SIGNED_OFF')),
  reconciled_by uuid not null,
  reconciled_at timestamptz not null default statement_timestamp(),
  signed_off_by uuid,
  signed_off_at timestamptz,
  correlation_key text not null unique,
  constraint whatsapp_reconciliation_window check (window_end > window_start),
  constraint whatsapp_reconciliation_signoff check (
    (status = 'SIGNED_OFF' and signed_off_by is not null and signed_off_at is not null)
    or (status <> 'SIGNED_OFF' and signed_off_by is null and signed_off_at is null)
  ),
  constraint whatsapp_reconciliation_alignment check (
    status <> 'ALIGNED'
    or (orphan_message_count = 0 and unresolved_count = 0)
  )
);

create table public.whatsapp_reconciliation_exceptions (
  id uuid primary key default gen_random_uuid(),
  reconciliation_run_id uuid not null
    references public.whatsapp_reconciliation_runs(id) on delete restrict,
  exception_type text not null check (exception_type in (
    'ORPHAN_RAW_MESSAGE', 'UNLINKED_FRAGMENT', 'PACKET_WITHOUT_CASE',
    'DUPLICATE_CONFLICT', 'IDENTITY_CONFLICT', 'UNRESOLVED_INTENT',
    'OUTBOUND_WITHOUT_DECISION', 'OTHER'
  )),
  business_object_type text not null,
  business_object_id uuid,
  details jsonb not null check (jsonb_typeof(details) = 'object'),
  owner_id uuid not null,
  due_at timestamptz not null,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution text,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_reconciliation_exception_resolution check (
    (resolved_at is null and resolved_by is null and resolution is null)
    or (resolved_at is not null and resolved_by is not null and length(btrim(resolution)) >= 5)
  )
);

create table public.whatsapp_learning_candidates (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  source_message_id uuid,
  candidate_type text not null check (candidate_type in (
    'PRODUCT_ALIAS', 'CUSTOMER_ALIAS', 'INTENT_PATTERN', 'QUANTITY_PATTERN'
  )),
  observed_value text not null,
  proposed_mapping jsonb not null check (jsonb_typeof(proposed_mapping) = 'object'),
  evidence jsonb not null check (jsonb_typeof(evidence) = 'object'),
  inference_ruleset_version text not null,
  status text not null default 'PENDING_REVIEW'
    check (status in ('PENDING_REVIEW', 'APPROVED', 'REJECTED', 'SUPERSEDED')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_reason text,
  promoted_object_type text,
  promoted_object_id uuid,
  correlation_key text not null unique,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_learning_candidates_review check (
    (status = 'PENDING_REVIEW' and reviewed_by is null and reviewed_at is null)
    or (status <> 'PENDING_REVIEW' and reviewed_by is not null and reviewed_at is not null
      and length(btrim(review_reason)) >= 5)
  ),
  constraint whatsapp_learning_candidates_promotion check (
    (status = 'APPROVED' and promoted_object_type is not null and promoted_object_id is not null)
    or (status <> 'APPROVED' and promoted_object_type is null and promoted_object_id is null)
  )
);

create table public.whatsapp_legacy_capability_retirements (
  id uuid primary key default gen_random_uuid(),
  capability_key text not null,
  revision_number integer not null default 1 check (revision_number > 0),
  supersedes_retirement_id uuid unique
    references public.whatsapp_legacy_capability_retirements(id) on delete restrict,
  legacy_surface text not null,
  disposition text not null check (disposition in (
    'RETIRED', 'MIGRATED_READ_ONLY', 'MIGRATED_SUGGESTION_ONLY', 'RETAINED_INGRESS_ONLY'
  )),
  canonical_destination text not null,
  commercial_write_authority boolean not null check (commercial_write_authority = false),
  evidence jsonb not null check (jsonb_typeof(evidence) = 'object'),
  verified_by uuid not null,
  verified_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_legacy_capability_retirements_revision_unique
    unique (capability_key, revision_number),
  constraint whatsapp_legacy_capability_retirements_supersession_shape check (
    (revision_number = 1 and supersedes_retirement_id is null)
    or (revision_number > 1 and supersedes_retirement_id is not null)
  )
);

create index whatsapp_replay_results_run_idx
  on public.whatsapp_replay_results (replay_run_id, passed, fixture_key);
create index whatsapp_reconciliation_exceptions_open_idx
  on public.whatsapp_reconciliation_exceptions (reconciliation_run_id, due_at)
  where resolved_at is null;
create index whatsapp_learning_candidates_review_idx
  on public.whatsapp_learning_candidates (status, candidate_type, created_at);

create or replace function public.guard_whatsapp_reconciliation_signoff()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.status = 'SIGNED_OFF' and exists (
    select 1
    from public.whatsapp_reconciliation_exceptions candidate
    where candidate.reconciliation_run_id = new.id
      and candidate.resolved_at is null
  ) then
    raise exception 'shift reconciliation cannot be signed off with open exceptions';
  end if;
  return new;
end;
$$;

create trigger whatsapp_reconciliation_signoff_guard
  before update on public.whatsapp_reconciliation_runs
  for each row execute function public.guard_whatsapp_reconciliation_signoff();

create or replace function public.guard_whatsapp_reconciliation_exception()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  parent_status text;
begin
  select status
    into parent_status
    from public.whatsapp_reconciliation_runs
    where id = new.reconciliation_run_id
    for update;

  if parent_status = 'SIGNED_OFF' and new.resolved_at is null then
    raise exception 'open exception cannot be added to or reopened on a signed-off reconciliation';
  end if;
  return new;
end;
$$;

create trigger whatsapp_reconciliation_exception_guard
  before insert or update on public.whatsapp_reconciliation_exceptions
  for each row execute function public.guard_whatsapp_reconciliation_exception();

create or replace function public.prevent_whatsapp_final_evidence_delete()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'WhatsApp final reconciliation evidence cannot be deleted';
end;
$$;

create or replace function public.prevent_whatsapp_retirement_evidence_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'WhatsApp legacy retirement evidence is append-only';
end;
$$;

create trigger whatsapp_legacy_capability_retirements_no_update
  before update on public.whatsapp_legacy_capability_retirements
  for each row execute function public.prevent_whatsapp_retirement_evidence_update();

do $$
declare relation_name text;
begin
  foreach relation_name in array array[
    'whatsapp_replay_runs',
    'whatsapp_replay_results',
    'whatsapp_reconciliation_runs',
    'whatsapp_reconciliation_exceptions',
    'whatsapp_learning_candidates',
    'whatsapp_legacy_capability_retirements'
  ] loop
    execute format('alter table public.%I enable row level security', relation_name);
    execute format(
      'create policy %I on public.%I for all to service_role using (true) with check (true)',
      relation_name || '_service_role', relation_name
    );
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_whatsapp_inbox_reader(auth.uid()))',
      relation_name || '_reader', relation_name
    );
    execute format(
      'create trigger %I before delete on public.%I for each row execute function public.prevent_whatsapp_final_evidence_delete()',
      relation_name || '_no_delete', relation_name
    );
  end loop;
end;
$$;

revoke all on function public.guard_whatsapp_reconciliation_signoff() from public;
revoke all on function public.guard_whatsapp_reconciliation_exception() from public;
revoke all on function public.prevent_whatsapp_final_evidence_delete() from public;
revoke all on function public.prevent_whatsapp_retirement_evidence_update() from public;

commit;
