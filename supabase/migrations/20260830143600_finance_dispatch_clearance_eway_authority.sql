-- Finance Exit F9-F10: explicit Finance Dispatch Clearance and governed E-way
-- evidence. Settlement facts are evidence only; they never imply clearance.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.finance_clearance_events
  DROP CONSTRAINT IF EXISTS finance_clearance_events_clearance_type_check;
ALTER TABLE public.finance_clearance_events
  ADD CONSTRAINT finance_clearance_events_clearance_type_check
  CHECK (clearance_type IN ('OPERATIONS','DISPATCH'));
ALTER TABLE public.finance_clearance_idempotency
  DROP CONSTRAINT IF EXISTS finance_clearance_idempotency_operation_check;
ALTER TABLE public.finance_clearance_idempotency
  ADD CONSTRAINT finance_clearance_idempotency_operation_check
  CHECK (operation IN ('GRANT_OPERATIONS','DENY_OPERATIONS','REVOKE_OPERATIONS','GRANT_DISPATCH','DENY_DISPATCH','REVOKE_DISPATCH'));

CREATE TABLE IF NOT EXISTS public.eway_bill_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  final_invoice_id uuid NOT NULL REFERENCES public.final_invoices(id),
  status text NOT NULL CHECK(status IN ('VALIDATED','NOT_REQUIRED')),
  eway_bill_number text,
  document_reference text,
  policy_reason text NOT NULL,
  valid_from timestamptz,
  valid_until timestamptz,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CHECK (
    (status='VALIDATED' AND nullif(btrim(eway_bill_number),'') IS NOT NULL AND nullif(btrim(document_reference),'') IS NOT NULL)
    OR (status='NOT_REQUIRED' AND eway_bill_number IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS eway_bill_evidence_order_idx ON public.eway_bill_evidence(order_id,created_at DESC);
ALTER TABLE public.eway_bill_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.eway_bill_evidence FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.eway_bill_evidence TO authenticated,service_role;
CREATE POLICY eway_bill_evidence_internal_read ON public.eway_bill_evidence FOR SELECT TO authenticated
  USING(public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_eway_bill_evidence_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN RAISE EXCEPTION 'EWAY_BILL_EVIDENCE_IMMUTABLE' USING ERRCODE='42501'; END; $$;
CREATE TRIGGER trg_eway_bill_evidence_immutable BEFORE UPDATE OR DELETE ON public.eway_bill_evidence
  FOR EACH ROW EXECUTE FUNCTION public.prevent_eway_bill_evidence_mutation();
REVOKE ALL ON FUNCTION public.prevent_eway_bill_evidence_mutation() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.record_eway_bill_evidence_v1(
  p_final_invoice_id uuid,
  p_status text,
  p_eway_bill_number text,
  p_document_reference text,
  p_policy_reason text,
  p_valid_from timestamptz,
  p_valid_until timestamptz,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(eway_evidence_id uuid,status text,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_invoice public.final_invoices%rowtype; v_existing public.eway_bill_evidence%rowtype; v_status text:=upper(btrim(coalesce(p_status,'')));
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF v_status NOT IN('VALIDATED','NOT_REQUIRED') OR length(btrim(coalesce(p_policy_reason,'')))<5
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'EWAY_BILL_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  IF v_status='VALIDATED' AND (nullif(btrim(p_eway_bill_number),'') IS NULL OR nullif(btrim(p_document_reference),'') IS NULL) THEN
    RAISE EXCEPTION 'EWAY_BILL_VALIDATION_DOCUMENT_REQUIRED' USING ERRCODE='P0001';
  END IF;
  IF v_status='NOT_REQUIRED' AND nullif(btrim(coalesce(p_eway_bill_number,'')),'') IS NOT NULL THEN
    RAISE EXCEPTION 'EWAY_BILL_NOT_REQUIRED_CANNOT_HAVE_NUMBER' USING ERRCODE='P0001';
  END IF;
  IF p_valid_until IS NOT NULL AND p_valid_from IS NOT NULL AND p_valid_until<=p_valid_from THEN
    RAISE EXCEPTION 'EWAY_BILL_VALIDITY_INVALID' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE id=p_final_invoice_id AND status='ISSUED';
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('eway:'||v_invoice.order_id::text,0));
  SELECT * INTO v_existing FROM public.eway_bill_evidence WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.final_invoice_id IS DISTINCT FROM p_final_invoice_id
       OR v_existing.status IS DISTINCT FROM v_status OR coalesce(v_existing.eway_bill_number,'') IS DISTINCT FROM coalesce(nullif(btrim(p_eway_bill_number),''),'')
       OR v_existing.policy_reason IS DISTINCT FROM btrim(p_policy_reason) THEN
      RAISE EXCEPTION 'EWAY_BILL_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.status,true; RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.eway_bill_evidence e WHERE e.final_invoice_id=p_final_invoice_id) THEN
    RAISE EXCEPTION 'EWAY_BILL_DECISION_ALREADY_RECORDED' USING ERRCODE='55000';
  END IF;
  INSERT INTO public.eway_bill_evidence(order_id,final_invoice_id,status,eway_bill_number,document_reference,policy_reason,
    valid_from,valid_until,actor_id,actor_role,correlation_id,idempotency_key)
  VALUES(v_invoice.order_id,p_final_invoice_id,v_status,CASE WHEN v_status='VALIDATED' THEN btrim(p_eway_bill_number) ELSE NULL END,
    CASE WHEN v_status='VALIDATED' THEN btrim(p_document_reference) ELSE nullif(btrim(p_document_reference),'') END,btrim(p_policy_reason),
    p_valid_from,p_valid_until,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id,v_existing.status,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamptz,timestamptz,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamptz,timestamptz,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.decide_finance_dispatch_clearance_v1(
  p_final_invoice_id uuid,
  p_decision text,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(clearance_event_id uuid,decision text,already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_decision text:=upper(btrim(coalesce(p_decision,'')));
  v_invoice public.final_invoices%rowtype; v_settlement jsonb; v_eway public.eway_bill_evidence%rowtype;
  v_latest public.finance_clearance_events%rowtype; v_existing public.finance_clearance_idempotency%rowtype;
  v_event public.finance_clearance_events%rowtype; v_operation text; v_fingerprint text; v_response jsonb;
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF v_decision NOT IN('GRANTED','DENIED','REVOKED') OR length(btrim(coalesce(p_reason,'')))<5
     OR nullif(btrim(p_evidence_reference),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE id=p_final_invoice_id AND status='ISSUED';
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('finance-dispatch-clearance:'||v_invoice.order_id::text,0));
  PERFORM public.assert_active_operations_clearance_v1(v_invoice.order_id);
  v_settlement:=public.get_final_settlement_facts_v1(p_final_invoice_id);
  SELECT * INTO v_eway FROM public.eway_bill_evidence WHERE final_invoice_id=p_final_invoice_id ORDER BY created_at DESC LIMIT 1;

  SELECT * INTO v_latest FROM public.finance_clearance_events e
   WHERE e.order_id=v_invoice.order_id AND e.clearance_type='DISPATCH' ORDER BY e.created_at DESC,e.id DESC LIMIT 1;
  IF v_decision='GRANTED' THEN
    IF coalesce((v_settlement->>'settled_for_dispatch')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_BALANCE_OUTSTANDING' USING ERRCODE='55000';
    END IF;
    IF v_eway.id IS NULL OR v_eway.status NOT IN('VALIDATED','NOT_REQUIRED')
       OR (v_eway.status='VALIDATED' AND v_eway.valid_until IS NOT NULL AND v_eway.valid_until<=statement_timestamp()) THEN
      RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_EWAY_REQUIRED' USING ERRCODE='55000';
    END IF;
  END IF;
  IF v_decision='REVOKED' AND (v_latest.id IS NULL OR v_latest.decision<>'GRANTED') THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_NOT_ACTIVE' USING ERRCODE='55000';
  END IF;

  v_operation:=CASE v_decision WHEN 'GRANTED' THEN 'GRANT_DISPATCH' WHEN 'DENIED' THEN 'DENY_DISPATCH' ELSE 'REVOKE_DISPATCH' END;
  v_fingerprint:=encode(extensions.digest(jsonb_build_object('operation',v_operation,'final_invoice_id',p_final_invoice_id,
    'reason',btrim(p_reason),'evidence_reference',btrim(p_evidence_reference),'correlation_id',btrim(p_correlation_id),
    'settlement',v_settlement-'facts_as_of','eway_evidence_id',v_eway.id)::text,'sha256'),'hex');
  SELECT * INTO v_existing FROM public.finance_clearance_idempotency WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_CLEARANCE_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.clearance_event_id,(v_existing.response->>'decision')::text,true; RETURN;
  END IF;

  INSERT INTO public.finance_clearance_events(order_id,company_id,proforma_invoice_id,commercial_version_id,clearance_type,decision,
    commercial_value,required_advance,verified_payment_amount,wallet_applied_amount,approved_credit_amount,covered_amount,
    reason,evidence_reference,actor_id,actor_role,source_channel,source_reference,correlation_id,idempotency_key,facts_snapshot)
  VALUES(v_invoice.order_id,v_invoice.company_id,v_invoice.proforma_invoice_id,v_invoice.commercial_version_id,'DISPATCH',v_decision,
    v_invoice.gross_total,0,(v_settlement->>'verified_payment_total')::numeric,(v_settlement->>'wallet_applied_total')::numeric,
    (v_settlement->>'approved_credit_total')::numeric,
    (v_settlement->>'verified_payment_total')::numeric+(v_settlement->>'wallet_applied_total')::numeric+(v_settlement->>'approved_credit_total')::numeric,
    btrim(p_reason),btrim(p_evidence_reference),v_actor,v_role,'FINANCE',p_final_invoice_id::text,btrim(p_correlation_id),btrim(p_idempotency_key),
    jsonb_build_object('final_invoice_id',p_final_invoice_id,'settlement',v_settlement,'eway_evidence_id',v_eway.id,'dispatch_release_mutated',false))
  RETURNING * INTO v_event;
  v_response:=jsonb_build_object('clearance_event_id',v_event.id,'decision',v_event.decision,'clearance_type','DISPATCH','order_id',v_invoice.order_id);
  INSERT INTO public.finance_clearance_idempotency(idempotency_key,operation,request_fingerprint,clearance_event_id,actor_id,response)
  VALUES(btrim(p_idempotency_key),v_operation,v_fingerprint,v_event.id,v_actor,v_response);
  RETURN QUERY SELECT v_event.id,v_event.decision,false;
END;
$$;
REVOKE ALL ON FUNCTION public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.decide_finance_dispatch_clearance_v1(uuid,text,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE VIEW public.finance_dispatch_clearance_authority_v1
WITH (security_invoker=true) AS
SELECT DISTINCT ON(e.order_id) e.order_id,e.company_id,e.proforma_invoice_id,e.commercial_version_id,e.id clearance_event_id,
  e.decision,(e.decision='GRANTED') dispatch_cleared,e.commercial_value invoice_gross_total,e.covered_amount,e.actor_id,e.actor_role,e.created_at
FROM public.finance_clearance_events e WHERE e.clearance_type='DISPATCH'
ORDER BY e.order_id,e.created_at DESC,e.id DESC;
REVOKE ALL ON public.finance_dispatch_clearance_authority_v1 FROM PUBLIC,anon;
GRANT SELECT ON public.finance_dispatch_clearance_authority_v1 TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.assert_active_dispatch_clearance_v1(p_order_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v public.finance_dispatch_clearance_authority_v1%rowtype;
BEGIN
  SELECT * INTO v FROM public.finance_dispatch_clearance_authority_v1 WHERE order_id=p_order_id;
  IF NOT FOUND OR NOT coalesce(v.dispatch_cleared,false) THEN RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_REQUIRED' USING ERRCODE='55000'; END IF;
  RETURN v.clearance_event_id;
END; $$;
REVOKE ALL ON FUNCTION public.assert_active_dispatch_clearance_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.assert_active_dispatch_clearance_v1(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.clear_order_for_dispatch_v1(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE v public.orders%rowtype; v_clearance uuid;
BEGIN
  PERFORM public.assert_order_transition_role('clear_dispatch');
  SELECT * INTO v FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); END IF;
  IF v.status='cleared_for_dispatch' THEN RETURN jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',true); END IF;
  IF v.status NOT IN('packed_ready','awaiting_final_payment') THEN
    RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status')));
  END IF;
  BEGIN v_clearance:=public.assert_active_dispatch_clearance_v1(p_order_id);
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','finance_dispatch_clearance_required','message',SQLERRM))); END;
  UPDATE public.orders SET status='cleared_for_dispatch' WHERE id=p_order_id;
  INSERT INTO public.order_status_history(order_id,old_status,new_status,changed_by) VALUES(p_order_id,v.status,'cleared_for_dispatch',auth.uid());
  INSERT INTO public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value)
  VALUES('ORDER_CLEARED_FOR_DISPATCH','Dispatch','orders',p_order_id::text,auth.uid(),'high',jsonb_build_object('finance_dispatch_clearance_event_id',v_clearance));
  RETURN jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',false,'finance_dispatch_clearance_event_id',v_clearance);
END; $$;
REVOKE ALL ON FUNCTION public.clear_order_for_dispatch_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.clear_order_for_dispatch_v1(uuid) TO authenticated,service_role;

COMMENT ON TABLE public.eway_bill_evidence IS 'Immutable Finance decision/evidence: validated E-way Bill or explicit not-required determination. No pseudo URL authority.';
