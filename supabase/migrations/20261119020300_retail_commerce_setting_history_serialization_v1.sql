-- GFT-100 / Core #561: audit-history consistency for first-write races.
-- Forward-only repair: prior 20261119020200 SQL is preserved unchanged
-- because it has already been applied in an isolated Supabase Preview.
-- This migration introduces no values, approval or activation.
-- 20261119020300 follows the retail configuration base and precedes the
-- dependent 20261119100000 retail-order series on the stacked #562 branch.
-- Pg advisory lock serializes a setting key before reading its old value.
-- Existing grants on this same function signature remain in force.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE FUNCTION public.retail_commerce_set_setting_v1(
  p_key text,
  p_value jsonb,
  p_status text DEFAULT 'proposed',
  p_approval_reference text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_old public.retail_commerce_settings%ROWTYPE;
  v_reference text := nullif(btrim(coalesce(p_approval_reference, '')), '');
BEGIN
  -- Only an authenticated, active administrator; service_role and automation can never write or approve.
  IF v_actor IS NULL OR NOT coalesce(public.is_admin(), false) THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('proposed', 'approved') THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  IF NOT public.retail_commerce_validate_value_v1(p_key, p_value) THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  IF p_status = 'approved' AND v_reference IS NULL THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_APPROVAL_REFERENCE_REQUIRED' USING ERRCODE = '22023';
  END IF;

  -- Lock the setting key even before the first insert: a row lock cannot
  -- protect a key that does not yet exist. Transaction scope releases on
  -- commit/rollback; collisions only serialize unrelated keys harmlessly.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('retail_commerce_settings:' || p_key, 0)
  );

  SELECT * INTO v_old FROM public.retail_commerce_settings WHERE setting_key = p_key FOR UPDATE;

  INSERT INTO public.retail_commerce_settings AS s (
    setting_key, value, status, approval_reference, approved_by, approved_at, updated_by, updated_at
  ) VALUES (
    p_key, p_value, p_status,
    CASE WHEN p_status = 'approved' THEN v_reference END,
    CASE WHEN p_status = 'approved' THEN v_actor END,
    CASE WHEN p_status = 'approved' THEN now() END,
    v_actor, now()
  )
  ON CONFLICT (setting_key) DO UPDATE
     SET value = EXCLUDED.value,
         status = EXCLUDED.status,
         approval_reference = EXCLUDED.approval_reference,
         approved_by = EXCLUDED.approved_by,
         approved_at = EXCLUDED.approved_at,
         updated_by = EXCLUDED.updated_by,
         updated_at = EXCLUDED.updated_at;

  INSERT INTO public.retail_commerce_setting_history (
    setting_key, old_value, new_value, old_status, new_status, approval_reference, changed_by
  ) VALUES (
    p_key, v_old.value, p_value, v_old.status, p_status, v_reference, v_actor
  );

  RETURN jsonb_build_object('key', p_key, 'status', p_status);
END;
$$;

-- Restate the unchanged ACL explicitly: this function is SECURITY DEFINER, and
-- governance requires an explicit REVOKE ALL beside every such definition.
-- Same grants as 20261119020200: administrators only (is_admin() is also checked in the body).
REVOKE ALL ON FUNCTION public.retail_commerce_set_setting_v1(text, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retail_commerce_set_setting_v1(text, jsonb, text, text) TO authenticated;
