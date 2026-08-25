-- Oasis App-Verse: 3PGS operational gap closure (Central issue #368).
--
-- The governed P&A -> 3PGS reserve/issue/acknowledge chain already exists.
-- The real gap was downstream: after a genuine 3PGS fulfilment,
-- b2b_assembly_components was not credited, so the P&A job could remain
-- permanently stuck at partially_reserved.
--
-- This migration closes that gap while preserving two non-negotiable
-- invariants found during adversarial review:
--   1. Stock issued but not yet acknowledged remains COMMITTED to the
--      requirement and cannot be reserved again.
--   2. P&A component credit/job resumption requires real receiver-acknowledged
--      custody evidence. A direct fulfil call cannot fabricate stock movement.
--
-- Lock ordering follows the assembly hierarchy (job -> component ->
-- requirement) to avoid inverse-lock deadlocks with existing assembly flows.
-- No RLS/AAL2/audit weakening; no production deployment in this PR.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 1. reserve_3pgs_requirement_stock
--    Serialize per requirement and count BOTH still-reserved and already-issued
--    quantities. issue_rgs_stock moves quantity from reserved_qty to
--    fulfilled_qty on inventory_reservations before receiver acknowledgement;
--    that issued quantity has physically left the source store and must remain
--    committed until the custody chain resolves.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.reserve_3pgs_requirement_stock(
  p_requirement_id uuid,
  p_priority text,
  p_correlation_id text
)
RETURNS public.inventory_reservations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
  v_reservation public.inventory_reservations%ROWTYPE;
  v_committed_qty numeric;
  v_target_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to reserve 3PGS stock against a requirement' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  -- Exact replay returns the original reservation before any outstanding
  -- calculation can reject it.
  SELECT * INTO v_reservation
  FROM public.inventory_reservations
  WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_reservation;
  END IF;

  -- Requirement-level serialization prevents two operators from calculating
  -- the same outstanding quantity concurrently.
  SELECT * INTO v_requirement
  FROM public.b2b_assembly_3pgs_requirements
  WHERE id = p_requirement_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '3PGS requirement not found';
  END IF;
  IF v_requirement.status IN ('fulfilled', 'cancelled') THEN
    RAISE EXCEPTION '3PGS requirement is already % and cannot be reserved against', v_requirement.status;
  END IF;

  -- IMPORTANT: inventory_reservations.fulfilled_qty means quantity already
  -- issued from the source store, not receiver-acknowledged requirement
  -- fulfilment. It must therefore remain counted as committed alongside
  -- reserved_qty. Do NOT also subtract v_requirement.fulfilled_qty here:
  -- acknowledged quantities are already included in the reservation row's
  -- fulfilled_qty, so doing both would double-count them.
  SELECT coalesce(sum(coalesce(reserved_qty, 0) + coalesce(fulfilled_qty, 0)), 0)
  INTO v_committed_qty
  FROM public.inventory_reservations
  WHERE demand_source_type = 'pna'
    AND demand_reference = v_requirement.requirement_number
    AND reservation_status NOT IN ('released', 'expired', 'cancelled');

  v_target_qty := v_requirement.requested_qty - v_committed_qty;
  IF v_target_qty <= 0 THEN
    RAISE EXCEPTION 'The full quantity for this 3PGS requirement is already committed (reserved or issued)';
  END IF;

  v_reservation := public.reserve_rgs_stock(
    p_reservation_number := v_requirement.requirement_number || ':' || p_correlation_id,
    p_order_id := NULL,
    p_product_id := v_requirement.product_id,
    p_sku := v_requirement.sku,
    p_requested_qty := v_target_qty,
    p_source_department := '3PGS',
    p_correlation_id := p_correlation_id,
    p_priority := coalesce(p_priority, 'normal'),
    p_location_code := v_requirement.source_store_code,
    p_demand_source_type := 'pna',
    p_demand_reference := v_requirement.requirement_number
  );

  RETURN v_reservation;
END;
$$;

COMMENT ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) IS
  'Bridges a P&A 3PGS requirement into reserve_rgs_stock. Serializes concurrent reservations per requirement and counts reserved plus already-issued quantity as committed, preventing re-reservation while issued stock awaits acknowledgement.';

REVOKE ALL ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) TO authenticated;

-- =================================================================================
-- 2. fulfil_assembly_3pgs_requirement
--    Close the loop into the P&A component/job, but only up to the amount of
--    real receiver-acknowledged custody evidence recorded on linked issue
--    events. The public signature is preserved because
--    acknowledge_3pgs_requirement_receipt already calls this function.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.fulfil_assembly_3pgs_requirement(
  p_requirement_id uuid,
  p_fulfilled_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_assembly_3pgs_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
  v_requirement_probe public.b2b_assembly_3pgs_requirements%ROWTYPE;
  v_component public.b2b_assembly_components%ROWTYPE;
  v_credit numeric;
  v_component_short boolean;
  v_acknowledged_total numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to fulfil a 3PGS requirement' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_fulfilled_qty IS NULL OR p_fulfilled_qty <= 0 THEN
    RAISE EXCEPTION 'Fulfilled quantity must be positive';
  END IF;

  -- Exact replay is harmless and returns the current requirement state.
  IF EXISTS (
    SELECT 1
    FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id
      AND movement_type = 'assembly_3pgs_requirement_fulfilled'
  ) THEN
    SELECT * INTO v_requirement
    FROM public.b2b_assembly_3pgs_requirements
    WHERE id = p_requirement_id;
    RETURN v_requirement;
  END IF;

  -- Read identifiers first without a row lock, then acquire locks in the
  -- canonical parent->child order used by assembly workflows:
  -- job -> component -> requirement. Re-read the requirement under lock.
  SELECT * INTO v_requirement_probe
  FROM public.b2b_assembly_3pgs_requirements
  WHERE id = p_requirement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '3PGS requirement not found';
  END IF;

  PERFORM 1
  FROM public.b2b_assembly_jobs
  WHERE id = v_requirement_probe.assembly_job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linked assembly job not found';
  END IF;

  SELECT * INTO v_component
  FROM public.b2b_assembly_components
  WHERE id = v_requirement_probe.assembly_component_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linked assembly component not found';
  END IF;

  SELECT * INTO v_requirement
  FROM public.b2b_assembly_3pgs_requirements
  WHERE id = p_requirement_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '3PGS requirement not found';
  END IF;

  -- Defensive linkage re-check after all locks are acquired.
  IF v_requirement.assembly_job_id IS DISTINCT FROM v_requirement_probe.assembly_job_id
     OR v_requirement.assembly_component_id IS DISTINCT FROM v_requirement_probe.assembly_component_id THEN
    RAISE EXCEPTION '3PGS requirement linkage changed during fulfilment' USING ERRCODE = '40001';
  END IF;

  IF v_requirement.status = 'cancelled' THEN
    RETURN v_requirement;
  END IF;
  IF v_requirement.status = 'fulfilled' THEN
    RETURN v_requirement;
  END IF;
  IF v_requirement.fulfilled_qty + p_fulfilled_qty > v_requirement.requested_qty THEN
    RAISE EXCEPTION 'Fulfilled quantity would exceed requested quantity';
  END IF;

  -- Custody proof: only receiver-acknowledged issue quantity linked to this
  -- exact P&A requirement can back requirement fulfilment. acknowledge_rgs_issue
  -- records acknowledged_qty/acknowledged_at and status acknowledged|variance
  -- before acknowledge_3pgs_requirement_receipt calls this function, so the
  -- evidence is visible in the same transaction. A direct caller with receive
  -- authority cannot manufacture P&A credit without this evidence.
  SELECT coalesce(sum(coalesce(acknowledged_qty, 0)), 0)
  INTO v_acknowledged_total
  FROM public.rgs_issue_events
  WHERE destination_type = 'pna'
    AND destination_reference = v_requirement.requirement_number
    AND status IN ('acknowledged', 'variance')
    AND acknowledged_at IS NOT NULL;

  IF v_requirement.fulfilled_qty + p_fulfilled_qty > v_acknowledged_total THEN
    RAISE EXCEPTION 'Fulfilment requires acknowledged 3PGS custody evidence (% requested cumulative, % acknowledged)',
      v_requirement.fulfilled_qty + p_fulfilled_qty, v_acknowledged_total;
  END IF;

  UPDATE public.b2b_assembly_3pgs_requirements
  SET fulfilled_qty = fulfilled_qty + p_fulfilled_qty,
      status = CASE
        WHEN fulfilled_qty + p_fulfilled_qty >= requested_qty THEN 'fulfilled'
        ELSE 'partially_fulfilled'
      END,
      updated_at = now()
  WHERE id = p_requirement_id
  RETURNING * INTO v_requirement;

  INSERT INTO public.inventory_movements (
    movement_type, product_id, sku, quantity, actor_id, correlation_id,
    source_document_type, source_document_reference, metadata
  ) VALUES (
    'assembly_3pgs_requirement_fulfilled',
    v_requirement.product_id,
    v_requirement.sku,
    p_fulfilled_qty,
    v_actor_id,
    p_correlation_id,
    'b2b_assembly_3pgs_requirement',
    v_requirement.requirement_number,
    jsonb_build_object(
      'requirement_id', v_requirement.id,
      'acknowledged_custody_total', v_acknowledged_total
    )
  );

  -- Stock represented by this fulfilment already left the 3PGS balance via
  -- issue_rgs_stock and has now been receiver-acknowledged. Credit reserved
  -- and issued in lockstep so issue_assembly_components cannot decrement the
  -- source stock a second time.
  v_credit := greatest(
    least(v_component.required_qty - v_component.reserved_qty, p_fulfilled_qty),
    0
  );

  IF v_credit > 0 THEN
    UPDATE public.b2b_assembly_components
    SET reserved_qty = least(reserved_qty + v_credit, required_qty),
        issued_qty = least(issued_qty + v_credit, required_qty)
    WHERE id = v_component.id;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.b2b_assembly_components
    WHERE assembly_job_id = v_requirement.assembly_job_id
      AND reserved_qty < required_qty
  ) INTO v_component_short;

  IF NOT v_component_short THEN
    UPDATE public.b2b_assembly_jobs
    SET status = 'materials_reserved',
        reserved_at = coalesce(reserved_at, now()),
        updated_at = now()
    WHERE id = v_requirement.assembly_job_id
      AND status = 'partially_reserved';
  END IF;

  RETURN v_requirement;
END;
$$;

COMMENT ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) IS
  'Credits a P&A 3PGS requirement/component only up to linked receiver-acknowledged issue quantity. Uses job->component->requirement lock order, prevents direct fulfilment without custody evidence, and resumes the assembly job when every component is fully covered.';

REVOKE ALL ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) TO authenticated;
