-- Forward-only defect closure: RGS lifecycle and quantity correctness.
-- Closes two defects surfaced by PR #89 review and deliberately deferred.
-- Documented in docs/reconciliation/production-migration-lineage-recovery-2026-08-18.md
-- under "Pre-existing production bugs surfaced by review".

-- =================================================================================
-- 1. canonical_production_department: STABLE SQL function, SECURITY INVOKER
--    by default. It reads production_departments, whose RLS policy is
--    "Staff can read production_departments" (USING is_internal_staff(uid)).
--    A non-staff authenticated caller -- who legitimately has SELECT on
--    products_canonical_department (GRANT SELECT ... TO authenticated,
--    security_invoker view) -- gets RLS-blocked on the underlying lookup and
--    silently receives NULL instead of the real department code, which the
--    view's own contract documents as "needs reconciliation", a false
--    positive.
--
--    The function returns only a single department code (reference/lookup
--    data, not sensitive), so SECURITY DEFINER with an empty search_path is
--    safe least-privilege here: it resolves the mapping for any caller
--    without granting broader access to production_departments itself.
--
-- Full definition reproduced from the last effective version
-- (supabase/migrations/20260817214000_fwd_rgs_department_taxonomy.sql)
-- with only LANGUAGE/SECURITY changed (sql -> plpgsql was not required;
-- SQL functions support SECURITY DEFINER directly).
-- =================================================================================

CREATE OR REPLACE FUNCTION public.canonical_production_department(_value text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT code
  FROM public.production_departments
  WHERE lower(_value) = ANY (SELECT lower(unnest(legacy_values)))
     OR upper(_value) = code
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.canonical_production_department(text) IS
  'Normalises any legacy or canonical department spelling to its canonical production_departments.code. Returns NULL for unmapped/unknown input -- callers must treat NULL as "needs reconciliation", never silently default it. SECURITY DEFINER: resolves for any authenticated caller despite production_departments RLS being staff-only, since only a single non-sensitive code is returned.';

-- =================================================================================
-- 2. quick_log_production_to_rgs: sets assigned_qty = p_produced_qty for the
--    ad-hoc production_jobs row it creates. declare_production_ready (called
--    immediately after) rejects when produced_qty + wasted_qty exceeds
--    assigned_qty * 1.1 -- with assigned_qty pinned to produced_qty, any
--    wastage above 10% of produced quantity spuriously fails a legitimate
--    quick-log call. The correct assigned quantity for an ad-hoc job is what
--    was actually produced plus what was legitimately wasted producing it.
--
-- Full definition reproduced from the last effective version
-- (supabase/migrations/20260817224000_fwd_rgs_authority_hardening.sql)
-- with only the assigned_qty value changed.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.quick_log_production_to_rgs(
  p_product_id uuid,
  p_department text,
  p_produced_qty numeric,
  p_wasted_qty numeric,
  p_correlation_id text,
  p_batch_number text DEFAULT NULL
)
RETURNS public.production_rgs_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_canonical_department text;
  v_job_id uuid;
  v_batch_number text;
  v_transfer public.production_rgs_transfers%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_produced_qty IS NULL OR p_produced_qty <= 0 THEN
    RAISE EXCEPTION 'Produced quantity must be positive';
  END IF;

  -- Idempotent replay: a retried quick-log call with the same correlation id
  -- returns the transfer it already produced.
  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE correlation_id = p_correlation_id;
  IF FOUND THEN RETURN v_transfer; END IF;

  v_canonical_department := public.canonical_production_department(p_department);
  IF v_canonical_department IS NULL THEN
    RAISE EXCEPTION 'Unknown production department %', p_department;
  END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_canonical_department USING ERRCODE = '42501';
  END IF;
  v_batch_number := coalesce(p_batch_number, 'QLOG-' || to_char(now(), 'YYYYMMDD') || '-' || substr(p_correlation_id, 1, 8));

  INSERT INTO public.production_jobs (
    order_id, product_id, department, requested_by, assigned_qty, priority, status, stage,
    started_at, batch_number, correlation_id
  ) VALUES (
    NULL, p_product_id, v_canonical_department, v_actor_id, p_produced_qty + coalesce(p_wasted_qty, 0), 'normal', 'in_production', 'processing',
    now(), v_batch_number, p_correlation_id || ':job'
  )
  RETURNING id INTO v_job_id;

  INSERT INTO public.production_job_outputs (job_id, produced_qty, wasted_qty, batch_number, recorded_by, correlation_id)
  VALUES (v_job_id, p_produced_qty, coalesce(p_wasted_qty, 0), v_batch_number, v_actor_id, p_correlation_id || ':output');

  INSERT INTO public.daily_production_logs (product_id, produced_qty, wastage_qty, department, logged_by)
  VALUES (p_product_id, p_produced_qty, coalesce(p_wasted_qty, 0), v_canonical_department, v_actor_id);

  PERFORM public.declare_production_ready(v_job_id, p_correlation_id || ':ready');

  SELECT * INTO v_transfer FROM public.dispatch_production_to_rgs(v_job_id, p_produced_qty, p_correlation_id);

  RETURN v_transfer;
END;
$$;

-- =================================================================================
-- Grants unchanged from the last effective version of each function
-- (CREATE OR REPLACE FUNCTION preserves existing ACLs, so these are
-- functionally no-ops); restated explicitly per migration governance, which
-- requires every migration creating SECURITY DEFINER code to carry its own
-- REVOKE ALL / GRANT EXECUTE pair rather than relying on inherited grants.
-- =================================================================================

REVOKE ALL ON FUNCTION public.canonical_production_department(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.canonical_production_department(text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) TO authenticated;
