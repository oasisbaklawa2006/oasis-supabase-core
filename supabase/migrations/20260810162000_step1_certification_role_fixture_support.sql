-- Step 1 certification support: preserve canonical RBAC while allowing the
-- staging harness to materialize legacy public.users roles into user_role_map.
--
-- This migration does not grant any new role, permission, or RPC authority.
-- It only provides a narrowly scoped helper that can map an already-created
-- staging certification user to an already-existing active role. Execution is
-- service_role only; authenticated/anon/public cannot call it.

create or replace function public.step1_certification_map_existing_role_v1(
  p_user_id uuid,
  p_role_key text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role_id uuid;
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;

  select r.id
    into v_role_id
  from public.roles r
  where upper(r.role_key) = upper(btrim(p_role_key))
    and coalesce(r.is_active, true)
  order by r.id
  limit 1;

  if v_role_id is null then
    return false;
  end if;

  insert into public.user_role_map(user_id, role_id)
  values (p_user_id, v_role_id)
  on conflict do nothing;

  return true;
end;
$$;

revoke all on function public.step1_certification_map_existing_role_v1(uuid,text)
  from public, anon, authenticated;
grant execute on function public.step1_certification_map_existing_role_v1(uuid,text)
  to service_role;

comment on function public.step1_certification_map_existing_role_v1(uuid,text) is
  'Staging certification fixture helper: maps an existing user to an existing active role without creating or broadening authority.';
