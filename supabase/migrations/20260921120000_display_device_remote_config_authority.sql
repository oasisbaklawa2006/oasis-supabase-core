-- Task 4 — governed Oasis Display remote assignment authority.
-- Contract coverage: 20260921120000_display_device_remote_config_authority.sql
-- Production apply is release-gated separately.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM vault.decrypted_secrets
     WHERE name = 'display_enrollment_code_hmac_v1'
  ) THEN
    PERFORM vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'display_enrollment_code_hmac_v1',
      'Server-only HMAC key for Oasis Display enrollment codes'
    );
  END IF;
END
$$;

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

CREATE OR REPLACE FUNCTION public.display_enrollment_code_hash_v1(p_code text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_secret text;
BEGIN
  SELECT decrypted_secret
    INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'display_enrollment_code_hmac_v1'
   ORDER BY created_at DESC
   LIMIT 1;

  IF nullif(v_secret, '') IS NULL THEN
    RAISE EXCEPTION 'DISPLAY_ENROLLMENT_SECRET_MISSING' USING ERRCODE = '55000';
  END IF;

  RETURN encode(
    extensions.hmac(
      convert_to(upper(btrim(coalesce(p_code, ''))), 'UTF8'),
      convert_to(v_secret, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
END
$$;

REVOKE ALL ON FUNCTION public.display_enrollment_code_hash_v1(text)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.display_enrollment_code_hash_v1(text) IS
  'Database-owner-only keyed representation for normalized Oasis Display enrollment codes. The HMAC key is held in Vault.';

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

  v_code_hash := public.display_enrollment_code_hash_v1(v_code);

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

CREATE OR REPLACE FUNCTION public.display_device_assignment_v1(
  p_device_id text,
  p_enrollment_code text,
  p_display_token_hash text,
  p_new_display_token_hash text,
  p_apk_version text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_device_id text := btrim(coalesce(p_device_id, ''));
  v_code text := upper(btrim(coalesce(p_enrollment_code, '')));
  v_token_hash text := lower(btrim(coalesce(p_display_token_hash, '')));
  v_new_token_hash text := lower(btrim(coalesce(p_new_display_token_hash, '')));
  v_apk_version text := nullif(left(btrim(coalesce(p_apk_version, '')), 64), '');
  v_now timestamptz := clock_timestamp();
  v_active boolean;
  v_auth_mode text;
  v_row public.display_device_registry_v1;
BEGIN
  IF v_device_id !~ '^tv-[0-9a-fA-F-]{36}$' THEN
    RETURN jsonb_build_object('status', 'pending_enrollment');
  END IF;

  IF v_token_hash <> '' THEN
    IF v_token_hash !~ '^[0-9a-f]{64}$'
       OR v_code <> ''
       OR v_new_token_hash <> '' THEN
      RETURN jsonb_build_object('status', 'device_token_invalid');
    END IF;

    UPDATE public.display_device_registry_v1
       SET last_seen_at = v_now,
           apk_version = v_apk_version,
           updated_at = v_now
     WHERE device_id = v_device_id
       AND is_active
       AND display_token_hash = v_token_hash
    RETURNING * INTO v_row;
    v_auth_mode := 'token';
  ELSE
    IF v_code !~ '^[A-Z0-9]{8,16}$'
       OR v_new_token_hash !~ '^[0-9a-f]{64}$' THEN
      RETURN jsonb_build_object('status', 'enrollment_code_invalid');
    END IF;

    UPDATE public.display_device_registry_v1
       SET display_token_hash = v_new_token_hash,
           last_seen_at = v_now,
           apk_version = v_apk_version,
           updated_at = v_now
     WHERE device_id = v_device_id
       AND is_active
       AND display_token_hash IS NULL
       AND enrollment_code_hash = public.display_enrollment_code_hash_v1(v_code)
    RETURNING * INTO v_row;
    v_auth_mode := 'enrollment';
  END IF;

  IF v_row.device_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'ok',
      'authMode', v_auth_mode,
      'assignment', jsonb_build_object(
        'v', 1,
        'surfaceKey', v_row.surface_key,
        'friendlyName', v_row.friendly_name,
        'location', v_row.location,
        'configVersion', v_row.config_version,
        'assignedAtEpochMs', floor(extract(epoch from v_row.assigned_at) * 1000)::bigint
      )
    );
  END IF;

  SELECT is_active
    INTO v_active
    FROM public.display_device_registry_v1
   WHERE device_id = v_device_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'pending_enrollment');
  END IF;
  IF NOT v_active THEN
    RETURN jsonb_build_object('status', 'device_revoked');
  END IF;
  IF v_auth_mode = 'token' THEN
    RETURN jsonb_build_object('status', 'device_token_invalid');
  END IF;
  RETURN jsonb_build_object('status', 'enrollment_code_invalid');
END
$$;

REVOKE ALL ON FUNCTION public.display_device_assignment_v1(text,text,text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.display_device_assignment_v1(text,text,text,text,text)
  TO service_role;

COMMENT ON FUNCTION public.display_device_assignment_v1(text,text,text,text,text) IS
  'Service-role-only atomic authentication, single-winner enrollment claim, activity update and assignment read for Oasis Display devices.';

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
