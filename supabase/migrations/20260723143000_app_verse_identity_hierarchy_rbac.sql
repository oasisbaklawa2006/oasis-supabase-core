-- App-Verse Points 16–18 runtime foundation
-- Additive migration: preserves existing public.roles, public.user_role_map,
-- and public.is_team_member(uuid) behavior.

begin;

create table if not exists public.identity_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  identity_class text not null default 'staff'
    check (identity_class in ('staff','customer','service','device')),
  status text not null default 'active'
    check (status in ('invited','pending_approval','active','suspended','disabled')),
  display_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.org_companies (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null,
  display_name text,
  external_ref text,
  status text not null default 'active'
    check (status in ('pending','active','suspended','closed')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists org_companies_external_ref_uidx
  on public.org_companies(external_ref)
  where external_ref is not null;

create table if not exists public.org_branches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.org_companies(id) on delete restrict,
  branch_code text,
  name text not null,
  branch_type text not null default 'operating'
    check (branch_type in ('registered','billing','shipping','operating','warehouse','outlet')),
  status text not null default 'active'
    check (status in ('pending','active','suspended','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists org_branches_company_code_uidx
  on public.org_branches(company_id, branch_code)
  where branch_code is not null;

create table if not exists public.org_contacts (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  full_name text not null,
  email text,
  phone text,
  status text not null default 'active'
    check (status in ('pending','active','suspended','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists org_contacts_email_uidx
  on public.org_contacts(lower(email))
  where email is not null;

create table if not exists public.org_memberships (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.org_companies(id) on delete restrict,
  contact_id uuid references public.org_contacts(id) on delete restrict,
  user_id uuid references auth.users(id) on delete restrict,
  status text not null default 'active'
    check (status in ('invited','pending_approval','active','suspended','ended')),
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (contact_id is not null or user_id is not null),
  check (valid_until is null or valid_until > valid_from)
);

create unique index if not exists org_memberships_company_user_uidx
  on public.org_memberships(company_id, user_id)
  where user_id is not null and status <> 'ended';

create unique index if not exists org_memberships_company_contact_uidx
  on public.org_memberships(company_id, contact_id)
  where contact_id is not null and status <> 'ended';

create table if not exists public.org_membership_branch_scopes (
  membership_id uuid not null references public.org_memberships(id) on delete cascade,
  branch_id uuid not null references public.org_branches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (membership_id, branch_id)
);

create table if not exists public.access_permissions (
  permission_key text primary key,
  description text not null,
  risk_level text not null default 'standard'
    check (risk_level in ('standard','sensitive','high_risk')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.role_permission_grants (
  role_key text not null,
  permission_key text not null references public.access_permissions(permission_key) on delete cascade,
  effect text not null default 'allow' check (effect in ('allow','deny')),
  created_at timestamptz not null default now(),
  primary key (role_key, permission_key)
);

create table if not exists public.org_membership_roles (
  membership_id uuid not null references public.org_memberships(id) on delete cascade,
  role_key text not null,
  created_at timestamptz not null default now(),
  primary key (membership_id, role_key)
);

create or replace function public.app_verse_set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.has_active_company_membership(
  p_user_id uuid,
  p_company_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.org_memberships m
    where m.user_id = p_user_id
      and m.company_id = p_company_id
      and m.status = 'active'
      and m.valid_from <= now()
      and (m.valid_until is null or m.valid_until > now())
  );
$$;

create or replace function public.has_app_permission(
  p_user_id uuid,
  p_permission_key text,
  p_company_id uuid default null,
  p_branch_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with global_roles as (
    select r.role_key
    from public.user_role_map urm
    join public.roles r on r.id = urm.role_id
    where urm.user_id = p_user_id
      and coalesce(r.is_active, true)
  ),
  scoped_roles as (
    select mr.role_key
    from public.org_memberships m
    join public.org_membership_roles mr on mr.membership_id = m.id
    where m.user_id = p_user_id
      and m.status = 'active'
      and m.valid_from <= now()
      and (m.valid_until is null or m.valid_until > now())
      and (p_company_id is null or m.company_id = p_company_id)
      and (
        p_branch_id is null
        or not exists (
          select 1 from public.org_membership_branch_scopes s0
          where s0.membership_id = m.id
        )
        or exists (
          select 1 from public.org_membership_branch_scopes s
          where s.membership_id = m.id and s.branch_id = p_branch_id
        )
      )
  ),
  all_roles as (
    select role_key from global_roles
    union
    select role_key from scoped_roles
  ),
  decisions as (
    select g.effect
    from all_roles ar
    join public.role_permission_grants g on g.role_key = ar.role_key
    join public.access_permissions p on p.permission_key = g.permission_key
    where g.permission_key = p_permission_key
      and p.is_active
  )
  select case
    when exists (select 1 from global_roles where role_key = 'super_admin') then true
    when exists (select 1 from decisions where effect = 'deny') then false
    else exists (select 1 from decisions where effect = 'allow')
  end;
$$;

revoke all on function public.has_active_company_membership(uuid, uuid) from public;
revoke all on function public.has_app_permission(uuid, text, uuid, uuid) from public;
grant execute on function public.has_active_company_membership(uuid, uuid) to authenticated;
grant execute on function public.has_app_permission(uuid, text, uuid, uuid) to authenticated;

insert into public.access_permissions(permission_key, description, risk_level)
values
  ('org.read', 'Read company, branch, contact and membership hierarchy', 'standard'),
  ('org.manage', 'Create or modify company hierarchy and memberships', 'sensitive'),
  ('rbac.read', 'Read roles, permissions and grants', 'standard'),
  ('rbac.manage', 'Create or modify role and permission grants', 'high_risk')
on conflict (permission_key) do update
set description = excluded.description,
    risk_level = excluded.risk_level,
    is_active = true,
    updated_at = now();

insert into public.role_permission_grants(role_key, permission_key, effect)
values
  ('super_admin', 'org.read', 'allow'),
  ('super_admin', 'org.manage', 'allow'),
  ('super_admin', 'rbac.read', 'allow'),
  ('super_admin', 'rbac.manage', 'allow'),
  ('admin', 'org.read', 'allow'),
  ('admin', 'org.manage', 'allow'),
  ('admin', 'rbac.read', 'allow'),
  ('owner', 'org.read', 'allow'),
  ('owner', 'org.manage', 'allow'),
  ('owner', 'rbac.read', 'allow'),
  ('sales', 'org.read', 'allow'),
  ('operations', 'org.read', 'allow')
on conflict (role_key, permission_key) do nothing;

-- updated_at triggers

do $$
declare
  t text;
begin
  foreach t in array array[
    'identity_profiles','org_companies','org_branches','org_contacts',
    'org_memberships','access_permissions'
  ] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.app_verse_set_updated_at()',
      'trg_' || t || '_updated_at', t
    );
  end loop;
end $$;

alter table public.identity_profiles enable row level security;
alter table public.org_companies enable row level security;
alter table public.org_branches enable row level security;
alter table public.org_contacts enable row level security;
alter table public.org_memberships enable row level security;
alter table public.org_membership_branch_scopes enable row level security;
alter table public.access_permissions enable row level security;
alter table public.role_permission_grants enable row level security;
alter table public.org_membership_roles enable row level security;

-- Identity profile: self-read plus privileged administration.
drop policy if exists identity_profiles_select on public.identity_profiles;
create policy identity_profiles_select on public.identity_profiles
for select to authenticated
using (
  user_id = auth.uid()
  or public.has_app_permission(auth.uid(), 'rbac.read', null, null)
);

drop policy if exists identity_profiles_manage on public.identity_profiles;
create policy identity_profiles_manage on public.identity_profiles
for all to authenticated
using (public.has_app_permission(auth.uid(), 'rbac.manage', null, null))
with check (public.has_app_permission(auth.uid(), 'rbac.manage', null, null));

-- Hierarchy read is membership-scoped or capability-scoped.
drop policy if exists org_companies_select on public.org_companies;
create policy org_companies_select on public.org_companies
for select to authenticated
using (
  public.has_active_company_membership(auth.uid(), id)
  or public.has_app_permission(auth.uid(), 'org.read', id, null)
);

drop policy if exists org_companies_manage on public.org_companies;
create policy org_companies_manage on public.org_companies
for all to authenticated
using (public.has_app_permission(auth.uid(), 'org.manage', id, null))
with check (public.has_app_permission(auth.uid(), 'org.manage', id, null));

drop policy if exists org_branches_select on public.org_branches;
create policy org_branches_select on public.org_branches
for select to authenticated
using (
  public.has_active_company_membership(auth.uid(), company_id)
  or public.has_app_permission(auth.uid(), 'org.read', company_id, id)
);

drop policy if exists org_branches_manage on public.org_branches;
create policy org_branches_manage on public.org_branches
for all to authenticated
using (public.has_app_permission(auth.uid(), 'org.manage', company_id, id))
with check (public.has_app_permission(auth.uid(), 'org.manage', company_id, id));

drop policy if exists org_contacts_select on public.org_contacts;
create policy org_contacts_select on public.org_contacts
for select to authenticated
using (
  auth_user_id = auth.uid()
  or exists (
    select 1 from public.org_memberships m
    where m.contact_id = org_contacts.id
      and public.has_active_company_membership(auth.uid(), m.company_id)
  )
  or public.has_app_permission(auth.uid(), 'org.read', null, null)
);

drop policy if exists org_contacts_manage on public.org_contacts;
create policy org_contacts_manage on public.org_contacts
for all to authenticated
using (public.has_app_permission(auth.uid(), 'org.manage', null, null))
with check (public.has_app_permission(auth.uid(), 'org.manage', null, null));

drop policy if exists org_memberships_select on public.org_memberships;
create policy org_memberships_select on public.org_memberships
for select to authenticated
using (
  user_id = auth.uid()
  or public.has_active_company_membership(auth.uid(), company_id)
  or public.has_app_permission(auth.uid(), 'org.read', company_id, null)
);

drop policy if exists org_memberships_manage on public.org_memberships;
create policy org_memberships_manage on public.org_memberships
for all to authenticated
using (public.has_app_permission(auth.uid(), 'org.manage', company_id, null))
with check (public.has_app_permission(auth.uid(), 'org.manage', company_id, null));

drop policy if exists org_membership_branch_scopes_select on public.org_membership_branch_scopes;
create policy org_membership_branch_scopes_select on public.org_membership_branch_scopes
for select to authenticated
using (
  exists (
    select 1
    from public.org_memberships m
    where m.id = org_membership_branch_scopes.membership_id
      and (
        m.user_id = auth.uid()
        or public.has_active_company_membership(auth.uid(), m.company_id)
        or public.has_app_permission(auth.uid(), 'org.read', m.company_id, org_membership_branch_scopes.branch_id)
      )
  )
);

drop policy if exists org_membership_branch_scopes_manage on public.org_membership_branch_scopes;
create policy org_membership_branch_scopes_manage on public.org_membership_branch_scopes
for all to authenticated
using (
  exists (
    select 1 from public.org_memberships m
    where m.id = org_membership_branch_scopes.membership_id
      and public.has_app_permission(auth.uid(), 'org.manage', m.company_id, org_membership_branch_scopes.branch_id)
  )
)
with check (
  exists (
    select 1 from public.org_memberships m
    where m.id = org_membership_branch_scopes.membership_id
      and public.has_app_permission(auth.uid(), 'org.manage', m.company_id, org_membership_branch_scopes.branch_id)
  )
);

drop policy if exists access_permissions_select on public.access_permissions;
create policy access_permissions_select on public.access_permissions
for select to authenticated
using (public.has_app_permission(auth.uid(), 'rbac.read', null, null));

drop policy if exists access_permissions_manage on public.access_permissions;
create policy access_permissions_manage on public.access_permissions
for all to authenticated
using (public.has_app_permission(auth.uid(), 'rbac.manage', null, null))
with check (public.has_app_permission(auth.uid(), 'rbac.manage', null, null));

drop policy if exists role_permission_grants_select on public.role_permission_grants;
create policy role_permission_grants_select on public.role_permission_grants
for select to authenticated
using (public.has_app_permission(auth.uid(), 'rbac.read', null, null));

drop policy if exists role_permission_grants_manage on public.role_permission_grants;
create policy role_permission_grants_manage on public.role_permission_grants
for all to authenticated
using (public.has_app_permission(auth.uid(), 'rbac.manage', null, null))
with check (public.has_app_permission(auth.uid(), 'rbac.manage', null, null));

drop policy if exists org_membership_roles_select on public.org_membership_roles;
create policy org_membership_roles_select on public.org_membership_roles
for select to authenticated
using (
  exists (
    select 1 from public.org_memberships m
    where m.id = org_membership_roles.membership_id
      and (
        m.user_id = auth.uid()
        or public.has_active_company_membership(auth.uid(), m.company_id)
        or public.has_app_permission(auth.uid(), 'rbac.read', m.company_id, null)
      )
  )
);

drop policy if exists org_membership_roles_manage on public.org_membership_roles;
create policy org_membership_roles_manage on public.org_membership_roles
for all to authenticated
using (
  exists (
    select 1 from public.org_memberships m
    where m.id = org_membership_roles.membership_id
      and public.has_app_permission(auth.uid(), 'rbac.manage', m.company_id, null)
  )
)
with check (
  exists (
    select 1 from public.org_memberships m
    where m.id = org_membership_roles.membership_id
      and public.has_app_permission(auth.uid(), 'rbac.manage', m.company_id, null)
  )
);

comment on function public.has_app_permission(uuid, text, uuid, uuid) is
  'Deny-overrides capability evaluation across existing global roles and new company-scoped membership roles.';

commit;
