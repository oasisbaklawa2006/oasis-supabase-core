-- Governed server-side staff/QA account provisioning authority.
--
-- Central issue #368, Lane 1 security closure. Central's /admin/users page
-- historically provisioned accounts client-side, including privileged role
-- writes. This migration creates the Core-owned server authority and closes
-- direct privilege-bearing browser mutation paths.
--
-- Role-key casing is lowercase snake_case, matching public.roles.role_key,
-- public.users.role, public.is_admin(), and user_role_map RLS semantics.
-- No RGS/P&A schema is touched here.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ---------------------------------------------------------------------
-- 1. Provisionable role allowlist.
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
  'enforced by the calling Edge Function before it reaches this RPC.';

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
  ('prod_dates',           'Dates production-TV role',                          false),
  ('prod_chocolate',       'Chocolate production-TV role',                      false),
  ('prod_dragees',         'Dragees production-TV role',                        false),
  ('prod_bakery',          'Bakery production-TV role',                         false),
  ('prod_nuts',            'Nuts production-TV role',                           false),
  ('tv_display',           'General display TV role',                           false),
  ('tv_assembly',          'Assembly TV role',                                  false),
  ('tv_ready',             'RGS TV kiosk (read-only) role',                     false),
  ('store_incharge',       'Store in-charge (RGS mutation surface)',            false),
  ('store_ready_goods',    'Ready Goods store role (RGS mutation surface)',     false),
  ('rgs_admin',            'RGS admin (RGS mutation surface)',                  false),
  ('dispatch_head',        'Dispatch department head',                          false),
  ('dispatch_manager',     'Dispatch manager',                                  false),
  ('dispatch_incharge',    'Dispatch in-charge',                                false),
  ('assembly_manager',     'Assembly manager',                                  false),
  ('packing_supervisor',   'Packing supervisor',                                false),
  ('sales_executive',      'Sales executive',                                   false),
  ('support_executive',    'Support executive',                                 false),
  ('catalogue_contributor','Catalogue contributor',                             false),
  ('security_control',     'Security control role',                             false),
  ('gate_security',        'Gate security role',                                false)
ON CONFLICT (role_key) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Active-admin authority helper hardening.
--    Existing RLS paths depend on public.is_admin(); a revoked admin must
--    therefore fail those paths too, not only the new provisioning RPCs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.role IN ('super_admin', 'admin')
      AND u.is_active IS TRUE
  );
$$;

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

-- Keep authenticated self-service profile UPDATE capability, but privileged
-- fields are no longer directly mutable by an admin browser session. Only
-- service_role -- the governed server-side provisioning path -- may alter
-- role/department/designation/active/invite privilege-bearing fields.
CREATE OR REPLACE FUNCTION public.protect_user_privilege_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL OR OLD.id IS DISTINCT FROM auth.uid() OR NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'user profile update not permitted';
  END IF;

  IF NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.role IS DISTINCT FROM OLD.role
     OR NEW.department IS DISTINCT FROM OLD.department
     OR NEW.designation IS DISTINCT FROM OLD.designation
     OR NEW.is_active IS DISTINCT FROM OLD.is_active
     OR NEW.invite_status IS DISTINCT FROM OLD.invite_status
     OR NEW.commission_rate_percentage IS DISTINCT FROM OLD.commission_rate_percentage
     OR NEW.is_sales_executive IS DISTINCT FROM OLD.is_sales_executive
     OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.joined_at IS DISTINCT FROM OLD.joined_at THEN
    RAISE EXCEPTION 'privileged user fields require governed server authority';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.protect_user_privilege_fields() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.protect_user_privilege_fields() TO service_role;

-- Direct account creation/deletion and all role-map mutations are removed
-- from authenticated clients. UPDATE on public.users is deliberately retained
-- for the existing non-privileged self-service profile contract; the trigger
-- above blocks privilege-bearing changes even for admins.
REVOKE INSERT, DELETE ON TABLE public.users FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.user_role_map FROM authenticated;

-- ---------------------------------------------------------------------
-- 3. can_grant_staff_role: pre-flight before any future Auth Admin API call.
--    super_admin may grant every provisionable role. admin may grant ordinary
--    provisionable roles but cannot create/elevate super_admin, owner or admin.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_grant_staff_role(p_actor uuid, p_role_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.staff_provisionable_roles r
      ON r.role_key = lower(p_role_key)
     AND r.is_active
    WHERE u.id = p_actor
      AND u.is_active IS TRUE
      AND (
        u.role = 'super_admin'
        OR (
          u.role = 'admin'
          AND r.role_key NOT IN ('super_admin', 'owner', 'admin')
        )
      )
  );
$$;

REVOKE ALL ON FUNCTION public.can_grant_staff_role(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_grant_staff_role(uuid, text) TO service_role;

-- ---------------------------------------------------------------------
-- 4. grant_staff_role: governed role grant, service_role only.
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

  SELECT * INTO v_role_row
  FROM public.staff_provisionable_roles
  WHERE role_key = v_role_key AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Role % is not on the provisionable allowlist', v_role_key USING ERRCODE = '42501';
  END IF;

  IF v_actor_role = 'admin' AND v_role_key IN ('super_admin', 'owner', 'admin') THEN
    RAISE EXCEPTION 'Admin cannot grant privileged role %', v_role_key USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing FROM public.users WHERE id = p_auth_user_id;

  -- Idempotent replay only when the requested grant produces no effective
  -- change. Metadata updates and inactive-identity recovery must still run.
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

  DELETE FROM public.user_role_map WHERE user_id = p_auth_user_id;
  INSERT INTO public.user_role_map (user_id, role_id)
  SELECT p_auth_user_id, r.id
  FROM public.roles r
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
-- 5. revoke_staff_user: authenticated RPC; authority comes from caller's
--    own active admin identity. Soft revoke immediately removes is_admin()
--    authority even if the JWT session itself has not yet expired.
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
    RETURN v_user;
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
