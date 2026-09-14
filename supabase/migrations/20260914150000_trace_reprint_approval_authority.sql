-- Trace #38 follow-up: make reprint approval a Core-authorized mutation.
-- Approval is intentionally narrower than general packing authority: ordinary
-- packing operators may request/reprint within threshold but may not approve a
-- manager-gated reprint.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE FUNCTION public.trace_reprint_approver_allowed_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  WITH roles AS (
    SELECT upper(x) AS role
      FROM unnest(public.get_current_user_roles()) AS x
  )
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (
       SELECT 1
         FROM roles
        WHERE role IN (
          'PACKING_SUPERVISOR',
          'ASSEMBLY_SUPERVISOR',
          'ASSEMBLY_HEAD',
          'OPERATIONS_MANAGER',
          'ADMIN',
          'SUPER_ADMIN',
          'OWNER'
        )
     )
$$;

CREATE OR REPLACE FUNCTION public.trace_approve_reprint_request_v1(
  p_request_id uuid,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_fingerprint text := md5(jsonb_build_array(p_request_id)::text);
  v_prior record;
  v_request public.ols_reprint_requests%ROWTYPE;
  v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED' USING ERRCODE = 'P0001';
  END IF;
  IF NOT public.trace_reprint_approver_allowed_v1() THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED: Trace reprint approval authority required' USING ERRCODE = 'P0001';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_REQUEST_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(coalesce(p_idempotency_key, '')), '') IS NULL THEN
    RAISE EXCEPTION 'INVALID_TRACE_MUTATION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));

  SELECT operation, payload_fingerprint, response
    INTO v_prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_prior.operation <> 'approve_reprint_request'
       OR v_prior.payload_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_prior.response;
  END IF;

  SELECT *
    INTO v_request
    FROM public.ols_reprint_requests
   WHERE id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF v_request.status = 'approved' AND v_request.approved_by IS NOT NULL THEN
    v_result := jsonb_build_object(
      'request_id', v_request.id,
      'status', v_request.status,
      'approved_by', v_request.approved_by,
      'idempotency_replayed', true
    );
  ELSE
    IF v_request.status <> 'pending' THEN
      RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_STATE_INVALID: %', v_request.status USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.ols_reprint_requests
       SET status = 'approved',
           approved_by = v_actor
     WHERE id = v_request.id
     RETURNING * INTO v_request;

    v_result := jsonb_build_object(
      'request_id', v_request.id,
      'status', v_request.status,
      'approved_by', v_request.approved_by,
      'idempotency_replayed', false
    );

    INSERT INTO public.ols_audit_logs(
      action, entity_type, entity_id, user_id, details, idempotency_key
    ) VALUES (
      'trace_reprint_request_approved',
      'reprint_request',
      v_request.id,
      v_actor,
      jsonb_build_object(
        'ref_type', v_request.ref_type,
        'ref_id', v_request.ref_id,
        'approved_by', v_actor
      ),
      p_idempotency_key
    );
  END IF;

  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key, operation, payload_fingerprint, response, actor_id
  ) VALUES (
    p_idempotency_key,
    'approve_reprint_request',
    v_fingerprint,
    v_result,
    v_actor
  );

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.trace_approve_reprint_request_v1(uuid, text) IS
  'Core authority for Trace reprint approvals. Only supervisor/manager/admin roles may transition a pending reprint request to approved; mutation is durable and idempotent.';

REVOKE ALL ON FUNCTION public.trace_reprint_approver_allowed_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_approve_reprint_request_v1(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trace_reprint_approver_allowed_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.trace_approve_reprint_request_v1(uuid, text) TO authenticated;
