-- FACT-C1: governed carton-content, evidence and lock authority.
--
-- The b2b_dispatch_contract migration (20260804103000) already modelled the
-- full carton lifecycle -- b2b_dispatch_carton_items (product/order-line
-- binding, batch_lot, per-unit barcode, scan attribution), the
-- b2b_dispatch_product_scan_events fail-closed rejection taxonomy, and the
-- b2b_dispatch_carton_lock_evidence_check CHECK constraint gating
-- locked/verified/labelled/ready_to_load/loaded/handed_over behind a real
-- photo + net/gross weight + locked_by/locked_at -- but no RPC ever wrote
-- to any of it, and the tables were left reachable by direct client
-- INSERT/UPDATE/DELETE via "FOR ALL" RLS policies gated only on role, with
-- no server-side cross-validation. That means a browser could, today,
-- insert an arbitrary carton_item claiming any product/quantity/batch, or
-- flip a carton straight to 'locked' with fabricated weight/photo refs,
-- entirely bypassing the schema's own evidence intent. This migration
-- closes that gap with three governed RPCs and locks the underlying tables
-- to RPC-only mutation, without altering the existing carton lifecycle,
-- state list or open_b2b_dispatch_carton's caller-supplied carton_code
-- contract (which already plays the same physical-barcode role as the
-- legacy carton barcode, per that RPC's own migration comment).
--
-- Scope is intentionally narrow: carton content scan-in, evidence capture,
-- and evidence-gated locking only. DPL creation/versioning/submission is a
-- separate FACT-C2 authority against the already-existing (and otherwise
-- untouched) b2b_dispatch_packing_list_versions table.

-- =============================================================================
-- A. Idempotency support: a scan attempt retried with the same correlation
--    id (e.g. a scanner retrying after a dropped response) must return the
--    same recorded outcome, not create a second audit row.
-- =============================================================================

ALTER TABLE public.b2b_dispatch_product_scan_events
  ADD CONSTRAINT b2b_dispatch_product_scan_event_carton_correlation_unique
  UNIQUE (carton_id, correlation_id);

-- =============================================================================
-- B. Governed carton-content recording (scan-in).
--
-- Resolves the physical barcode to an authoritative product via
-- products.barcode_sku/sku (never trusting a client-declared product_id),
-- and validates it against the specific consignment line the operator says
-- they are packing -- so neither the product identity nor the order/line
-- binding is taken on the browser's word.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_b2b_dispatch_carton_item_scan(
  p_carton_id uuid,
  p_consignment_line_id uuid,
  p_barcode_value text,
  p_batch_lot text,
  p_quantity numeric,
  p_correlation_id text,
  p_expiry_date date DEFAULT NULL,
  p_device_id text DEFAULT NULL
)
RETURNS public.b2b_dispatch_product_scan_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_barcode text := nullif(btrim(p_barcode_value), '');
  v_batch_lot text := nullif(btrim(p_batch_lot), '');
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_carton public.b2b_dispatch_cartons%ROWTYPE;
  v_line public.b2b_dispatch_consignment_lines%ROWTYPE;
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_resolved_product_id uuid;
  v_existing_event public.b2b_dispatch_product_scan_events%ROWTYPE;
  v_existing_item public.b2b_dispatch_carton_items%ROWTYPE;
  v_packed_so_far numeric;
  v_item public.b2b_dispatch_carton_items%ROWTYPE;
  v_event public.b2b_dispatch_product_scan_events%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to record a dispatch carton scan' USING ERRCODE = '42501';
  END IF;
  IF v_barcode IS NULL OR v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A barcode value and correlation id are required';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Scan quantity must be positive';
  END IF;

  SELECT * INTO v_carton FROM public.b2b_dispatch_cartons WHERE id = p_carton_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton not found';
  END IF;

  -- Idempotent replay: the exact same scan attempt (same carton +
  -- correlation id) returns its already-recorded outcome directly, whether
  -- it was accepted or rejected, rather than re-validating or
  -- double-applying quantity.
  SELECT * INTO v_existing_event
  FROM public.b2b_dispatch_product_scan_events
  WHERE carton_id = p_carton_id AND correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing_event;
  END IF;

  IF v_carton.status NOT IN ('open', 'under_packing', 'photo_required') THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_unreleased', v_actor_id, p_device_id,
      format('carton is %s', v_carton.status), v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  SELECT * INTO v_line FROM public.b2b_dispatch_consignment_lines WHERE id = p_consignment_line_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment line not found';
  END IF;

  IF v_line.consignment_id <> v_carton.consignment_id THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_wrong_so', v_actor_id, p_device_id,
      'consignment line does not belong to this carton''s consignment', v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = v_carton.consignment_id;
  IF v_consignment.status IN ('dispatched', 'delivery_exception', 'delivered', 'closed', 'cancelled') THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_unreleased', v_actor_id, p_device_id,
      format('consignment is %s', v_consignment.status), v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  IF v_batch_lot IS NULL THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_wrong_batch', v_actor_id, p_device_id, 'batch/lot is required', v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  IF p_expiry_date IS NOT NULL AND p_expiry_date < current_date THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_expired', v_actor_id, p_device_id, 'expiry date is in the past', v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  -- Resolve the physical barcode to a real product independently of
  -- whatever the caller believes it scanned -- the caller never supplies
  -- product_id directly.
  SELECT id INTO v_resolved_product_id
  FROM public.products
  WHERE barcode_sku = v_barcode OR sku = v_barcode
  LIMIT 1;

  IF v_resolved_product_id IS NULL OR v_resolved_product_id <> v_line.product_id THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, resolved_product_id, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_wrong_product', v_resolved_product_id, v_actor_id, p_device_id,
      'scanned barcode does not resolve to the expected consignment-line product', v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  SELECT * INTO v_existing_item FROM public.b2b_dispatch_carton_items
    WHERE carton_id = p_carton_id AND barcode_value = v_barcode;
  IF FOUND THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, resolved_product_id, resolved_batch_lot, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_duplicate', v_resolved_product_id, v_existing_item.batch_lot, v_actor_id, p_device_id,
      'barcode already recorded against this carton', v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  SELECT coalesce(sum(quantity), 0) INTO v_packed_so_far
  FROM public.b2b_dispatch_carton_items
  WHERE consignment_line_id = p_consignment_line_id;

  IF v_packed_so_far + p_quantity > v_line.accepted_ready_qty + 0.0001 THEN
    INSERT INTO public.b2b_dispatch_product_scan_events
      (carton_id, barcode_value, scan_result, resolved_product_id, resolved_batch_lot, scanned_by, device_id, reason, correlation_id)
    VALUES (p_carton_id, v_barcode, 'blocked_excess', v_resolved_product_id, v_batch_lot, v_actor_id, p_device_id,
      format('packing %s would exceed accepted-ready quantity %s (already packed %s)', p_quantity, v_line.accepted_ready_qty, v_packed_so_far),
      v_correlation_id)
    RETURNING * INTO v_event;
    RETURN v_event;
  END IF;

  INSERT INTO public.b2b_dispatch_carton_items (
    carton_id, consignment_line_id, order_item_id, product_id, product_code,
    barcode_value, batch_lot, expiry_date, uom, quantity, scan_status, scanned_by, scan_device_id
  ) VALUES (
    p_carton_id, p_consignment_line_id, v_line.order_item_id, v_line.product_id, v_line.product_code,
    v_barcode, v_batch_lot, p_expiry_date, v_line.uom, p_quantity, 'verified', v_actor_id, p_device_id
  ) RETURNING * INTO v_item;

  UPDATE public.b2b_dispatch_consignment_lines
  SET packed_qty = packed_qty + p_quantity
  WHERE id = p_consignment_line_id;

  IF v_carton.status = 'open' THEN
    UPDATE public.b2b_dispatch_cartons SET status = 'under_packing' WHERE id = p_carton_id;
  END IF;

  INSERT INTO public.b2b_dispatch_product_scan_events
    (carton_id, barcode_value, scan_result, resolved_product_id, resolved_batch_lot, scanned_by, device_id, correlation_id)
  VALUES (p_carton_id, v_barcode, 'verified', v_resolved_product_id, v_batch_lot, v_actor_id, p_device_id, v_correlation_id)
  RETURNING * INTO v_event;

  INSERT INTO public.b2b_dispatch_events (
    order_id, order_item_id, consignment_id, carton_id, event_type, quantity, uom,
    custodian_id, actor_id, actor_role, device_id, source_record_type, source_record_id, correlation_id
  ) VALUES (
    v_consignment.order_id, v_line.order_item_id, v_carton.consignment_id, p_carton_id, 'carton_item_scanned',
    p_quantity, v_line.uom, v_actor_id, v_actor_id, public.get_user_role(v_actor_id), p_device_id,
    'b2b_dispatch_carton_items', v_item.id, v_correlation_id
  );

  RETURN v_event;
END;
$$;

COMMENT ON FUNCTION public.record_b2b_dispatch_carton_item_scan(uuid, uuid, text, text, numeric, text, date, text) IS
  'Governed carton content scan-in. Resolves barcode to a real product server-side, validates it against the declared consignment line, enforces batch/expiry/duplicate/excess-quantity fail-closed rejections, and reconciles consignment_line.packed_qty. Returns the recorded b2b_dispatch_product_scan_events row (scan_result indicates verified vs. the specific blocked_* rejection); all attempts, accepted or rejected, are persisted with the taxonomy the schema already defines.';

REVOKE ALL ON FUNCTION public.record_b2b_dispatch_carton_item_scan(uuid, uuid, text, text, numeric, text, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_b2b_dispatch_carton_item_scan(uuid, uuid, text, text, numeric, text, date, text) TO authenticated;

-- =============================================================================
-- C. Governed evidence capture (weight + open photo), pre-lock.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_b2b_dispatch_carton_evidence(
  p_carton_id uuid,
  p_net_weight numeric,
  p_gross_weight numeric,
  p_open_photo_ref text,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_cartons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_photo_ref text := nullif(btrim(p_open_photo_ref), '');
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_carton public.b2b_dispatch_cartons%ROWTYPE;
  v_carton_out public.b2b_dispatch_cartons%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to record dispatch carton evidence' USING ERRCODE = '42501';
  END IF;
  IF v_photo_ref IS NULL OR v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A photo reference and correlation id are required';
  END IF;
  IF p_net_weight IS NULL OR p_net_weight < 0 OR p_gross_weight IS NULL OR p_gross_weight < 0 THEN
    RAISE EXCEPTION 'Net and gross weight must be non-negative';
  END IF;
  IF p_gross_weight + 0.0001 < p_net_weight THEN
    RAISE EXCEPTION 'Gross weight cannot be less than net weight';
  END IF;

  SELECT * INTO v_carton FROM public.b2b_dispatch_cartons WHERE id = p_carton_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton not found';
  END IF;
  IF v_carton.status NOT IN ('open', 'under_packing', 'photo_required') THEN
    RAISE EXCEPTION 'Carton % is % and its evidence can no longer be amended', p_carton_id, v_carton.status USING ERRCODE = '42501';
  END IF;

  UPDATE public.b2b_dispatch_cartons
  SET net_weight = p_net_weight, gross_weight = p_gross_weight, open_photo_ref = v_photo_ref
  WHERE id = p_carton_id
  RETURNING * INTO v_carton_out;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, carton_id, event_type, actor_id, actor_role,
    source_record_type, source_record_id, evidence_refs, correlation_id
  )
  SELECT c.order_id, v_carton.consignment_id, p_carton_id, 'carton_evidence_recorded', v_actor_id,
    public.get_user_role(v_actor_id), 'b2b_dispatch_cartons', p_carton_id, jsonb_build_array(v_photo_ref), v_correlation_id
  FROM public.b2b_dispatch_consignments c WHERE c.id = v_carton.consignment_id;

  RETURN v_carton_out;
END;
$$;

COMMENT ON FUNCTION public.record_b2b_dispatch_carton_evidence(uuid, numeric, numeric, text, text) IS
  'Records the net/gross weight and open-carton photo reference a carton needs before it can be locked. Rejects amendment once the carton has advanced past packing.';

REVOKE ALL ON FUNCTION public.record_b2b_dispatch_carton_evidence(uuid, numeric, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_b2b_dispatch_carton_evidence(uuid, numeric, numeric, text, text) TO authenticated;

-- =============================================================================
-- D. Evidence-gated, optimistically-concurrent carton lock.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.lock_b2b_dispatch_carton(
  p_carton_id uuid,
  p_expected_version integer,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_cartons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_carton public.b2b_dispatch_cartons%ROWTYPE;
  v_carton_out public.b2b_dispatch_cartons%ROWTYPE;
  v_item_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to lock a dispatch carton' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_expected_version IS NULL THEN
    RAISE EXCEPTION 'The expected carton version is required';
  END IF;

  SELECT * INTO v_carton FROM public.b2b_dispatch_cartons WHERE id = p_carton_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton not found';
  END IF;

  IF v_carton.status IN ('locked', 'finance_check_open', 'verified', 'labelled', 'ready_to_load', 'loaded', 'handed_over') THEN
    RAISE EXCEPTION 'Carton % is already locked' , p_carton_id USING ERRCODE = '42501';
  END IF;
  IF v_carton.status NOT IN ('open', 'under_packing', 'photo_required') THEN
    RAISE EXCEPTION 'Carton % is % and cannot be locked from this state', p_carton_id, v_carton.status USING ERRCODE = '42501';
  END IF;
  IF v_carton.current_version <> p_expected_version THEN
    RAISE EXCEPTION 'Carton % has changed since it was loaded; reload and retry', p_carton_id USING ERRCODE = '40001';
  END IF;

  SELECT count(*) INTO v_item_count FROM public.b2b_dispatch_carton_items WHERE carton_id = p_carton_id;
  IF v_item_count = 0 THEN
    RAISE EXCEPTION 'Carton % has no scanned contents and cannot be locked', p_carton_id USING ERRCODE = '22023';
  END IF;
  IF v_carton.net_weight IS NULL OR v_carton.gross_weight IS NULL OR v_carton.open_photo_ref IS NULL THEN
    RAISE EXCEPTION 'Carton % is missing required weight or photo evidence', p_carton_id USING ERRCODE = '22023';
  END IF;

  UPDATE public.b2b_dispatch_cartons
  SET status = 'locked', locked_by = v_actor_id, locked_at = now(), current_version = current_version + 1
  WHERE id = p_carton_id AND current_version = p_expected_version
  RETURNING * INTO v_carton_out;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton % has changed since it was loaded; reload and retry', p_carton_id USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, carton_id, event_type, old_status, new_status,
    custodian_id, actor_id, actor_role, source_record_type, source_record_id, correlation_id
  )
  SELECT c.order_id, v_carton.consignment_id, p_carton_id, 'carton_locked', v_carton.status, 'locked',
    v_actor_id, v_actor_id, public.get_user_role(v_actor_id), 'b2b_dispatch_cartons', p_carton_id, v_correlation_id
  FROM public.b2b_dispatch_consignments c WHERE c.id = v_carton.consignment_id;

  RETURN v_carton_out;
END;
$$;

COMMENT ON FUNCTION public.lock_b2b_dispatch_carton(uuid, integer, text) IS
  'Locks a carton once it has at least one scanned item and complete weight/photo evidence. Optimistically concurrent on current_version; rejects an already-locked carton (no silent replay) and any stale-version caller.';

REVOKE ALL ON FUNCTION public.lock_b2b_dispatch_carton(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lock_b2b_dispatch_carton(uuid, integer, text) TO authenticated;

-- =============================================================================
-- E. Close the direct-write gap: these three tables are now RPC-only for
--    mutation. SELECT access for internal staff (granted by the base
--    migration's blanket read policies) is untouched.
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_cartons FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_carton_items FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_product_scan_events FROM authenticated;

DROP POLICY IF EXISTS "Dispatch operators maintain cartons" ON public.b2b_dispatch_cartons;
DROP POLICY IF EXISTS "Dispatch operators maintain carton items" ON public.b2b_dispatch_carton_items;
DROP POLICY IF EXISTS "Dispatch operators record product scan events" ON public.b2b_dispatch_product_scan_events;
