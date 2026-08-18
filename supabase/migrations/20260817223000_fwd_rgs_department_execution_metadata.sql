-- Forward-only replacement of supabase/migrations/20260817140000_rgs_department_execution_metadata.sql.
-- The original was merged to Core main (PR #83) but never applied to production
-- (tcxvcatsqqertcnycuop) because its historical timestamp sits below the current
-- production ledger max (20260817211610, from an unrelated WhatsApp deploy that
-- landed out of band). Per the Controlled Supabase Production Release runbook,
-- a migration below production max must never be pushed under its original
-- timestamp; this is the same content, forward-timestamped, unmodified.
-- Original: supabase/migrations/20260817140000_rgs_department_execution_metadata.sql -- content preserved verbatim below.

-- RGS + Production reconciliation, step 3: department-specific execution
-- metadata, without building six disconnected department apps.
--
-- The handover asks each of the six Production departments to capture
-- different execution fields (Arabic Sweets: bake/syrup stage, nut variant;
-- Chocolates & Confectionery: tempering/coating stage; Fusion Sweets:
-- recipe/cooking stage; Seasoned Nuts & Mixes: roast/seasoning profile;
-- Dates: variety/grade/filling; Bakery & Semi-Prepared: dough/bake/freeze
-- stage) while explicitly warning not to build six disconnected apps.
--
-- Rather than six rigid per-department table shapes, production_job_outputs
-- gains one flexible, schema-validated jsonb column. The common PHH shell in
-- Central renders the right fields per department from a shared config
-- (departmentExecutionFields.ts); this migration only needs to accept and
-- preserve whatever that shell captures, keyed by canonical department code
-- so a payload can never silently apply to the wrong department's schema.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.production_job_outputs
  ADD COLUMN IF NOT EXISTS execution_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.production_job_outputs.execution_metadata IS
  'Department-specific execution fields (bake stage, tempering stage, roast profile, etc.) captured by the common PHH shell per production_departments.code. Schema is intentionally flexible per department rather than one rigid table per department -- see departmentExecutionFields.ts in oasis-baklawa-central for the field definitions each department renders.';

-- CREATE OR REPLACE cannot change a function's parameter list; the prior
-- 6-parameter signature from 20260817100000 must be dropped explicitly or
-- it coexists as an ambiguous overload with this 7-parameter version.
DROP FUNCTION IF EXISTS public.record_production_output(uuid, numeric, numeric, text, text, text);

CREATE OR REPLACE FUNCTION public.record_production_output(
  p_job_id uuid,
  p_produced_qty numeric,
  p_wasted_qty numeric,
  p_batch_number text,
  p_correlation_id text,
  p_notes text DEFAULT NULL,
  p_execution_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS public.production_job_outputs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.production_jobs%ROWTYPE;
  v_output public.production_job_outputs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF coalesce(p_produced_qty, 0) < 0 OR coalesce(p_wasted_qty, 0) < 0 THEN
    RAISE EXCEPTION 'Quantities cannot be negative';
  END IF;
  IF p_execution_metadata IS NOT NULL AND jsonb_typeof(p_execution_metadata) <> 'object' THEN
    RAISE EXCEPTION 'Execution metadata must be a JSON object';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF v_job.status <> 'in_production' THEN
    RAISE EXCEPTION 'Job is not in production';
  END IF;

  INSERT INTO public.production_job_outputs (
    job_id, produced_qty, wasted_qty, batch_number, notes, recorded_by, correlation_id, execution_metadata
  ) VALUES (
    p_job_id, coalesce(p_produced_qty, 0), coalesce(p_wasted_qty, 0), p_batch_number, p_notes, v_actor_id, p_correlation_id,
    coalesce(p_execution_metadata, '{}'::jsonb)
  )
  ON CONFLICT (correlation_id) DO NOTHING
  RETURNING * INTO v_output;

  IF v_output.id IS NULL THEN
    -- Idempotent replay: identical retried call, return what was already recorded.
    SELECT * INTO v_output FROM public.production_job_outputs WHERE correlation_id = p_correlation_id;
  END IF;

  RETURN v_output;
END;
$$;

-- DROP FUNCTION resets privileges to owner-only; restore the authenticated
-- grant this RPC has carried since 20260817100000.
REVOKE ALL ON FUNCTION public.record_production_output(uuid, numeric, numeric, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_production_output(uuid, numeric, numeric, text, text, text, jsonb) TO authenticated;
