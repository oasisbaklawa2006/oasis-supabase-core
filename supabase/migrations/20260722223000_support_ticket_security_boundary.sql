-- Canonical support-ticket security boundary.
--
-- Goals:
--   * retain public.support_tickets as the active operational table
--   * freeze the unused public.tickets duplicate without deleting evidence
--   * add canonical company ownership
--   * preserve existing Central customer/admin workflows through strict RLS
--   * remove anonymous table access and dangerous broad privileges
--   * expose customer reads/submission through governed RPCs

create schema if not exists cleanup_archive;

create table if not exists cleanup_archive.support_ticket_orphan_snapshot_20260722
as
select st.*, now() as archived_at, null::text as archive_reason
from public.support_tickets st
where false;

insert into cleanup_archive.support_ticket_orphan_snapshot_20260722
select st.*, now(), 'Referenced order is no longer present; ticket retained in canonical table with recovered company ownership.'
from public.support_tickets st
where st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and not exists (
    select 1 from public.orders o where o.id = st.order_id::uuid
  )
  and not exists (
    select 1
    from cleanup_archive.support_ticket_orphan_snapshot_20260722 a
    where a.id = st.id
  );

alter table public.support_tickets
  add column if not exists company_id uuid,
  add column if not exists updated_at timestamptz not null default now();

update public.support_tickets st
set company_id = coalesce(
      st.company_id,
      case
        when st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (select o.company_id from public.orders o where o.id = st.order_id::uuid)
      end,
      (select p.company_id from public.profiles p where p.id = coalesce(st.user_id, st.created_by)),
      (select u.company_id from public.users u where u.id = coalesce(st.user_id, st.created_by))
    ),
    user_id = coalesce(st.user_id, st.created_by),
    created_by = coalesce(st.created_by, st.user_id),
    updated_at = coalesce(st.updated_at, st.created_at, now());

create index if not exists support_tickets_company_created_idx
  on public.support_tickets (company_id, created_at desc);

create index if not exists support_tickets_order_id_idx
  on public.support_tickets (order_id);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'support_tickets_company_id_fkey'
  ) then
    alter table public.support_tickets
      add constraint support_tickets_company_id_fkey
      foreign key (company_id) references public.companies(id) not valid;
  end if;
end $$;

alter table public.support_tickets validate constraint support_tickets_company_id_fkey;

-- Existing production rows are now resolvable. Future authenticated inserts are
-- forced through the context trigger below.
alter table public.support_tickets alter column company_id set not null;

create or replace function public.support_ticket_set_customer_context()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  actor_id uuid := auth.uid();
  actor_company_id uuid;
  actor_is_admin boolean := false;
begin
  new.updated_at := now();

  if tg_op = 'UPDATE' then
    return new;
  end if;

  if auth.role() = 'service_role' then
    return new;
  end if;

  if actor_id is null then
    raise exception 'authentication required';
  end if;

  select exists (
    select 1
    from public.users u
    where u.id = actor_id
      and u.role in ('admin', 'super_admin')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
  ) into actor_is_admin;

  if actor_is_admin then
    new.created_by := coalesce(new.created_by, actor_id);
    new.user_id := coalesce(new.user_id, actor_id);
    return new;
  end if;

  select candidate.company_id
  into actor_company_id
  from (
    select p.company_id, 1 as priority
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = actor_id
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false

    union all

    select u.company_id, 2 as priority
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = actor_id
      and u.company_id is not null
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  ) candidate
  order by candidate.priority
  limit 1;

  if actor_company_id is null then
    raise exception 'approved customer company required';
  end if;

  if new.order_id is null
     or new.order_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     or not exists (
       select 1 from public.orders o
       where o.id = new.order_id::uuid
         and o.company_id = actor_company_id
         and coalesce(o.is_waste, false) is false
         and coalesce(o.is_duplicate, false) is false
     ) then
    raise exception 'order is not available to the authenticated company';
  end if;

  new.company_id := actor_company_id;
  new.created_by := actor_id;
  new.user_id := actor_id;
  new.status := coalesce(nullif(btrim(new.status), ''), 'open');

  -- Customer inserts may not seed internal workflow or financial fields.
  new.resolution_notes := null;
  new.routed_to_department := null;
  new.assigned_employee_id := null;
  new.sla_first_response_at := null;
  new.sla_action_at := null;
  new.sla_resolved_at := null;
  new.sla_state := null;
  new.estimated_financial_loss := null;
  new.admin_rating_speed := null;
  new.admin_rating_quality := null;
  new.admin_rating_communication := null;
  new.rejection_reason_template := null;
  new.resolution_template_used := null;
  new.ai_rewritten_reply := null;
  new.escalated_to_hod := false;
  new.commission_blocked := false;

  return new;
end;
$$;

drop trigger if exists support_ticket_customer_context_trg on public.support_tickets;
create trigger support_ticket_customer_context_trg
before insert or update on public.support_tickets
for each row execute function public.support_ticket_set_customer_context();

alter table public.support_tickets enable row level security;
alter table public.tickets enable row level security;

-- Remove every accumulated permissive/duplicated policy before rebuilding a
-- small explicit policy set.
do $$
declare pol record;
begin
  for pol in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('support_tickets', 'tickets')
  loop
    execute format('drop policy if exists %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
  end loop;
end $$;

create policy support_tickets_admin_all
on public.support_tickets
for all
to authenticated
using (
  exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and u.role in ('admin', 'super_admin')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
  )
)
with check (
  exists (
    select 1 from public.users u
    where u.id = auth.uid()
      and u.role in ('admin', 'super_admin')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
  )
);

create policy support_tickets_customer_select
on public.support_tickets
for select
to authenticated
using (
  company_id in (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false

    union

    select u.company_id
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = auth.uid()
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  )
);

create policy support_tickets_customer_insert
on public.support_tickets
for insert
to authenticated
with check (
  created_by = auth.uid()
  and user_id = auth.uid()
  and company_id in (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false

    union

    select u.company_id
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = auth.uid()
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  )
);

-- Browser roles receive only the operations required by the strict RLS policy
-- set. Dangerous table-owner-like privileges are removed.
revoke all on table public.support_tickets from anon;
revoke all on table public.support_tickets from authenticated;
grant select, insert, update, delete on table public.support_tickets to authenticated;

-- The duplicate table is unused and frozen. No data is deleted.
revoke all on table public.tickets from anon;
revoke all on table public.tickets from authenticated;
comment on table public.tickets is
  'Deprecated duplicate support-ticket table. Frozen 2026-07-22; public.support_tickets is canonical pending a future physical retirement tranche.';

create or replace function public.customer_support_tickets_v1()
returns table (
  ticket_id uuid,
  order_id text,
  order_number text,
  issue_type text,
  description text,
  customer_status text,
  product_sku text,
  quantity_affected integer,
  created_at timestamptz,
  updated_at timestamptz,
  first_response_due timestamptz,
  resolution_due timestamptz,
  resolved_at timestamptz,
  customer_rating integer
)
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  with eligible_companies as (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false

    union

    select u.company_id
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = auth.uid()
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  )
  select
    st.id as ticket_id,
    st.order_id,
    o.order_number,
    st.issue_type,
    st.description,
    case
      when lower(coalesce(st.status, '')) in ('resolved', 'closed') then 'resolved'
      when lower(coalesce(st.status, '')) in ('rejected', 'cancelled') then 'closed'
      when st.sla_first_response_at is not null then 'in_progress'
      else 'open'
    end as customer_status,
    st.product_sku,
    st.qty_affected as quantity_affected,
    st.created_at,
    st.updated_at,
    st.sla_first_response_due as first_response_due,
    st.sla_resolution_due as resolution_due,
    st.sla_resolved_at as resolved_at,
    st.customer_rating
  from public.support_tickets st
  join eligible_companies ec on ec.company_id = st.company_id
  left join public.orders o
    on st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
   and o.id = st.order_id::uuid
  order by st.created_at desc, st.id;
$$;

create or replace function public.submit_customer_support_ticket_v1(
  p_order_id uuid,
  p_issue_type text,
  p_description text,
  p_product_sku text default null,
  p_quantity_affected integer default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  new_ticket_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;

  if nullif(btrim(p_issue_type), '') is null then
    raise exception 'issue type is required';
  end if;

  if nullif(btrim(p_description), '') is null or length(btrim(p_description)) < 10 then
    raise exception 'description must contain at least 10 characters';
  end if;

  if length(btrim(p_description)) > 4000 then
    raise exception 'description exceeds 4000 characters';
  end if;

  if p_quantity_affected is not null and p_quantity_affected <= 0 then
    raise exception 'quantity affected must be positive';
  end if;

  insert into public.support_tickets (
    order_id,
    issue_type,
    description,
    product_sku,
    qty_affected,
    status
  ) values (
    p_order_id::text,
    lower(replace(btrim(p_issue_type), ' ', '_')),
    btrim(p_description),
    nullif(btrim(p_product_sku), ''),
    p_quantity_affected,
    'open'
  )
  returning id into new_ticket_id;

  return new_ticket_id;
end;
$$;

comment on function public.customer_support_tickets_v1() is
  'Customer-safe support ticket projection scoped to the authenticated approved company.';
comment on function public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) is
  'Creates a support ticket only for an order owned by the authenticated approved company.';

revoke all on function public.customer_support_tickets_v1() from public, anon;
revoke all on function public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) from public, anon;
grant execute on function public.customer_support_tickets_v1() to authenticated, service_role;
grant execute on function public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) to authenticated, service_role;
