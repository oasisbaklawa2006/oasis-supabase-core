-- Point 25 clean-replay repair: operational_events existed in production
-- before Core migration ownership. This additive baseline represents the
-- pre-Point-20 shape required by the canonical ledger migration.

create table if not exists public.operational_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  entity_type text not null,
  entity_id uuid not null,
  order_id uuid,
  customer_id uuid,
  queue_item_id uuid,
  actor_id uuid,
  actor_role text,
  actor_department text,
  visibility text not null default 'internal'
    check (visibility in ('internal', 'public_candidate', 'staff_only')),
  severity text not null default 'info'
    check (severity in ('info', 'warning', 'urgent', 'critical')),
  title text not null,
  message text,
  reason_code text,
  reason_text text,
  metadata jsonb not null default '{}'::jsonb,
  correlation_id text not null,
  idempotency_key text,
  created_at timestamptz not null default now()
);

create unique index if not exists idx_operational_events_idempotency_key
  on public.operational_events (idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_operational_events_correlation_id
  on public.operational_events (correlation_id);

create index if not exists idx_operational_events_entity_created
  on public.operational_events (entity_type, entity_id, created_at desc);

create index if not exists idx_operational_events_order_created
  on public.operational_events (order_id, created_at desc)
  where order_id is not null;

create index if not exists idx_operational_events_queue_item_created
  on public.operational_events (queue_item_id, created_at desc)
  where queue_item_id is not null;

create or replace function public.prevent_operational_event_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'operational_events are append-only (% on %)', tg_op, tg_table_name;
end;
$$;

revoke all on function public.prevent_operational_event_mutation() from public, anon, authenticated;

drop trigger if exists trg_operational_events_no_update on public.operational_events;
create trigger trg_operational_events_no_update
before update on public.operational_events
for each row execute function public.prevent_operational_event_mutation();

drop trigger if exists trg_operational_events_no_delete on public.operational_events;
create trigger trg_operational_events_no_delete
before delete on public.operational_events
for each row execute function public.prevent_operational_event_mutation();

alter table public.operational_events enable row level security;

comment on table public.operational_events is
  'Legacy append-only operational event baseline represented for deterministic Core migration replay.';
