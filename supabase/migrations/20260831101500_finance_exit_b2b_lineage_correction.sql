-- Finance Exit lineage correction: bind Finance receipt and physical gate to the
-- governed FACT-C1/FACT-C2 b2b_dispatch_* truth. Legacy dispatch_cartons and
-- browser-composed DPL packets are not Finance Exit authority.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

-- -----------------------------------------------------------------------------
-- A. Finance receives one server-composed order-level packet containing every
-- current submitted FACT-C2 DPL version for the order. This preserves fragmented
-- consignments while preventing the browser from composing quantities/cartons.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_submitted_b2b_dispatch_dpls_v1(
  p_order_id uuid,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(receipt_id uuid, already_received boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_snapshot jsonb;
  v_fingerprint text;
  v_request_fingerprint text;
  v_existing public.finance_dpl_receipt_idempotency%rowtype;
  v_receipt public.finance_dpl_receipts%rowtype;
  v_external_id text;
  v_version_number integer;
  v_invalid integer;
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF p_order_id IS NULL OR nullif(btrim(p_evidence_reference),'') IS NULL
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'B2B_FINANCE_DPL_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('b2b-finance-dpl:'||p_order_id::text,0));
  PERFORM public.assert_active_operations_clearance_v1(p_order_id);
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR SHARE;
  IF NOT FOUND OR v_order.company_id IS NULL OR v_order.commercial_current_version IS NULL THEN
    RAISE EXCEPTION 'B2B_FINANCE_DPL_ORDER_NOT_GOVERNED' USING ERRCODE='40001';
  END IF;
  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE order_id=p_order_id AND version_number=v_order.commercial_current_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'B2B_FINANCE_DPL_COMMERCIAL_VERSION_REQUIRED' USING ERRCODE='40001'; END IF;

  -- Every non-cancelled consignment must have exactly one current submitted DPL.
  IF EXISTS(
    SELECT 1 FROM public.b2b_dispatch_consignments c
    WHERE c.order_id=p_order_id AND c.status<>'cancelled'
      AND NOT EXISTS(
        SELECT 1 FROM public.b2b_dispatch_packing_list_versions d
        WHERE d.consignment_id=c.id AND d.superseded_by IS NULL AND d.status='submitted_to_finance'
      )
  ) THEN RAISE EXCEPTION 'B2B_FINANCE_DPL_SUBMISSION_INCOMPLETE' USING ERRCODE='55000'; END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.b2b_dispatch_consignments c
    JOIN public.b2b_dispatch_packing_list_versions d ON d.consignment_id=c.id
    WHERE c.order_id=p_order_id AND c.status<>'cancelled' AND d.superseded_by IS NULL AND d.status='submitted_to_finance'
  ) THEN RAISE EXCEPTION 'B2B_FINANCE_DPL_NOT_SUBMITTED' USING ERRCODE='55000'; END IF;

  -- Reject duplicate order-item allocation across current DPLs only when the
  -- aggregate packed quantity would exceed the frozen order quantity.
  WITH submitted AS (
    SELECT c.id consignment_id,d.id dpl_id,d.version_number,d.submitted_to_finance_at
    FROM public.b2b_dispatch_consignments c
    JOIN public.b2b_dispatch_packing_list_versions d ON d.consignment_id=c.id
    WHERE c.order_id=p_order_id AND c.status<>'cancelled' AND d.superseded_by IS NULL AND d.status='submitted_to_finance'
  ), agg AS (
    SELECT cl.order_item_id,cl.product_id,max(cl.uom) uom,sum(cl.packed_qty) actual_dispatch_qty
    FROM submitted s JOIN public.b2b_dispatch_consignment_lines cl ON cl.consignment_id=s.consignment_id
    GROUP BY cl.order_item_id,cl.product_id
  )
  SELECT count(*) INTO v_invalid FROM agg a
  LEFT JOIN public.order_items oi ON oi.id=a.order_item_id AND oi.order_id=p_order_id AND oi.product_id=a.product_id
  WHERE oi.id IS NULL OR a.actual_dispatch_qty<=0 OR a.actual_dispatch_qty>oi.quantity OR nullif(btrim(a.uom),'') IS NULL;
  IF v_invalid>0 THEN RAISE EXCEPTION 'B2B_FINANCE_DPL_LINE_TRUTH_INVALID' USING ERRCODE='40001'; END IF;

  WITH submitted AS (
    SELECT c.id consignment_id,d.id dpl_id,d.version_number,d.submitted_to_finance_at,d.physical_truth_snapshot
    FROM public.b2b_dispatch_consignments c
    JOIN public.b2b_dispatch_packing_list_versions d ON d.consignment_id=c.id
    WHERE c.order_id=p_order_id AND c.status<>'cancelled' AND d.superseded_by IS NULL AND d.status='submitted_to_finance'
  ), lines AS (
    SELECT cl.order_item_id,cl.product_id,max(cl.uom) uom,sum(cl.packed_qty) actual_dispatch_qty
    FROM submitted s JOIN public.b2b_dispatch_consignment_lines cl ON cl.consignment_id=s.consignment_id
    GROUP BY cl.order_item_id,cl.product_id
  ), cartons AS (
    SELECT bc.id carton_id
    FROM submitted s JOIN public.b2b_dispatch_cartons bc ON bc.consignment_id=s.consignment_id
  )
  SELECT jsonb_build_object(
    'order_id',p_order_id,
    'commercial_version_id',v_version.id,
    'external_dpl_id','b2b-order-dpl:'||p_order_id::text,
    'dpl_version',1,
    'source_authority','b2b_dispatch_packing_list_versions',
    'source_dpl_versions',(SELECT jsonb_agg(jsonb_build_object('consignment_id',s.consignment_id,'dpl_id',s.dpl_id,'version_number',s.version_number,'submitted_to_finance_at',s.submitted_to_finance_at) ORDER BY s.consignment_id) FROM submitted s),
    'lines',(SELECT jsonb_agg(jsonb_build_object('order_item_id',l.order_item_id,'product_id',l.product_id,'actual_dispatch_qty',l.actual_dispatch_qty,'uom',l.uom) ORDER BY l.order_item_id) FROM lines l),
    'carton_ids',(SELECT jsonb_agg(c.carton_id::text ORDER BY c.carton_id::text) FROM cartons c)
  ) INTO v_snapshot;

  IF jsonb_array_length(coalesce(v_snapshot->'lines','[]'::jsonb))=0 OR jsonb_array_length(coalesce(v_snapshot->'carton_ids','[]'::jsonb))=0 THEN
    RAISE EXCEPTION 'B2B_FINANCE_DPL_EMPTY' USING ERRCODE='40001';
  END IF;
  v_external_id:='b2b-order-dpl:'||p_order_id::text;
  v_version_number:=1;
  v_fingerprint:=encode(extensions.digest(v_snapshot::text,'sha256'),'hex');
  v_request_fingerprint:=encode(extensions.digest(jsonb_build_object('order_id',p_order_id,'commercial_version_id',v_version.id,
    'dpl_fingerprint',v_fingerprint,'evidence_reference',btrim(p_evidence_reference),'correlation_id',btrim(p_correlation_id))::text,'sha256'),'hex');

  SELECT * INTO v_existing FROM public.finance_dpl_receipt_idempotency WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_request_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_DPL_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.receipt_id,true; RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_dpl_receipts r WHERE r.order_id=p_order_id) THEN
    RAISE EXCEPTION 'B2B_FINANCE_DPL_ALREADY_FROZEN' USING ERRCODE='55000';
  END IF;

  INSERT INTO public.finance_dpl_receipts(order_id,company_id,commercial_version_id,external_dpl_id,dpl_version,dpl_fingerprint,dpl_snapshot,
    finalized_at,received_by,received_role,source_channel,source_reference,evidence_reference,correlation_id,idempotency_key)
  VALUES(p_order_id,v_order.company_id,v_version.id,v_external_id,v_version_number,v_fingerprint,v_snapshot,statement_timestamp(),v_actor,v_role,
    'B2B_DISPATCH','FACT-C2',btrim(p_evidence_reference),btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_receipt;
  INSERT INTO public.finance_dpl_receipt_idempotency(idempotency_key,request_fingerprint,receipt_id,actor_id,response)
  VALUES(btrim(p_idempotency_key),v_request_fingerprint,v_receipt.id,v_actor,jsonb_build_object('receipt_id',v_receipt.id,'order_id',p_order_id));

  -- Finance acknowledgement is projection-only on the FACT-C2 rows; physical
  -- truth is never rewritten.
  UPDATE public.b2b_dispatch_packing_list_versions d SET finance_check_state='verified',status='finance_verified'
   WHERE d.id IN (
    SELECT d2.id FROM public.b2b_dispatch_consignments c2 JOIN public.b2b_dispatch_packing_list_versions d2 ON d2.consignment_id=c2.id
    WHERE c2.order_id=p_order_id AND c2.status<>'cancelled' AND d2.superseded_by IS NULL AND d2.status='submitted_to_finance'
   );
  RETURN QUERY SELECT v_receipt.id,false;
END;
$$;
REVOKE ALL ON FUNCTION public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- B. Independent physical gate decision ledger for governed B2B cartons.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.b2b_dispatch_gate_decisions(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  carton_id uuid NOT NULL REFERENCES public.b2b_dispatch_cartons(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  scan_evidence_id uuid NOT NULL REFERENCES public.operational_scan_records(id),
  decision text NOT NULL CHECK(decision IN('released','denied')),
  blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text,
  finance_dispatch_clearance_event_id uuid REFERENCES public.finance_clearance_events(id),
  final_invoice_id uuid REFERENCES public.final_invoices(id),
  finance_dpl_receipt_id uuid REFERENCES public.finance_dpl_receipts(id),
  eway_evidence_id uuid REFERENCES public.eway_bill_evidence(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.b2b_dispatch_gate_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.b2b_dispatch_gate_decisions FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.b2b_dispatch_gate_decisions TO authenticated,service_role;
CREATE POLICY b2b_dispatch_gate_decisions_internal_read ON public.b2b_dispatch_gate_decisions FOR SELECT TO authenticated USING(public.is_internal_staff(auth.uid()));
CREATE TRIGGER trg_b2b_dispatch_gate_decisions_immutable BEFORE UPDATE OR DELETE ON public.b2b_dispatch_gate_decisions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_dispatch_gate_decision_mutation();

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
  SELECT * INTO v_scan FROM public.operational_scan_records WHERE id=p_scan_evidence_id;
  IF NOT FOUND OR v_scan.entity_id IS DISTINCT FROM p_carton_id OR v_scan.order_id IS DISTINCT FROM v_cons.order_id
     OR coalesce(v_scan.entity_type,'') NOT IN('b2b_dispatch_carton','dispatch_carton') OR coalesce(v_scan.scan_type,'') NOT IN('carton','dispatch_gate')
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
  UPDATE public.b2b_dispatch_cartons SET status='handed_over',physical_location='READY_TO_LOAD_BAY' WHERE id=p_carton_id;
  INSERT INTO public.b2b_dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,actor_id,actor_role,finance_dispatch_clearance_event_id,final_invoice_id,finance_dpl_receipt_id,eway_evidence_id)
  VALUES(p_carton_id,v_order.id,p_scan_evidence_id,'released',auth.uid(),public.get_user_role(auth.uid()),v_clearance,v_invoice.id,v_dpl.id,v_eway.id);
  RETURN jsonb_build_object('ok',true,'carton_id',p_carton_id,'order_id',v_order.id,'already_released',false,'finance_dispatch_clearance_event_id',v_clearance);
END;
$$;
REVOKE ALL ON FUNCTION public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- C. Dispatch proof now consumes the governed B2B gate ledger/cartons.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_dispatch_proof_packet_v1(
  p_order_id uuid,p_transport_snapshot jsonb,p_evidence_references jsonb,p_dispatched_at timestamptz,
  p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(dispatch_proof_id uuid,proof_fingerprint text,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_invoice public.final_invoices%rowtype; v_dpl public.finance_dpl_receipts%rowtype;
  v_clearance uuid; v_remaining integer; v_gate_ids jsonb; v_fingerprint text; v_existing public.dispatch_proof_packets%rowtype;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN RAISE EXCEPTION 'DISPATCH_PROOF_ACTOR_REQUIRED' USING ERRCODE='42501'; END IF;
  PERFORM public.assert_order_transition_role('gate_release'); v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');
  IF jsonb_typeof(p_transport_snapshot) IS DISTINCT FROM 'object' OR nullif(btrim(p_transport_snapshot->>'transporter'),'') IS NULL
     OR nullif(btrim(p_transport_snapshot->>'lr_awb_bilty'),'') IS NULL OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references)=0 OR p_dispatched_at IS NULL OR p_dispatched_at>statement_timestamp()+interval '5 minutes'
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN RAISE EXCEPTION 'DISPATCH_PROOF_EVIDENCE_REQUIRED' USING ERRCODE='P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('dispatch-proof:'||p_order_id::text,0));
  v_clearance:=public.assert_active_dispatch_clearance_v1(p_order_id);
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF v_invoice.id IS NULL THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE id=v_invoice.finance_dpl_receipt_id;
  IF v_dpl.id IS NULL OR v_dpl.dpl_snapshot->>'source_authority' IS DISTINCT FROM 'b2b_dispatch_packing_list_versions' THEN RAISE EXCEPTION 'FINAL_B2B_DPL_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT count(*) INTO v_remaining FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value)
   WHERE NOT EXISTS(SELECT 1 FROM public.b2b_dispatch_cartons bc WHERE bc.id::text=c.value AND bc.status='handed_over');
  IF v_remaining>0 THEN RAISE EXCEPTION 'DISPATCH_PROOF_GATE_RELEASE_INCOMPLETE' USING ERRCODE='55000'; END IF;
  SELECT coalesce(jsonb_agg(g.id ORDER BY g.created_at,g.id),'[]'::jsonb) INTO v_gate_ids FROM public.b2b_dispatch_gate_decisions g
   WHERE g.order_id=p_order_id AND g.decision='released' AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value) WHERE c.value=g.carton_id::text);
  IF jsonb_array_length(v_gate_ids) IS DISTINCT FROM jsonb_array_length(v_dpl.dpl_snapshot->'carton_ids') THEN RAISE EXCEPTION 'DISPATCH_PROOF_GATE_LINEAGE_INCOMPLETE' USING ERRCODE='55000'; END IF;
  v_fingerprint:=encode(extensions.digest(jsonb_build_object('order_id',p_order_id,'final_invoice_id',v_invoice.id,'finance_dpl_receipt_id',v_dpl.id,
    'finance_dispatch_clearance_event_id',v_clearance,'transport_snapshot',p_transport_snapshot,'gate_decision_ids',v_gate_ids,
    'evidence_references',p_evidence_references,'dispatched_at',p_dispatched_at)::text,'sha256'),'hex');
  SELECT * INTO v_existing FROM public.dispatch_proof_packets WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN IF v_existing.recorded_by IS DISTINCT FROM v_actor OR v_existing.proof_fingerprint IS DISTINCT FROM v_fingerprint THEN RAISE EXCEPTION 'DISPATCH_PROOF_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505'; END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.proof_fingerprint,true; RETURN; END IF;
  IF EXISTS(SELECT 1 FROM public.dispatch_proof_packets WHERE order_id=p_order_id) THEN RAISE EXCEPTION 'DISPATCH_PROOF_ALREADY_FROZEN' USING ERRCODE='55000'; END IF;
  INSERT INTO public.dispatch_proof_packets(order_id,final_invoice_id,finance_dpl_receipt_id,finance_dispatch_clearance_event_id,transport_snapshot,gate_decision_ids,evidence_references,
    dispatched_at,proof_fingerprint,recorded_by,recorded_role,correlation_id,idempotency_key)
  VALUES(p_order_id,v_invoice.id,v_dpl.id,v_clearance,p_transport_snapshot,v_gate_ids,p_evidence_references,p_dispatched_at,v_fingerprint,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id,v_existing.proof_fingerprint,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamptz,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamptz,text,text,uuid) TO authenticated;
