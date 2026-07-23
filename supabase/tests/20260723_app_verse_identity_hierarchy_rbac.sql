-- Contract assertions for 20260723143000_app_verse_identity_hierarchy_rbac.sql
-- Intended for a disposable/local database after migrations are applied.

begin;

select plan(1);

do $$
declare
  required_table text;
begin
  foreach required_table in array array[
    'identity_profiles',
    'org_companies',
    'org_branches',
    'org_contacts',
    'org_memberships',
    'org_membership_branch_scopes',
    'access_permissions',
    'role_permission_grants',
    'org_membership_roles'
  ] loop
    if to_regclass('public.' || required_table) is null then
      raise exception 'missing required table: public.%', required_table;
    end if;
  end loop;
end $$;

do $$
begin
  if to_regprocedure('public.has_active_company_membership(uuid,uuid)') is null then
    raise exception 'missing helper function has_active_company_membership(uuid,uuid)';
  end if;

  if to_regprocedure('public.has_app_permission(uuid,text,uuid,uuid)') is null then
    raise exception 'missing helper function has_app_permission(uuid,text,uuid,uuid)';
  end if;
end $$;

do $$
declare
  insecure_table text;
begin
  select c.relname
  into insecure_table
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = any(array[
      'identity_profiles',
      'org_companies',
      'org_branches',
      'org_contacts',
      'org_memberships',
      'org_membership_branch_scopes',
      'access_permissions',
      'role_permission_grants',
      'org_membership_roles'
    ])
    and not c.relrowsecurity
  limit 1;

  if insecure_table is not null then
    raise exception 'RLS is not enabled on public.%', insecure_table;
  end if;
end $$;

do $$
declare
  missing_permission text;
begin
  select required.permission_key
  into missing_permission
  from (values
    ('org.read'),
    ('org.manage'),
    ('rbac.read'),
    ('rbac.manage')
  ) as required(permission_key)
  left join public.access_permissions p
    on p.permission_key = required.permission_key
   and p.is_active
  where p.permission_key is null
  limit 1;

  if missing_permission is not null then
    raise exception 'missing active permission seed: %', missing_permission;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from public.role_permission_grants
    where role_key = 'super_admin'
      and permission_key = 'rbac.manage'
      and effect = 'allow'
  ) then
    raise exception 'super_admin rbac.manage grant missing';
  end if;
end $$;

select ok(true, 'App-Verse identity hierarchy and RBAC contract holds');
select * from finish();
rollback;
