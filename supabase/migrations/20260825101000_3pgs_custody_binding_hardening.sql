-- Oasis App-Verse: harden the P&A <- 3PGS custody boundary.
--
-- The credit/resume migration requires acknowledged custody before P&A credit.
-- This follow-up closes the remaining confused-deputy surface: the dedicated
-- acknowledgement wrapper must prove the issue event belongs to the exact
-- requirement/product/SKU/reservation, and the lower-level fulfil helper must
-- not be directly executable by ordinary authenticated sessions.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.acknowledge_3pgs_requirement_receipt(
  p_issue_event_id uuid,
  p_received_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_assembly_3pgs_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_issue public.rgs_issue_events%ROWTYPE;
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
  v_reservation public.inventory_reservations%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to acknowledge a 3PGS requirement receipt' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_received_qty IS NULL OR p_received_qty <= 0 THEN
    RAISE EXCEPTION 'Received quantity must be positive';
  END IF;

  SELECT * INTO v_issue
  FROM public.rgs_issue_events
  WHERE id = p_issue_event_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Issue event not found';
  END IF;
  IF v_issue.destination_type <> 'pna' THEN
    RAISE EXCEPTION 'This issue event was not dispatched against a P&A 3PGS requirement';
  END IF;
  IF nullif(btrim(v_issue.destination_reference), '') IS NULL THEN
    RAISE EXCEPTION 'Issue event has no linked P&A 3PGS requirement';
  END IF;
  IF v_issue.issued_by IS NULL OR v_actor_id = v_issue.issued_by THEN
    RAISE EXCEPTION 'The 3PGS requirement receiver must be a different actor than whoever issued it -- P&A cannot self-fulfil its own requirement' USING ERRCODE = '42501';
  END IF;
  IF p_received_qty > v_issue.issued_qty THEN
    RAISE EXCEPTION 'Received quantity cannot exceed the issued quantity (% > %)', p_received_qty, v_issue.issued_qty;
  END IF;

  SELECT * INTO v_requirement
  FROM public.b2b_assembly_3pgs_requirements
  WHERE requirement_number = v_issue.destination_reference
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linked 3PGS requirement not found for %', v_issue.destination_reference;
  END IF;

  -- Bind custody to the exact material identity. A token/wrong-SKU issue event
  -- carrying the same destination reference is not evidence for this requirement.
  IF v_issue.product_id IS DISTINCT FROM v_requirement.product_id
     OR v_issue.sku IS DISTINCT FROM v_requirement.sku THEN
    RAISE EXCEPTION 'Issue event material does not match the linked 3PGS requirement';
  END IF;

  -- Bind the issue back to a reservation that was itself created for this
  -- exact requirement and material. This prevents a generic RGS issue from
  -- borrowing the requirement number as its destination_reference.
  SELECT * INTO v_reservation
  FROM public.inventory_reservations
  WHERE id = v_issue.reservation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linked inventory reservation not found';
  END IF;
  IF v_reservation.demand_source_type <> 'pna'
     OR v_reservation.demand_reference IS DISTINCT FROM v_requirement.requirement_number
     OR v_reservation.product_id IS DISTINCT FROM v_requirement.product_id
     OR v_reservation.sku IS DISTINCT FROM v_requirement.sku THEN
    RAISE EXCEPTION 'Issue event reservation does not belong to the linked 3PGS requirement';
  END IF;

  -- The generic acknowledgement records the receiver/quantity evidence first.
  -- The fulfil helper then consumes that evidence in the same transaction.
  PERFORM public.acknowledge_rgs_issue(p_issue_event_id, p_received_qty, p_correlation_id);

  RETURN public.fulfil_assembly_3pgs_requirement(
    v_requirement.id,
    p_received_qty,
    p_correlation_id || ':fulfil'
  );
END;
$$;

COMMENT ON FUNCTION public.acknowledge_3pgs_requirement_receipt(uuid, numeric, text) IS
  'Authoritative receiver-side finalisation for a P&A 3PGS requirement. Requires a distinct receiver, positive quantity not exceeding the issue, exact product/SKU identity, and an issue reservation linked to the exact P&A requirement before acknowledgement and fulfilment can advance.';

REVOKE ALL ON FUNCTION public.acknowledge_3pgs_requirement_receipt(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_3pgs_requirement_receipt(uuid, numeric, text) TO authenticated;

-- fulfil_assembly_3pgs_requirement is an internal effect helper. Central has
-- no direct caller; the governed acknowledgement wrapper above is the sole
-- operational entry point. Keeping the helper non-executable by authenticated
-- sessions removes the remaining direct-call confused-deputy path entirely.
REVOKE ALL ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) IS
  'Internal 3PGS->P&A credit/resume effect. Ordinary authenticated sessions cannot execute it directly; acknowledge_3pgs_requirement_receipt is the governed operational entry point and validates exact custody, material identity, reservation lineage, quantity, and distinct actors first.';
