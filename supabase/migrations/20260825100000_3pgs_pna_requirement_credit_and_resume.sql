-- Oasis App-Verse: 3PGS operational gap closure (Central issue #368).
--
-- FINDING, verified directly against current main (not assumed from an
-- earlier report): the full governed RPC chain for P&A -> 3PGS fulfilment
-- already exists (20260820100000_3pgs_governed_fulfilment_authority.sql --
-- create_procurement_requirement/assign_procurement_vendor/
-- link_procurement_receipt, reserve_3pgs_requirement_stock/
-- issue_3pgs_requirement_stock/acknowledge_3pgs_requirement_receipt, and the
-- b2b_3pgs_pending_demand_priority queue view), and Central already has a
-- real, routed caller for every one of them
-- (src/pages/admin/ThreePgsProcurementQueue.tsx, /admin/3pgs-procurement-queue).
-- The prior Lane 1/Lane 2 reconciliation's claim that "no live 3PGS-side
-- fulfilment workflow consumes these requirements" is therefore WRONG on
-- current main -- this migration does not build that workflow, because it
-- is not missing.
--
-- THE ACTUAL, NARROW GAP: fulfil_assembly_3pgs_requirement (PR B, unaltered
-- signature, still called verbatim by acknowledge_3pgs_requirement_receipt)
-- only ever updated b2b_assembly_3pgs_requirements itself. Nothing credited
-- the linked b2b_assembly_components.reserved_qty/issued_qty, and
-- authorize_partial_assembly_issue's unresolved-3PGS-shortfall check reads
-- EXACTLY that column (reserved_qty < required_qty), not the requirement's
-- own status. A 3PGS requirement could therefore reach a genuine, fully
-- evidenced 'fulfilled' status -- real reservation, real issue, real
-- distinct-actor acknowledgement, all already governed and unmodified here
-- -- while the P&A job that raised it stayed permanently stuck at
-- partially_reserved, because nothing ever told the job's own component
-- that its shortfall was actually covered. authorize_partial_assembly_issue
-- refuses unconditionally around any unresolved 3PGS/PACKING_ASSEMBLY/
-- B2B_RAW shortfall by design (20260819120000), so there was no
-- back door and no way to progress: the P&A side of this loop was a dead
-- end, not merely undiscovered.
--
-- FIX: extend fulfil_assembly_3pgs_requirement (same signature, same
-- idempotency guard, same callers -- acknowledge_3pgs_requirement_receipt
-- is unmodified) to credit the linked component's reserved_qty AND
-- issued_qty by the amount just fulfilled (capped at required_qty, so a
-- manually-raised requirement -- create_assembly_3pgs_requirement -- can
-- never over-credit a component even if its requested_qty does not exactly
-- match the live shortfall). issued_qty is credited in lockstep with
-- reserved_qty because the stock this represents already left 3PGS's
-- inventory_stock_balances via issue_3pgs_requirement_stock's own call to
-- issue_rgs_stock, and was already handed to a distinct, acknowledging
-- receiver -- it is not sitting in the store's reserved bucket waiting for
-- issue_assembly_components to move it a second time (which would double-
-- decrement a stock balance that issue_rgs_stock already correctly
-- decremented). Crediting only reserved_qty without issued_qty would make
-- issue_assembly_components's own per-component loop
-- (WHERE reserved_qty > issued_qty) attempt exactly that double-decrement
-- for the bridge-fulfilled quantity. Once every component of the job is
-- fully reserved, the job resumes from partially_reserved to
-- materials_reserved -- the same transition reserve_assembly_components
-- itself makes when its own reservation pass completes.
--
-- SECOND, NARROWER FINDING from adversarial self-review: two 3PGS operators
-- concurrently reserving against the SAME governed requirement could both
-- read the same "already reserved" total (an unlocked SELECT) before either
-- committed, together reserving more than the requirement's own
-- requested_qty (though never more than physically available -- that ceiling
-- is already enforced by reserve_rgs_stock's own advisory lock + FOR UPDATE
-- on the stock balance, unmodified and unaffected by this migration). Fixed
-- by locking the requirement row before computing the outstanding amount,
-- serialising concurrent reservation attempts against the same requirement.
--
-- Neither fix touches reserve_rgs_stock, issue_rgs_stock, or
-- acknowledge_rgs_issue -- all three remain exactly as hardened by prior
-- migrations. Neither weakens RLS, AAL2, audit, or idempotency anywhere.
-- Does not touch the vendor-shortage/procurement bridge (already correct),
-- the 3PGS packing-material catalogue, or any Production/Finance/PI/Sales/
-- CRM surface.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 1. reserve_3pgs_requirement_stock: lock the requirement row before reading
--    how much is already reserved against it, closing the concurrent
--    last-stock reservation race.
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
  v_already_reserved numeric;
  v_target_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to reserve 3PGS stock against a requirement' USING ERRCODE = '42501';
  END IF;

  -- Idempotent replay by correlation_id, checked before anything else: an
  -- exact retry of an already-successful call must return that reservation,
  -- never be rejected by the already-reserved computation below (which
  -- would otherwise see this very reservation as "already reserved" and
  -- refuse a legitimate replay).
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_reservation;
  END IF;

  -- FOR UPDATE: two operators concurrently reserving against the SAME
  -- requirement must serialise here. Without this lock, both could read the
  -- same v_already_reserved before either commits and together reserve more
  -- than the requirement's own requested_qty (physical stock itself stays
  -- protected regardless, by reserve_rgs_stock's own advisory lock + FOR
  -- UPDATE on the stock balance -- this lock closes the requirement-level
  -- over-commit, not a stock-level one).
  SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '3PGS requirement not found'; END IF;
  IF v_requirement.status IN ('fulfilled', 'cancelled') THEN
    RAISE EXCEPTION '3PGS requirement is already % and cannot be reserved against', v_requirement.status;
  END IF;

  -- A requirement can legitimately be reserved against more than once (e.g.
  -- a first call only partially covers it; a second call is made once more
  -- stock arrives). Each such call creates its OWN inventory_reservations
  -- row (reservation_number is suffixed by correlation_id -- see below), so
  -- the amount already held by every still-active prior reservation must be
  -- subtracted here, or a retry/second attempt would over-reserve on top of
  -- stock this requirement already has a claim on. reserved_qty ALREADY nets
  -- out fulfilled/released amounts as they happen (issue_rgs_stock and
  -- release_rgs_stock both decrement reserved_qty by exactly the amount they
  -- move into fulfilled_qty/released_qty) -- summing reserved_qty alone is
  -- therefore the full "still actively held" amount; subtracting
  -- fulfilled_qty/released_qty again here would double-count and
  -- UNDER-report how much is already reserved, risking over-allocation.
  SELECT coalesce(sum(reserved_qty), 0) INTO v_already_reserved
  FROM public.inventory_reservations
  WHERE demand_source_type = 'pna' AND demand_reference = v_requirement.requirement_number
    AND reservation_status NOT IN ('released', 'expired', 'cancelled');

  v_target_qty := v_requirement.requested_qty - v_requirement.fulfilled_qty - v_already_reserved;
  IF v_target_qty <= 0 THEN
    RAISE EXCEPTION 'The full outstanding quantity for this 3PGS requirement is already reserved';
  END IF;

  -- Suffixed with the correlation id (not the bare requirement_number, which
  -- never changes): a partially-reserved requirement legitimately supports a
  -- second, later reservation attempt once more stock arrives, and
  -- inventory_reservations.reservation_number is unique -- reusing the bare
  -- requirement_number would collide on that constraint for any such retry.
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
  'Bridges a P&A b2b_assembly_3pgs_requirements row into the existing, unmodified reserve_rgs_stock pipeline -- the SAME reservation mechanism outlet/b2b/internal 3PGS demand already uses. Does not duplicate reservation logic. Locks the requirement row before computing the outstanding amount, so two concurrent reservation attempts against the same requirement cannot together over-commit it.';

REVOKE ALL ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) TO authenticated;

-- =================================================================================
-- 2. fulfil_assembly_3pgs_requirement: close the loop back into the P&A
--    assembly component/job (the actual missing capability). Same
--    signature, same idempotency guard, same callers.
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
  v_credit numeric;
  v_component_short boolean;
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

  -- Idempotent replay by correlation_id, not merely by terminal status: a
  -- retried PARTIAL fulfilment call (status stays 'partially_fulfilled', not
  -- 'fulfilled') would otherwise double-count on every retry.
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'assembly_3pgs_requirement_fulfilled'
  ) THEN
    SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id;
    RETURN v_requirement;
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '3PGS requirement not found'; END IF;
  IF v_requirement.status IN ('fulfilled', 'cancelled') THEN
    RETURN v_requirement; -- idempotent replay (fully fulfilled/cancelled before this call was ever made)
  END IF;
  IF v_requirement.fulfilled_qty + p_fulfilled_qty > v_requirement.requested_qty THEN
    RAISE EXCEPTION 'Fulfilled quantity would exceed requested quantity';
  END IF;

  UPDATE public.b2b_assembly_3pgs_requirements
  SET fulfilled_qty = fulfilled_qty + p_fulfilled_qty,
      status = CASE WHEN fulfilled_qty + p_fulfilled_qty >= requested_qty THEN 'fulfilled' ELSE 'partially_fulfilled' END,
      updated_at = now()
  WHERE id = p_requirement_id
  RETURNING * INTO v_requirement;

  INSERT INTO public.inventory_movements (
    movement_type, product_id, sku, quantity, actor_id, correlation_id,
    source_document_type, source_document_reference, metadata
  ) VALUES (
    'assembly_3pgs_requirement_fulfilled', v_requirement.product_id, v_requirement.sku, p_fulfilled_qty,
    v_actor_id, p_correlation_id, 'b2b_assembly_3pgs_requirement', v_requirement.requirement_number,
    jsonb_build_object('requirement_id', v_requirement.id)
  );

  -- THE FIX: close the loop back into P&A's own assembly component
  -- reservation. Lock the component (matching reserve_assembly_components'
  -- own FOR UPDATE pattern) and credit exactly the amount just fulfilled,
  -- capped at required_qty so this can never over-reserve/over-issue the
  -- component even if a requirement's requested_qty was manually raised
  -- (create_assembly_3pgs_requirement) inconsistently with the component's
  -- real, current shortfall. issued_qty is credited in lockstep with
  -- reserved_qty (see file header: the stock already left 3PGS via
  -- issue_3pgs_requirement_stock -> issue_rgs_stock and was already handed
  -- to a distinct, acknowledging receiver -- crediting reserved_qty alone
  -- would make issue_assembly_components try to decrement the 3PGS store's
  -- balance a second time for stock that already left it).
  SELECT least(required_qty - reserved_qty, p_fulfilled_qty) INTO v_credit
  FROM public.b2b_assembly_components WHERE id = v_requirement.assembly_component_id FOR UPDATE;
  v_credit := greatest(coalesce(v_credit, 0), 0);

  IF v_credit > 0 THEN
    UPDATE public.b2b_assembly_components
    SET reserved_qty = least(reserved_qty + v_credit, required_qty),
        issued_qty = least(issued_qty + v_credit, required_qty)
    WHERE id = v_requirement.assembly_component_id;
  END IF;

  -- If every component of the linked job is now fully reserved, resume the
  -- job from partially_reserved to materials_reserved -- the same
  -- transition reserve_assembly_components itself makes when reservation
  -- completes there. Lock the job row first (matching
  -- reserve_assembly_components' own FOR UPDATE on the job) so this can
  -- never race a concurrent reserve_assembly_components call on the same
  -- job. Guarded to partially_reserved only: a no-op for a job already
  -- issued/cancelled/etc.
  PERFORM 1 FROM public.b2b_assembly_jobs WHERE id = v_requirement.assembly_job_id FOR UPDATE;
  SELECT EXISTS (
    SELECT 1 FROM public.b2b_assembly_components
    WHERE assembly_job_id = v_requirement.assembly_job_id AND reserved_qty < required_qty
  ) INTO v_component_short;
  IF NOT v_component_short THEN
    UPDATE public.b2b_assembly_jobs
    SET status = 'materials_reserved', reserved_at = coalesce(reserved_at, now()), updated_at = now()
    WHERE id = v_requirement.assembly_job_id AND status = 'partially_reserved';
  END IF;

  RETURN v_requirement;
END;
$$;

COMMENT ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) IS
  'Records that 3PGS has fulfilled (fully or partially) a governed P&A 3PGS requirement, called by acknowledge_3pgs_requirement_receipt once a distinct receiver confirms real receipt. Credits the linked assembly component''s reserved_qty/issued_qty by the amount fulfilled (capped at required_qty) and resumes the job from partially_reserved to materials_reserved once every component is fully reserved -- without this, a job could never progress past partially_reserved even after 3PGS genuinely, fully resolved its shortfall.';

REVOKE ALL ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) TO authenticated;
