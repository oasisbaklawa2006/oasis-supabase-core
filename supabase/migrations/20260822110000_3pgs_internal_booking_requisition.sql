-- Central issue #368 operational-closure programme, Phase 4B (3PGS insider
-- packing-material booking). Owner-directed requirement: an authorised
-- manager/staff member browsing the packing-material catalogue must be able
-- to book/hold available stock, identifying the requesting department and
-- requester, and optionally linking a purpose note -- using the canonical
-- reservation authority, never a parallel stock ledger.
--
-- The canonical reservation authority is the existing, unmodified
-- reserve_rgs_stock RPC (20260817100000_rgs_production_governed_authority.sql),
-- which already accepts location_code = '3PGS' as one of its established
-- demand sources. The one real gap: reserve_rgs_stock requires a non-null
-- p_order_id, because every other caller books against a real commercial
-- order. An internal packing-material requisition has no commercial order
-- behind it. inventory_reservations.order_id carries no foreign-key
-- constraint (verified against the schema -- it is a plain NOT NULL uuid
-- column, not a validated reference), so this wrapper satisfies that
-- constraint with a fresh synthetic id rather than fabricating a fake
-- commercial order row or altering the shared reservations table's
-- constraints for every other caller. Idempotent replay is unaffected: the
-- underlying reserve_rgs_stock RPC's own correlation_id check runs first
-- and returns the original reservation before order_id is used at all.
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
    p_order_id := pg_catalog.gen_random_uuid(),
    p_product_id := p_product_id,
    p_sku := p_sku,
    p_requested_qty := p_requested_qty,
    p_source_department := p_requesting_department,
    p_correlation_id := p_correlation_id,
    p_priority := 'normal',
    p_location_code := '3PGS'
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
  'Central issue #368 Phase 4B: insider 3PGS packing-material booking. Thin wrapper around reserve_rgs_stock (location_code=3PGS) for requisitions with no backing commercial order. No new authority beyond reserve_rgs_stock''s own role gate.';

REVOKE ALL ON FUNCTION public.book_3pgs_packing_material_requisition(uuid, text, numeric, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.book_3pgs_packing_material_requisition(uuid, text, numeric, text, text, text) TO authenticated;
