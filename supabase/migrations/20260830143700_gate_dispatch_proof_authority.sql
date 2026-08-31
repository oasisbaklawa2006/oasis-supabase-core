-- Finance Exit F11-F12: gate consumes explicit Finance Dispatch Clearance and
-- exact DPL carton membership. Dispatch proof is frozen only after every DPL
-- carton has independently passed the physical gate.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.release_carton_at_dispatch_gate_v1(p_carton_id uuid,p_scan_evidence_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE
  v_carton public.dispatch_cartons%rowtype;
  v_order public.orders%rowtype;
  v_scan public.operational_scan_records%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_dpl public.finance_dpl_receipts%rowtype;
  v_eway public.eway_bill_evidence%rowtype;
  v_clearance uuid;
  v_blockers jsonb:='[]'::jsonb;
  v_remaining int;
BEGIN
  PERFORM public.assert_order_transition_role('gate_release');
  SELECT * INTO v_carton FROM public.dispatch_cartons WHERE id=p_carton_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','carton_not_found'))); END IF;
  IF v_carton.status='physically_dispatched' THEN RETURN jsonb_build_object('ok',true,'carton_id',p_carton_id,'already_released',true); END IF;

  SELECT * INTO v_scan FROM public.operational_scan_records WHERE id=p_scan_evidence_id;
  IF NOT FOUND OR v_scan.entity_id IS DISTINCT FROM p_carton_id OR v_scan.order_id IS DISTINCT FROM v_carton.order_id
     OR coalesce(v_scan.entity_type,'')<>'dispatch_carton' OR coalesce(v_scan.scan_type,'') NOT IN('carton','dispatch_gate')
     OR coalesce(v_scan.verification_status,'') NOT IN('scanned','verified') OR nullif(btrim(coalesce(v_carton.barcode_string,'')),'') IS NULL
     OR lower(btrim(coalesce(v_scan.barcode_value,''))) IS DISTINCT FROM lower(btrim(coalesce(v_carton.barcode_string,''))) THEN
    v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','invalid_scan_evidence'));
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id=v_carton.order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status<>'cleared_for_dispatch' THEN
    v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','order_not_cleared_for_dispatch'));
  ELSE
    BEGIN v_clearance:=public.assert_active_dispatch_clearance_v1(v_order.id);
    EXCEPTION WHEN OTHERS THEN v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','finance_dispatch_clearance_required','message',SQLERRM)); END;
  END IF;

  IF v_order.id IS NOT NULL THEN
    SELECT * INTO v_invoice FROM public.final_invoices f WHERE f.order_id=v_order.id AND f.status='ISSUED' ORDER BY f.created_at DESC LIMIT 1;
    IF v_invoice.id IS NULL THEN
      v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','canonical_final_invoice_missing'));
    ELSE
      SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE id=v_invoice.finance_dpl_receipt_id;
      IF v_dpl.id IS NULL OR NOT EXISTS(
        SELECT 1 FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value)
         WHERE c.value=p_carton_id::text
      ) THEN
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','carton_not_in_final_dpl'));
      END IF;
      SELECT * INTO v_eway FROM public.eway_bill_evidence e WHERE e.final_invoice_id=v_invoice.id ORDER BY e.created_at DESC LIMIT 1;
      IF v_eway.id IS NULL OR v_eway.status NOT IN('VALIDATED','NOT_REQUIRED')
         OR (v_eway.status='VALIDATED' AND v_eway.valid_until IS NOT NULL AND v_eway.valid_until<=statement_timestamp()) THEN
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','eway_evidence_invalid_or_expired'));
      END IF;
    END IF;
  END IF;

  IF jsonb_array_length(v_blockers)>0 THEN
    INSERT INTO public.dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,blockers,actor_id,actor_role,metadata)
    VALUES(p_carton_id,v_carton.order_id,p_scan_evidence_id,'denied',v_blockers,auth.uid(),public.get_user_role(auth.uid()),
      jsonb_build_object('finance_dispatch_clearance_event_id',v_clearance,'final_invoice_id',v_invoice.id,'finance_dpl_receipt_id',v_dpl.id,'eway_evidence_id',v_eway.id));
    RETURN jsonb_build_object('ok',false,'blockers',v_blockers);
  END IF;

  UPDATE public.dispatch_cartons SET status='physically_dispatched',scanned_out_at=statement_timestamp() WHERE id=p_carton_id;
  INSERT INTO public.dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,actor_id,actor_role,metadata)
  VALUES(p_carton_id,v_order.id,p_scan_evidence_id,'released',auth.uid(),public.get_user_role(auth.uid()),
    jsonb_build_object('finance_dispatch_clearance_event_id',v_clearance,'final_invoice_id',v_invoice.id,'finance_dpl_receipt_id',v_dpl.id,'eway_evidence_id',v_eway.id));
  INSERT INTO public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value)
  VALUES('CARTON_GATE_RELEASED','SecurityGate','dispatch_cartons',p_carton_id::text,auth.uid(),'high',
    jsonb_build_object('order_id',v_order.id,'scan_evidence_id',p_scan_evidence_id,'finance_dispatch_clearance_event_id',v_clearance,
      'final_invoice_id',v_invoice.id,'finance_dpl_receipt_id',v_dpl.id,'eway_evidence_id',v_eway.id));
  SELECT count(*) INTO v_remaining FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value)
   WHERE NOT EXISTS(SELECT 1 FROM public.dispatch_cartons dc WHERE dc.id::text=c.value AND dc.order_id=v_order.id AND dc.status='physically_dispatched');
  RETURN jsonb_build_object('ok',true,'carton_id',p_carton_id,'order_id',v_order.id,'remaining_dpl_cartons',v_remaining,
    'already_released',false,'finance_dispatch_clearance_event_id',v_clearance,'final_invoice_id',v_invoice.id,'finance_dpl_receipt_id',v_dpl.id);
END;
$$;
REVOKE ALL ON FUNCTION public.release_carton_at_dispatch_gate_v1(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.release_carton_at_dispatch_gate_v1(uuid,uuid) TO authenticated,service_role;

CREATE TABLE IF NOT EXISTS public.dispatch_proof_packets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  final_invoice_id uuid NOT NULL REFERENCES public.final_invoices(id),
  finance_dpl_receipt_id uuid NOT NULL REFERENCES public.finance_dpl_receipts(id),
  finance_dispatch_clearance_event_id uuid NOT NULL REFERENCES public.finance_clearance_events(id),
  transport_snapshot jsonb NOT NULL,
  gate_decision_ids jsonb NOT NULL,
  evidence_references jsonb NOT NULL,
  dispatched_at timestamptz NOT NULL,
  proof_fingerprint text NOT NULL CHECK(proof_fingerprint~'^[0-9a-f]{64}$'),
  recorded_by uuid NOT NULL REFERENCES auth.users(id),
  recorded_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(order_id)
);
ALTER TABLE public.dispatch_proof_packets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dispatch_proof_packets FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.dispatch_proof_packets TO authenticated,service_role;
CREATE POLICY dispatch_proof_packets_internal_read ON public.dispatch_proof_packets FOR SELECT TO authenticated
  USING(public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_dispatch_proof_packet_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN RAISE EXCEPTION 'DISPATCH_PROOF_PACKET_IMMUTABLE' USING ERRCODE='42501'; END; $$;
CREATE TRIGGER trg_dispatch_proof_packets_immutable BEFORE UPDATE OR DELETE ON public.dispatch_proof_packets
  FOR EACH ROW EXECUTE FUNCTION public.prevent_dispatch_proof_packet_mutation();
REVOKE ALL ON FUNCTION public.prevent_dispatch_proof_packet_mutation() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.record_dispatch_proof_packet_v1(
  p_order_id uuid,
  p_transport_snapshot jsonb,
  p_evidence_references jsonb,
  p_dispatched_at timestamptz,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(dispatch_proof_id uuid,proof_fingerprint text,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_invoice public.final_invoices%rowtype; v_dpl public.finance_dpl_receipts%rowtype;
  v_clearance uuid; v_remaining integer; v_gate_ids jsonb; v_fingerprint text; v_existing public.dispatch_proof_packets%rowtype;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'DISPATCH_PROOF_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;
  PERFORM public.assert_order_transition_role('gate_release');
  v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');
  IF jsonb_typeof(p_transport_snapshot) IS DISTINCT FROM 'object'
     OR nullif(btrim(p_transport_snapshot->>'transporter'),'') IS NULL
     OR nullif(btrim(p_transport_snapshot->>'lr_awb_bilty'),'') IS NULL
     OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array' OR jsonb_array_length(p_evidence_references)=0
     OR p_dispatched_at IS NULL OR p_dispatched_at>statement_timestamp()+interval '5 minutes'
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'DISPATCH_PROOF_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('dispatch-proof:'||p_order_id::text,0));
  v_clearance:=public.assert_active_dispatch_clearance_v1(p_order_id);
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF v_invoice.id IS NULL THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE id=v_invoice.finance_dpl_receipt_id;
  IF v_dpl.id IS NULL THEN RAISE EXCEPTION 'FINAL_DPL_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT count(*) INTO v_remaining FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value)
   WHERE NOT EXISTS(SELECT 1 FROM public.dispatch_cartons dc WHERE dc.id::text=c.value AND dc.order_id=p_order_id AND dc.status='physically_dispatched');
  IF v_remaining>0 THEN RAISE EXCEPTION 'DISPATCH_PROOF_GATE_RELEASE_INCOMPLETE' USING ERRCODE='55000'; END IF;
  SELECT coalesce(jsonb_agg(g.id ORDER BY g.created_at,g.id),'[]'::jsonb) INTO v_gate_ids
   FROM public.dispatch_gate_decisions g
   WHERE g.order_id=p_order_id AND g.decision='released'
     AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value) WHERE c.value=g.carton_id::text);
  IF jsonb_array_length(v_gate_ids) IS DISTINCT FROM jsonb_array_length(v_dpl.dpl_snapshot->'carton_ids') THEN
    RAISE EXCEPTION 'DISPATCH_PROOF_GATE_LINEAGE_INCOMPLETE' USING ERRCODE='55000';
  END IF;
  v_fingerprint:=encode(extensions.digest(jsonb_build_object('order_id',p_order_id,'final_invoice_id',v_invoice.id,
    'finance_dpl_receipt_id',v_dpl.id,'finance_dispatch_clearance_event_id',v_clearance,'transport_snapshot',p_transport_snapshot,
    'gate_decision_ids',v_gate_ids,'evidence_references',p_evidence_references,'dispatched_at',p_dispatched_at)::text,'sha256'),'hex');
  SELECT * INTO v_existing FROM public.dispatch_proof_packets WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.recorded_by IS DISTINCT FROM v_actor OR v_existing.proof_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'DISPATCH_PROOF_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.proof_fingerprint,true; RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.dispatch_proof_packets WHERE order_id=p_order_id) THEN RAISE EXCEPTION 'DISPATCH_PROOF_ALREADY_FROZEN' USING ERRCODE='55000'; END IF;
  INSERT INTO public.dispatch_proof_packets(order_id,final_invoice_id,finance_dpl_receipt_id,finance_dispatch_clearance_event_id,
    transport_snapshot,gate_decision_ids,evidence_references,dispatched_at,proof_fingerprint,recorded_by,recorded_role,correlation_id,idempotency_key)
  VALUES(p_order_id,v_invoice.id,v_dpl.id,v_clearance,p_transport_snapshot,v_gate_ids,p_evidence_references,p_dispatched_at,v_fingerprint,
    v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id,v_existing.proof_fingerprint,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamptz,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamptz,text,text,uuid) TO authenticated;

COMMENT ON TABLE public.dispatch_proof_packets IS 'Immutable shipment proof packet frozen after every final-DPL carton independently clears the physical gate.';
