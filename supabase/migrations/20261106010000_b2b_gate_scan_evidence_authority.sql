-- B2B Gate scan evidence authority (additive, forward-only; ASM CP17 Task 3).
-- Closes the provenance gap found in CP16: release_b2b_dispatch_carton_at_gate_v1 validated only the CONTENT of an
-- operational_scan_records row, and any internal staff member could insert a matching row. This migration:
--   1. adds record_b2b_dispatch_gate_scan_v1, the single governed writer of B2B Gate scan evidence (Gate authority
--      only; actor, role, order, carton and barcode derived server-side; idempotent; duplicate and wrong-carton rejection);
--   2. rejects direct client (authenticated/anon) INSERT of dispatch_gate evidence with a BEFORE INSERT guard keyed on
--      current_user, which a client cannot forge (the append-only evidence model is unchanged);
--   3. makes the Gate release require that authoritative evidence (scan source, authority marker, Gate-authority actor).
-- Production holds no consignment, scan or Gate decision rows at the time of writing, so no data is reclassified.
-- rollback-plan: drop trigger trg_operational_scan_records_gate_authority first, then restore the previous
-- release_b2b_dispatch_carton_at_gate_v1 definition from 20260831101700, then drop record_b2b_dispatch_gate_scan_v1.
-- No existing table, column or evidence row is altered or removed.

CREATE OR REPLACE FUNCTION public.record_b2b_dispatch_gate_scan_v1(
  p_carton_id uuid,
  p_scanned_barcode text,
  p_idempotency_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_barcode text := btrim(coalesce(p_scanned_barcode, ''));
  v_corr text;
  v_carton public.b2b_dispatch_cartons%rowtype;
  v_cons public.b2b_dispatch_consignments%rowtype;
  v_order public.orders%rowtype;
  v_existing public.operational_scan_records%rowtype;
  v_scan public.operational_scan_records%rowtype;
BEGIN
  PERFORM public.assert_order_transition_role('gate_release');
  IF p_carton_id IS NULL OR v_key = '' OR v_barcode = '' THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_INVALID: carton, barcode and idempotency key are required' USING ERRCODE = '22023';
  END IF;
  v_corr := 'b2b-gate-scan:' || v_key;
  PERFORM pg_advisory_xact_lock(hashtextextended('b2b-gate-scan:' || p_carton_id::text, 0));

  SELECT * INTO v_existing FROM public.operational_scan_records
   WHERE correlation_id = v_corr AND scan_source = 'B2B_GATE_SCAN_V1';
  IF FOUND THEN
    IF v_existing.entity_id IS DISTINCT FROM p_carton_id
       OR lower(btrim(v_existing.barcode_value)) IS DISTINCT FROM lower(v_barcode)
       OR v_existing.actor_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'B2B_GATE_SCAN_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('ok', true, 'scan_id', v_existing.id, 'carton_id', p_carton_id, 'already_recorded', true);
  END IF;

  SELECT * INTO v_carton FROM public.b2b_dispatch_cartons WHERE id = p_carton_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_CARTON_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO v_cons FROM public.b2b_dispatch_consignments WHERE id = v_carton.consignment_id;
  SELECT * INTO v_order FROM public.orders WHERE id = v_cons.order_id;
  IF v_carton.status NOT IN ('ready_to_load', 'loaded') THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_CARTON_NOT_READY: carton status is %', v_carton.status USING ERRCODE = '55000';
  END IF;
  IF v_order.id IS NULL OR v_order.status <> 'cleared_for_dispatch' THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_ORDER_NOT_CLEARED' USING ERRCODE = '55000';
  END IF;
  IF lower(btrim(v_carton.carton_code)) IS DISTINCT FROM lower(v_barcode) THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_BARCODE_MISMATCH' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.operational_scan_records
              WHERE scan_source = 'B2B_GATE_SCAN_V1' AND entity_id = p_carton_id) THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_DUPLICATE: a Gate scan already exists for this carton' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.operational_scan_records(
    scan_type, verification_type, entity_type, entity_id, order_id, barcode_value, expected_barcode,
    verification_status, scan_source, actor_id, actor_role, correlation_id, idempotency_key, metadata
  ) VALUES (
    'dispatch_gate', 'gate_check', 'b2b_dispatch_carton', p_carton_id, v_order.id, v_barcode, v_carton.carton_code,
    'scanned', 'B2B_GATE_SCAN_V1', auth.uid(), upper(coalesce(public.get_user_role(auth.uid()), '')), v_corr, v_key,
    jsonb_build_object('authority', 'B2B_GATE_SCAN_V1', 'consignment_id', v_cons.id)
  ) RETURNING * INTO v_scan;

  RETURN jsonb_build_object('ok', true, 'scan_id', v_scan.id, 'carton_id', p_carton_id, 'order_id', v_order.id, 'already_recorded', false);
END;
$$;

REVOKE ALL ON FUNCTION public.record_b2b_dispatch_gate_scan_v1(uuid, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.record_b2b_dispatch_gate_scan_v1(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_b2b_gate_scan_insert_v1() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  -- current_user is the invoking database role: PostgREST clients run as authenticated/anon, while the SECURITY
  -- DEFINER writer runs as its owner. A client cannot change it, unlike a session setting.
  IF (NEW.scan_type = 'dispatch_gate' OR NEW.scan_source = 'B2B_GATE_SCAN_V1')
     AND current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'B2B_GATE_SCAN_DIRECT_INSERT_FORBIDDEN: use record_b2b_dispatch_gate_scan_v1' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_operational_scan_records_gate_authority ON public.operational_scan_records;
CREATE TRIGGER trg_operational_scan_records_gate_authority
  BEFORE INSERT ON public.operational_scan_records
  FOR EACH ROW EXECUTE FUNCTION public.guard_b2b_gate_scan_insert_v1();

CREATE OR REPLACE FUNCTION public.release_b2b_dispatch_carton_at_gate_v1(p_carton_id uuid,p_scan_evidence_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE v_carton public.b2b_dispatch_cartons%rowtype; v_cons public.b2b_dispatch_consignments%rowtype; v_order public.orders%rowtype;
  v_scan public.operational_scan_records%rowtype; v_invoice public.final_invoices%rowtype; v_dpl public.finance_dpl_receipts%rowtype;
  v_eway public.eway_bill_evidence%rowtype; v_clearance uuid; v_blockers jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.assert_order_transition_role('gate_release');
  SELECT * INTO v_carton FROM public.b2b_dispatch_cartons WHERE id=p_carton_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','carton_not_found'))); END IF;
  SELECT * INTO v_cons FROM public.b2b_dispatch_consignments WHERE id=v_carton.consignment_id;
  SELECT * INTO v_order FROM public.orders WHERE id=v_cons.order_id;
  IF v_carton.status='handed_over' THEN RETURN jsonb_build_object('ok',true,'carton_id',p_carton_id,'already_released',true); END IF;

  IF v_carton.status NOT IN('ready_to_load','loaded') THEN
    v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','carton_not_ready_for_gate','status',v_carton.status));
  END IF;
  IF v_carton.open_photo_ref IS NULL OR v_carton.net_weight IS NULL OR v_carton.gross_weight IS NULL
     OR v_carton.locked_by IS NULL OR v_carton.locked_at IS NULL THEN
    v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','carton_lock_evidence_incomplete'));
  END IF;

  SELECT * INTO v_scan FROM public.operational_scan_records WHERE id=p_scan_evidence_id;
  -- Gate evidence must be authoritative: written only by record_b2b_dispatch_gate_scan_v1 (scan_source and metadata
  -- authority marker), authored by a Gate-authority role, and bound to this carton, order and barcode.
  IF NOT FOUND OR v_scan.entity_id IS DISTINCT FROM p_carton_id OR v_scan.order_id IS DISTINCT FROM v_cons.order_id
     OR coalesce(v_scan.entity_type,'') <> 'b2b_dispatch_carton' OR coalesce(v_scan.scan_type,'') <> 'dispatch_gate'
     OR coalesce(v_scan.scan_source,'') <> 'B2B_GATE_SCAN_V1' OR coalesce(v_scan.metadata->>'authority','') <> 'B2B_GATE_SCAN_V1'
     OR upper(coalesce(v_scan.actor_role,'')) NOT IN('SECURITY_CONTROL','GATE_SECURITY','ADMIN','SUPER_ADMIN','OWNER')
     OR v_scan.actor_id IS NULL
     OR coalesce(v_scan.verification_status,'') NOT IN('scanned','verified') OR lower(btrim(coalesce(v_scan.barcode_value,''))) IS DISTINCT FROM lower(btrim(v_carton.carton_code)) THEN
    v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','invalid_scan_evidence'));
  END IF;
  IF v_order.status<>'cleared_for_dispatch' THEN v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','order_not_cleared_for_dispatch'));
  ELSE BEGIN v_clearance:=public.assert_active_dispatch_clearance_v1(v_order.id); EXCEPTION WHEN OTHERS THEN v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','finance_dispatch_clearance_required','message',SQLERRM)); END; END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=v_order.id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF v_invoice.id IS NULL THEN v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','canonical_final_invoice_missing'));
  ELSE
    SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE id=v_invoice.finance_dpl_receipt_id;
    IF v_dpl.id IS NULL OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value) WHERE c.value=p_carton_id::text) THEN
      v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','carton_not_in_final_dpl'));
    END IF;
    SELECT * INTO v_eway FROM public.eway_bill_evidence WHERE final_invoice_id=v_invoice.id ORDER BY created_at DESC LIMIT 1;
    IF v_eway.id IS NULL OR v_eway.status NOT IN('VALIDATED','NOT_REQUIRED') OR (v_eway.status='VALIDATED' AND v_eway.valid_until IS NOT NULL AND v_eway.valid_until<=statement_timestamp()) THEN
      v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','eway_evidence_invalid_or_expired'));
    END IF;
  END IF;
  IF jsonb_array_length(v_blockers)>0 THEN
    INSERT INTO public.b2b_dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,blockers,actor_id,actor_role,finance_dispatch_clearance_event_id,final_invoice_id,finance_dpl_receipt_id,eway_evidence_id)
    VALUES(p_carton_id,v_order.id,p_scan_evidence_id,'denied',v_blockers,auth.uid(),public.get_user_role(auth.uid()),v_clearance,v_invoice.id,v_dpl.id,v_eway.id);
    RETURN jsonb_build_object('ok',false,'blockers',v_blockers);
  END IF;
  UPDATE public.b2b_dispatch_cartons SET status='handed_over',physical_location='LOADED' WHERE id=p_carton_id;
  INSERT INTO public.b2b_dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,actor_id,actor_role,finance_dispatch_clearance_event_id,final_invoice_id,finance_dpl_receipt_id,eway_evidence_id)
  VALUES(p_carton_id,v_order.id,p_scan_evidence_id,'released',auth.uid(),public.get_user_role(auth.uid()),v_clearance,v_invoice.id,v_dpl.id,v_eway.id);
  RETURN jsonb_build_object('ok',true,'carton_id',p_carton_id,'order_id',v_order.id,'already_released',false,'finance_dispatch_clearance_event_id',v_clearance);
END;
$$;

REVOKE ALL ON FUNCTION public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid) TO authenticated;
