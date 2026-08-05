-- Phase 3: governed B2B inventory receiving actions.
-- Physical arrival is recorded separately from authorised stock acceptance.
-- No frontend or authenticated role may post receipt stock through direct table writes.

CREATE OR REPLACE FUNCTION public.record_b2b_inventory_receipt(
  p_receipt_id uuid,
  p_lines jsonb,
  p_correlation_id text
)
RETURNS public.b2b_inventory_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_line_count integer;
  v_payload_count integer;
  v_line jsonb;
  v_line_id uuid;
  v_received_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to record B2B inventory receipts' USING ERRCODE = '42501';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Every receipt line must be supplied';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_receipt
  FROM public.b2b_inventory_receipts
  WHERE id = p_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Receipt not found'; END IF;
  IF v_receipt.status <> 'expected' THEN
    RAISE EXCEPTION 'Receipt has already been recorded or closed';
  END IF;
  IF v_receipt.correlation_id <> p_correlation_id THEN
    RAISE EXCEPTION 'Receipt correlation id mismatch';
  END IF;

  SELECT count(*) INTO v_line_count
  FROM public.b2b_inventory_receipt_lines
  WHERE receipt_id = p_receipt_id;
  SELECT count(DISTINCT (item->>'line_id')::uuid) INTO v_payload_count
  FROM jsonb_array_elements(p_lines) AS item;
  IF v_line_count <> jsonb_array_length(p_lines) OR v_payload_count <> v_line_count THEN
    RAISE EXCEPTION 'Payload must contain every receipt line exactly once';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_line_id := (v_line->>'line_id')::uuid;
    v_received_qty := (v_line->>'received_qty')::numeric;
    IF v_received_qty IS NULL THEN RAISE EXCEPTION 'Received quantity is required'; END IF;
    IF v_received_qty < 0 THEN RAISE EXCEPTION 'Received quantity cannot be negative'; END IF;

    UPDATE public.b2b_inventory_receipt_lines
    SET received_qty = v_received_qty,
        supplier_batch_lot = coalesce(nullif(btrim(v_line->>'supplier_batch_lot'), ''), supplier_batch_lot),
        oasis_batch_lot = coalesce(nullif(btrim(v_line->>'oasis_batch_lot'), ''), oasis_batch_lot),
        expiry_date = coalesce(nullif(v_line->>'expiry_date', '')::date, expiry_date),
        notes = coalesce(nullif(btrim(v_line->>'notes'), ''), notes)
    WHERE id = v_line_id AND receipt_id = p_receipt_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown receipt line %', v_line_id; END IF;
  END LOOP;

  UPDATE public.b2b_inventory_receipts
  SET status = 'received', received_by = v_actor_id, received_at = now(), updated_at = now()
  WHERE id = p_receipt_id
  RETURNING * INTO v_receipt;
  RETURN v_receipt;
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_b2b_inventory_receipt(
  p_receipt_id uuid,
  p_lines jsonb,
  p_correlation_id text
)
RETURNS public.b2b_inventory_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_db_line public.b2b_inventory_receipt_lines%ROWTYPE;
  v_line jsonb;
  v_line_count integer;
  v_payload_count integer;
  v_accepted numeric;
  v_damaged numeric;
  v_rejected numeric;
  v_expected_version integer;
  v_current_version integer;
  v_balance record;
  v_movement_type text;
  v_total_accepted numeric := 0;
  v_total_unaccepted numeric := 0;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to accept B2B inventory receipts' USING ERRCODE = '42501';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Every receipt line must be dispositioned';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_receipt
  FROM public.b2b_inventory_receipts
  WHERE id = p_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Receipt not found'; END IF;
  IF v_receipt.status <> 'received' THEN
    RAISE EXCEPTION 'Receipt is not awaiting acceptance';
  END IF;
  IF v_receipt.correlation_id <> p_correlation_id THEN
    RAISE EXCEPTION 'Receipt correlation id mismatch';
  END IF;

  SELECT count(*) INTO v_line_count FROM public.b2b_inventory_receipt_lines WHERE receipt_id = p_receipt_id;
  SELECT count(DISTINCT (item->>'line_id')::uuid) INTO v_payload_count FROM jsonb_array_elements(p_lines) AS item;
  IF v_line_count <> jsonb_array_length(p_lines) OR v_payload_count <> v_line_count THEN
    RAISE EXCEPTION 'Payload must disposition every receipt line exactly once';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_db_line
    FROM public.b2b_inventory_receipt_lines
    WHERE id = (v_line->>'line_id')::uuid AND receipt_id = p_receipt_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown receipt line'; END IF;

    v_accepted := (v_line->>'accepted_qty')::numeric;
    v_damaged := (v_line->>'damaged_qty')::numeric;
    v_rejected := (v_line->>'rejected_qty')::numeric;
    v_expected_version := (v_line->>'expected_balance_version')::integer;
    IF v_accepted IS NULL OR v_damaged IS NULL OR v_rejected IS NULL THEN
      RAISE EXCEPTION 'Accepted, damaged, and rejected quantities are required for receipt line %', v_db_line.id;
    END IF;
    IF v_accepted > 0 AND v_expected_version IS NULL THEN
      RAISE EXCEPTION 'An expected balance version is required for receipt line %', v_db_line.id;
    END IF;
    IF least(v_accepted, v_damaged, v_rejected) < 0
       OR v_accepted + v_damaged + v_rejected <> v_db_line.received_qty THEN
      RAISE EXCEPTION 'Every received unit must be accepted, damaged, or rejected';
    END IF;

    UPDATE public.b2b_inventory_receipt_lines
    SET accepted_qty = v_accepted, damaged_qty = v_damaged, rejected_qty = v_rejected
    WHERE id = v_db_line.id;

    v_total_accepted := v_total_accepted + v_accepted;
    v_total_unaccepted := v_total_unaccepted + v_damaged + v_rejected;
  END LOOP;

  -- A receipt can contain several batches for the same stock balance. Apply
  -- their accepted quantity once per balance identity so one line cannot make
  -- a sibling line's optimistic-lock version stale.
  FOR v_balance IN
    SELECT
      receipt_line.product_id,
      receipt_line.sku,
      sum((payload.value->>'accepted_qty')::numeric) AS accepted_qty,
      min((payload.value->>'expected_balance_version')::integer) AS expected_version,
      count(DISTINCT (payload.value->>'expected_balance_version')::integer) AS version_count
    FROM jsonb_array_elements(p_lines) AS payload(value)
    JOIN public.b2b_inventory_receipt_lines AS receipt_line
      ON receipt_line.id = (payload.value->>'line_id')::uuid
     AND receipt_line.receipt_id = p_receipt_id
    WHERE (payload.value->>'accepted_qty')::numeric > 0
    GROUP BY receipt_line.product_id, receipt_line.sku
    ORDER BY receipt_line.product_id, receipt_line.sku
  LOOP
    IF v_balance.version_count <> 1 THEN
      RAISE EXCEPTION 'All accepted lines for stock balance % / % must use the same expected version',
        v_balance.product_id, v_balance.sku USING ERRCODE = '40001';
    END IF;

    -- Serialize both the existing-row and first-insert paths for this identity.
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        v_balance.product_id::text || ':' || v_balance.sku || ':' || v_receipt.destination_store_code,
        0
      )
    );

    SELECT version INTO v_current_version
    FROM public.inventory_stock_balances
    WHERE product_id = v_balance.product_id
      AND sku = v_balance.sku
      AND location_code = v_receipt.destination_store_code
    FOR UPDATE;

    IF FOUND THEN
      IF v_current_version <> v_balance.expected_version THEN
        RAISE EXCEPTION 'Stale stock balance version for % / %', v_balance.product_id, v_balance.sku
          USING ERRCODE = '40001';
      END IF;
      UPDATE public.inventory_stock_balances
      SET available_qty = available_qty + v_balance.accepted_qty,
          version = version + 1,
          updated_at = now()
      WHERE product_id = v_balance.product_id
        AND sku = v_balance.sku
        AND location_code = v_receipt.destination_store_code
        AND version = v_balance.expected_version;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock balance update did not apply for % / %', v_balance.product_id, v_balance.sku
          USING ERRCODE = '40001';
      END IF;
    ELSE
      IF v_balance.expected_version <> 0 THEN
        RAISE EXCEPTION 'Stock balance does not exist at expected version %', v_balance.expected_version
          USING ERRCODE = '40001';
      END IF;
      INSERT INTO public.inventory_stock_balances (product_id, sku, location_code, available_qty)
      VALUES (v_balance.product_id, v_balance.sku, v_receipt.destination_store_code, v_balance.accepted_qty);
    END IF;
  END LOOP;

  -- Preserve batch-level provenance in the append-only ledger even though the
  -- materialized balance is updated at the aggregated SKU/location level.
  v_movement_type := CASE v_receipt.receipt_source
    WHEN 'supplier' THEN 'supplier_receipt_accepted'
    WHEN 'production' THEN 'production_receipt_accepted'
    WHEN 'opening_balance' THEN 'opening_balance_accepted'
    WHEN 'return_from_assembly' THEN 'returned_from_assembly'
  END;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_accepted := (v_line->>'accepted_qty')::numeric;
    IF v_accepted > 0 THEN
      SELECT * INTO v_db_line
      FROM public.b2b_inventory_receipt_lines
      WHERE id = (v_line->>'line_id')::uuid AND receipt_id = p_receipt_id;

      INSERT INTO public.inventory_movements (
        movement_type, product_id, sku, quantity, destination_location, actor_id,
        reason_code, correlation_id, source_document_type, source_document_reference,
        batch_lot, expiry_date, metadata
      ) VALUES (
        v_movement_type, v_db_line.product_id, v_db_line.sku, v_accepted,
        v_receipt.destination_store_code, v_actor_id, 'b2b_receipt_acceptance',
        p_correlation_id || ':' || v_db_line.id::text,
        v_receipt.source_document_type, v_receipt.source_document_reference,
        coalesce(v_db_line.oasis_batch_lot, v_db_line.supplier_batch_lot), v_db_line.expiry_date,
        jsonb_build_object('receiving_action', 'accepted', 'receipt_id', p_receipt_id, 'receipt_line_id', v_db_line.id)
      );
    END IF;
  END LOOP;

  UPDATE public.b2b_inventory_receipts
  SET status = CASE
        WHEN v_total_accepted = 0 THEN 'rejected'
        WHEN v_total_unaccepted > 0 THEN 'partially_accepted'
        ELSE 'accepted'
      END,
      accepted_by = v_actor_id, accepted_at = now(), updated_at = now()
  WHERE id = p_receipt_id
  RETURNING * INTO v_receipt;
  RETURN v_receipt;
END;
$$;

-- Receipt evidence can be read by staff but changed only through the governed actions.
REVOKE INSERT, UPDATE, DELETE ON public.b2b_inventory_receipts FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_inventory_receipt_lines FROM authenticated, anon;

REVOKE ALL ON FUNCTION public.record_b2b_inventory_receipt(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_b2b_inventory_receipt(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_b2b_inventory_receipt(uuid, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_b2b_inventory_receipt(uuid, jsonb, text) TO authenticated;

COMMENT ON FUNCTION public.record_b2b_inventory_receipt(uuid, jsonb, text) IS
  'Records physical quantities and immutable authenticated authorship; does not create stock.';
COMMENT ON FUNCTION public.accept_b2b_inventory_receipt(uuid, jsonb, text) IS
  'Atomically dispositions every received unit, appends accepted stock movements, and increments versioned balances.';
