-- MACRO-DISPATCH-FINALIZE: canonical order-level dispatch finalization.
--
-- Physical/carton authority remains in the existing B2B gate ledger and immutable
-- dispatch proof packet. This RPC performs only the final governed order status
-- transition after those authorities have already succeeded.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

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

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

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

  -- A clearance may be revoked after a proof packet was recorded. Final status
  -- therefore re-checks the live Finance authority at the moment of transition.
  BEGIN
    v_clearance := public.assert_active_dispatch_clearance_v1(p_order_id);
  EXCEPTION WHEN OTHERS THEN
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
  -- and the optional transport values above agree with it.
  IF lower(coalesce(v_order.status, '')) = 'dispatched' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'order_id', p_order_id,
      'previous_status', 'dispatched',
      'new_status', 'dispatched',
      'already_applied', true,
      'dispatch_proof_id', v_proof.id,
      'finance_dispatch_clearance_event_id', v_clearance
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

  v_correlation := coalesce(nullif(btrim(p_correlation_id), ''), v_proof.correlation_id);

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
