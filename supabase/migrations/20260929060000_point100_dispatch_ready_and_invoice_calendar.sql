-- Point100 authority-gap closure:
-- 1) governed locked -> ready_to_load transition for B2B cartons
-- 2) final-invoice business-date consistency with Asia/Kolkata
--
-- This migration removes the need for certification-only shadow SQL and
-- aligns final-invoice date validation with the existing final-payment
-- request gate, which already evaluates issued_at in Asia/Kolkata.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =============================================================================
-- A. Governed carton readiness transition
-- =============================================================================

CREATE OR REPLACE FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(
  p_carton_id uuid,
  p_correlation_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_carton public.b2b_dispatch_cartons%rowtype;
  v_consignment public.b2b_dispatch_consignments%rowtype;
  v_order public.orders%rowtype;
  v_clearance uuid;
  v_receipt_id uuid;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor) THEN
    RAISE EXCEPTION 'Not authorised to mark a dispatch carton ready to load'
      USING ERRCODE = '42501';
  END IF;

  IF p_carton_id IS NULL OR v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'Carton id and correlation id are required'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('carton-ready-to-load:' || p_carton_id::text, 0));

  SELECT *
    INTO v_carton
    FROM public.b2b_dispatch_cartons
   WHERE id = p_carton_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(jsonb_build_object('code', 'carton_not_found'))
    );
  END IF;

  IF v_carton.status IN ('ready_to_load', 'loaded', 'handed_over') THEN
    RETURN jsonb_build_object(
      'ok', true,
      'carton_id', p_carton_id,
      'status', v_carton.status,
      'already_ready', true
    );
  END IF;

  IF v_carton.status <> 'locked' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(
        jsonb_build_object(
          'code', 'carton_not_locked_for_readiness',
          'status', v_carton.status
        )
      )
    );
  END IF;

  IF v_carton.open_photo_ref IS NULL
     OR v_carton.net_weight IS NULL
     OR v_carton.gross_weight IS NULL
     OR v_carton.locked_by IS NULL
     OR v_carton.locked_at IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(
        jsonb_build_object('code', 'carton_lock_evidence_incomplete')
      )
    );
  END IF;

  SELECT *
    INTO v_consignment
    FROM public.b2b_dispatch_consignments
   WHERE id = v_carton.consignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(
        jsonb_build_object('code', 'consignment_not_found')
      )
    );
  END IF;

  SELECT *
    INTO v_order
    FROM public.orders
   WHERE id = v_consignment.order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(
        jsonb_build_object('code', 'order_not_found')
      )
    );
  END IF;

  -- Ready-to-load is a post-Finance transition. It must be backed by the
  -- same active Finance dispatch clearance consumed by the independent gate.
  v_clearance := public.assert_active_dispatch_clearance_v1(v_order.id);

  -- The carton must belong to the exact Finance DPL used by the issued final
  -- invoice. This prevents a locked carton from being promoted merely because
  -- some other carton/order version has clearance.
  SELECT r.id
    INTO v_receipt_id
    FROM public.final_invoices f
    JOIN public.finance_dpl_receipts r
      ON r.id = f.finance_dpl_receipt_id
   WHERE f.order_id = v_order.id
     AND f.status = 'ISSUED'
     AND EXISTS (
       SELECT 1
         FROM jsonb_array_elements_text(r.dpl_snapshot->'carton_ids') c(value)
        WHERE c.value = p_carton_id::text
     )
   ORDER BY f.created_at DESC
   LIMIT 1;

  IF v_receipt_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(
        jsonb_build_object('code', 'carton_not_in_final_finance_dpl')
      )
    );
  END IF;

  UPDATE public.b2b_dispatch_cartons
     SET status = 'ready_to_load',
         physical_location = 'READY_TO_LOAD_BAY',
         updated_at = statement_timestamp()
   WHERE id = p_carton_id
     AND status = 'locked';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton readiness transition raced with another update'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.b2b_dispatch_events (
    order_id,
    consignment_id,
    carton_id,
    event_type,
    old_status,
    new_status,
    location_code,
    actor_id,
    actor_role,
    source_record_type,
    source_record_id,
    authority_id,
    correlation_id,
    metadata
  ) VALUES (
    v_order.id,
    v_consignment.id,
    p_carton_id,
    'carton_ready_to_load',
    'locked',
    'ready_to_load',
    'READY_TO_LOAD_BAY',
    v_actor,
    public.get_user_role(v_actor),
    'b2b_dispatch_cartons',
    p_carton_id,
    v_clearance,
    v_correlation_id,
    jsonb_build_object(
      'finance_dpl_receipt_id', v_receipt_id,
      'authority', 'FINANCE_DISPATCH_CLEARANCE'
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'carton_id', p_carton_id,
    'status', 'ready_to_load',
    'already_ready', false,
    'finance_dispatch_clearance_event_id', v_clearance,
    'finance_dpl_receipt_id', v_receipt_id
  );
END;
$$;

COMMENT ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, text) IS
  'Governed post-Finance carton transition from locked to ready_to_load. Requires complete carton lock evidence, active Finance dispatch clearance, and membership in the exact Finance DPL bound to the issued final invoice. Idempotent once the carton is ready_to_load, loaded, or handed_over.';

REVOKE ALL ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, text)
  TO authenticated;

-- =============================================================================
-- B. India business-date consistency for final-invoice issuance
-- =============================================================================

-- issue_final_invoice_v1 validates p_invoice_date against current_date.
-- Configure the function-local timezone so current_date uses the same
-- Asia/Kolkata business calendar as the final-payment request trigger.
ALTER FUNCTION public.issue_final_invoice_v1(
  uuid, uuid, uuid, uuid, text, date, text, text, text, text, uuid
) SET TimeZone TO 'Asia/Kolkata';
