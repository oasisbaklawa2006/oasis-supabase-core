-- Governed server-side staff/QA account provisioning authority.
--
-- Central issue #368, Lane 1 security closure. Central's /admin/users page
-- (src/pages/admin/AdminUsers.tsx) currently provisions accounts entirely
-- client-side: it calls supabase.auth.signUp() from the browser, then
-- upserts public.users and public.user_role_map from the browser, with no
-- server-side check that the caller is actually authorized to grant the
-- requested role, and emails the generated password in plaintext. None of
-- that is acceptable for privileged accounts (see
-- docs/LANE1_QA_ACCOUNT_MATRIX.md in the Central repo, which now states
-- QA_ACCOUNT_PROVISIONING_AUTHORITY_MISSING pending this migration).
--
-- This migration is the server-side half of the fix: two SECURITY DEFINER
-- RPCs plus a role allowlist. It does not itself talk to the Supabase Auth
-- Admin API (that requires a service-role Edge Function, tracked
-- separately) -- it is the governed "grant an internal role" step that
-- Edge Function must call, so the browser is structurally incapable of
-- writing public.users.role or public.user_role_map on its own, and every
-- grant/revoke is authority-checked and audited server-side regardless of
-- which client calls it.
--
-- Role-key casing: lowercase snake_case (super_admin, admin, hod_arabic,
-- ...), matching public.roles.role_key's existing convention and, crucially,
-- public.is_admin()'s literal `role IN ('super_admin','admin')` check and
-- the "Admins manage user_role_map" RLS policy, both of which compare
-- public.users.role case-sensitively against those two lowercase literals.
-- Central's own app-layer normalizeRole() uppercases for its own
-- comparisons regardless of stored case, so lowercase storage here stays
-- fully compatible with Central's routing -- writing uppercase instead
-- would silently break is_admin() and the user_role_map RLS policy for
-- every account this authority grants admin/super_admin through.
--
-- No RGS/P&A schema is touched here (kept separate per governance policy).

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ---------------------------------------------------------------------
-- 1. Role allowlist. This is the anti-escalation control: grant_staff_role
--    below refuses any role_key not listed here and active, so a caller
--    (or a compromised Edge Function) cannot grant an arbitrary role by
--    supplying an arbitrary string. Extending this list is itself a
--    reviewed migration, never a runtime write from any RPC.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_provisionable_roles (
  role_key text PRIMARY KEY,
  description text NOT NULL,
  requires_step_up boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.staff_provisionable_roles IS
  'Allowlist of role_key values grant_staff_role() may assign. requires_step_up '
  'marks roles that need an AAL2 (step-up) session on the granting admin, '
  'enforced by the calling Edge Function before it ever reaches this RPC.';

REVOKE ALL ON TABLE public.staff_provisionable_roles FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.staff_provisionable_roles TO authenticated;

INSERT INTO public.staff_provisionable_roles (role_key, description, requires_step_up) VALUES
  ('super_admin',          'Full system authority',                             true),
  ('owner',                'Business owner',                                    true),
  ('admin',                'Full administrative authority',                     true),
  ('finance_head',         'Finance department head',                           true),
  ('finance_exec',         'Finance executive',                                 true),
  ('finance_auditor',      'Finance auditor (read/verify)',                     true),
  ('operations_manager',   'Cross-department operations authority',             false),
  ('production_manager',   'Cross-department production authority',             false),
  ('hod_arabic',           'Arabic Sweets department head',                     false),
  ('hod_fusion',           'Fusion Sweets department head',                     false),
  ('hod_chocolate',        'Chocolate & Confectionery department head',         false),
  ('hod_dragees',          'Dragees department head',                           false),
  ('hod_dates',            'Dates department head',                             false),
  ('hod_bakery',           'Bakery department head',                            false),
  ('hod_nuts',             'Seasoned Nuts & Mixes department head',             false),
  ('hod_assembly',         'Assembly department head',                          false),
  ('prod_arabic_sweets',   'Arabic Sweets production-TV role',                  false),
  ('prod_fusion',          'Fusion Sweets production-TV role',                  false),
  ('prod_dates',           'Dates production-TV role',                         false),
  ('prod_chocolate',       'Chocolate production-TV role',                      false),
  ('prod_dragees',         'Dragees production-TV role',                        false),
  ('prod_bakery',          'Bakery production-TV role',                         false),
  ('prod_nuts',            'Nuts production-TV role',                          false),
  ('tv_display',           'General display TV role',                          false),
  ('tv_assembly',          'Assembly TV role',                                 false),
  ('tv_ready',             'RGS TV kiosk (read-only) role',                    false),
  ('store_incharge',       'Store in-charge (RGS mutation surface)',           false),
  ('store_ready_goods',    'Ready Goods store role (RGS mutation surface)',    false),
  ('rgs_admin',            'RGS admin (RGS mutation surface)',                 false),
  ('dispatch_head',        'Dispatch department head',                         false),
  ('dispatch_manager',     'Dispatch manager',                                 false),
  ('dispatch_incharge',    'Dispatch in-charge',                               false),
  ('assembly_manager',     'Assembly manager',                                 false),
  ('packing_supervisor',   'Packing supervisor',                               false),
  ('sales_executive',      'Sales executive',                                  false),
  ('support_executive',    'Support executive',                                false),
  ('catalogue_contributor','Catalogue contributor',                            false),
  ('security_control',     'Security control role',                            false),
  ('gate_security',        'Gate security role',                               false)
ON CONFLICT (role_key) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. can_grant_staff_role: cheap pre-check an Edge Function calls BEFORE
--    doing anything with the Supabase Auth Admin API, so an unauthorized
--    request never gets as far as creating an auth identity. grant_staff_role
--    (below) re-checks the same conditions itself -- this is a pre-flight
--    optimization, not the sole authority boundary.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_grant_staff_role(p_actor uuid, p_role_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = p_actor
      AND role IN ('super_admin', 'admin')
      AND is_active IS TRUE
  )
  AND EXISTS (
    SELECT 1 FROM public.staff_provisionable_roles
    WHERE role_key = lower(p_role_key) AND is_active
  );
$$;

REVOKE ALL ON FUNCTION public.can_grant_staff_role(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_grant_staff_role(uuid, text) TO service_role;

-- ---------------------------------------------------------------------
-- 3. grant_staff_role: the only path allowed to write public.users.role /
--    public.user_role_map for a governed staff/QA grant. Callable only by
--    service_role -- i.e. only from a trusted server-side Edge Function
--    that has already authenticated the caller and (for
--    requires_step_up roles) verified their session is AAL2. The browser
--    can never reach this function directly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grant_staff_role(
  p_auth_user_id uuid,
  p_email text,
  p_display_name text,
  p_role_key text,
  p_actor uuid,
  p_department text DEFAULT NULL,
  p_designation text DEFAULT NULL
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role_key text := lower(p_role_key);
  v_actor_role text;
  v_actor_active boolean;
  v_role_row public.staff_provisionable_roles%ROWTYPE;
  v_existing public.users%ROWTYPE;
  v_user public.users%ROWTYPE;
BEGIN
  IF p_auth_user_id IS NULL OR p_actor IS NULL OR nullif(btrim(p_email), '') IS NULL THEN
    RAISE EXCEPTION 'auth_user_id, actor and email are required';
  END IF;

  SELECT role, is_active INTO v_actor_role, v_actor_active
  FROM public.users
  WHERE id = p_actor;
  IF v_actor_role IS NULL OR v_actor_role NOT IN ('super_admin', 'admin') OR v_actor_active IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to grant staff roles' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_role_row FROM public.staff_provisionable_roles
  WHERE role_key = v_role_key AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Role % is not on the provisionable allowlist' , v_role_key USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM public.users WHERE id = p_auth_user_id;

  -- Idempotent replay only when the requested grant would make no effective
  -- change. This deliberately does not suppress metadata updates for an
  -- already-active user carrying the same role, and does not suppress
  -- recovery of an inactive/partially-provisioned identity.
  IF FOUND
     AND v_existing.role = v_role_key
     AND v_existing.is_active
     AND v_existing.invite_status = 'active'
     AND v_existing.email IS NOT DISTINCT FROM btrim(p_email)
     AND v_existing.full_name IS NOT DISTINCT FROM coalesce(p_display_name, v_existing.full_name)
     AND v_existing.department IS NOT DISTINCT FROM coalesce(p_department, v_existing.department)
     AND v_existing.designation IS NOT DISTINCT FROM coalesce(p_designation, v_existing.designation)
  THEN
    RETURN v_existing;
  END IF;

  INSERT INTO public.users (id, email, full_name, role, department, designation, is_active, invite_status)
  VALUES (p_auth_user_id, btrim(p_email), p_display_name, v_role_key, p_department, p_designation, true, 'active')
  ON CONFLICT (id) DO UPDATE SET
    email = excluded.email,
    full_name = coalesce(excluded.full_name, public.users.full_name),
    role = excluded.role,
    department = coalesce(excluded.department, public.users.department),
    designation = coalesce(excluded.designation, public.users.designation),
    is_active = true,
    invite_status = 'active'
  RETURNING * INTO v_user;

  -- Legacy-compatible user_role_map mirror, best-effort: a single row per
  -- user, replaced (not appended) so one user never carries two mappings.
  DELETE FROM public.user_role_map WHERE user_id = p_auth_user_id;
  INSERT INTO public.user_role_map (user_id, role_id)
  SELECT p_auth_user_id, r.id FROM public.roles r
  WHERE r.role_key = v_role_key AND r.is_active
  LIMIT 1;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, new_value, risk_level)
  VALUES (
    p_actor, 'UserAdmin', 'users', p_auth_user_id::text, 'STAFF_ROLE_GRANTED',
    jsonb_build_object('role', v_role_key, 'email', v_user.email, 'requires_step_up', v_role_row.requires_step_up),
    CASE WHEN v_role_row.requires_step_up THEN 'high' ELSE 'normal' END
  );

  RETURN v_user;
END;
$$;

REVOKE ALL ON FUNCTION public.grant_staff_role(uuid, text, text, text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_staff_role(uuid, text, text, text, uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------
-- 4. revoke_staff_user: safe to call directly as the acting admin's own
--    session (no Auth Admin API step involved in a soft revoke), so this
--    one is granted to `authenticated` and authorises off auth.uid()
--    itself rather than routing through an Edge Function.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revoke_staff_user(p_target_user_id uuid, p_reason text)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_actor_role text;
  v_actor_active boolean;
  v_user public.users%ROWTYPE;
BEGIN
  SELECT role, is_active INTO v_actor_role, v_actor_active
  FROM public.users
  WHERE id = v_actor;
  IF v_actor IS NULL OR v_actor_role IS NULL OR v_actor_role NOT IN ('super_admin', 'admin') OR v_actor_active IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to revoke staff users' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'A revocation reason is required';
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = p_target_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found';
  END IF;

  IF NOT v_user.is_active THEN
    RETURN v_user; -- idempotent replay
  END IF;

  UPDATE public.users
  SET is_active = false, invite_status = 'revoked'
  WHERE id = p_target_user_id
  RETURNING * INTO v_user;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, reason, risk_level)
  VALUES (v_actor, 'UserAdmin', 'users', p_target_user_id::text, 'STAFF_USER_REVOKED', p_reason, 'high');

  RETURN v_user;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_staff_user(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_staff_user(uuid, text) TO authenticated;
