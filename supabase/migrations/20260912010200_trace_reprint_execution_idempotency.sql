-- Trace #38 / Core #291: durable atomic execution claim for governed reprints.
-- Rendering stays in Trace; Core atomically persists one generated command/job/log
-- per governed reprint request and replays the existing durable result on retries.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

ALTER TABLE public.ols_print_jobs
  ADD COLUMN IF NOT EXISTS reprint_request_id uuid;

ALTER TABLE public.ols_print_logs
  ADD COLUMN IF NOT EXISTS reprint_request_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS ols_print_jobs_reprint_request_uniq
  ON public.ols_print_jobs(reprint_request_id)
  WHERE reprint_request_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ols_print_logs_reprint_request_uniq
  ON public.ols_print_logs(reprint_request_id)
  WHERE reprint_request_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.trace_record_reprint_command_v1(
  p_reprint_request_id uuid,
  p_ref_type text,
  p_ref_id uuid,
  p_template_id uuid,
  p_printer_id uuid,
  p_command_lang text,
  p_command_payload text,
  p_reprint_count integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_input_ref_type text := lower(btrim(coalesce(p_ref_type, '')));
  v_ref_type text;
  v_lang text := upper(btrim(coalesce(p_command_lang, '')));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_allocation public.ols_trace_reprint_allocations%ROWTYPE;
  v_existing_log public.ols_print_logs%ROWTYPE;
  v_existing_job public.ols_print_jobs%ROWTYPE;
  v_job_id uuid;
  v_log_id uuid;
BEGIN
  PERFORM public.trace_assert_role_v1('packing');

  IF p_reprint_request_id IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REQUEST_ID_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF p_ref_id IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REF_ID_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF p_reprint_count IS NULL OR p_reprint_count < 1 THEN
    RAISE EXCEPTION 'TRACE_REPRINT_COUNT_INVALID' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(coalesce(p_command_payload, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_COMMAND_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF v_lang NOT IN ('TSPL', 'ZPL') THEN
    RAISE EXCEPTION 'TRACE_REPRINT_COMMAND_LANG_INVALID' USING ERRCODE = '22023';
  END IF;
  IF nullif(v_reason, '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REASON_REQUIRED' USING ERRCODE = '22023';
  END IF;

  v_ref_type := CASE v_input_ref_type
    WHEN 'shipping' THEN 'shipping_label'
    ELSE v_input_ref_type
  END;

  IF v_ref_type NOT IN ('carton', 'production_label', 'shipping_label') THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REF_TYPE_INVALID: %', p_ref_type USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('trace_reprint_execution:' || p_reprint_request_id::text, 0));

  SELECT *
    INTO v_existing_log
    FROM public.ols_print_logs
   WHERE reprint_request_id = p_reprint_request_id
   LIMIT 1;

  IF FOUND THEN
    SELECT *
      INTO v_existing_job
      FROM public.ols_print_jobs
     WHERE reprint_request_id = p_reprint_request_id
     LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'TRACE_REPRINT_EXECUTION_INCONSISTENT' USING ERRCODE = 'P0001';
    END IF;

    IF v_existing_log.ref_id <> p_ref_id
       OR CASE lower(v_existing_log.ref_type)
            WHEN 'shipping' THEN 'shipping_label'
            ELSE lower(v_existing_log.ref_type)
          END <> v_ref_type
       OR v_existing_log.reprint_count <> p_reprint_count
       OR v_existing_job.command_lang <> v_lang
       OR v_existing_job.command_payload <> p_command_payload THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
      'job_id', v_existing_job.id,
      'log_id', v_existing_log.id,
      'reprint_request_id', p_reprint_request_id,
      'ref_type', v_ref_type,
      'ref_id', p_ref_id,
      'reprint_count', p_reprint_count,
      'idempotency_replayed', true
    );
  END IF;

  SELECT *
    INTO v_allocation
    FROM public.ols_trace_reprint_allocations
   WHERE idempotency_key = 'trace-reprint:' || p_reprint_request_id::text
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRACE_REPRINT_ALLOCATION_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF v_allocation.ref_id <> p_ref_id
     OR v_allocation.ref_type <> v_ref_type
     OR v_allocation.reprint_count <> p_reprint_count THEN
    RAISE EXCEPTION 'TRACE_REPRINT_ALLOCATION_MISMATCH' USING ERRCODE = 'P0001';
  END IF;

  IF NOT v_allocation.allowed THEN
    RAISE EXCEPTION 'TRACE_REPRINT_NOT_AUTHORIZED' USING ERRCODE = 'P0001';
  END IF;

  IF v_allocation.approval_required THEN
    IF v_allocation.approval_request_id IS DISTINCT FROM p_reprint_request_id THEN
      RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_BINDING_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
      SELECT 1
        FROM public.ols_reprint_requests rr
       WHERE rr.id = p_reprint_request_id
         AND rr.ref_id = p_ref_id
         AND rr.status = 'approved'
         AND rr.approved_by IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  INSERT INTO public.ols_print_jobs(
    template_id,
    printer_id,
    command_lang,
    command_payload,
    status,
    created_by,
    reprint_request_id
  ) VALUES (
    p_template_id,
    p_printer_id,
    v_lang,
    p_command_payload,
    'generated',
    v_actor,
    p_reprint_request_id
  )
  RETURNING id INTO v_job_id;

  INSERT INTO public.ols_print_logs(
    ref_type,
    ref_id,
    printer_id,
    printed_by,
    is_reprint,
    reprint_count,
    reason,
    success,
    reprint_request_id
  ) VALUES (
    p_ref_type,
    p_ref_id,
    p_printer_id,
    v_actor,
    true,
    p_reprint_count,
    v_reason,
    true,
    p_reprint_request_id
  )
  RETURNING id INTO v_log_id;

  INSERT INTO public.ols_audit_logs(
    action,
    entity_type,
    entity_id,
    user_id,
    details,
    idempotency_key
  ) VALUES (
    'trace_reprint_command_recorded',
    v_ref_type,
    p_ref_id,
    v_actor,
    jsonb_build_object(
      'reprint_request_id', p_reprint_request_id,
      'allocation_id', v_allocation.id,
      'reprint_count', p_reprint_count,
      'print_job_id', v_job_id,
      'print_log_id', v_log_id,
      'command_lang', v_lang
    ),
    'trace-reprint-command:' || p_reprint_request_id::text
  ) ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'job_id', v_job_id,
    'log_id', v_log_id,
    'reprint_request_id', p_reprint_request_id,
    'ref_type', v_ref_type,
    'ref_id', p_ref_id,
    'reprint_count', p_reprint_count,
    'idempotency_replayed', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.trace_record_reprint_command_v1(uuid,text,uuid,uuid,uuid,text,text,integer,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trace_record_reprint_command_v1(uuid,text,uuid,uuid,uuid,text,text,integer,text) TO authenticated, service_role;

COMMENT ON FUNCTION public.trace_record_reprint_command_v1(uuid,text,uuid,uuid,uuid,text,text,integer,text) IS
  'Core #291 / Trace #38: atomically persists one governed generated reprint command/job/log per reprint request and idempotently replays the durable result.';
