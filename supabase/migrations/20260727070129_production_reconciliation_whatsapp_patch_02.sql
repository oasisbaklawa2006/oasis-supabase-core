-- Canonical SQL body attached to production-recorded version 20260727070129.
-- Original reviewed version: 20260725173000.
-- Canonical WhatsApp case accountability, departmental contribution, and escalation.
-- One team/owner remains accountable for the customer response while other teams
-- contribute through explicit, time-bound tasks.

begin;

alter table public.whatsapp_communication_cases
  add column accountability_status text not null default 'UNASSIGNED'
    check (accountability_status in ('UNASSIGNED', 'ASSIGNED', 'ESCALATED')),
  add column assigned_at timestamptz,
  add column assigned_by uuid,
  add column last_escalated_at timestamptz;

alter table public.whatsapp_communication_cases
  add constraint whatsapp_communication_cases_accountability_shape check (
    (
      accountability_status = 'UNASSIGNED'
      and accountable_team is null
      and accountable_owner_id is null
      and assigned_at is null
      and assigned_by is null
    )
    or (
      accountability_status in ('ASSIGNED', 'ESCALATED')
      and accountable_team is not null
      and accountable_owner_id is not null
      and assigned_at is not null
      and assigned_by is not null
      and next_action is not null
      and next_action_due_at is not null
    )
  );

create table public.whatsapp_case_department_tasks (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  department text not null,
  assigned_user_id uuid,
  task_type text not null,
  instructions text not null check (length(btrim(instructions)) > 0),
  status text not null default 'OPEN'
    check (status in ('OPEN', 'IN_PROGRESS', 'BLOCKED', 'COMPLETED', 'CANCELLED')),
  due_at timestamptz not null,
  response_payload jsonb,
  completed_by uuid,
  completed_at timestamptz,
  correlation_key text not null,
  created_by uuid not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_department_tasks_correlation_unique
    unique (case_id, correlation_key),
  constraint whatsapp_case_department_tasks_completion_shape check (
    (
      status = 'COMPLETED'
      and completed_by is not null
      and completed_at is not null
      and response_payload is not null
    )
    or (
      status <> 'COMPLETED'
      and completed_by is null
      and completed_at is null
    )
  )
);

create table public.whatsapp_case_handoffs (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  from_team text not null,
  from_owner_id uuid not null,
  to_team text not null,
  to_owner_id uuid not null,
  reason text not null check (length(btrim(reason)) > 0),
  open_work_snapshot jsonb not null check (jsonb_typeof(open_work_snapshot) = 'object'),
  accepted_by uuid not null,
  accepted_at timestamptz not null,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_handoffs_distinct_owner check (
    from_team <> to_team or from_owner_id <> to_owner_id
  ),
  constraint whatsapp_case_handoffs_correlation_unique
    unique (case_id, correlation_key)
);

create table public.whatsapp_case_escalations (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.whatsapp_communication_cases(id) on delete restrict,
  department_task_id uuid references public.whatsapp_case_department_tasks(id) on delete restrict,
  escalation_level integer not null check (escalation_level between 1 and 5),
  reason text not null check (length(btrim(reason)) > 0),
  escalated_to_team text not null,
  escalated_to_user_id uuid,
  due_at timestamptz not null,
  acknowledged_by uuid,
  acknowledged_at timestamptz,
  resolved_by uuid,
  resolved_at timestamptz,
  resolution text,
  correlation_key text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_case_escalations_correlation_unique
    unique (case_id, correlation_key),
  constraint whatsapp_case_escalations_ack_shape check (
    (acknowledged_by is null and acknowledged_at is null)
    or (acknowledged_by is not null and acknowledged_at is not null)
  ),
  constraint whatsapp_case_escalations_resolution_shape check (
    (resolved_by is null and resolved_at is null and resolution is null)
    or (
      resolved_by is not null
      and resolved_at is not null
      and length(btrim(resolution)) > 0
    )
  )
);

create index whatsapp_case_department_tasks_queue_idx
  on public.whatsapp_case_department_tasks (status, due_at, department, assigned_user_id);
create index whatsapp_case_escalations_queue_idx
  on public.whatsapp_case_escalations (resolved_at, due_at, escalation_level);
create index whatsapp_case_handoffs_case_idx
  on public.whatsapp_case_handoffs (case_id, accepted_at, id);

create or replace function public.prevent_whatsapp_case_handoff_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'whatsapp_case_handoffs is append-only';
end;
$$;

create trigger whatsapp_case_handoffs_no_update
  before update or delete on public.whatsapp_case_handoffs
  for each row execute function public.prevent_whatsapp_case_handoff_mutation();

create or replace function public.touch_whatsapp_case_department_task()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at := statement_timestamp();
  return new;
end;
$$;

create trigger whatsapp_case_department_tasks_touch
  before update on public.whatsapp_case_department_tasks
  for each row execute function public.touch_whatsapp_case_department_task();

alter table public.whatsapp_case_department_tasks enable row level security;
alter table public.whatsapp_case_handoffs enable row level security;
alter table public.whatsapp_case_escalations enable row level security;

do $$
declare
  relation_name text;
begin
  foreach relation_name in array array[
    'whatsapp_case_department_tasks',
    'whatsapp_case_handoffs',
    'whatsapp_case_escalations'
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

revoke all on function public.prevent_whatsapp_case_handoff_mutation() from public;
revoke all on function public.touch_whatsapp_case_department_task() from public;

comment on table public.whatsapp_case_department_tasks is
  'Time-bound departmental contributions; these tasks never replace the case accountable response owner.';
comment on table public.whatsapp_case_handoffs is
  'Append-only, accepted transfer of customer-response accountability with an open-work snapshot.';
comment on table public.whatsapp_case_escalations is
  'Auditable SLA and operational escalation evidence for canonical WhatsApp cases and contributor tasks.';

commit;
