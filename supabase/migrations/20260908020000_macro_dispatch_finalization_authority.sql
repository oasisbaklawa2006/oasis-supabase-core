-- MACRO-DISPATCH-FINALIZE: canonical order-level dispatch finalization.
--
-- Physical/carton authority remains in the existing B2B gate ledger and immutable
-- dispatch proof packet. This RPC performs only the final governed order status
-- transition after those authorities have already succeeded.

CREATE OR REPLACE FUNCTION public.lock_finance_dispatch_eligibility_v1(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_ELIGIBILITY_ORDER_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('finance-dispatch-eligibility:' || p_order_id::text, 0));
END;
$$;

CREATE OR REPLACE FUNCTION public.lock_finance_dispatch_eligibility_company_v1(p_company_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_company_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_ELIGIBILITY_COMPANY_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('finance-dispatch-eligibility-company:' || p_company_id::text, 0));
END;
$$;

REVOKE ALL ON FUNCTION public.lock_finance_dispatch_eligibility_v1(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.lock_finance_dispatch_eligibility_company_v1(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.release_order_to_dispatched_v1(
  p_order_id uuid,
  p_tracking_number text DEFAULT NULL,
  p_courier_name text DEFAULT NULL,
  p_finalize_reason text DEFAULT NULL,
  p_correlation_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
SET lock_timeout = '5s'
SET statement_timeout = '60s'
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_role text;
  v_order public.orders%rowtype;
  v_proof public.dispatch_proof_packets%rowtype;
  v_clearance uuid;
  v_tracking text := nullif(btrim(p_tracking_number), '');
  v_courier text := nullif(btrim(p_courier_name), '');
  v_reason text := nullif(btrim(p_finalize_reason), '');
  v_correlation text;
  v_blockers jsonb := '[]'::jsonb;
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'DISPATCH_FINALIZATION_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;

  -- Final order release is a physical-exit authority. Reuse the already-deployed
  -- gate role boundary rather than creating a second, divergent role list.
  PERFORM public.assert_order_transition_role('gate_release');
  v_role := coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN');

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'DISPATCH_FINALIZATION_ORDER_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_reason IS NOT NULL AND length(v_reason) < 5 THEN
    RAISE EXCEPTION 'DISPATCH_FINALIZATION_REASON_TOO_SHORT' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('dispatch-finalize:' || p_order_id::text, 0));

  -- Read order state without a row-exclusive lock first so Finance hold mutations that
  -- join the eligibility lock protocol cannot deadlock waiting on this transaction.
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(jsonb_build_object('code', 'order_not_found', 'message', 'Order not found'))
    );
  END IF;

  -- The immutable proof packet is the canonical statement that every frozen-DPL
  -- carton passed the independent physical gate. Do not reconstruct that truth here.
  SELECT * INTO v_proof
  FROM public.dispatch_proof_packets
  WHERE order_id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'dispatch_proof_required',
        'message', 'Immutable dispatch proof is required before final dispatch status'
      ))
    );
  END IF;

  -- Optional Central convenience fields are validation-only. Canonical transport
  -- truth remains the frozen dispatch proof packet and is never overwritten here.
  IF v_tracking IS NOT NULL
     AND lower(v_tracking) IS DISTINCT FROM lower(btrim(coalesce(v_proof.transport_snapshot->>'tracking_reference', '')))
     AND lower(v_tracking) IS DISTINCT FROM lower(btrim(coalesce(v_proof.transport_snapshot->>'lr_awb_bilty', ''))) THEN
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'tracking_reference_mismatch',
      'message', 'Tracking reference does not match the frozen dispatch proof'
    ));
  END IF;

  IF v_courier IS NOT NULL
     AND lower(v_courier) IS DISTINCT FROM lower(btrim(coalesce(v_proof.transport_snapshot->>'transporter', ''))) THEN
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'courier_mismatch',
      'message', 'Courier/transporter does not match the frozen dispatch proof'
    ));
  END IF;

  IF jsonb_array_length(v_blockers) > 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', v_blockers
    );
  END IF;

  -- Idempotent replay is accepted only when the same canonical proof still exists
  -- and the optional transport values above agree with it. Replay does not require
  -- a still-active Finance clearance; the frozen proof already bound the grant.
  IF lower(coalesce(v_order.status, '')) = 'dispatched' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'order_id', p_order_id,
      'previous_status', 'dispatched',
      'new_status', 'dispatched',
      'already_applied', true,
      'dispatch_proof_id', v_proof.id,
      'finance_dispatch_clearance_event_id', v_proof.finance_dispatch_clearance_event_id
    );
  END IF;

  IF lower(coalesce(v_order.status, '')) <> 'cleared_for_dispatch' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status',
        'message', 'Order must be cleared_for_dispatch before final dispatch'
      ))
    );
  END IF;

  -- Serialize with Finance hold/clearance mutations on the canonical per-order and
  -- per-company eligibility locks before the row-exclusive order lock, then revalidate
  -- immediately before transition.
  PERFORM public.lock_finance_dispatch_eligibility_v1(p_order_id);
  PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_order.company_id);

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF lower(coalesce(v_order.status, '')) <> 'cleared_for_dispatch' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status',
        'message', 'Order must be cleared_for_dispatch before final dispatch'
      ))
    );
  END IF;

  BEGIN
    v_clearance := public.assert_active_dispatch_clearance_v1(p_order_id);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'finance_dispatch_clearance_required',
        'message', SQLERRM
      ))
    );
  END;

  v_correlation := coalesce(nullif(btrim(p_correlation_id), ''), v_proof.correlation_id);

  -- Revalidate under the held eligibility lock so a concurrent hold/clearance mutation
  -- cannot slip between the first assertion and the atomic status transition.
  BEGIN
    v_clearance := public.assert_active_dispatch_clearance_v1(p_order_id);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'finance_dispatch_clearance_required',
        'message', SQLERRM
      ))
    );
  END;

  UPDATE public.orders
  SET status = 'dispatched'
  WHERE id = p_order_id;

  INSERT INTO public.order_status_history(order_id, old_status, new_status, changed_by)
  VALUES(p_order_id, v_order.status, 'dispatched', v_actor);

  INSERT INTO public.audit_logs(
    action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value
  ) VALUES (
    'ORDER_DISPATCHED',
    'Dispatch',
    'orders',
    p_order_id::text,
    v_actor,
    'high',
    jsonb_build_object(
      'previous_status', v_order.status,
      'new_status', 'dispatched',
      'dispatch_proof_id', v_proof.id,
      'dispatch_proof_fingerprint', v_proof.proof_fingerprint,
      'finance_dispatch_clearance_event_id', v_clearance,
      'final_invoice_id', v_proof.final_invoice_id,
      'finance_dpl_receipt_id', v_proof.finance_dpl_receipt_id,
      'transport_snapshot', v_proof.transport_snapshot,
      'proof_dispatched_at', v_proof.dispatched_at,
      'finalized_at', statement_timestamp(),
      'finalize_reason', v_reason,
      'correlation_id', v_correlation,
      'actor_role', v_role
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'previous_status', v_order.status,
    'new_status', 'dispatched',
    'already_applied', false,
    'dispatch_proof_id', v_proof.id,
    'finance_dispatch_clearance_event_id', v_clearance,
    'correlation_id', v_correlation
  );
END;
$$;

REVOKE ALL ON FUNCTION public.release_order_to_dispatched_v1(uuid,text,text,text,text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.release_order_to_dispatched_v1(uuid,text,text,text,text)
  TO authenticated;

COMMENT ON FUNCTION public.release_order_to_dispatched_v1(uuid,text,text,text,text) IS
  'Final governed order transition: cleared_for_dispatch -> dispatched, requiring active Finance dispatch clearance and the immutable post-gate dispatch proof packet.';

-- Join Finance hold/clearance mutations to the same dispatch-eligibility lock protocol.
CREATE OR REPLACE FUNCTION public.apply_finance_hold_v1(
  p_company_id uuid,
  p_order_id uuid,
  p_final_invoice_id uuid,
  p_scope text,
  p_amount numeric,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, requires_second_approval boolean, already_applied boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_scope text := upper(btrim(coalesce(p_scope, '')));
  v_threshold numeric := 100000;
  v_requires_second boolean := false;
  v_blocking boolean := false;
  v_decision text := 'APPLIED';
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  IF v_scope NOT IN ('COMPANY','ORDER','INVOICE','DISPATCH')
     OR p_amount IS NULL OR p_amount < 0
     OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_HOLD_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_scope IN ('ORDER','DISPATCH') AND p_order_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_HOLD_ORDER_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_scope = 'INVOICE' AND p_final_invoice_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_HOLD_INVOICE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_scope IN ('ORDER','DISPATCH') AND p_order_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.orders o WHERE o.id = p_order_id AND o.company_id = p_company_id
     ) THEN
    RAISE EXCEPTION 'FINANCE_HOLD_ORDER_COMPANY_MISMATCH' USING ERRCODE = '42501';
  END IF;
  IF v_scope = 'INVOICE' AND p_final_invoice_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.final_invoices fi
        WHERE fi.id = p_final_invoice_id AND fi.company_id = p_company_id
     ) THEN
    RAISE EXCEPTION 'FINANCE_HOLD_INVOICE_COMPANY_MISMATCH' USING ERRCODE = '42501';
  END IF;
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF p_amount >= v_threshold THEN
    v_requires_second := true;
    v_blocking := false;
    v_decision := 'PENDING';
  ELSE
    v_blocking := true;
    v_decision := 'APPLIED';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'company_id', p_company_id, 'order_id', p_order_id, 'final_invoice_id', p_final_invoice_id,
    'scope', v_scope, 'amount', p_amount, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_HOLD_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT
      (v_existing.response->>'control_event_id')::uuid,
      v_existing.response->>'decision',
      coalesce((v_existing.response->>'requires_second_approval')::boolean, false),
      true;
    RETURN;
  END IF;
  IF v_scope IN ('ORDER','DISPATCH','COMPANY') THEN
    IF p_order_id IS NOT NULL THEN
      PERFORM public.lock_finance_dispatch_eligibility_v1(p_order_id);
    END IF;
    PERFORM public.lock_finance_dispatch_eligibility_company_v1(p_company_id);
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    p_company_id, p_order_id, p_final_invoice_id, 'HOLD', v_scope, v_blocking, p_amount, v_decision,
    btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object(
    'control_event_id', v_event.id, 'decision', v_event.decision,
    'requires_second_approval', v_requires_second, 'blocking', v_blocking
  );
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'APPLY_HOLD', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, v_event.decision, v_requires_second, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_finance_hold_v1(
  p_hold_event_id uuid,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, already_released boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_hold public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_RELEASE_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_hold FROM public.finance_control_events WHERE id = p_hold_event_id;
  IF NOT FOUND OR v_hold.control_kind <> 'HOLD' THEN
    RAISE EXCEPTION 'FINANCE_HOLD_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_hold.decision = 'PENDING' THEN
    RAISE EXCEPTION 'FINANCE_HOLD_PENDING_APPROVAL' USING ERRCODE = '55000';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events r
     WHERE r.prior_event_id = p_hold_event_id AND r.control_kind = 'RELEASE' AND r.decision = 'RELEASED'
  ) THEN
    RAISE EXCEPTION 'FINANCE_HOLD_ALREADY_RELEASED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'hold_event_id', p_hold_event_id, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_RELEASE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, 'RELEASED'::text, true;
    RETURN;
  END IF;
  IF v_hold.scope IN ('ORDER','DISPATCH','COMPANY') THEN
    IF v_hold.order_id IS NOT NULL THEN
      PERFORM public.lock_finance_dispatch_eligibility_v1(v_hold.order_id);
    END IF;
    PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_hold.company_id);
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    v_hold.company_id, v_hold.order_id, v_hold.final_invoice_id, 'RELEASE', v_hold.scope, false, v_hold.amount,
    p_hold_event_id, 'RELEASED', btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', 'RELEASED');
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'RELEASE_HOLD', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, 'RELEASED'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_finance_control_v1(
  p_event_id uuid,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, already_reversed boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_source public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_source FROM public.finance_control_events WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_CONTROL_EVENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events r
     WHERE r.prior_event_id = p_event_id AND r.control_kind = 'REVERSAL' AND r.decision = 'REVERSED'
  ) THEN
    RAISE EXCEPTION 'FINANCE_CONTROL_ALREADY_REVERSED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'event_id', p_event_id, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, 'REVERSED'::text, true;
    RETURN;
  END IF;
  IF v_source.scope IN ('ORDER','DISPATCH','COMPANY') THEN
    IF v_source.order_id IS NOT NULL THEN
      PERFORM public.lock_finance_dispatch_eligibility_v1(v_source.order_id);
    END IF;
    PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_source.company_id);
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key, facts_snapshot
  ) VALUES (
    v_source.company_id, v_source.order_id, v_source.final_invoice_id, 'REVERSAL', v_source.scope, false,
    v_source.amount, p_event_id, 'REVERSED', btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('reversed_event_id', p_event_id, 'reversed_kind', v_source.control_kind)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', 'REVERSED');
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'REVERSE_CONTROL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, 'REVERSED'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_finance_second_approval_v1(
  p_pending_hold_event_id uuid,
  p_approve boolean,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_hold public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_decision text := CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_hold FROM public.finance_control_events WHERE id = p_pending_hold_event_id FOR UPDATE;
  IF NOT FOUND OR v_hold.control_kind <> 'HOLD' OR v_hold.decision <> 'PENDING' THEN
    RAISE EXCEPTION 'FINANCE_HOLD_NOT_PENDING' USING ERRCODE = '55000';
  END IF;
  IF v_hold.actor_id = v_actor THEN
    RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_MAKER_CHECKER' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events s
     WHERE s.prior_event_id = p_pending_hold_event_id AND s.control_kind = 'SECOND_APPROVAL'
  ) THEN
    RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_ALREADY_DECIDED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'pending_hold_event_id', p_pending_hold_event_id, 'approve', p_approve,
    'reason', btrim(p_reason), 'evidence_reference', btrim(p_evidence_reference),
    'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, v_existing.response->>'decision', true;
    RETURN;
  END IF;
  IF v_hold.scope IN ('ORDER','DISPATCH','COMPANY') THEN
    IF v_hold.order_id IS NOT NULL THEN
      PERFORM public.lock_finance_dispatch_eligibility_v1(v_hold.order_id);
    END IF;
    PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_hold.company_id);
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, approver_id, correlation_id, idempotency_key
  ) VALUES (
    v_hold.company_id, v_hold.order_id, v_hold.final_invoice_id, 'SECOND_APPROVAL', v_hold.scope,
    p_approve, v_hold.amount, p_pending_hold_event_id, v_decision, btrim(p_reason), btrim(p_evidence_reference),
    v_hold.actor_id, v_hold.actor_role, v_actor, btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  IF p_approve THEN
    INSERT INTO public.finance_control_events(
      company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
      reason, evidence_reference, actor_id, actor_role, approver_id, correlation_id, idempotency_key
    ) VALUES (
      v_hold.company_id, v_hold.order_id, v_hold.final_invoice_id, 'HOLD', v_hold.scope, true, v_hold.amount,
      p_pending_hold_event_id, 'APPLIED', btrim(p_reason), btrim(p_evidence_reference), v_hold.actor_id,
      v_hold.actor_role, v_actor, btrim(p_correlation_id), btrim(p_idempotency_key) || ':applied'
    );
  END IF;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', v_decision);
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'SECOND_APPROVAL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, v_decision, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_finance_dispatch_clearance_v1(
  p_final_invoice_id uuid,
  p_decision text,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(clearance_event_id uuid,decision text,already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_decision text:=upper(btrim(coalesce(p_decision,'')));
  v_invoice public.final_invoices%rowtype; v_settlement jsonb; v_eway public.eway_bill_evidence%rowtype;
  v_latest public.finance_clearance_events%rowtype; v_existing public.finance_clearance_idempotency%rowtype;
  v_event public.finance_clearance_events%rowtype; v_operation text; v_fingerprint text; v_response jsonb;
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF v_decision NOT IN('GRANTED','DENIED','REVOKED') OR length(btrim(coalesce(p_reason,'')))<5
     OR nullif(btrim(p_evidence_reference),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE id=p_final_invoice_id AND status='ISSUED';
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  PERFORM public.lock_finance_dispatch_eligibility_v1(v_invoice.order_id);
  PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_invoice.company_id);
  PERFORM public.assert_active_operations_clearance_v1(v_invoice.order_id);
  v_settlement:=public.get_final_settlement_facts_v1(p_final_invoice_id);
  SELECT * INTO v_eway FROM public.eway_bill_evidence WHERE final_invoice_id=p_final_invoice_id ORDER BY created_at DESC LIMIT 1;

  SELECT * INTO v_latest FROM public.finance_clearance_events e
   WHERE e.order_id=v_invoice.order_id AND e.clearance_type='DISPATCH' ORDER BY e.created_at DESC,e.id DESC LIMIT 1;
  IF v_decision='GRANTED' THEN
    IF coalesce((v_settlement->>'settled_for_dispatch')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_BALANCE_OUTSTANDING' USING ERRCODE='55000';
    END IF;
    IF v_eway.id IS NULL OR v_eway.status NOT IN('VALIDATED','NOT_REQUIRED')
       OR (v_eway.status='VALIDATED' AND v_eway.valid_until IS NOT NULL AND v_eway.valid_until<=statement_timestamp()) THEN
      RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_EWAY_REQUIRED' USING ERRCODE='55000';
    END IF;
  END IF;
  IF v_decision='REVOKED' AND (v_latest.id IS NULL OR v_latest.decision<>'GRANTED') THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_NOT_ACTIVE' USING ERRCODE='55000';
  END IF;

  v_operation:=CASE v_decision WHEN 'GRANTED' THEN 'GRANT_DISPATCH' WHEN 'DENIED' THEN 'DENY_DISPATCH' ELSE 'REVOKE_DISPATCH' END;
  v_fingerprint:=encode(extensions.digest(jsonb_build_object('operation',v_operation,'final_invoice_id',p_final_invoice_id,
    'reason',btrim(p_reason),'evidence_reference',btrim(p_evidence_reference),'correlation_id',btrim(p_correlation_id),
    'settlement',v_settlement-'facts_as_of','eway_evidence_id',v_eway.id)::text,'sha256'),'hex');
  SELECT * INTO v_existing FROM public.finance_clearance_idempotency WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_CLEARANCE_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.clearance_event_id,(v_existing.response->>'decision')::text,true; RETURN;
  END IF;

  INSERT INTO public.finance_clearance_events(order_id,company_id,proforma_invoice_id,commercial_version_id,clearance_type,decision,
    commercial_value,required_advance,verified_payment_amount,wallet_applied_amount,approved_credit_amount,covered_amount,
    reason,evidence_reference,actor_id,actor_role,source_channel,source_reference,correlation_id,idempotency_key,facts_snapshot)
  VALUES(v_invoice.order_id,v_invoice.company_id,v_invoice.proforma_invoice_id,v_invoice.commercial_version_id,'DISPATCH',v_decision,
    v_invoice.gross_total,0,(v_settlement->>'verified_payment_total')::numeric,(v_settlement->>'wallet_applied_total')::numeric,
    (v_settlement->>'approved_credit_total')::numeric,
    (v_settlement->>'verified_payment_total')::numeric+(v_settlement->>'wallet_applied_total')::numeric+(v_settlement->>'approved_credit_total')::numeric,
    btrim(p_reason),btrim(p_evidence_reference),v_actor,v_role,'FINANCE',p_final_invoice_id::text,btrim(p_correlation_id),btrim(p_idempotency_key),
    jsonb_build_object('final_invoice_id',p_final_invoice_id,'settlement',v_settlement,'eway_evidence_id',v_eway.id,'dispatch_release_mutated',false))
  RETURNING * INTO v_event;
  v_response:=jsonb_build_object('clearance_event_id',v_event.id,'decision',v_event.decision,'clearance_type','DISPATCH','order_id',v_invoice.order_id);
  INSERT INTO public.finance_clearance_idempotency(idempotency_key,operation,request_fingerprint,clearance_event_id,actor_id,response)
  VALUES(btrim(p_idempotency_key),v_operation,v_fingerprint,v_event.id,v_actor,v_response);
  RETURN QUERY SELECT v_event.id,v_event.decision,false;
END;
$$;
