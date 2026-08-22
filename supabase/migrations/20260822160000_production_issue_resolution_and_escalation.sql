-- Production day-end/escalation audit finding (this session's operations-
-- closure programme): production_issues is a write-only sink -- issues get
-- reported (one direct client INSERT from the mobile handheld surface) but
-- the table has no lifecycle column at all, so nothing can ever be marked
-- resolved, and the existing escalation machinery (CMD War Room /
-- Execution Command Center, which reads operational_events and matches
-- event_type containing "escalat"/"failed" -- see
-- buildEscalationTopology()) never receives a single row from Production,
-- because nothing in this repo has ever called the existing
-- append_operational_event_v1() primitive for a production issue.
--
-- This migration closes both gaps narrowly, without inventing a new
-- escalation mechanism or a day-end/shift-close policy (that remains a
-- separate, genuine owner decision -- what counts as a shift boundary,
-- what happens to jobs still open at cutoff -- deliberately out of scope
-- here): it adds a minimal resolution lifecycle to production_issues, and
-- two governed RPCs (report + resolve) that plug straight into the
-- already-existing, already-wired-into-CMD-War-Room event bus.

ALTER TABLE public.production_issues
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS resolved_by uuid NULL,
  ADD COLUMN IF NOT EXISTS resolved_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS resolution_notes text NULL,
  ADD COLUMN IF NOT EXISTS correlation_id text NULL;

ALTER TABLE public.production_issues
  DROP CONSTRAINT IF EXISTS production_issues_status_check;
ALTER TABLE public.production_issues
  ADD CONSTRAINT production_issues_status_check CHECK (status IN ('open', 'resolved'));

ALTER TABLE public.production_issues
  DROP CONSTRAINT IF EXISTS production_issues_resolution_state_check;
ALTER TABLE public.production_issues
  ADD CONSTRAINT production_issues_resolution_state_check CHECK (
    (status = 'open' AND resolved_by IS NULL AND resolved_at IS NULL)
    OR (status = 'resolved' AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL AND resolution_notes IS NOT NULL)
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_production_issues_correlation_id
  ON public.production_issues (correlation_id) WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_production_issues_open
  ON public.production_issues (department, created_at) WHERE status = 'open';

-- Legacy grants on this table are broad (GRANT ALL ... TO anon/authenticated
-- from the original baseline migration), gated only by the existing
-- "Staff can manage production_issues" RLS policy (is_internal_staff). This
-- migration does not touch that -- narrowing 15+ pre-existing legacy grants
-- unrelated to this fix is a separate, larger initiative, consistent with
-- this programme's one-operation-at-a-time approach.

CREATE OR REPLACE FUNCTION public.report_production_issue(
  p_job_id uuid,
  p_department text,
  p_issue_type text,
  p_comment text,
  p_photo_url text DEFAULT NULL,
  p_correlation_id text DEFAULT NULL
)
RETURNS public.production_issues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_existing public.production_issues%ROWTYPE;
  v_issue public.production_issues%ROWTYPE;
  v_severity text;
  v_correlation_id text := nullif(btrim(coalesce(p_correlation_id, '')), '');
  v_job_department text;
  v_job_canonical_department text;
  v_canonical_dept text;
BEGIN
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to report a production issue' USING ERRCODE = '42501';
  END IF;
  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'A job_id is required';
  END IF;
  IF nullif(btrim(coalesce(p_department, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A department is required';
  END IF;
  IF p_issue_type NOT IN ('material', 'machine', 'delay') THEN
    RAISE EXCEPTION 'issue_type must be one of material, machine, delay';
  END IF;
  IF nullif(btrim(coalesce(p_comment, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A comment describing the issue is required';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT department, canonical_department INTO v_job_department, v_job_canonical_department
  FROM public.production_jobs WHERE id = p_job_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Production job % not found', p_job_id;
  END IF;

  -- Bind the reported department to the job's actual department -- a caller
  -- cannot report a job under a department it does not belong to, which
  -- would otherwise corrupt department-scoped escalation/day-end reporting.
  v_canonical_dept := public.canonical_production_department(p_department);
  IF v_canonical_dept IS NULL OR v_canonical_dept IS DISTINCT FROM v_job_canonical_department THEN
    RAISE EXCEPTION 'department % does not match production job %''s department', p_department, p_job_id;
  END IF;

  SELECT * INTO v_existing FROM public.production_issues WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  v_severity := CASE p_issue_type
    WHEN 'machine' THEN 'urgent'
    WHEN 'delay' THEN 'warning'
    ELSE 'warning'
  END;

  BEGIN
    INSERT INTO public.production_issues (
      job_id, department, issue_type, comment, photo_url, reported_by, correlation_id
    ) VALUES (
      p_job_id, v_job_department, p_issue_type, btrim(p_comment), p_photo_url, v_actor_id, v_correlation_id
    )
    RETURNING * INTO v_issue;
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.production_issues WHERE correlation_id = v_correlation_id;
    IF FOUND THEN
      RETURN v_existing;
    END IF;
    RAISE;
  END;

  -- event_type deliberately contains "escalation" so this surfaces in the
  -- existing CMD War Room / Execution Command Center escalation topology
  -- (buildEscalationTopology() matches event_type on "escalat"/"failed")
  -- without any new escalation mechanism -- Production plugs into the same
  -- bus every other department's escalations already flow through.
  PERFORM public.append_operational_event_v1(
    p_event_type := 'production_issue_escalation',
    p_entity_type := 'production_issue',
    p_entity_id := v_issue.id,
    p_title := 'Production issue: ' || p_issue_type || ' (' || v_job_department || ')',
    p_source_application := 'production',
    p_correlation_id := v_correlation_id,
    p_actor_id := v_actor_id,
    p_actor_department := v_job_department,
    p_severity := v_severity,
    p_message := btrim(p_comment),
    p_idempotency_key := 'production-issue-escalation:' || v_correlation_id
  );

  RETURN v_issue;
END;
$$;

COMMENT ON FUNCTION public.report_production_issue(uuid, text, text, text, text, text) IS
  'Governed replacement for the direct client INSERT into production_issues -- records the issue AND appends a production_issue_escalation operational_event so it surfaces in the existing CMD War Room / Execution Command Center escalation topology (previously: production_issues was a write-only sink with zero consumers). Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.report_production_issue(uuid, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_production_issue(uuid, text, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_production_issue(
  p_issue_id uuid,
  p_resolution_notes text
)
RETURNS public.production_issues
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_issue public.production_issues%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR public.is_internal_staff(v_actor_id) IS NOT TRUE THEN
    RAISE EXCEPTION 'Not authorised to resolve a production issue' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(coalesce(p_resolution_notes, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Resolution notes are required';
  END IF;

  SELECT * INTO v_issue FROM public.production_issues WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Production issue % not found', p_issue_id;
  END IF;

  -- Idempotent: a real retry after a lost response is a safe no-op, not an
  -- error and not a second resolution event.
  IF v_issue.status = 'resolved' THEN
    RETURN v_issue;
  END IF;

  UPDATE public.production_issues
  SET status = 'resolved', resolved_by = v_actor_id, resolved_at = now(), resolution_notes = btrim(p_resolution_notes)
  WHERE id = p_issue_id
  RETURNING * INTO v_issue;

  PERFORM public.append_operational_event_v1(
    p_event_type := 'production_issue_resolved',
    p_entity_type := 'production_issue',
    p_entity_id := v_issue.id,
    p_title := 'Production issue resolved: ' || v_issue.issue_type || ' (' || v_issue.department || ')',
    p_source_application := 'production',
    p_correlation_id := 'resolve-' || p_issue_id::text,
    p_actor_id := v_actor_id,
    p_actor_department := v_issue.department,
    p_severity := 'info',
    p_message := btrim(p_resolution_notes),
    p_idempotency_key := 'resolve-' || p_issue_id::text
  );

  RETURN v_issue;
END;
$$;

COMMENT ON FUNCTION public.resolve_production_issue(uuid, text) IS
  'The only path to close a production_issues row -- requires resolution notes, records resolver/timestamp, and appends a production_issue_resolved operational_event. Idempotent: resolving an already-resolved issue is a safe no-op.';

REVOKE ALL ON FUNCTION public.resolve_production_issue(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_production_issue(uuid, text) TO authenticated;
