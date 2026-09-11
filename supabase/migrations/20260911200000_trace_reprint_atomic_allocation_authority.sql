-- Issue #285 / Trace #38: atomic reprint count allocation and threshold authority.
--
-- Census finding: ols_print_logs and ols_reprint_requests exist but no Core-owned
-- transactional path atomically allocates the next (ref_type, ref_id) reprint
-- count or evaluates the governed approval threshold. Client-side priorCount+1
-- is therefore raceable. This migration adds the smallest durable authority:
--   1) per-reference counter with ON CONFLICT increment (like identity sequences);
--   2) immutable allocation ledger with unique (ref_type, ref_id, reprint_count);
--   3) governed SECURITY DEFINER RPC with idempotency receipts and threshold eval.
--
-- Boundary preserved: no print rendering or Trace UI authority moves into Core.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE TABLE IF NOT EXISTS public.ols_trace_reprint_counters (
  ref_type text NOT NULL,
  ref_id uuid NOT NULL,
  next_reprint_count integer NOT NULL CHECK (next_reprint_count > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (ref_type, ref_id)
);

CREATE TABLE IF NOT EXISTS public.ols_trace_reprint_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref_type text NOT NULL,
  ref_id uuid NOT NULL,
  reprint_count integer NOT NULL CHECK (reprint_count > 0),
  idempotency_key text NOT NULL UNIQUE,
  actor_id uuid NOT NULL,
  reason text NOT NULL,
  approval_threshold integer NOT NULL CHECK (approval_threshold >= 0),
  approval_required boolean NOT NULL,
  approval_granted boolean NOT NULL,
  approval_request_id uuid,
  allowed boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ols_trace_reprint_allocations_ref_count_uniq
    UNIQUE (ref_type, ref_id, reprint_count)
);

ALTER TABLE public.ols_trace_reprint_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ols_trace_reprint_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ols_trace_reprint_counters FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.ols_trace_reprint_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ols_trace_reprint_counters TO service_role;
GRANT SELECT, INSERT ON TABLE public.ols_trace_reprint_allocations TO service_role;

INSERT INTO public.ols_settings(key, value)
VALUES (
  'trace_reprint_approval_threshold',
  jsonb_build_object(
    'max_reprints_without_approval', 1,
    'description', 'Reprint counts <= this value proceed without manager approval; higher counts require an approved ols_reprint_requests row.'
  )
)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.trace_reprint_approval_threshold_v1()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (
      SELECT (s.value->>'max_reprints_without_approval')::integer
      FROM public.ols_settings s
      WHERE s.key = 'trace_reprint_approval_threshold'
    ),
    1
  );
$$;

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
  v_ref_type text := lower(btrim(coalesce(p_ref_type, '')));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_actor uuid := auth.uid();
  v_fingerprint text := md5(
    jsonb_build_array(v_ref_type, p_ref_id, v_reason, p_approval_request_id)::text
  );
  v_prior record;
  v_threshold integer;
  v_allocated_count integer;
  v_approval_required boolean;
  v_approval_granted boolean := false;
  v_allowed boolean;
  v_allocation_id uuid;
  v_result jsonb;
BEGIN
  PERFORM public.trace_assert_role_v1('packing');

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

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));

  SELECT payload_fingerprint, response
    INTO v_prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_prior.payload_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_prior.response || jsonb_build_object('idempotency_replayed', true);
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.ols_print_logs pl
     WHERE pl.ref_type = v_ref_type
       AND pl.ref_id = p_ref_id
       AND pl.success = true
  ) THEN
    RAISE EXCEPTION 'TRACE_REPRINT_NO_PRIOR_PRINT' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('trace_reprint:' || v_ref_type || ':' || p_ref_id::text, 0)
  );

  v_threshold := public.trace_reprint_approval_threshold_v1();

  INSERT INTO public.ols_trace_reprint_counters(ref_type, ref_id, next_reprint_count, updated_at)
  VALUES (v_ref_type, p_ref_id, 1, now())
  ON CONFLICT (ref_type, ref_id)
  DO UPDATE SET
    next_reprint_count = public.ols_trace_reprint_counters.next_reprint_count + 1,
    updated_at = now()
  RETURNING next_reprint_count INTO v_allocated_count;

  v_approval_required := v_allocated_count > v_threshold;

  IF v_approval_required THEN
    IF p_approval_request_id IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1
          FROM public.ols_reprint_requests rr
         WHERE rr.id = p_approval_request_id
           AND rr.ref_type = v_ref_type
           AND rr.ref_id = p_ref_id
           AND rr.status = 'approved'
           AND rr.approved_by IS NOT NULL
      ) INTO v_approval_granted;
    END IF;
    v_allowed := v_approval_granted;
  ELSE
    v_allowed := true;
  END IF;

  INSERT INTO public.ols_trace_reprint_allocations(
    ref_type,
    ref_id,
    reprint_count,
    idempotency_key,
    actor_id,
    reason,
    approval_threshold,
    approval_required,
    approval_granted,
    approval_request_id,
    allowed
  ) VALUES (
    v_ref_type,
    p_ref_id,
    v_allocated_count,
    p_idempotency_key,
    v_actor,
    v_reason,
    v_threshold,
    v_approval_required,
    v_approval_granted,
    p_approval_request_id,
    v_allowed
  )
  RETURNING id INTO v_allocation_id;

  v_result := jsonb_build_object(
    'allocation_id', v_allocation_id,
    'ref_type', v_ref_type,
    'ref_id', p_ref_id,
    'reprint_count', v_allocated_count,
    'approval_threshold', v_threshold,
    'approval_required', v_approval_required,
    'approval_granted', v_approval_granted,
    'allowed', v_allowed,
    'idempotency_replayed', false
  );

  INSERT INTO public.ols_audit_logs(
    action,
    entity_type,
    entity_id,
    user_id,
    details,
    idempotency_key
  ) VALUES (
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
      'approval_request_id', p_approval_request_id
    ),
    p_idempotency_key
  );

  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key,
    operation,
    payload_fingerprint,
    response,
    actor_id
  ) VALUES (
    p_idempotency_key,
    'allocate_reprint_count',
    v_fingerprint,
    v_result,
    v_actor
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.trace_reprint_approval_threshold_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_allocate_reprint_count_v1(text, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trace_reprint_approval_threshold_v1() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_allocate_reprint_count_v1(text, uuid, text, text, uuid) TO authenticated, service_role;
