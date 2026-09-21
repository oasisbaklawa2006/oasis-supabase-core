-- Task 4 — governed Oasis Display remote assignment authority.
-- Contract coverage: 20260921120000_display_device_remote_config_authority.sql
-- Production apply is release-gated separately.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.display_device_registry_v1 (
  device_id text PRIMARY KEY,
  enrollment_code_hash text NOT NULL,
  display_token_hash text,
  surface_key text NOT NULL,
  friendly_name text,
  location text,
  config_version bigint NOT NULL DEFAULT 1 CHECK (config_version > 0),
  is_active boolean NOT NULL DEFAULT true,
  apk_version text,
  last_seen_at timestamptz,
  assigned_by uuid,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT display_device_registry_device_id_check
    CHECK (device_id ~ '^tv-[0-9a-fA-F-]{36}$'),
  CONSTRAINT display_device_registry_surface_check
    CHECK (surface_key IN (
      'arabic-sweets','chocolate','fusion','nuts','bakery','ready-goods',
      'third-party','assembly','dispatch-central','trace-gate','trace-dispatch'
    ))
);

ALTER TABLE public.display_device_registry_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.display_device_registry_v1
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.display_device_registry_v1 TO service_role;

COMMENT ON TABLE public.display_device_registry_v1 IS
  'Server-owned Oasis Display device pairing, read-token hash, assignment and health registry. Browser/TV clients have no direct table access.';

CREATE OR REPLACE FUNCTION public.admin_assign_display_device_v1(
  p_device_id text,
  p_enrollment_code text,
  p_surface_key text,
  p_friendly_name text DEFAULT NULL,
  p_location text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_code text := upper(btrim(coalesce(p_enrollment_code, '')));
  v_surface text := btrim(coalesce(p_surface_key, ''));
  v_code_hash text;
  v_row public.display_device_registry_v1;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'DISPLAY_ADMIN_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF v_device_id !~ '^tv-[0-9a-fA-F-]{36}$'
     OR v_code !~ '^[A-Z0-9]{8,16}$' THEN
    RAISE EXCEPTION 'DISPLAY_ENROLLMENT_IDENTITY_INVALID' USING ERRCODE = '22023';
  END IF;
  IF v_surface NOT IN (
    'arabic-sweets','chocolate','fusion','nuts','bakery','ready-goods',
    'third-party','assembly','dispatch-central','trace-gate','trace-dispatch'
  ) THEN
    RAISE EXCEPTION 'DISPLAY_SURFACE_INVALID' USING ERRCODE = '22023';
  END IF;

  v_code_hash := encode(extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'), 'hex');

  SELECT * INTO v_row
    FROM public.display_device_registry_v1
   WHERE device_id = v_device_id
   FOR UPDATE;

  IF FOUND AND v_row.enrollment_code_hash <> v_code_hash THEN
    RAISE EXCEPTION 'DISPLAY_ENROLLMENT_CODE_MISMATCH' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.display_device_registry_v1(
    device_id, enrollment_code_hash, surface_key, friendly_name, location,
    config_version, is_active, assigned_by, assigned_at, updated_at
  ) VALUES(
    v_device_id, v_code_hash, v_surface,
    nullif(btrim(coalesce(p_friendly_name, '')), ''),
    nullif(btrim(coalesce(p_location, '')), ''),
    1, true, v_actor, now(), now()
  )
  ON CONFLICT (device_id)
  DO UPDATE SET
    surface_key = excluded.surface_key,
    friendly_name = excluded.friendly_name,
    location = excluded.location,
    config_version = public.display_device_registry_v1.config_version + 1,
    is_active = true,
    assigned_by = v_actor,
    assigned_at = now(),
    updated_at = now()
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'deviceId', v_row.device_id,
    'surfaceKey', v_row.surface_key,
    'friendlyName', v_row.friendly_name,
    'location', v_row.location,
    'configVersion', v_row.config_version,
    'assignedAtEpochMs', floor(extract(epoch from v_row.assigned_at) * 1000)::bigint
  );
END
$$;

CREATE OR REPLACE FUNCTION public.admin_list_display_devices_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'DISPLAY_ADMIN_REQUIRED' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'deviceId', d.device_id,
    'surfaceKey', d.surface_key,
    'friendlyName', d.friendly_name,
    'location', d.location,
    'configVersion', d.config_version,
    'active', d.is_active,
    'apkVersion', d.apk_version,
    'lastSeenAt', d.last_seen_at,
    'assignedAt', d.assigned_at
  ) ORDER BY d.friendly_name NULLS LAST, d.device_id), '[]'::jsonb)
  INTO v_rows
  FROM public.display_device_registry_v1 d;

  RETURN v_rows;
END
$$;

CREATE OR REPLACE FUNCTION public.admin_revoke_display_device_v1(p_device_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'DISPLAY_ADMIN_REQUIRED' USING ERRCODE = '42501';
  END IF;
  UPDATE public.display_device_registry_v1
     SET is_active = false,
         display_token_hash = NULL,
         config_version = config_version + 1,
         updated_at = now()
   WHERE device_id = btrim(coalesce(p_device_id, ''));
END
$$;

REVOKE ALL ON FUNCTION public.admin_assign_display_device_v1(text,text,text,text,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_list_display_devices_v1()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_revoke_display_device_v1(text)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_assign_display_device_v1(text,text,text,text,text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_display_devices_v1()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_revoke_display_device_v1(text)
  TO authenticated, service_role;
