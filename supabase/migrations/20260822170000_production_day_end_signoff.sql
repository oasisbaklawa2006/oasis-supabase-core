-- Production day-end closure: owner decision (this session's operations-
-- closure programme). Verbatim owner ruling, paraphrased for the schema:
--
--   Day-end is an accountability CHECKPOINT, not job closure. Do NOT
--   automatically close/cancel/reset/complete a production_jobs row merely
--   because a shift/day ends -- open jobs legitimately roll forward in
--   their existing operational state, unmodified by this migration. Day-end
--   is a separate governed accountability record: at day-end the system
--   compiles, department-wise, a real (never fabricated) snapshot covering
--   opening/pending jobs, jobs received, required/produced/wasted
--   quantities, completed/WIP/paused jobs, shortages, batches, goods
--   declared ready, goods handed to RGS, handovers awaiting RGS
--   acknowledgement, material still under department custody, urgent jobs
--   outstanding, and open escalations (production_issues, closed by the
--   preceding migration). The HOD/in-charge reviews this, adds exception
--   notes, and signs. The signed record is actor/time-bound and immutable;
--   a correction is a new record referencing the one it corrects, never a
--   silent edit. The next day's opening position is derived live from
--   production_jobs' actual current state (jobs are never mutated, so
--   nothing needs to be manually re-entered) rather than from the stored
--   snapshot -- the snapshot is the audit trail, not the source of truth.
--
-- No new role: authority is the existing user_canonical_department() (a
-- HOD's own department) plus the existing admin/production-manager roles,
-- exactly mirroring how create_production_shortage_demand /
-- start_production_job already gate department-scoped actions.

CREATE TABLE IF NOT EXISTS public.production_day_end_signoffs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  department text NOT NULL REFERENCES public.production_departments (code),
  business_date date NOT NULL,
  summary jsonb NOT NULL,
  exception_notes text NULL,
  signed_by uuid NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  signed_at timestamptz NOT NULL DEFAULT now(),
  corrects_signoff_id uuid NULL REFERENCES public.production_day_end_signoffs (id) ON DELETE RESTRICT,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- Monotonic tiebreaker: within a single transaction now() is constant
  -- (it's the transaction start time), so a correction submitted in the
  -- same transaction as its original would tie on created_at. A bigserial
  -- is always strictly increasing regardless of transaction timing.
  signoff_seq bigserial NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_production_day_end_signoffs_dept_date
  ON public.production_day_end_signoffs (department, business_date, signoff_seq DESC);

-- production_issues has no trigger-maintained canonical_department column
-- (unlike production_jobs), so the escalations_open subquery below still
-- calls canonical_production_department(department) per row -- index that
-- exact call shape so it isn't a sequential scan.
CREATE INDEX IF NOT EXISTS idx_production_issues_canonical_department
  ON public.production_issues (public.canonical_production_department(department))
  WHERE status = 'open';

ALTER TABLE public.production_day_end_signoffs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Staff can read production day-end signoffs"
  ON public.production_day_end_signoffs FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

REVOKE ALL ON TABLE public.production_day_end_signoffs FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.production_day_end_signoffs TO authenticated;

-- Immutable: a submitted signoff is never edited or deleted. A correction
-- is always a new row (corrects_signoff_id) preserving the original.
CREATE OR REPLACE FUNCTION public.prevent_production_day_end_signoff_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'production_day_end_signoffs is append-only -- submit a correcting signoff instead' USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE TRIGGER trg_production_day_end_signoffs_no_update
  BEFORE UPDATE ON public.production_day_end_signoffs
  FOR EACH ROW EXECUTE FUNCTION public.prevent_production_day_end_signoff_mutation();
CREATE OR REPLACE TRIGGER trg_production_day_end_signoffs_no_delete
  BEFORE DELETE ON public.production_day_end_signoffs
  FOR EACH ROW EXECUTE FUNCTION public.prevent_production_day_end_signoff_mutation();

-- Latest signoff per department/day (whether or not it has since been
-- corrected) -- callers should read this, not the raw table, to see the
-- currently-authoritative record.
CREATE OR REPLACE VIEW public.production_day_end_current AS
SELECT DISTINCT ON (department, business_date)
  id, department, business_date, summary, exception_notes, signed_by, signed_at,
  corrects_signoff_id, correlation_id, created_at, signoff_seq
FROM public.production_day_end_signoffs
ORDER BY department, business_date, signoff_seq DESC;

ALTER VIEW public.production_day_end_current SET (security_invoker = true);
GRANT SELECT ON public.production_day_end_current TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_production_day_end(
  p_department text,
  p_business_date date,
  p_exception_notes text DEFAULT NULL,
  p_corrects_signoff_id uuid DEFAULT NULL,
  p_correlation_id text DEFAULT NULL
)
RETURNS public.production_day_end_signoffs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_actor_dept text;
  v_canonical_dept text;
  v_correlation_id text := nullif(btrim(coalesce(p_correlation_id, '')), '');
  v_existing public.production_day_end_signoffs%ROWTYPE;
  v_corrects public.production_day_end_signoffs%ROWTYPE;
  v_summary jsonb;
  v_signoff public.production_day_end_signoffs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to submit a production day-end signoff' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION 'A business date is required';
  END IF;
  IF p_business_date > current_date THEN
    RAISE EXCEPTION 'Cannot sign off a future business date';
  END IF;

  v_canonical_dept := public.canonical_production_department(p_department);
  IF v_canonical_dept IS NULL THEN
    RAISE EXCEPTION 'Unknown production department %', p_department;
  END IF;

  SELECT upper(role) INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  v_actor_dept := public.role_canonical_department(v_actor_role);
  IF v_actor_dept IS DISTINCT FROM v_canonical_dept
     AND v_actor_role NOT IN ('SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised to sign off department %', v_canonical_dept USING ERRCODE = '42501';
  END IF;

  -- Idempotent by correlation_id: a retried submission returns the same
  -- signed record rather than creating a second one -- but only if it's
  -- genuinely a retry of *this* department/date, not a correlation_id
  -- accidentally reused for a different signoff (which would otherwise
  -- silently report success against the wrong record).
  SELECT * INTO v_existing FROM public.production_day_end_signoffs WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    IF v_existing.department <> v_canonical_dept OR v_existing.business_date <> p_business_date THEN
      RAISE EXCEPTION 'correlation_id % is already in use by a different department or business date', v_correlation_id;
    END IF;
    RETURN v_existing;
  END IF;

  IF p_corrects_signoff_id IS NOT NULL THEN
    SELECT * INTO v_corrects FROM public.production_day_end_signoffs WHERE id = p_corrects_signoff_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Signoff to correct % not found', p_corrects_signoff_id;
    END IF;
    IF v_corrects.department <> v_canonical_dept OR v_corrects.business_date <> p_business_date THEN
      RAISE EXCEPTION 'A correction must reference a signoff for the same department and business date';
    END IF;
  END IF;

  -- Real, non-fabricated department-wise snapshot computed live from the
  -- existing governed schema -- never a duplicate of operational truth.
  -- "pj.canonical_department = v_canonical_dept" everywhere below uses the
  -- trigger-maintained, indexed column from the department-taxonomy
  -- migration (idx_production_jobs_canonical_department) rather than
  -- calling canonical_production_department(pj.department) per row.
  -- production_issues has no equivalent maintained column yet, so the
  -- escalations_open subquery below still calls the function directly
  -- against an index built for that call shape.
  SELECT jsonb_build_object(
    'department', v_canonical_dept,
    'business_date', p_business_date,
    'opening_pending_jobs', (
      SELECT count(*) FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.status = 'pending'
    ),
    'jobs_received_today', (
      SELECT count(*) FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.created_at >= p_business_date AND pj.created_at < p_business_date + interval '1 day'
    ),
    'quantity_required_today', (
      SELECT coalesce(sum(pj.assigned_qty), 0) FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.created_at >= p_business_date AND pj.created_at < p_business_date + interval '1 day'
    ),
    'quantity_produced_today', (
      SELECT coalesce(sum(pjo.produced_qty), 0)
      FROM public.production_job_outputs pjo
      JOIN public.production_jobs pj ON pj.id = pjo.job_id
      WHERE pj.canonical_department = v_canonical_dept
        AND pjo.created_at >= p_business_date AND pjo.created_at < p_business_date + interval '1 day'
    ),
    'wastage_today', (
      SELECT coalesce(sum(pjo.wasted_qty), 0)
      FROM public.production_job_outputs pjo
      JOIN public.production_jobs pj ON pj.id = pjo.job_id
      WHERE pj.canonical_department = v_canonical_dept
        AND pjo.created_at >= p_business_date AND pjo.created_at < p_business_date + interval '1 day'
    ),
    'batches_recorded_today', (
      SELECT coalesce(jsonb_agg(DISTINCT pjo.batch_number), '[]'::jsonb)
      FROM public.production_job_outputs pjo
      JOIN public.production_jobs pj ON pj.id = pjo.job_id
      WHERE pj.canonical_department = v_canonical_dept
        AND pjo.created_at >= p_business_date AND pjo.created_at < p_business_date + interval '1 day'
        AND pjo.batch_number IS NOT NULL
    ),
    'completed_jobs_today', (
      SELECT count(*) FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.status = 'completed' AND pj.completed_at >= p_business_date AND pj.completed_at < p_business_date + interval '1 day'
    ),
    'goods_declared_ready_today', (
      SELECT count(*) FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.status = 'completed' AND pj.stage = 'ready' AND pj.completed_at >= p_business_date AND pj.completed_at < p_business_date + interval '1 day'
    ),
    'shortfall_completed_jobs', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'job_id', pj.id, 'batch_number', pj.batch_number,
        'assigned_qty', pj.assigned_qty, 'produced_qty', pj.produced_qty
      )), '[]'::jsonb)
      FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.status = 'completed' AND pj.completed_at >= p_business_date AND pj.completed_at < p_business_date + interval '1 day'
        AND coalesce(pj.produced_qty, 0) < pj.assigned_qty
    ),
    'wip_jobs', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'job_id', pj.id, 'status', pj.status, 'stage', pj.stage,
        'assigned_qty', pj.assigned_qty, 'produced_qty', coalesce(pj.produced_qty, 0),
        'balance_qty', pj.assigned_qty - coalesce(pj.produced_qty, 0)
      )), '[]'::jsonb)
      FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.status IN ('accepted', 'in_production')
    ),
    'paused_jobs', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'job_id', pp.job_id, 'reason', pp.reason, 'comment', pp.comment, 'paused_at', pp.paused_at
      )), '[]'::jsonb)
      FROM public.production_pauses pp
      JOIN public.production_jobs pj ON pj.id = pp.job_id
      WHERE pj.canonical_department = v_canonical_dept
        AND pp.resumed_at IS NULL
    ),
    'material_under_department_custody', (
      SELECT coalesce(sum(pj.assigned_qty - coalesce(pj.produced_qty, 0)), 0)
      FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.status NOT IN ('completed', 'transferred', 'rejected')
    ),
    'urgent_jobs_outstanding', (
      SELECT count(*) FROM public.production_jobs pj
      WHERE pj.canonical_department = v_canonical_dept
        AND pj.priority IN ('urgent', 'red')
        AND pj.status NOT IN ('completed', 'transferred', 'rejected')
    ),
    'goods_handed_to_rgs_today', (
      SELECT coalesce(sum(prt.quantity), 0)
      FROM public.production_rgs_transfers prt
      JOIN public.production_jobs pj ON pj.id = prt.job_id
      WHERE pj.canonical_department = v_canonical_dept
        AND prt.created_at >= p_business_date AND prt.created_at < p_business_date + interval '1 day'
    ),
    'handovers_awaiting_rgs_acknowledgement', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'job_id', prt.job_id, 'status', prt.status, 'quantity', prt.quantity, 'created_at', prt.created_at
      )), '[]'::jsonb)
      FROM public.production_rgs_transfers prt
      JOIN public.production_jobs pj ON pj.id = prt.job_id
      WHERE pj.canonical_department = v_canonical_dept
        AND prt.status NOT IN ('accepted', 'rejected', 'cancelled')
    ),
    'escalations_open', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'issue_id', pi.id, 'job_id', pi.job_id, 'issue_type', pi.issue_type, 'comment', pi.comment, 'created_at', pi.created_at
      )), '[]'::jsonb)
      FROM public.production_issues pi
      WHERE public.canonical_production_department(pi.department) = v_canonical_dept
        AND pi.status = 'open'
    )
  ) INTO v_summary;

  BEGIN
    INSERT INTO public.production_day_end_signoffs (
      department, business_date, summary, exception_notes, signed_by, corrects_signoff_id, correlation_id
    ) VALUES (
      v_canonical_dept, p_business_date, v_summary, nullif(btrim(coalesce(p_exception_notes, '')), ''),
      v_actor_id, p_corrects_signoff_id, v_correlation_id
    )
    RETURNING * INTO v_signoff;
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.production_day_end_signoffs WHERE correlation_id = v_correlation_id;
    IF FOUND THEN
      RETURN v_existing;
    END IF;
    RAISE;
  END;

  PERFORM public.append_operational_event_v1(
    p_event_type := 'production_day_end_signed',
    p_entity_type := 'production_day_end_signoff',
    p_entity_id := v_signoff.id,
    p_title := 'Production day-end signed: ' || v_canonical_dept || ' (' || p_business_date::text || ')',
    p_source_application := 'production',
    p_correlation_id := v_correlation_id,
    p_actor_id := v_actor_id,
    p_actor_department := v_canonical_dept,
    p_severity := CASE WHEN v_signoff.exception_notes IS NOT NULL THEN 'warning' ELSE 'info' END,
    p_message := v_signoff.exception_notes,
    p_idempotency_key := 'production-day-end:' || v_signoff.id::text
  );

  RETURN v_signoff;
END;
$$;

COMMENT ON FUNCTION public.submit_production_day_end(text, date, text, uuid, text) IS
  'Department-wise day-end accountability checkpoint -- never mutates production_jobs (open jobs roll forward unmodified). Compiles a real, non-fabricated summary live from production_jobs/production_job_outputs/production_pauses/production_rgs_transfers/production_issues, requires HOD/production-manager authority for the target department (via the existing canonical-department taxonomy, no new role), and is append-only: a correction is a new row via p_corrects_signoff_id, never an edit. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.submit_production_day_end(text, date, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_production_day_end(text, date, text, uuid, text) TO authenticated;
