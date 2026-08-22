-- Central issue #368 operational-closure programme, Phase 4B (3PGS insider
-- packing-material booking). Owner-directed requirement: an authorised
-- manager/staff member browsing the packing-material catalogue must be able
-- to book/hold available stock, identifying the requesting department and
-- requester, and optionally linking a purpose note -- using the canonical
-- reservation authority, never a parallel stock ledger.
--
-- The canonical reservation authority is the existing, unmodified
-- reserve_rgs_stock RPC, which already accepts location_code = '3PGS' as one
-- of its established demand sources. reserve_rgs_stock was ALREADY
-- generalised for exactly this situation by
-- 20260817160000_rgs_demand_source_linkage.sql (merged ahead of this PR):
-- order_id is nullable, gated by a CHECK that requires it only when
-- demand_source_type = 'b2b', and a parallel demand_reference text column
-- exists for non-order demand. 'internal' is already one of the four
-- allowed demand_source_type values (see that migration's CHECK constraint)
-- and is already consumed by the b2b_3pgs_pending_demand_priority view's
-- priority ranking (20260820100000_3pgs_governed_fulfilment_authority.sql)
-- -- it was designed for, and had simply never had a caller before this one.
-- This wrapper therefore passes p_order_id := NULL and
-- p_demand_source_type := 'internal', exactly mirroring the pattern already
-- used by create_production_shortage_demand and
-- reserve_3pgs_requirement_stock for their own non-order demand (both pass
-- demand_source_type = 'pna'). p_demand_reference is left NULL: unlike
-- those two callers, there is no separate upstream job/requirement entity
-- to reference here -- the reservation itself is the requisition record,
-- and the priority view's own coalesce(demand_reference, reservation_number)
-- was built precisely for this case. An earlier revision of this migration
-- passed a freshly generated random UUID as p_order_id to satisfy the
-- (then-believed) NOT NULL constraint; that was rejected on review as a
-- fabricated commercial-order identity and is not what ships here.
-- Idempotent replay is unaffected: reserve_rgs_stock's own correlation_id
-- check runs first and returns the original reservation before order_id or
-- demand_source_type are used at all.
--
-- No new role predicate: authorisation is delegated entirely to
-- reserve_rgs_stock's own is_inventory_manage_role / is_inventory_receive_role
-- gate. This wrapper adds no authority beyond what that RPC already grants.

CREATE OR REPLACE FUNCTION public.book_3pgs_packing_material_requisition(
  p_product_id uuid,
  p_sku text,
  p_requested_qty numeric,
  p_requesting_department text,
  p_correlation_id text,
  p_purpose_note text DEFAULT NULL
)
RETURNS public.inventory_reservations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_reservation public.inventory_reservations%ROWTYPE;
  v_purpose_note text := nullif(btrim(p_purpose_note), '');
BEGIN
  IF nullif(btrim(p_requesting_department), '') IS NULL THEN
    RAISE EXCEPTION 'Requesting department is required for a 3PGS packing-material booking';
  END IF;
  -- Validated here, ahead of building reservation_number below: reserve_rgs_stock
  -- also validates this, but only after concatenation has already turned a
  -- null/blank correlation id into a null reservation_number, which would
  -- otherwise surface as a generic NOT NULL violation instead of this clear message.
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  -- Delegates quantity and role validation entirely to reserve_rgs_stock --
  -- not duplicated here.
  v_reservation := public.reserve_rgs_stock(
    p_reservation_number := 'INT-3PGS:' || p_correlation_id,
    p_order_id := NULL,
    p_product_id := p_product_id,
    p_sku := p_sku,
    p_requested_qty := p_requested_qty,
    p_source_department := p_requesting_department,
    p_correlation_id := p_correlation_id,
    p_priority := 'normal',
    p_location_code := '3PGS',
    p_demand_source_type := 'internal',
    p_demand_reference := NULL
  );

  -- Record the purpose note once, on first creation only -- never overwrite
  -- an existing reservation's note on an idempotent replay. Blank/whitespace
  -- notes are treated as absent rather than stored.
  IF v_purpose_note IS NOT NULL AND v_reservation.notes IS NULL THEN
    UPDATE public.inventory_reservations
    SET notes = v_purpose_note
    WHERE id = v_reservation.id
    RETURNING * INTO v_reservation;
  END IF;

  RETURN v_reservation;
END;
$$;

COMMENT ON FUNCTION public.book_3pgs_packing_material_requisition(uuid, text, numeric, text, text, text) IS
  'Central issue #368 Phase 4B: insider 3PGS packing-material booking. Thin wrapper around reserve_rgs_stock (location_code=3PGS, demand_source_type=internal, order_id=NULL) for requisitions with no backing commercial order. No new authority beyond reserve_rgs_stock''s own role gate.';

REVOKE ALL ON FUNCTION public.book_3pgs_packing_material_requisition(uuid, text, numeric, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.book_3pgs_packing_material_requisition(uuid, text, numeric, text, text, text) TO authenticated;
