-- Governed runtime knowledge publication for WhatsApp interpretation.
-- Product truth remains in products/product_aliases/catalogue_versions; this table
-- records an immutable, approved reference bundle used by a historical run.

begin;

create table public.whatsapp_intelligence_knowledge_snapshots (
  id uuid primary key default gen_random_uuid(),
  schema_version text not null check (length(btrim(schema_version)) > 0),
  lifecycle text not null default 'DRAFT' check (lifecycle in ('DRAFT','REVIEWED','APPROVED','PUBLISHED','ACTIVE','SUPERSEDED')),
  source_catalogue_version_ids uuid[] not null default '{}'::uuid[],
  knowledge jsonb not null,
  content_checksum text not null check (length(btrim(content_checksum)) = 64),
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  published_at timestamptz,
  activated_at timestamptz,
  superseded_at timestamptz,
  superseded_by uuid references public.whatsapp_intelligence_knowledge_snapshots(id) on delete restrict,
  constraint whatsapp_intelligence_snapshot_shape check (jsonb_typeof(knowledge) = 'object'),
  constraint whatsapp_intelligence_snapshot_review_shape check (
    (lifecycle in ('DRAFT') and reviewed_by is null and reviewed_at is null and approved_by is null and approved_at is null)
    or (lifecycle in ('REVIEWED','APPROVED','PUBLISHED','ACTIVE','SUPERSEDED') and reviewed_by is not null and reviewed_at is not null)
  ),
  constraint whatsapp_intelligence_snapshot_approval_shape check (
    lifecycle not in ('APPROVED','PUBLISHED','ACTIVE','SUPERSEDED')
    or (approved_by is not null and approved_at is not null)
  )
);

create unique index whatsapp_intelligence_snapshot_one_active
  on public.whatsapp_intelligence_knowledge_snapshots ((true)) where lifecycle = 'ACTIVE';
create index whatsapp_intelligence_snapshot_lifecycle_created
  on public.whatsapp_intelligence_knowledge_snapshots (lifecycle, created_at desc);

alter table public.whatsapp_packet_ai_interpretations
  add column if not exists knowledge_snapshot_id uuid references public.whatsapp_intelligence_knowledge_snapshots(id) on delete restrict,
  add column if not exists knowledge_snapshot_schema_version text,
  add column if not exists interpretation_schema_version text,
  add column if not exists prompt_policy_version text,
  add column if not exists resolver_policy_version text;

comment on column public.whatsapp_packet_ai_interpretations.knowledge_snapshot_id is
  'Exact approved intelligence publication consumed by this interpretation. Historical rows may be null.';
comment on column public.whatsapp_packet_ai_interpretations.knowledge_snapshot_schema_version is
  'Schema/version of the exact knowledge publication consumed by this interpretation. Historical rows may be null.';

alter table public.whatsapp_intelligence_knowledge_snapshots enable row level security;
revoke all on table public.whatsapp_intelligence_knowledge_snapshots from public, anon, authenticated;
grant select, insert, update on table public.whatsapp_intelligence_knowledge_snapshots to service_role;
revoke delete on table public.whatsapp_intelligence_knowledge_snapshots from service_role;

create or replace function public.whatsapp_active_intelligence_knowledge_snapshot()
returns public.whatsapp_intelligence_knowledge_snapshots
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select *
  from public.whatsapp_intelligence_knowledge_snapshots
  where lifecycle = 'ACTIVE'
  order by activated_at desc, id desc
  limit 1;
$$;

revoke all on function public.whatsapp_active_intelligence_knowledge_snapshot() from public, anon, authenticated;
grant execute on function public.whatsapp_active_intelligence_knowledge_snapshot() to service_role;

-- Publication contents are frozen once review starts.  Activation below is the
-- sole state transition that changes the runtime selector, and it takes the
-- active-row lock before superseding/activating in one transaction.
create or replace function public.whatsapp_guard_intelligence_snapshot_mutation()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if (new.lifecycle = 'ACTIVE' or old.lifecycle = 'ACTIVE')
     and current_setting('app.whatsapp_knowledge_activation', true) is distinct from 'on' then
    raise exception 'knowledge activation must use governed activation RPC' using errcode = '42501';
  end if;
  if old.lifecycle <> 'DRAFT' and (
    new.schema_version is distinct from old.schema_version
    or new.source_catalogue_version_ids is distinct from old.source_catalogue_version_ids
    or new.knowledge is distinct from old.knowledge
    or new.content_checksum is distinct from old.content_checksum
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  ) then
    raise exception 'approved intelligence publication content is immutable' using errcode = '55000';
  end if;
  return new;
end $$;

drop trigger if exists whatsapp_intelligence_snapshot_content_immutable
  on public.whatsapp_intelligence_knowledge_snapshots;
create trigger whatsapp_intelligence_snapshot_content_immutable
before update on public.whatsapp_intelligence_knowledge_snapshots
for each row execute function public.whatsapp_guard_intelligence_snapshot_mutation();

create or replace function public.whatsapp_activate_intelligence_knowledge_snapshot(
  p_snapshot_id uuid
)
returns public.whatsapp_intelligence_knowledge_snapshots
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_target public.whatsapp_intelligence_knowledge_snapshots%rowtype;
  v_previous public.whatsapp_intelligence_knowledge_snapshots%rowtype;
begin
  -- Serialize all activation attempts, including the no-active-row case.
  perform pg_advisory_xact_lock(hashtextextended('whatsapp_intelligence_knowledge_snapshot_activation', 0));
  select * into v_target from public.whatsapp_intelligence_knowledge_snapshots
  where id = p_snapshot_id for update;
  if not found then raise exception 'knowledge publication not found' using errcode = 'P0002'; end if;
  if v_target.lifecycle not in ('APPROVED','ACTIVE') then
    raise exception 'only approved knowledge can become active' using errcode = '55000';
  end if;
  if v_target.lifecycle = 'ACTIVE' then return v_target; end if;

  select * into v_previous from public.whatsapp_intelligence_knowledge_snapshots
  where lifecycle = 'ACTIVE' for update;
  perform set_config('app.whatsapp_knowledge_activation', 'on', true);
  if found then
    update public.whatsapp_intelligence_knowledge_snapshots
    set lifecycle = 'SUPERSEDED', superseded_at = statement_timestamp(), superseded_by = v_target.id
    where id = v_previous.id;
  end if;
  update public.whatsapp_intelligence_knowledge_snapshots
  set lifecycle = 'ACTIVE',
      published_at = coalesce(published_at, statement_timestamp()),
      activated_at = statement_timestamp(),
      superseded_at = null,
      superseded_by = null
  where id = v_target.id
  returning * into v_target;
  return v_target;
end $$;

revoke all on function public.whatsapp_guard_intelligence_snapshot_mutation() from public, anon, authenticated, service_role;
revoke all on function public.whatsapp_activate_intelligence_knowledge_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_activate_intelligence_knowledge_snapshot(uuid) to service_role;

comment on table public.whatsapp_intelligence_knowledge_snapshots is
  'Approved, immutable WhatsApp intelligence reference bundles. They reference canonical catalogue records and copy only the governed terminology/rules required to reproduce an interpretation; they are not a second product master.';
comment on function public.whatsapp_active_intelligence_knowledge_snapshot() is
  'Service-role-only runtime selector. A worker must persist the returned snapshot id/version with every advisory interpretation.';

commit;
