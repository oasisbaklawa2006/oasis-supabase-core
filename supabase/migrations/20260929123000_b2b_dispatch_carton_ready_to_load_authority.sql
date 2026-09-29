-- POINT100 / Dispatch: governed locked-carton -> ready_to_load authority.
--
-- The physical gate RPC intentionally accepts only ready_to_load/loaded cartons,
-- but Core previously exposed no canonical transition that could move a locked
-- FACT-C1 carton into that state. Central's certification harness must never
-- manufacture that state with raw SQL. This RPC closes that authority gap while
-- preserving Finance, invoice, DPL and E-way prerequisites fail-closed.

CREATE OR REPLACE FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(
  p_carton_id uuid,
  p_expected_version integer,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_cartons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth'
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_carton public.b2b_dispatch_cartons%ROWTYPE;
  v_carton_out public.b2b_dispatch_cartons%ROWTYPE;
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_invoice public.final_invoices%ROWTYPE;
  v_dpl public.finance_dpl_receipts%ROWTYPE;
  v_eway public.eway_bill_evidence%ROWTYPE;
  v_clearance uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_ACTOR_NOT_AUTHORISED'
      USING ERRCODE = '42501';
  END IF;

  IF p_carton_id IS NULL OR p_expected_version IS NULL OR v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_EVIDENCE_REQUIRED'
      USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_carton
    FROM public.b2b_dispatch_cartons
   WHERE id = p_carton_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_CARTON_NOT_FOUND'
      USING ERRCODE = 'P0002';
  END IF;

  -- Idempotent success only for states at or beyond this transition.
  IF v_carton.status IN ('ready_to_load', 'loaded', 'handed_over') THEN
    RETURN v_carton;
  END IF;

  IF v_carton.status NOT IN ('locked', 'finance_check_open', 'verified', 'labelled') THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_INVALID_CARTON_STATE:%', v_carton.status
      USING ERRCODE = '55000';
  END IF;

  IF v_carton.current_version <> p_expected_version THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_CARTON_VERSION_CONFLICT'
      USING ERRCODE = '40001';
  END IF;

  IF v_carton.open_photo_ref IS NULL
     OR v_carton.net_weight IS NULL
     OR v_carton.gross_weight IS NULL
     OR v_carton.locked_by IS NULL
     OR v_carton.locked_at IS NULL THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_CARTON_EVIDENCE_INCOMPLETE'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
    INTO v_consignment
    FROM public.b2b_dispatch_consignments
   WHERE id = v_carton.consignment_id;

  IF NOT FOUND OR v_consignment.order_id IS NULL THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_CONSIGNMENT_NOT_GOVERNED'
      USING ERRCODE = '55000';
  END IF;

  -- Canonical Finance Dispatch Clearance must still be active now.
  v_clearance := public.assert_active_dispatch_clearance_v1(v_consignment.order_id);
  IF v_clearance IS NULL THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_FINANCE_CLEARANCE_REQUIRED'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
    INTO v_invoice
    FROM public.final_invoices
   WHERE order_id = v_consignment.order_id
     AND status = 'ISSUED'
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND OR v_invoice.finance_dpl_receipt_id IS NULL THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_FINAL_INVOICE_REQUIRED'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
    INTO v_dpl
    FROM public.finance_dpl_receipts
   WHERE id = v_invoice.finance_dpl_receipt_id;

  IF NOT FOUND
     OR v_dpl.dpl_snapshot->>'source_authority' IS DISTINCT FROM 'b2b_dispatch_packing_list_versions'
     OR NOT EXISTS (
       SELECT 1
         FROM jsonb_array_elements_text(coalesce(v_dpl.dpl_snapshot->'carton_ids', '[]'::jsonb)) c(value)
        WHERE c.value = p_carton_id::text
     ) THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_FINAL_DPL_REQUIRED'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
    INTO v_eway
    FROM public.eway_bill_evidence
   WHERE final_invoice_id = v_invoice.id
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND
     OR v_eway.status NOT IN ('VALIDATED', 'NOT_REQUIRED')
     OR (
       v_eway.status = 'VALIDATED'
       AND v_eway.valid_until IS NOT NULL
       AND v_eway.valid_until <= statement_timestamp()
     ) THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_EWAY_REQUIRED'
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.b2b_dispatch_cartons
     SET status = 'ready_to_load',
         physical_location = 'READY_TO_LOAD_BAY',
         current_version = current_version + 1
   WHERE id = p_carton_id
     AND current_version = p_expected_version
  RETURNING * INTO v_carton_out;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'B2B_DISPATCH_READY_CARTON_VERSION_CONFLICT'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.b2b_dispatch_events (
    order_id,
    consignment_id,
    carton_id,
    event_type,
    old_status,
    new_status,
    custodian_id,
    actor_id,
    actor_role,
    source_record_type,
    source_record_id,
    correlation_id
  )
  VALUES (
    v_consignment.order_id,
    v_carton.consignment_id,
    p_carton_id,
    'carton_ready_to_load',
    v_carton.status,
    'ready_to_load',
    v_actor_id,
    v_actor_id,
    public.get_user_role(v_actor_id),
    'b2b_dispatch_cartons',
    p_carton_id,
    v_correlation_id
  );

  RETURN v_carton_out;
END;
$$;

COMMENT ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, integer, text) IS
  'Canonical Dispatch transition from locked/finance-verified carton truth to ready_to_load. Requires Dispatch authority, complete carton evidence, active Finance Dispatch Clearance, issued final invoice, final governed DPL membership and valid/not-required E-way evidence. Idempotent at or beyond ready_to_load.';

REVOKE ALL ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, integer, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, integer, text)
  TO authenticated;
