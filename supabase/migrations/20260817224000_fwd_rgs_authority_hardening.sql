-- Forward-only replacement of supabase/migrations/20260817150000_rgs_authority_hardening.sql.
-- The original was merged to Core main (PR #83) but never applied to production
-- (tcxvcatsqqertcnycuop) because its historical timestamp sits below the current
-- production ledger max (20260817211610, from an unrelated WhatsApp deploy that
-- landed out of band). Per the Controlled Supabase Production Release runbook,
-- a migration below production max must never be pushed under its original
-- timestamp; this is the same content, forward-timestamped, unmodified.
-- Original: supabase/migrations/20260817150000_rgs_authority_hardening.sql -- content preserved verbatim below.

-- RGS + Production reconciliation, step 4: authority + idempotency hardening
-- requested in review of PR #83 (head 9a6ec92).
--
-- Two real gaps in the governed authority added by this branch:
--
-- 1. advance_production_job_stage accepted p_correlation_id but never
--    persisted or checked it, so a retried request could silently advance
--    a job's stage twice (e.g. skip prep -> processing -> finishing in one
--    replayed call). Fixed with a durable transition ledger
--    (production_job_stage_transitions) keyed uniquely on correlation_id,
--    matching the check-first-return-early idempotency pattern already
--    used by reserve_rgs_stock / dispatch_production_to_rgs.
--
-- 2. Several SECURITY DEFINER production mutation RPCs authorised only via
--    is_internal_staff() -- any internal staff role, not just the job's own
--    department -- preserving the blanket-write authority this branch was
--    meant to replace. record_production_output, declare_production_ready,
--    pause_production_job, resume_production_job, advance_production_job_stage
--    and reject_production_job now fail closed with the same
--    role_canonical_department() department-match check start_production_job
--    and accept_production_job already had. quick_log_production_to_rgs now
--    validates the actor's own department against the department it is
--    logging for, not just that the department string is canonically
--    mappable to *some* department.
--
-- Also hardens record_rgs_receipt and acknowledge_rgs_issue, which accepted
-- correlation ids but never used them for replay: a successful request
-- retried after a lost response would previously raise "already received" /
-- "already acknowledged" instead of returning the original result.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 1. Durable stage-transition ledger + idempotent, department-scoped
--    advance_production_job_stage.
-- =================================================================================

CREATE TABLE IF NOT EXISTS public.production_job_stage_transitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.production_jobs(id) ON DELETE CASCADE,
  from_stage text NOT NULL,
  to_stage text NOT NULL,
  advanced_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  correlation_id text NOT NULL,
  advanced_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_production_job_stage_transitions_correlation UNIQUE (correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_production_job_stage_transitions_job_id ON public.production_job_stage_transitions (job_id);
ALTER TABLE public.production_job_stage_transitions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Staff can read production_job_stage_transitions" ON public.production_job_stage_transitions;
CREATE POLICY "Staff can read production_job_stage_transitions" ON public.production_job_stage_transitions
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));
REVOKE ALL ON public.production_job_stage_transitions FROM anon, authenticated;
GRANT SELECT ON public.production_job_stage_transitions TO authenticated;

COMMENT ON TABLE public.production_job_stage_transitions IS
  'Append-only, correlation-id-deduplicated ledger backing advance_production_job_stage. A retried call with the same correlation_id returns the job unchanged instead of advancing the stage a second time.';

CREATE OR REPLACE FUNCTION public.advance_production_job_stage(
  p_job_id uuid,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
  v_stages text[] := ARRAY['prep', 'processing', 'finishing', 'ready'];
  v_idx integer;
  v_existing_job_id uuid;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  -- Idempotent replay: a retried call with the same correlation id returns
  -- the job unchanged rather than advancing the stage a second time.
  SELECT job_id INTO v_existing_job_id
  FROM public.production_job_stage_transitions WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    SELECT * INTO v_job FROM public.production_jobs WHERE id = v_existing_job_id;
    RETURN v_job;
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status NOT IN ('in_production', 'paused') THEN
    RAISE EXCEPTION 'Job is not active';
  END IF;

  v_idx := array_position(v_stages, v_job.stage);
  IF v_idx IS NULL OR v_idx >= array_length(v_stages, 1) THEN
    RETURN v_job; -- already at the final stage; no-op, no transition recorded
  END IF;

  INSERT INTO public.production_job_stage_transitions (job_id, from_stage, to_stage, advanced_by, correlation_id)
  VALUES (p_job_id, v_job.stage, v_stages[v_idx + 1], v_actor_id, p_correlation_id);

  UPDATE public.production_jobs SET stage = v_stages[v_idx + 1], updated_at = now() WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- =================================================================================
-- 2. Department-scoped authorisation for the remaining production mutation RPCs.
--    Signatures are unchanged; only the internal authorisation check changes,
--    so CREATE OR REPLACE applies cleanly without a DROP FUNCTION first.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.pause_production_job(
  p_job_id uuid,
  p_reason text,
  p_comment text,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF p_reason NOT IN ('machine_breakdown', 'material_shortage', 'other') THEN
    RAISE EXCEPTION 'Unknown pause reason %', p_reason;
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'paused' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'in_production' THEN
    RAISE EXCEPTION 'Job is not in production';
  END IF;

  INSERT INTO public.production_pauses (job_id, reason, comment, paused_by)
  VALUES (p_job_id, p_reason, p_comment, v_actor_id);

  UPDATE public.production_jobs SET status = 'paused', updated_at = now() WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.resume_production_job(
  p_job_id uuid,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'in_production' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'paused' THEN
    RAISE EXCEPTION 'Job is not paused';
  END IF;

  UPDATE public.production_pauses SET resumed_at = now() WHERE job_id = p_job_id AND resumed_at IS NULL;
  UPDATE public.production_jobs SET status = 'in_production', updated_at = now() WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_production_job(
  p_job_id uuid,
  p_rejection_reason text,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_rejection_reason), '') IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'rejected' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'pending' THEN
    RAISE EXCEPTION 'Job is not pending';
  END IF;

  UPDATE public.production_jobs
  SET status = 'rejected', rejection_reason = p_rejection_reason, updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

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
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
  v_output public.production_job_outputs%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
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
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
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

CREATE OR REPLACE FUNCTION public.declare_production_ready(
  p_job_id uuid,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'completed' THEN
    RETURN v_job; -- idempotent replay: already declared ready
  END IF;
  IF v_job.status <> 'in_production' THEN
    RAISE EXCEPTION 'Job is not in production';
  END IF;
  IF v_job.produced_qty IS NULL OR v_job.produced_qty <= 0 THEN
    RAISE EXCEPTION 'Cannot declare ready with no recorded output';
  END IF;
  IF v_job.produced_qty + coalesce(v_job.wasted_qty, 0) > v_job.assigned_qty * 1.1 THEN
    RAISE EXCEPTION 'Produced + wasted exceeds assigned quantity tolerance';
  END IF;

  UPDATE public.production_jobs
  SET status = 'completed', stage = 'ready', completed_at = now(), locked = true, updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- =================================================================================
-- 3. quick_log_production_to_rgs: the actor's own department must match the
--    department they are logging ad-hoc output for.
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
    NULL, p_product_id, v_canonical_department, v_actor_id, p_produced_qty, 'normal', 'in_production', 'processing',
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
-- 4. Idempotent record_rgs_receipt / acknowledge_rgs_issue: a retried request
--    after a lost response now returns the original result instead of
--    raising "already received" / "already acknowledged".
-- =================================================================================

ALTER TABLE public.production_rgs_transfers
  ADD COLUMN IF NOT EXISTS received_correlation_id text NULL;

CREATE OR REPLACE FUNCTION public.record_rgs_receipt(
  p_transfer_id uuid,
  p_received_qty numeric,
  p_correlation_id text
)
RETURNS public.production_rgs_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_transfer public.production_rgs_transfers%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to record RGS receipts' USING ERRCODE = '42501';
  END IF;
  IF p_received_qty IS NULL OR p_received_qty < 0 THEN
    RAISE EXCEPTION 'Received quantity cannot be negative';
  END IF;

  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status = 'received' AND v_transfer.received_correlation_id = p_correlation_id THEN
    RETURN v_transfer; -- idempotent replay
  END IF;
  IF v_transfer.status <> 'in_transit' THEN
    RAISE EXCEPTION 'Transfer has already been received or closed';
  END IF;

  UPDATE public.production_rgs_transfers
  SET status = 'received', received_qty = p_received_qty, received_by = v_actor_id, received_at = now(),
      received_correlation_id = p_correlation_id
  WHERE id = p_transfer_id
  RETURNING * INTO v_transfer;

  RETURN v_transfer;
END;
$$;

ALTER TABLE public.rgs_issue_events
  ADD COLUMN IF NOT EXISTS acknowledged_correlation_id text NULL;

CREATE OR REPLACE FUNCTION public.acknowledge_rgs_issue(
  p_issue_id uuid,
  p_acknowledged_qty numeric,
  p_correlation_id text
)
RETURNS public.rgs_issue_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_issue public.rgs_issue_events%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_issue FROM public.rgs_issue_events WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Issue event not found'; END IF;
  IF v_issue.status <> 'issued' AND v_issue.acknowledged_correlation_id = p_correlation_id THEN
    RETURN v_issue; -- idempotent replay
  END IF;
  IF v_issue.status <> 'issued' THEN
    RAISE EXCEPTION 'Issue has already been acknowledged';
  END IF;

  UPDATE public.rgs_issue_events
  SET acknowledged_qty = p_acknowledged_qty, acknowledged_by = v_actor_id, acknowledged_at = now(),
      acknowledged_correlation_id = p_correlation_id,
      status = CASE WHEN p_acknowledged_qty = issued_qty THEN 'acknowledged' ELSE 'variance' END
  WHERE id = p_issue_id
  RETURNING * INTO v_issue;

  RETURN v_issue;
END;
$$;

-- =================================================================================
-- 5. Restore grants (CREATE OR REPLACE preserves privileges when the
--    signature is unchanged, but re-asserted here defensively since several
--    of these were touched).
-- =================================================================================

GRANT EXECUTE ON FUNCTION public.advance_production_job_stage(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pause_production_job(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resume_production_job(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_production_job(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_production_output(uuid, numeric, numeric, text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.declare_production_ready(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_rgs_receipt(uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_rgs_issue(uuid, numeric, text) TO authenticated;
REVOKE ALL ON FUNCTION public.advance_production_job_stage(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pause_production_job(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resume_production_job(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reject_production_job(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_production_output(uuid, numeric, numeric, text, text, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.declare_production_ready(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.quick_log_production_to_rgs(uuid, text, numeric, numeric, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_rgs_receipt(uuid, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.acknowledge_rgs_issue(uuid, numeric, text) FROM PUBLIC, anon;
