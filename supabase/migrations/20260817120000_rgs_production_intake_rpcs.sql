-- RGS + Production reconciliation, step 2c: job intake accept/reject RPCs.
-- Central's PHH JobIntakeTab.tsx performs pending -> accepted / pending ->
-- rejected transitions as direct production_jobs writes, also broken by the
-- REVOKE in 20260817100000. Close this gap the same way as the pause/resume/
-- stage-advance gap closed in 20260817110000.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.accept_production_job(
  p_job_id uuid,
  p_batch_number text,
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
  IF v_actor_id IS NULL OR NOT public.is_staff_role(v_actor_role) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF v_job.status = 'accepted' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'pending' THEN
    RAISE EXCEPTION 'Job is not pending';
  END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;

  UPDATE public.production_jobs
  SET status = 'accepted', assigned_to = v_actor_id,
      batch_number = coalesce(p_batch_number, batch_number), updated_at = now()
  WHERE id = p_job_id
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
  v_job public.production_jobs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_rejection_reason), '') IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
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

REVOKE ALL ON FUNCTION public.accept_production_job(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reject_production_job(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_production_job(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_production_job(uuid, text, text) TO authenticated;
