-- Lane 1 B1 (Central issue #368): TV device/session authority.
--
-- A physical TV kiosk gets a dedicated Supabase Auth identity (provisioned
-- through the existing governed staff authority in
-- 20260819110000_staff_provisioning_authority.sql -- grant_staff_role with
-- role_key in ('tv_display','tv_assembly','tv_ready') -- this migration
-- does not create auth identities itself). This migration adds the
-- device-binding layer on top of that identity: which physical screen it
-- is, which of the six canonical TV groups it belongs to, and whether it is
-- currently paired/enabled/revoked. It is orthogonal to, and does NOT
-- broaden, is_internal_staff()/is_admin()/is_staff_role() -- a TV identity
-- passing is_tv_device() must never thereby satisfy any of those checks.
--
-- Six canonical Lane 1 TV groups (owner's physical estate, Central issue
-- #368, matching 20260818090000_rgs_six_tv_department_correction.sql's
-- corrected production-department model plus RGS as its own non-production
-- group): BAKERY, CHOCOLATES_CONFECTIONERY, FUSION_SWEETS, ARABIC_SWEETS,
-- SEASONED_NUTS_MIXES, RGS. Dragees/Dates/semi-prepared are aliased into
-- their respective groups at the production_departments layer already --
-- no separate TV group is created for them, nor for Assembly/Dispatch
-- (those application surfaces, if they exist, are outside this six-device
-- authority per the owner's scope).

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Single source of truth for the six canonical Lane 1 TV groups -- the
-- table CHECK constraint and both admin RPCs below all validate against
-- this one function rather than each hardcoding their own copy of the list.
CREATE OR REPLACE FUNCTION public.is_canonical_tv_group(p_group text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_group = ANY (ARRAY[
    'BAKERY', 'CHOCOLATES_CONFECTIONERY', 'FUSION_SWEETS',
    'ARABIC_SWEETS', 'SEASONED_NUTS_MIXES', 'RGS'
  ]);
$$;

REVOKE ALL ON FUNCTION public.is_canonical_tv_group(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_canonical_tv_group(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1. Device registry. One row per physical TV, one auth identity per row.
--    No plaintext credential, access token or refresh token is ever
--    stored here -- the identity's own Supabase Auth session is the only
--    credential, and this table only records which identity is bound to
--    which screen and group.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tv_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),
  device_label text NOT NULL,
  tv_group text NOT NULL CHECK (public.is_canonical_tv_group(tv_group)),
  is_enabled boolean NOT NULL DEFAULT true,
  paired_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id),
  revoked_by uuid REFERENCES auth.users(id),
  CONSTRAINT tv_devices_revoked_consistency CHECK (
    (revoked_at IS NULL AND revoked_reason IS NULL AND revoked_by IS NULL)
    OR (revoked_at IS NOT NULL AND revoked_reason IS NOT NULL AND revoked_by IS NOT NULL)
  )
);

COMMENT ON TABLE public.tv_devices IS
  'Lane 1 B1 (Central issue #368): device/session binding for the six-TV physical estate. One row per physical TV kiosk, bound to a dedicated auth identity provisioned via grant_staff_role(). Read-only by design -- see is_tv_device()/current_tv_group()/tv_device_status().';

CREATE INDEX IF NOT EXISTS idx_tv_devices_tv_group ON public.tv_devices (tv_group) WHERE revoked_at IS NULL;

CREATE OR REPLACE FUNCTION public.tv_devices_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tv_devices_updated_at ON public.tv_devices;
CREATE TRIGGER trg_tv_devices_updated_at
  BEFORE UPDATE ON public.tv_devices
  FOR EACH ROW EXECUTE FUNCTION public.tv_devices_set_updated_at();

ALTER TABLE public.tv_devices ENABLE ROW LEVEL SECURITY;

-- No direct authenticated write path exists -- every mutation goes through
-- the SECURITY DEFINER RPCs below, which re-check admin authority
-- themselves. A device may read its own row (its own label/group/status);
-- it can never see or touch any other device's row, and can never write
-- its own.
CREATE POLICY "tv_devices_admin_full_access" ON public.tv_devices
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "tv_devices_self_select" ON public.tv_devices
  FOR SELECT TO authenticated
  USING (auth_user_id = auth.uid());

REVOKE ALL ON TABLE public.tv_devices FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.tv_devices TO authenticated;
GRANT ALL ON TABLE public.tv_devices TO service_role;

-- ---------------------------------------------------------------------
-- 2. Read-only identity/group resolution helpers. Deliberately NOT named
--    or composed to overlap with is_internal_staff()/is_admin()/
--    is_staff_role() -- callers that need "is this caller allowed to
--    mutate operational state" must keep using those, unchanged. A device
--    is fail-closed: no row, disabled, or revoked all resolve to "not a
--    TV" / NULL group, never an exception (these are read-path checks
--    used inside other RLS/RPC bodies, where an exception would be the
--    wrong failure mode for a routine "is this a TV" check).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_tv_device()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.tv_devices
    WHERE auth_user_id = auth.uid() AND is_enabled AND revoked_at IS NULL
  );
$$;

COMMENT ON FUNCTION public.is_tv_device() IS
  'True only for an enabled, non-revoked TV device session. Orthogonal to is_internal_staff()/is_admin()/is_staff_role() -- must never be used to broaden any of those.';

REVOKE ALL ON FUNCTION public.is_tv_device() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_tv_device() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.current_tv_group()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT tv_group FROM public.tv_devices
  WHERE auth_user_id = auth.uid() AND is_enabled AND revoked_at IS NULL;
$$;

COMMENT ON FUNCTION public.current_tv_group() IS
  'Canonical tv_group for the caller''s own enabled, non-revoked device row, resolved server-side. NULL for any non-TV caller or a disabled/revoked device. Never trust a client-supplied group value in its place.';

REVOKE ALL ON FUNCTION public.current_tv_group() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_tv_group() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.is_tv_device_for_group(p_group text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.current_tv_group() = upper(coalesce(p_group, ''));
$$;

REVOKE ALL ON FUNCTION public.is_tv_device_for_group(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_tv_device_for_group(text) TO authenticated, service_role;

-- Canonical status the TV client polls to decide its own UI state. Never
-- falls back to any generic "authenticated" success state -- an
-- unregistered caller is fail-closed to NOT_REGISTERED, same posture as
-- DISABLED/REVOKED/GROUP_MISMATCH.
CREATE OR REPLACE FUNCTION public.tv_device_status(p_expected_group text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_device public.tv_devices%ROWTYPE;
BEGIN
  SELECT * INTO v_device FROM public.tv_devices WHERE auth_user_id = auth.uid();
  IF NOT FOUND THEN
    RETURN 'NOT_REGISTERED';
  END IF;
  IF v_device.revoked_at IS NOT NULL THEN
    RETURN 'REVOKED';
  END IF;
  IF NOT v_device.is_enabled THEN
    RETURN 'DISABLED';
  END IF;
  IF p_expected_group IS NOT NULL AND v_device.tv_group <> upper(p_expected_group) THEN
    RETURN 'GROUP_MISMATCH';
  END IF;
  RETURN 'ACTIVE';
END;
$$;

COMMENT ON FUNCTION public.tv_device_status(text) IS
  'ACTIVE | DISABLED | REVOKED | GROUP_MISMATCH | NOT_REGISTERED for the caller''s own device, optionally checked against an expected group. The TV client polls this to decide its own UI state -- never silently falls back to generic authenticated access on any non-ACTIVE result.';

REVOKE ALL ON FUNCTION public.tv_device_status(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tv_device_status(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. Lifecycle RPCs. Admin-only (same is_admin() boundary as
--    revoke_staff_user), called directly as the acting admin's own
--    session -- none of these touch the Supabase Auth Admin API, so no
--    Edge Function/service_role indirection is needed. Every transition
--    is audited via the existing public.audit_logs append-only table
--    (module_name = 'TvDeviceAdmin'), the same mechanism
--    grant_staff_role()/revoke_staff_user() use -- no second audit system.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_tv_device(
  p_auth_user_id uuid,
  p_device_label text,
  p_tv_group text
)
RETURNS public.tv_devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_group text := upper(coalesce(p_tv_group, ''));
  v_device public.tv_devices%ROWTYPE;
  v_was_present boolean;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Not authorised to register TV devices' USING ERRCODE = '42501';
  END IF;
  IF p_auth_user_id IS NULL OR nullif(btrim(p_device_label), '') IS NULL THEN
    RAISE EXCEPTION 'auth_user_id and device_label are required';
  END IF;
  IF NOT public.is_canonical_tv_group(v_group) THEN
    RAISE EXCEPTION 'Unknown tv_group %', p_tv_group USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.tv_devices WHERE auth_user_id = p_auth_user_id) INTO v_was_present;

  INSERT INTO public.tv_devices (auth_user_id, device_label, tv_group, is_enabled, paired_at, revoked_at, revoked_reason, revoked_by, created_by)
  VALUES (p_auth_user_id, btrim(p_device_label), v_group, true, now(), NULL, NULL, NULL, v_actor)
  ON CONFLICT (auth_user_id) DO UPDATE SET
    device_label = excluded.device_label,
    tv_group = excluded.tv_group,
    is_enabled = true,
    paired_at = now(),
    revoked_at = NULL,
    revoked_reason = NULL,
    revoked_by = NULL
  RETURNING * INTO v_device;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, new_value, risk_level)
  VALUES (
    v_actor, 'TvDeviceAdmin', 'tv_devices', v_device.id::text,
    CASE WHEN v_was_present THEN 'TV_DEVICE_REPAIRED' ELSE 'TV_DEVICE_REGISTERED' END,
    jsonb_build_object('device_label', v_device.device_label, 'tv_group', v_device.tv_group, 'auth_user_id', p_auth_user_id), 'normal'
  );

  RETURN v_device;
END;
$$;

REVOKE ALL ON FUNCTION public.register_tv_device(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_tv_device(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_tv_device_group(p_device_id uuid, p_tv_group text)
RETURNS public.tv_devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_group text := upper(coalesce(p_tv_group, ''));
  v_device public.tv_devices%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Not authorised to change TV device groups' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_canonical_tv_group(v_group) THEN
    RAISE EXCEPTION 'Unknown tv_group %', p_tv_group USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_device FROM public.tv_devices WHERE id = p_device_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TV device not found';
  END IF;
  IF v_device.tv_group = v_group THEN
    RETURN v_device; -- idempotent replay
  END IF;

  UPDATE public.tv_devices SET tv_group = v_group WHERE id = p_device_id RETURNING * INTO v_device;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, new_value, risk_level)
  VALUES (v_actor, 'TvDeviceAdmin', 'tv_devices', p_device_id::text, 'TV_DEVICE_GROUP_CHANGED', jsonb_build_object('tv_group', v_group), 'normal');

  RETURN v_device;
END;
$$;

REVOKE ALL ON FUNCTION public.set_tv_device_group(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_tv_device_group(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.disable_tv_device(p_device_id uuid, p_reason text)
RETURNS public.tv_devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_device public.tv_devices%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Not authorised to disable TV devices' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_device FROM public.tv_devices WHERE id = p_device_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TV device not found';
  END IF;
  IF NOT v_device.is_enabled THEN
    RETURN v_device; -- idempotent replay
  END IF;

  UPDATE public.tv_devices SET is_enabled = false WHERE id = p_device_id RETURNING * INTO v_device;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, reason, risk_level)
  VALUES (v_actor, 'TvDeviceAdmin', 'tv_devices', p_device_id::text, 'TV_DEVICE_DISABLED', p_reason, 'normal');

  RETURN v_device;
END;
$$;

REVOKE ALL ON FUNCTION public.disable_tv_device(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.disable_tv_device(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.enable_tv_device(p_device_id uuid)
RETURNS public.tv_devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_device public.tv_devices%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Not authorised to enable TV devices' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_device FROM public.tv_devices WHERE id = p_device_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TV device not found';
  END IF;
  IF v_device.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'A revoked TV device cannot be re-enabled -- re-register it instead' USING ERRCODE = '42501';
  END IF;
  IF v_device.is_enabled THEN
    RETURN v_device; -- idempotent replay
  END IF;

  UPDATE public.tv_devices SET is_enabled = true WHERE id = p_device_id RETURNING * INTO v_device;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, risk_level)
  VALUES (v_actor, 'TvDeviceAdmin', 'tv_devices', p_device_id::text, 'TV_DEVICE_RE_ENABLED', 'normal');

  RETURN v_device;
END;
$$;

REVOKE ALL ON FUNCTION public.enable_tv_device(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enable_tv_device(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.revoke_tv_device(p_device_id uuid, p_reason text)
RETURNS public.tv_devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_device public.tv_devices%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'Not authorised to revoke TV devices' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'A revocation reason is required';
  END IF;

  SELECT * INTO v_device FROM public.tv_devices WHERE id = p_device_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TV device not found';
  END IF;
  IF v_device.revoked_at IS NOT NULL THEN
    RETURN v_device; -- idempotent replay
  END IF;

  UPDATE public.tv_devices
  SET is_enabled = false, revoked_at = now(), revoked_reason = p_reason, revoked_by = v_actor
  WHERE id = p_device_id
  RETURNING * INTO v_device;

  INSERT INTO public.audit_logs (actor_id, module_name, entity_name, entity_id, action_type, reason, risk_level)
  VALUES (v_actor, 'TvDeviceAdmin', 'tv_devices', p_device_id::text, 'TV_DEVICE_REVOKED', p_reason, 'high');

  RETURN v_device;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_tv_device(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_tv_device(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. Group-scoped read surfaces. Read-only (SELECT only, no mutation
--    path), and the group is always resolved server-side from
--    current_tv_group() -- a client can never widen its own read scope by
--    supplying a different group. Reuses the existing production_jobs /
--    inventory_stock_balances tables rather than a parallel TV-only data
--    model; RLS on those tables still requires is_internal_staff(), which
--    a TV identity never satisfies, so these SECURITY DEFINER RPCs are the
--    only read path available to a TV caller -- narrower than RLS, never
--    broader.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tv_department_production_queue()
RETURNS SETOF public.production_jobs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH caller AS (SELECT public.current_tv_group() AS tv_group)
  SELECT j.* FROM public.production_jobs j, caller
  WHERE caller.tv_group IS NOT NULL
    AND caller.tv_group <> 'RGS'
    AND j.canonical_department = caller.tv_group
    AND j.status IN ('pending', 'accepted', 'in_production', 'paused');
$$;

COMMENT ON FUNCTION public.tv_department_production_queue() IS
  'Read-only production_jobs queue scoped to the caller''s own current_tv_group(). Empty for any non-TV caller, a disabled/revoked device, or the RGS group (which has its own read surface below) -- never returns another group''s rows.';

REVOKE ALL ON FUNCTION public.tv_department_production_queue() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tv_department_production_queue() TO authenticated;

CREATE OR REPLACE FUNCTION public.tv_rgs_stock_snapshot()
RETURNS SETOF public.inventory_stock_balances
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.* FROM public.inventory_stock_balances b, (SELECT public.is_tv_device_for_group('RGS') AS is_rgs) AS caller
  WHERE caller.is_rgs;
$$;

COMMENT ON FUNCTION public.tv_rgs_stock_snapshot() IS
  'Read-only inventory_stock_balances snapshot, visible only to a caller whose current_tv_group() is RGS. Empty for every other caller.';

REVOKE ALL ON FUNCTION public.tv_rgs_stock_snapshot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tv_rgs_stock_snapshot() TO authenticated;
