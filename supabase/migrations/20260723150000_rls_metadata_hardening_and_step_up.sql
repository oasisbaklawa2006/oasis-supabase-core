-- Supabase advisor remediation + App-Verse Point 19
-- 1. Remove RLS authorization based on editable auth.user_metadata.
-- 2. Restore explicit function EXECUTE grants after function replacement drift.
-- 3. Require AAL2 for permissions marked as requiring step-up authentication.
-- Point 25 reconciliation: legacy-table remediations are conditional because
-- those tables pre-dated the Core migration chain in production.

begin;

-- Replace insecure user_metadata policies only where the legacy tables exist.
do $$
begin
  if to_regclass('public.orders') is not null then
    execute 'drop policy if exists operations_view_in_production_orders on public.orders';
    execute $policy$
      create policy operations_view_in_production_orders
      on public.orders for select to authenticated
      using (
        upper(public.get_user_role(auth.uid())) = any (
          array['SUPER_ADMIN','ADMIN','OWNER','OPERATIONS_MANAGER','OPERATIONS_EXEC',
                'PRODUCTION_MANAGER','ASSEMBLY_MANAGER','PACKING_SUPERVISOR',
                'DISPATCH_HEAD','DISPATCH_MANAGER']
        )
        and status = any (array['in_production','dispatched','delivered'])
      )
    $policy$;
  end if;

  if to_regclass('public.whatsapp_messages') is not null
     and to_regclass('public.orders') is not null then
    execute 'drop policy if exists whatsapp_messages_finance_ops on public.whatsapp_messages';
    execute $policy$
      create policy whatsapp_messages_finance_ops
      on public.whatsapp_messages for select to authenticated
      using (
        exists (
          select 1 from public.orders o
          where o.id = whatsapp_messages.order_id
            and upper(public.get_user_role(auth.uid())) = any (
              array['FINANCE_HEAD','FINANCE_EXEC','OPERATIONS_MANAGER','OPERATIONS_EXEC',
                    'PRODUCTION_MANAGER','ASSEMBLY_MANAGER','DISPATCH_HEAD',
                    'DISPATCH_MANAGER','SUPER_ADMIN','ADMIN','OWNER']
            )
        )
      )
    $policy$;
  end if;
end
$$;

alter table public.access_permissions
  add column if not exists requires_step_up boolean not null default false;

update public.access_permissions
set requires_step_up = true,
    updated_at = now()
where permission_key = 'rbac.manage';

create or replace function public.has_step_up_auth()
returns boolean
language sql
stable
security invoker
set search_path = public, auth
as $$
  select auth.role() = 'service_role'
      or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;

create or replace function public.has_active_company_membership(
  p_user_id uuid,
  p_company_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    (p_user_id = auth.uid() or auth.role() = 'service_role')
    and exists (
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
set search_path = public, auth
as $$
  with permission_config as (
    select p.requires_step_up
    from public.access_permissions p
    where p.permission_key = p_permission_key
      and p.is_active
  ),
  global_roles as (
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
    where g.permission_key = p_permission_key
  )
  select case
    when not (p_user_id = auth.uid() or auth.role() = 'service_role') then false
    when not exists (select 1 from permission_config) then false
    when coalesce((select requires_step_up from permission_config), false)
      and not public.has_step_up_auth() then false
    when exists (select 1 from decisions where effect = 'deny') then false
    when exists (select 1 from global_roles where role_key = 'super_admin') then true
    else exists (select 1 from decisions where effect = 'allow')
  end;
$$;

comment on function public.has_step_up_auth() is
  'Returns true for Supabase AAL2 sessions or service-role execution.';
comment on column public.access_permissions.requires_step_up is
  'When true, has_app_permission requires an AAL2 Supabase Auth session.';

revoke all on function public.has_step_up_auth() from public, anon, authenticated;
grant execute on function public.has_step_up_auth() to authenticated, service_role;

revoke all on function public.has_active_company_membership(uuid, uuid) from public, anon, authenticated;
grant execute on function public.has_active_company_membership(uuid, uuid) to authenticated, service_role;

revoke all on function public.has_app_permission(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.has_app_permission(uuid, text, uuid, uuid) to authenticated, service_role;

-- Harden legacy helpers only when they are present in the replay target.
do $$
begin
  if to_regprocedure('public.is_staff_role(text)') is not null then
    execute 'alter function public.is_staff_role(text) set search_path = public';
  end if;
  if to_regprocedure('public.touch_updated_at()') is not null then
    execute 'alter function public.touch_updated_at() set search_path = public';
  end if;
  if to_regprocedure('public.ols_set_updated_at()') is not null then
    execute 'alter function public.ols_set_updated_at() set search_path = public';
  end if;
end
$$;

commit;
