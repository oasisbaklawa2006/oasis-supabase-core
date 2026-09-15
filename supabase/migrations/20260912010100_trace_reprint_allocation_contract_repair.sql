-- Trace #38 follow-up: repair the production reprint-allocation contract before
-- the Trace client consumes trace_allocate_reprint_count_v1.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE FUNCTION public.trace_allocate_reprint_count_v1(
  p_ref_type text,
  p_ref_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_approval_request_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_input_ref_type text := lower(btrim(coalesce(p_ref_type, '')));
  v_ref_type text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_actor uuid := auth.uid();
  v_fingerprint text;
  v_prior record;
  v_existing public.ols_trace_reprint_allocations%ROWTYPE;
  v_threshold integer;
  v_allocated_count integer;
  v_approval_required boolean;
  v_approval_request_matches boolean := false;
  v_approval_granted boolean := false;
  v_allowed boolean;
  v_allocation_id uuid;
  v_effective_approval_request_id uuid;
  v_result jsonb;
  v_attached_approval boolean := false;
  v_granted_approval boolean := false;
BEGIN
  PERFORM public.trace_assert_role_v1('packing');

  v_ref_type := CASE v_input_ref_type
    WHEN 'shipping' THEN 'shipping_label'
    ELSE v_input_ref_type
  END;

  IF v_ref_type NOT IN ('carton', 'production_label', 'shipping_label') THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REF_TYPE_INVALID: %', p_ref_type USING ERRCODE = '22023';
  END IF;
  IF p_ref_id IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REF_ID_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF nullif(v_reason, '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_REASON_REQUIRED' USING ERRCODE = '22023';
  END IF;
  IF nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'INVALID_TRACE_MUTATION' USING ERRCODE = 'P0001';
  END IF;

  v_fingerprint := md5(jsonb_build_array(v_ref_type, p_ref_id, v_reason, p_approval_request_id)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));

  SELECT operation, payload_fingerprint, response
    INTO v_prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_prior.operation <> 'allocate_reprint_count' THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    SELECT *
      INTO v_existing
      FROM public.ols_trace_reprint_allocations
     WHERE idempotency_key = p_idempotency_key
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'TRACE_REPRINT_ALLOCATION_RECEIPT_INCONSISTENT' USING ERRCODE = 'P0001';
    END IF;

    IF v_existing.ref_type <> v_ref_type
       OR v_existing.ref_id <> p_ref_id
       OR v_existing.reason <> v_reason THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    IF NOT v_existing.approval_required THEN
      IF v_prior.payload_fingerprint <> v_fingerprint THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      IF v_existing.approval_request_id IS NULL AND p_approval_request_id IS NOT NULL THEN
        IF EXISTS (
          SELECT 1
            FROM public.ols_trace_reprint_allocations other
           WHERE other.approval_request_id = p_approval_request_id
             AND other.idempotency_key <> p_idempotency_key
        ) THEN
          RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_ALREADY_BOUND' USING ERRCODE = 'P0001';
        END IF;

        SELECT EXISTS (
          SELECT 1
            FROM public.ols_reprint_requests rr
           WHERE rr.id = p_approval_request_id
             AND rr.ref_id = p_ref_id
             AND (
               (v_ref_type = 'shipping_label' AND rr.ref_type IN ('shipping', 'shipping_label'))
               OR rr.ref_type = v_ref_type
             )
        ) INTO v_approval_request_matches;

        IF NOT v_approval_request_matches THEN
          RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_REQUEST_INVALID' USING ERRCODE = 'P0001';
        END IF;

        BEGIN
          UPDATE public.ols_trace_reprint_allocations
             SET approval_request_id = p_approval_request_id
           WHERE id = v_existing.id
           RETURNING * INTO v_existing;
        EXCEPTION
          WHEN unique_violation THEN
            RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_ALREADY_BOUND' USING ERRCODE = 'P0001';
        END;
        v_attached_approval := true;
      ELSIF v_existing.approval_request_id IS NOT NULL
            AND p_approval_request_id IS NOT NULL
            AND v_existing.approval_request_id <> p_approval_request_id THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
      ELSIF v_existing.approval_request_id IS NULL
            AND p_approval_request_id IS NULL
            AND v_prior.payload_fingerprint <> v_fingerprint THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
      END IF;

      v_effective_approval_request_id := v_existing.approval_request_id;

      IF v_effective_approval_request_id IS NOT NULL THEN
        SELECT EXISTS (
          SELECT 1
            FROM public.ols_reprint_requests rr
           WHERE rr.id = v_effective_approval_request_id
             AND rr.ref_id = p_ref_id
             AND (
               (v_ref_type = 'shipping_label' AND rr.ref_type IN ('shipping', 'shipping_label'))
               OR rr.ref_type = v_ref_type
             )
             AND rr.status = 'approved'
             AND rr.approved_by IS NOT NULL
        ) INTO v_approval_granted;
      END IF;

      IF v_approval_granted AND NOT v_existing.allowed THEN
        UPDATE public.ols_trace_reprint_allocations
           SET approval_granted = true,
               allowed = true
         WHERE id = v_existing.id
         RETURNING * INTO v_existing;
        v_granted_approval := true;
      END IF;
    END IF;

    v_result := jsonb_build_object(
      'allocation_id', v_existing.id,
      'ref_type', v_existing.ref_type,
      'ref_id', v_existing.ref_id,
      'reprint_count', v_existing.reprint_count,
      'approval_threshold', v_existing.approval_threshold,
      'approval_required', v_existing.approval_required,
      'approval_granted', v_existing.approval_granted,
      'approval_request_id', v_existing.approval_request_id,
      'allowed', v_existing.allowed,
      'idempotency_replayed', true
    );

    IF v_attached_approval THEN
      INSERT INTO public.ols_audit_logs(action, entity_type, entity_id, user_id, details, idempotency_key)
      VALUES (
        'trace_reprint_approval_attached',
        v_existing.ref_type,
        v_existing.ref_id,
        v_actor,
        jsonb_build_object(
          'allocation_id', v_existing.id,
          'reprint_count', v_existing.reprint_count,
          'approval_request_id', v_existing.approval_request_id,
          'allowed', v_existing.allowed
        ),
        p_idempotency_key || ':approval-attached:' || v_existing.approval_request_id::text
      ) ON CONFLICT DO NOTHING;
    END IF;

    IF v_granted_approval THEN
      INSERT INTO public.ols_audit_logs(action, entity_type, entity_id, user_id, details, idempotency_key)
      VALUES (
        'trace_reprint_approval_granted',
        v_existing.ref_type,
        v_existing.ref_id,
        v_actor,
        jsonb_build_object(
          'allocation_id', v_existing.id,
          'reprint_count', v_existing.reprint_count,
          'approval_request_id', v_existing.approval_request_id,
          'approval_granted', true,
          'allowed', true
        ),
        p_idempotency_key || ':approval-granted:' || v_existing.approval_request_id::text
      ) ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_result;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.ols_print_logs pl
     WHERE pl.ref_id = p_ref_id
       AND pl.success = true
       AND (
         (v_ref_type = 'shipping_label' AND pl.ref_type IN ('shipping', 'shipping_label'))
         OR pl.ref_type = v_ref_type
       )
  ) THEN
    RAISE EXCEPTION 'TRACE_REPRINT_NO_PRIOR_PRINT' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('trace_reprint:' || v_ref_type || ':' || p_ref_id::text, 0));
  v_threshold := public.trace_reprint_approval_threshold_v1();

  INSERT INTO public.ols_trace_reprint_counters(ref_type, ref_id, next_reprint_count, updated_at)
  VALUES (v_ref_type, p_ref_id, 1, now())
  ON CONFLICT (ref_type, ref_id)
  DO UPDATE SET
    next_reprint_count = public.ols_trace_reprint_counters.next_reprint_count + 1,
    updated_at = now()
  RETURNING next_reprint_count INTO v_allocated_count;

  v_approval_required := v_allocated_count > v_threshold;
  v_effective_approval_request_id := NULL;

  IF NOT v_approval_required AND p_approval_request_id IS NOT NULL THEN
    RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_NOT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF v_approval_required AND p_approval_request_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
        FROM public.ols_trace_reprint_allocations other
       WHERE other.approval_request_id = p_approval_request_id
    ) THEN
      RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_ALREADY_BOUND' USING ERRCODE = 'P0001';
    END IF;

    SELECT EXISTS (
      SELECT 1
        FROM public.ols_reprint_requests rr
       WHERE rr.id = p_approval_request_id
         AND rr.ref_id = p_ref_id
         AND (
           (v_ref_type = 'shipping_label' AND rr.ref_type IN ('shipping', 'shipping_label'))
           OR rr.ref_type = v_ref_type
         )
    ) INTO v_approval_request_matches;

    IF NOT v_approval_request_matches THEN
      RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_REQUEST_INVALID' USING ERRCODE = 'P0001';
    END IF;

    v_effective_approval_request_id := p_approval_request_id;

    SELECT EXISTS (
      SELECT 1
        FROM public.ols_reprint_requests rr
       WHERE rr.id = p_approval_request_id
         AND rr.ref_id = p_ref_id
         AND (
           (v_ref_type = 'shipping_label' AND rr.ref_type IN ('shipping', 'shipping_label'))
           OR rr.ref_type = v_ref_type
         )
         AND rr.status = 'approved'
         AND rr.approved_by IS NOT NULL
    ) INTO v_approval_granted;
  END IF;

  v_allowed := NOT v_approval_required OR v_approval_granted;

  BEGIN
    INSERT INTO public.ols_trace_reprint_allocations(
      ref_type, ref_id, reprint_count, idempotency_key, actor_id, reason,
      approval_threshold, approval_required, approval_granted,
      approval_request_id, allowed
    ) VALUES (
      v_ref_type, p_ref_id, v_allocated_count, p_idempotency_key, v_actor, v_reason,
      v_threshold, v_approval_required, v_approval_granted,
      v_effective_approval_request_id, v_allowed
    )
    RETURNING id INTO v_allocation_id;
  EXCEPTION
    WHEN unique_violation THEN
      IF v_effective_approval_request_id IS NOT NULL THEN
        RAISE EXCEPTION 'TRACE_REPRINT_APPROVAL_ALREADY_BOUND' USING ERRCODE = 'P0001';
      END IF;
      RAISE;
  END;

  v_result := jsonb_build_object(
    'allocation_id', v_allocation_id,
    'ref_type', v_ref_type,
    'ref_id', p_ref_id,
    'reprint_count', v_allocated_count,
    'approval_threshold', v_threshold,
    'approval_required', v_approval_required,
    'approval_granted', v_approval_granted,
    'approval_request_id', v_effective_approval_request_id,
    'allowed', v_allowed,
    'idempotency_replayed', false
  );

  INSERT INTO public.ols_audit_logs(action, entity_type, entity_id, user_id, details, idempotency_key)
  VALUES (
    'trace_reprint_count_allocated',
    v_ref_type,
    p_ref_id,
    v_actor,
    jsonb_build_object(
      'reprint_count', v_allocated_count,
      'approval_required', v_approval_required,
      'approval_granted', v_approval_granted,
      'allowed', v_allowed,
      'reason', v_reason,
      'approval_request_id', v_effective_approval_request_id
    ),
    p_idempotency_key
  );

  INSERT INTO public.ols_trace_mutation_receipts(idempotency_key, operation, payload_fingerprint, response, actor_id)
  VALUES (p_idempotency_key, 'allocate_reprint_count', v_fingerprint, v_result, v_actor);

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.trace_allocate_reprint_count_v1(text, uuid, text, text, uuid) IS
  'Trace #38 contract repair: atomically allocates one durable reprint count, canonicalizes shipping to shipping_label, allows a blocked idempotent allocation to attach/re-check a manager approval without consuming another count, and enforces single-use approval requests.';

REVOKE ALL ON FUNCTION public.trace_allocate_reprint_count_v1(text, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trace_allocate_reprint_count_v1(text, uuid, text, text, uuid) TO authenticated, service_role;
