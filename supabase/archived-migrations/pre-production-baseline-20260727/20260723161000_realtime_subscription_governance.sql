-- Point 23: realtime architecture and subscription governance

create table if not exists public.realtime_subscription_contracts (
  id uuid primary key default gen_random_uuid(),
  schema_name text not null default 'public',
  table_name text not null,
  owning_application text not null,
  consumer_applications text[] not null default '{}',
  enabled boolean not null default false,
  row_filter_required boolean not null default true,
  rls_required boolean not null default true,
  event_types text[] not null default array['INSERT','UPDATE','DELETE'],
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(schema_name, table_name)
);

alter table public.realtime_subscription_contracts enable row level security;

drop policy if exists "Internal staff read realtime contracts" on public.realtime_subscription_contracts;
create policy "Internal staff read realtime contracts"
on public.realtime_subscription_contracts for select to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists "Admins manage realtime contracts" on public.realtime_subscription_contracts;
create policy "Admins manage realtime contracts"
on public.realtime_subscription_contracts for all to authenticated
using (public.get_user_role(auth.uid()) in ('admin','super_admin'))
with check (public.get_user_role(auth.uid()) in ('admin','super_admin'));

insert into public.realtime_subscription_contracts
(schema_name, table_name, owning_application, consumer_applications, enabled, row_filter_required, rls_required, event_types, notes)
values
('public','whatsapp_inbound_messages','Central',array['Central','AI Studio'],true,true,true,array['INSERT','UPDATE'],'Operator inbox inbound message refresh'),
('public','whatsapp_operator_decisions','Central',array['Central','AI Studio'],true,true,true,array['INSERT','UPDATE'],'Operator decision refresh'),
('public','whatsapp_sales_order_drafts','Central',array['Central','AI Studio'],true,true,true,array['INSERT','UPDATE'],'Sales-order draft refresh')
on conflict (schema_name, table_name) do update set
  owning_application=excluded.owning_application,
  consumer_applications=excluded.consumer_applications,
  enabled=excluded.enabled,
  row_filter_required=excluded.row_filter_required,
  rls_required=excluded.rls_required,
  event_types=excluded.event_types,
  notes=excluded.notes,
  updated_at=now();

create or replace view public.realtime_contract_health
with (security_invoker=true)
as
select
  c.schema_name,
  c.table_name,
  c.owning_application,
  c.consumer_applications,
  c.enabled,
  c.row_filter_required,
  c.rls_required,
  exists (
    select 1 from pg_publication_tables p
    where p.pubname='supabase_realtime'
      and p.schemaname=c.schema_name
      and p.tablename=c.table_name
  ) as is_published,
  coalesce(cls.relrowsecurity,false) as rls_enabled,
  exists (
    select 1 from pg_policies pol
    where pol.schemaname=c.schema_name
      and pol.tablename=c.table_name
      and pol.cmd in ('SELECT','ALL')
  ) as has_read_policy,
  case
    when not c.enabled then 'disabled'
    when not exists (
      select 1 from pg_publication_tables p
      where p.pubname='supabase_realtime' and p.schemaname=c.schema_name and p.tablename=c.table_name
    ) then 'missing_publication'
    when c.rls_required and not coalesce(cls.relrowsecurity,false) then 'missing_rls'
    when c.rls_required and not exists (
      select 1 from pg_policies pol
      where pol.schemaname=c.schema_name and pol.tablename=c.table_name and pol.cmd in ('SELECT','ALL')
    ) then 'missing_read_policy'
    else 'healthy'
  end as health_status
from public.realtime_subscription_contracts c
left join pg_namespace ns on ns.nspname=c.schema_name
left join pg_class cls on cls.relnamespace=ns.oid and cls.relname=c.table_name and cls.relkind='r';

grant select on public.realtime_contract_health to authenticated, service_role;

comment on table public.realtime_subscription_contracts is 'Allow-listed authority for App-Verse Postgres Changes subscriptions.';
comment on view public.realtime_contract_health is 'Runtime verification of publication, RLS and read-policy readiness for governed realtime tables.';
