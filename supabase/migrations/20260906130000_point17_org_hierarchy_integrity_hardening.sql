-- POINT17-CORE: close cross-company branch integrity gaps in org hierarchy authority.
--
-- Census (20260906130000):
--   has_app_permission(uuid,text,uuid,uuid) — did not verify p_branch_id belongs to
--     p_company_id before granting scoped membership permissions when branch scopes
--     were empty (default-all-branches semantics).
--   org_membership_branch_scopes — FKs to memberships and branches did not prevent
--     pairing a membership with a branch from a different company.
--
-- Chronology: sequenced after Point36 (20260906100000). Point37 (20260906110000)
-- must merge to main before this migration in production ledger order.
-- Point18 dispatch/RBAC authority is untouched.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.has_app_permission(
  p_user_id uuid,
  p_permission_key text,
  p_company_id uuid DEFAULT NULL,
  p_branch_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  with permission_config as (
    select p.requires_step_up
    from public.access_permissions p
    where p.permission_key = p_permission_key and p.is_active
  ),
  global_roles as (
    select r.role_key from public.user_role_map urm
    join public.roles r on r.id = urm.role_id
    where urm.user_id = p_user_id and coalesce(r.is_active, true)
  ),
  scoped_roles as (
    select mr.role_key from public.org_memberships m
    join public.org_membership_roles mr on mr.membership_id = m.id
    where m.user_id = p_user_id and m.status = 'active'
      and m.valid_from <= now() and (m.valid_until is null or m.valid_until > now())
      and (p_company_id is null or m.company_id = p_company_id)
      and (
        p_branch_id is null
        or not exists (select 1 from public.org_membership_branch_scopes s0 where s0.membership_id = m.id)
        or exists (select 1 from public.org_membership_branch_scopes s where s.membership_id = m.id and s.branch_id = p_branch_id)
      )
  ),
  all_roles as (
    select role_key from global_roles union select role_key from scoped_roles
  ),
  decisions as (
    select g.effect from all_roles ar
    join public.role_permission_grants g on g.role_key = ar.role_key
    where g.permission_key = p_permission_key
  )
  select case
    when not (p_user_id = auth.uid() or auth.role() = 'service_role') then false
    when not exists (select 1 from permission_config) then false
    when p_company_id is not null
      and p_branch_id is not null
      and not exists (
        select 1
        from public.org_branches b
        where b.id = p_branch_id
          and b.company_id = p_company_id
      ) then false
    when coalesce((select requires_step_up from permission_config), false)
      and not public.has_step_up_auth() then false
    when exists (select 1 from decisions where effect = 'deny') then false
    when exists (select 1 from global_roles where role_key = 'super_admin') then true
    else exists (select 1 from decisions where effect = 'allow')
  end;
$$;

COMMENT ON FUNCTION public.has_app_permission(uuid, text, uuid, uuid) IS
  'Deny-overrides capability evaluation across existing global roles and new company-scoped membership roles. Fails closed when p_branch_id is not owned by p_company_id.';

CREATE OR REPLACE FUNCTION public.enforce_org_membership_branch_scope_company_match()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_membership_company uuid;
  v_branch_company uuid;
BEGIN
  SELECT m.company_id
  INTO v_membership_company
  FROM public.org_memberships m
  WHERE m.id = NEW.membership_id;

  SELECT b.company_id
  INTO v_branch_company
  FROM public.org_branches b
  WHERE b.id = NEW.branch_id;

  IF v_membership_company IS DISTINCT FROM v_branch_company THEN
    RAISE EXCEPTION 'org_membership_branch_scopes branch must belong to membership company'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_org_membership_branch_scopes_company_match
  ON public.org_membership_branch_scopes;

CREATE TRIGGER trg_org_membership_branch_scopes_company_match
  BEFORE INSERT OR UPDATE ON public.org_membership_branch_scopes
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_org_membership_branch_scope_company_match();
