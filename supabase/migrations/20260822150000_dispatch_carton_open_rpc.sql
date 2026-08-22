-- Dispatch migration G2 (continuing the one-operation-at-a-time programme
-- started by 20260822140000_dispatch_consignment_creation_rpc.sql): the
-- next legacy action in the inventory is "seal/label a carton" (a
-- dispatch_cartons insert carrying a barcode, box number and total-box
-- count, done in a single step in the legacy screens).
--
-- b2b_dispatch_cartons/b2b_dispatch_carton_items model a materially richer
-- lifecycle than the legacy table: open -> under_packing -> ... -> labelled
-- -> ready_to_load -> loaded, with carton_items requiring a NOT NULL
-- batch_lot and a per-unit barcode_value for each item scanned in, and the
-- "b2b_dispatch_carton_lock_evidence_check" constraint requires a real
-- photo reference and real net/gross weight before a carton can advance
-- past 'open'/'under_packing' into 'locked'/'labelled'/'ready_to_load'/etc.
--
-- None of that evidence exists anywhere in this migration path yet (no RPC
-- captures a weight or photo, and the legacy flow has no batch/lot capture
-- at all -- confirmed by inventory). Fabricating placeholder batch_lot,
-- weight or photo values to force a carton through to 'labelled' in one
-- step would be exactly the synthetic-data shortcut the owner has
-- previously and explicitly rejected (see the PR #105 correction:
-- fabricated identifiers are not an acceptable substitute for the real
-- missing capability). So this migration adds only the one honest,
-- data-complete primitive available today: opening a carton for a
-- consignment. Advancing a carton toward 'labelled' (weight/photo capture,
-- item-level scan-in) is deliberately left for a later, separate PR once
-- a real evidence source for those fields is established -- narrower is
-- correct here, not a shortcut.
--
-- No client wiring, no legacy table touched, no legacy path disabled.
-- Pure additive capability; main stays coherent.

CREATE OR REPLACE FUNCTION public.open_b2b_dispatch_carton(
  p_consignment_id uuid,
  p_carton_code text
)
RETURNS public.b2b_dispatch_cartons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_existing public.b2b_dispatch_cartons%ROWTYPE;
  v_next_sequence integer;
  v_carton public.b2b_dispatch_cartons%ROWTYPE;
  v_carton_code text := nullif(btrim(p_carton_code), '');
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to open a dispatch carton' USING ERRCODE = '42501';
  END IF;
  IF v_carton_code IS NULL THEN
    RAISE EXCEPTION 'A carton code is required';
  END IF;

  -- carton_code is globally UNIQUE on b2b_dispatch_cartons, exactly like the
  -- legacy barcode_string a caller already generates client-side per
  -- carton -- so it is the natural idempotency key here, with no need for
  -- a separate correlation_id column/parameter. This first check is a fast
  -- path only (no lock held yet); the authoritative check happens after the
  -- consignment lock below, and the INSERT itself is still guarded against
  -- a concurrent-retry race (see exception handler).
  SELECT * INTO v_existing FROM public.b2b_dispatch_cartons WHERE carton_code = v_carton_code;
  IF FOUND THEN
    IF v_existing.consignment_id <> p_consignment_id THEN
      RAISE EXCEPTION 'carton_code % is already in use by a different consignment', v_carton_code;
    END IF;
    RETURN v_existing;
  END IF;

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment not found';
  END IF;
  IF v_consignment.status IN ('dispatched', 'delivery_exception', 'delivered', 'closed', 'cancelled') THEN
    RAISE EXCEPTION 'Consignment % is % and can no longer accept new cartons', p_consignment_id, v_consignment.status USING ERRCODE = '42501';
  END IF;

  -- Re-check now that the consignment row is locked: a concurrent call with
  -- the identical carton_code that raced past the fast-path check above and
  -- committed first while we waited on the lock must be caught here too.
  SELECT * INTO v_existing FROM public.b2b_dispatch_cartons WHERE carton_code = v_carton_code;
  IF FOUND THEN
    IF v_existing.consignment_id <> p_consignment_id THEN
      RAISE EXCEPTION 'carton_code % is already in use by a different consignment', v_carton_code;
    END IF;
    RETURN v_existing;
  END IF;

  SELECT coalesce(max(carton_sequence), 0) + 1 INTO v_next_sequence
  FROM public.b2b_dispatch_cartons
  WHERE consignment_id = p_consignment_id;

  BEGIN
    INSERT INTO public.b2b_dispatch_cartons (carton_code, consignment_id, carton_sequence)
    VALUES (v_carton_code, p_consignment_id, v_next_sequence)
    RETURNING * INTO v_carton;
  EXCEPTION WHEN unique_violation THEN
    -- A concurrent call with the identical carton_code committed between
    -- our re-check and this INSERT. Return that row (or raise the
    -- cross-consignment conflict) instead of surfacing a raw constraint
    -- error to the caller.
    SELECT * INTO v_existing FROM public.b2b_dispatch_cartons WHERE carton_code = v_carton_code;
    IF FOUND THEN
      IF v_existing.consignment_id <> p_consignment_id THEN
        RAISE EXCEPTION 'carton_code % is already in use by a different consignment', v_carton_code;
      END IF;
      RETURN v_existing;
    END IF;
    RAISE;
  END;

  RETURN v_carton;
END;
$$;

COMMENT ON FUNCTION public.open_b2b_dispatch_carton(uuid, text) IS
  'Opens a new carton (status=open) for a b2b_dispatch consignment -- the entry point of the carton lifecycle, matching the legacy "seal/label a carton" action at the header level. Does not populate carton_items, weight or photo evidence: those require real sources (batch/lot capture, a scale/camera reading) that no RPC in this repo captures yet, so they are deliberately deferred to a later PR rather than fabricated. Idempotent on carton_code (globally unique, caller-supplied, same role the legacy barcode already plays).';

REVOKE ALL ON FUNCTION public.open_b2b_dispatch_carton(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_b2b_dispatch_carton(uuid, text) TO authenticated;
