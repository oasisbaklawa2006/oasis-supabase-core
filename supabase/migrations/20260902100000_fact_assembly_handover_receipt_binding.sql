-- FACT-E2E / Core #176
-- Bind acknowledged P&A Assembly handover truth to the existing governed
-- b2b_inventory_receipts -> record -> accept stock-credit authority.
--
-- This migration deliberately does NOT create a second stock ledger or a
-- second acceptance subsystem. The only stock-balance mutation remains
-- accept_b2b_inventory_receipt. This migration closes the missing lineage
-- boundary so receipt_source='return_from_assembly' cannot be fabricated from
-- caller-supplied product/SKU/destination/source-document data.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- New return-from-assembly receipts must carry the canonical Assembly handover
-- source shape. Keep this NOT VALID so historical rows are not rewritten or
-- blocked by a validation scan; all new/updated rows are checked immediately.
ALTER TABLE public.b2b_inventory_receipts
  DROP CONSTRAINT IF EXISTS b2b_inventory_receipts_source_reference_check;

ALTER TABLE public.b2b_inventory_receipts
  ADD CONSTRAINT b2b_inventory_receipts_source_reference_check CHECK (
    (
      receipt_source = 'supplier'
      AND (
        supplier_id IS NOT NULL
        OR (
          source_document_type = 'procurement_requirement'
          AND nullif(btrim(source_document_reference), '') IS NOT NULL
        )
      )
    )
    OR (receipt_source = 'production' AND production_job_id IS NOT NULL)
    OR receipt_source = 'opening_balance'
    OR (
      receipt_source = 'return_from_assembly'
      AND source_document_type = 'b2b_assembly_handover'
      AND nullif(btrim(source_document_reference), '') IS NOT NULL
    )
  ) NOT VALID;

COMMENT ON CONSTRAINT b2b_inventory_receipts_source_reference_check ON public.b2b_inventory_receipts IS
  'Supplier/prod/opening rules are preserved. New return_from_assembly receipts must be bound to a b2b_assembly_handover source document and are created only through create_b2b_inventory_receipt_from_assembly_handover.';

-- Harden the existing generic opener: return_from_assembly has stronger
-- server-derived lineage requirements than generic supplier/production/opening
-- receipts and therefore must use the dedicated handover-bound opener below.
CREATE OR REPLACE FUNCTION public.create_b2b_inventory_receipt(
  p_receipt_number text,
  p_receipt_source text,
  p_destination_store_code text,
  p_source_document_type text,
  p_source_document_reference text,
  p_lines jsonb,
  p_correlation_id text,
  p_supplier_id uuid DEFAULT NULL,
  p_production_job_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS public.b2b_inventory_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_line jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create an inventory receipt' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_receipt_source = 'return_from_assembly' THEN
    RAISE EXCEPTION 'return_from_assembly receipts must be created from an acknowledged Assembly handover'
      USING ERRCODE = '42501';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'At least one receipt line is required';
  END IF;

  SELECT * INTO v_receipt
  FROM public.b2b_inventory_receipts
  WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_receipt;
  END IF;

  INSERT INTO public.b2b_inventory_receipts (
    receipt_number, receipt_source, destination_store_code, source_document_type,
    source_document_reference, supplier_id, production_job_id, status, correlation_id, notes
  ) VALUES (
    p_receipt_number, p_receipt_source, p_destination_store_code, p_source_document_type,
    p_source_document_reference, p_supplier_id, p_production_job_id, 'expected', p_correlation_id, p_notes
  )
  RETURNING * INTO v_receipt;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    IF NOT (v_line ? 'product_id' AND v_line ? 'sku' AND v_line ? 'expected_qty') THEN
      RAISE EXCEPTION 'Each receipt line requires product_id, sku and expected_qty';
    END IF;
    INSERT INTO public.b2b_inventory_receipt_lines (
      receipt_id, product_id, sku, supplier_batch_lot, expiry_date, expected_qty
    ) VALUES (
      v_receipt.id,
      (v_line->>'product_id')::uuid,
      v_line->>'sku',
      nullif(v_line->>'supplier_batch_lot', ''),
      nullif(v_line->>'expiry_date', '')::date,
      (v_line->>'expected_qty')::numeric
    );
  END LOOP;

  RETURN v_receipt;
END;
$$;

COMMENT ON FUNCTION public.create_b2b_inventory_receipt(text, text, text, text, text, jsonb, text, uuid, uuid, text) IS
  'Opens generic governed inward receipts. return_from_assembly is intentionally rejected here and must use create_b2b_inventory_receipt_from_assembly_handover so product/SKU/destination/quantity lineage is server-derived from acknowledged Assembly custody.';

REVOKE ALL ON FUNCTION public.create_b2b_inventory_receipt(text, text, text, text, text, jsonb, text, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_b2b_inventory_receipt(text, text, text, text, text, jsonb, text, uuid, uuid, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.create_b2b_inventory_receipt_from_assembly_handover(
  p_handover_id uuid,
  p_receipt_number text,
  p_expected_qty numeric,
  p_correlation_id text,
  p_notes text DEFAULT NULL
)
RETURNS public.b2b_inventory_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_handover public.b2b_assembly_handovers%ROWTYPE;
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_existing_line public.b2b_inventory_receipt_lines%ROWTYPE;
  v_existing_line_count integer;
  v_bound_qty numeric := 0;
  v_remaining_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create an Assembly return receipt' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_receipt_number), '') IS NULL THEN
    RAISE EXCEPTION 'A receipt number is required';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_expected_qty IS NULL OR p_expected_qty <= 0 THEN
    RAISE EXCEPTION 'Expected receipt quantity must be positive';
  END IF;

  -- The handover row is the shared allocation authority. Serialising on it
  -- prevents concurrent receipt-open calls from jointly binding more than the
  -- acknowledged physical quantity.
  SELECT * INTO v_handover
  FROM public.b2b_assembly_handovers
  WHERE id = p_handover_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assembly handover not found';
  END IF;
  IF v_handover.status <> 'acknowledged'
     OR v_handover.acknowledged_at IS NULL
     OR v_handover.receiver_id IS NULL
     OR v_handover.received_qty IS NULL THEN
    RAISE EXCEPTION 'Assembly handover is not fully acknowledged and receivable';
  END IF;

  SELECT * INTO v_job
  FROM public.b2b_assembly_jobs
  WHERE id = v_handover.assembly_job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assembly job not found for handover';
  END IF;
  IF v_job.output_product_id IS NULL OR nullif(btrim(v_job.output_sku), '') IS NULL THEN
    RAISE EXCEPTION 'Assembly job output identity is incomplete';
  END IF;

  -- A stock receipt is legal only when the acknowledged handover destination
  -- reference is itself a live canonical B2B inventory store. OUTLET /
  -- CUSTOMER_DIRECT / arbitrary INTERNAL destinations therefore fail closed
  -- unless their exact destination_reference is a canonical store code.
  IF NOT EXISTS (
    SELECT 1
    FROM public.b2b_inventory_stores s
    WHERE s.store_code = v_handover.destination_reference
      AND s.active
  ) THEN
    RAISE EXCEPTION 'Assembly handover destination % is not an active canonical inventory store',
      v_handover.destination_reference;
  END IF;
  IF NOT public.can_access_b2b_inventory_store(
    v_actor_id,
    v_handover.destination_reference,
    'receive'
  ) THEN
    RAISE EXCEPTION 'Not authorised to receive Assembly output into store %',
      v_handover.destination_reference USING ERRCODE = '42501';
  END IF;

  -- Idempotent replay is checked after the handover lock and must match every
  -- business-significant field. A reused correlation id may never silently
  -- return an unrelated or differently-sized receipt.
  SELECT * INTO v_receipt
  FROM public.b2b_inventory_receipts
  WHERE correlation_id = p_correlation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.receipt_source <> 'return_from_assembly'
       OR v_receipt.source_document_type <> 'b2b_assembly_handover'
       OR v_receipt.source_document_reference <> p_handover_id::text
       OR v_receipt.destination_store_code <> v_handover.destination_reference
       OR v_receipt.receipt_number <> p_receipt_number THEN
      RAISE EXCEPTION 'Assembly handover receipt correlation id conflicts with an existing receipt';
    END IF;

    SELECT count(*)::integer INTO v_existing_line_count
    FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id = v_receipt.id;
    IF v_existing_line_count <> 1 THEN
      RAISE EXCEPTION 'Assembly handover receipt replay has invalid line cardinality';
    END IF;

    SELECT * INTO v_existing_line
    FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id = v_receipt.id;
    IF v_existing_line.product_id <> v_job.output_product_id
       OR v_existing_line.sku <> v_job.output_sku
       OR v_existing_line.expected_qty <> p_expected_qty THEN
      RAISE EXCEPTION 'Assembly handover receipt correlation id conflicts with existing line identity or quantity';
    END IF;
    RETURN v_receipt;
  END IF;

  -- While a bound receipt is still expected/received, reserve its expected
  -- quantity against the handover so concurrent receipts cannot oversubscribe
  -- it. Once the receipt reaches a terminal disposition, only physically
  -- received quantity remains consumed; a documented short receipt therefore
  -- releases its unreceived remainder for a later cumulative receipt.
  SELECT coalesce(sum(
    CASE
      WHEN r.status = 'cancelled' THEN 0::numeric
      WHEN r.status IN ('accepted', 'partially_accepted', 'rejected') THEN l.received_qty
      ELSE l.expected_qty
    END
  ), 0::numeric)
  INTO v_bound_qty
  FROM public.b2b_inventory_receipts r
  JOIN public.b2b_inventory_receipt_lines l ON l.receipt_id = r.id
  WHERE r.receipt_source = 'return_from_assembly'
    AND r.source_document_type = 'b2b_assembly_handover'
    AND r.source_document_reference = p_handover_id::text;

  v_remaining_qty := v_handover.received_qty - v_bound_qty;
  IF v_remaining_qty <= 0 OR p_expected_qty > v_remaining_qty THEN
    RAISE EXCEPTION 'Expected receipt quantity % exceeds remaining acknowledged handover quantity %',
      p_expected_qty, greatest(v_remaining_qty, 0::numeric);
  END IF;

  INSERT INTO public.b2b_inventory_receipts (
    receipt_number,
    receipt_source,
    destination_store_code,
    source_document_type,
    source_document_reference,
    status,
    correlation_id,
    notes
  ) VALUES (
    p_receipt_number,
    'return_from_assembly',
    v_handover.destination_reference,
    'b2b_assembly_handover',
    p_handover_id::text,
    'expected',
    p_correlation_id,
    p_notes
  )
  RETURNING * INTO v_receipt;

  INSERT INTO public.b2b_inventory_receipt_lines (
    receipt_id,
    product_id,
    sku,
    expected_qty,
    notes
  ) VALUES (
    v_receipt.id,
    v_job.output_product_id,
    v_job.output_sku,
    p_expected_qty,
    'Server-bound from acknowledged Assembly handover ' || p_handover_id::text
  );

  RETURN v_receipt;
END;
$$;

COMMENT ON FUNCTION public.create_b2b_inventory_receipt_from_assembly_handover(uuid, text, numeric, text, text) IS
  'Binds an acknowledged b2b_assembly_handover to the existing return_from_assembly receipt subsystem. Product/SKU/destination are server-derived from Assembly output/custody; cumulative bound quantity cannot exceed receiver-acknowledged quantity. Stock is NOT credited here: record_b2b_inventory_receipt then accept_b2b_inventory_receipt remain the sole physical-record and stock-acceptance authorities.';

REVOKE ALL ON FUNCTION public.create_b2b_inventory_receipt_from_assembly_handover(uuid, text, numeric, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_b2b_inventory_receipt_from_assembly_handover(uuid, text, numeric, text, text)
  TO authenticated;

-- Re-assert the existing RPC-only table boundary. No authenticated caller may
-- bypass the new binding by inserting or rewriting receipt/header/line truth.
REVOKE INSERT, UPDATE, DELETE ON public.b2b_inventory_receipts FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_inventory_receipt_lines FROM authenticated, anon;
