-- Lane 1 B1 (Central issue #368): TV kiosk accounts must be provably
-- read-only. is_staff_role()'s allowlist -- correctly used for read-side
-- and general "is this a real staff account" checks -- also includes the
-- four TV display accounts ('TV_DISPLAY', 'TV_ASSEMBLY', 'TV_READY',
-- 'TV_DRAGEES'), commented in its own definition as "read-only wall
-- screens". Two governed production-lifecycle RPCs gate solely on
-- is_staff_role() and therefore currently accept a TV-authenticated caller:
--
--   - public.start_production_job (20260817215000_fwd_rgs_production_governed_authority.sql)
--   - public.accept_production_job (20260819100000_fwd_rgs_authorization_idempotency_hardening.sql)
--
-- Every other governed RGS/production RPC checked (record_production_output,
-- declare_production_ready, pause/resume/reject_production_job,
-- quick_log_production_to_rgs, record_rgs_receipt, acknowledge_rgs_issue,
-- reserve_rgs_stock, release_rgs_reservation, pick_rgs_reservation,
-- issue_rgs_stock, dispatch_production_to_rgs, accept_rgs_production_receipt)
-- gates on is_internal_staff(), whose allowlist never included any TV_*
-- role -- those are already safe.
--
-- Forward-only correction, per this repo's convention: is_staff_role()
-- itself is deliberately NOT redefined (it is also relied on by
-- customer_identity_projections_v1.sql's `not is_staff_role(role)` check to
-- exclude staff from customer projections; narrowing it would misclassify
-- TV accounts as customers). Instead a new, narrowly-scoped
-- is_tv_display_role() predicate is added, and the two exposed RPCs are
-- reproduced in full from their last effective version with one additional
-- guard clause.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.is_tv_display_role(_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (
    ARRAY['TV_DISPLAY', 'TV_ASSEMBLY', 'TV_READY', 'TV_DRAGEES']
  );
$$;

COMMENT ON FUNCTION public.is_tv_display_role(text) IS
  'True for the four read-only TV kiosk accounts (Central issue #368 six-TV estate). Governed mutating RPCs must reject these callers even when is_staff_role() would otherwise accept them.';

REVOKE ALL ON FUNCTION public.is_tv_display_role(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_tv_display_role(text) TO authenticated, service_role;

-- Full definition reproduced from the last effective version
-- (20260817215000_fwd_rgs_production_governed_authority.sql) with only the
-- authorization guard changed.
CREATE OR REPLACE FUNCTION public.start_production_job(
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
  IF v_actor_id IS NULL OR NOT (public.is_staff_role(v_actor_role)) OR public.is_tv_display_role(v_actor_role) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;

  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'in_production' THEN
    RETURN v_job; -- idempotent replay: already started
  END IF;
  IF v_job.status NOT IN ('pending', 'accepted') THEN
    RAISE EXCEPTION 'Job is not in a startable state';
  END IF;

  UPDATE public.production_jobs
  SET status = 'in_production', stage = 'processing', started_at = now(),
      assigned_to = coalesce(assigned_to, v_actor_id), updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- Full definition reproduced from the last effective version
-- (20260819100000_fwd_rgs_authorization_idempotency_hardening.sql) with
-- only the authorization guard changed.
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
  IF v_actor_id IS NULL OR NOT public.is_staff_role(v_actor_role) OR public.is_tv_display_role(v_actor_role) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'accepted' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'pending' THEN
    RAISE EXCEPTION 'Job is not pending';
  END IF;

  UPDATE public.production_jobs
  SET status = 'accepted', assigned_to = v_actor_id,
      batch_number = coalesce(p_batch_number, batch_number), updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;
