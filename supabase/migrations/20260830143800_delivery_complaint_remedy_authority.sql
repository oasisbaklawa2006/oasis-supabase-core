-- Finance Exit F13-F17: delivery evidence, 10-calendar-day complaint window,
-- governed complaint decisions and append-only financial remedies.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE IF NOT EXISTS public.delivery_proofs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  dispatch_proof_id uuid NOT NULL REFERENCES public.dispatch_proof_packets(id),
  delivered_at timestamptz NOT NULL,
  recipient_reference text NOT NULL,
  evidence_references jsonb NOT NULL,
  proof_fingerprint text NOT NULL CHECK(proof_fingerprint~'^[0-9a-f]{64}$'),
  recorded_by uuid NOT NULL REFERENCES auth.users(id),
  recorded_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(order_id)
);
ALTER TABLE public.delivery_proofs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.delivery_proofs FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.delivery_proofs TO authenticated,service_role;
CREATE POLICY delivery_proofs_internal_read ON public.delivery_proofs FOR SELECT TO authenticated
  USING(public.is_internal_staff(auth.uid()) OR order_id IN(SELECT o.id FROM public.orders o WHERE o.company_id=public.auth_buyer_company_id()));

CREATE OR REPLACE FUNCTION public.prevent_delivery_proof_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN RAISE EXCEPTION 'DELIVERY_PROOF_IMMUTABLE' USING ERRCODE='42501'; END; $$;
CREATE TRIGGER trg_delivery_proofs_immutable BEFORE UPDATE OR DELETE ON public.delivery_proofs FOR EACH ROW EXECUTE FUNCTION public.prevent_delivery_proof_mutation();
REVOKE ALL ON FUNCTION public.prevent_delivery_proof_mutation() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.record_delivery_proof_v1(
  p_order_id uuid,p_delivered_at timestamptz,p_recipient_reference text,p_evidence_references jsonb,
  p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(delivery_proof_id uuid,complaint_deadline timestamptz,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_dispatch public.dispatch_proof_packets%rowtype; v_existing public.delivery_proofs%rowtype; v_fp text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN RAISE EXCEPTION 'DELIVERY_PROOF_ACTOR_REQUIRED' USING ERRCODE='42501'; END IF;
  PERFORM public.assert_order_transition_role('gate_release');
  v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');
  IF p_delivered_at IS NULL OR p_delivered_at>statement_timestamp()+interval '5 minutes'
     OR nullif(btrim(p_recipient_reference),'') IS NULL OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references)=0 OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_dispatch FROM public.dispatch_proof_packets WHERE order_id=p_order_id;
  IF NOT FOUND OR p_delivered_at<v_dispatch.dispatched_at THEN RAISE EXCEPTION 'DELIVERY_PROOF_DISPATCH_BINDING_INVALID' USING ERRCODE='40001'; END IF;
  v_fp:=encode(extensions.digest(jsonb_build_object('order_id',p_order_id,'dispatch_proof_id',v_dispatch.id,'delivered_at',p_delivered_at,
    'recipient_reference',btrim(p_recipient_reference),'evidence_references',p_evidence_references)::text,'sha256'),'hex');
  SELECT * INTO v_existing FROM public.delivery_proofs WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.recorded_by IS DISTINCT FROM v_actor OR v_existing.proof_fingerprint IS DISTINCT FROM v_fp THEN RAISE EXCEPTION 'DELIVERY_PROOF_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505'; END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.delivered_at+interval '10 days',true; RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.delivery_proofs WHERE order_id=p_order_id) THEN RAISE EXCEPTION 'DELIVERY_PROOF_ALREADY_RECORDED' USING ERRCODE='55000'; END IF;
  INSERT INTO public.delivery_proofs(order_id,dispatch_proof_id,delivered_at,recipient_reference,evidence_references,proof_fingerprint,recorded_by,recorded_role,correlation_id,idempotency_key)
  VALUES(p_order_id,v_dispatch.id,p_delivered_at,btrim(p_recipient_reference),p_evidence_references,v_fp,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id,v_existing.delivered_at+interval '10 days',false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid) TO authenticated;

CREATE TABLE IF NOT EXISTS public.commercial_complaints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  dispatch_proof_id uuid NOT NULL REFERENCES public.dispatch_proof_packets(id),
  delivery_proof_id uuid REFERENCES public.delivery_proofs(id),
  complaint_type text NOT NULL CHECK(complaint_type IN('SHORTAGE','WRONG_PRODUCT','DAMAGE','QUALITY','EXPIRY','PACKAGING_DAMAGE','TRANSIT_DAMAGE','INVOICE_MISMATCH','PRICE_MISMATCH','TAX_ERROR','DELIVERY_DISPUTE')),
  description text NOT NULL,
  evidence_references jsonb NOT NULL,
  filed_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  complaint_deadline timestamptz,
  late_exception_reason text,
  filed_by uuid NOT NULL REFERENCES auth.users(id),
  filed_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE TABLE IF NOT EXISTS public.commercial_complaint_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  complaint_id uuid NOT NULL REFERENCES public.commercial_complaints(id),
  status text NOT NULL CHECK(status IN('OPEN','UNDER_REVIEW','RESOLVED')),
  notes text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.commercial_complaints ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commercial_complaint_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.commercial_complaints,public.commercial_complaint_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.commercial_complaints,public.commercial_complaint_events TO authenticated,service_role;
CREATE POLICY complaints_authorized_read ON public.commercial_complaints FOR SELECT TO authenticated
  USING(public.is_internal_staff(auth.uid()) OR company_id=public.auth_buyer_company_id());
CREATE POLICY complaint_events_authorized_read ON public.commercial_complaint_events FOR SELECT TO authenticated
  USING(EXISTS(SELECT 1 FROM public.commercial_complaints c WHERE c.id=complaint_id AND (public.is_internal_staff(auth.uid()) OR c.company_id=public.auth_buyer_company_id())));

CREATE OR REPLACE FUNCTION public.prevent_complaint_fact_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN RAISE EXCEPTION 'COMMERCIAL_COMPLAINT_FACTS_IMMUTABLE' USING ERRCODE='42501'; END; $$;
CREATE TRIGGER trg_commercial_complaints_immutable BEFORE UPDATE OR DELETE ON public.commercial_complaints FOR EACH ROW EXECUTE FUNCTION public.prevent_complaint_fact_mutation();
CREATE TRIGGER trg_commercial_complaint_events_immutable BEFORE UPDATE OR DELETE ON public.commercial_complaint_events FOR EACH ROW EXECUTE FUNCTION public.prevent_complaint_fact_mutation();
REVOKE ALL ON FUNCTION public.prevent_complaint_fact_mutation() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.file_commercial_complaint_v1(
  p_order_id uuid,p_complaint_type text,p_description text,p_evidence_references jsonb,p_late_exception_reason text,
  p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(complaint_id uuid,complaint_deadline timestamptz,late_exception boolean,already_filed boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_order public.orders%rowtype; v_dispatch public.dispatch_proof_packets%rowtype; v_delivery public.delivery_proofs%rowtype;
  v_internal boolean; v_role text; v_type text:=upper(btrim(coalesce(p_complaint_type,''))); v_existing public.commercial_complaints%rowtype; v_deadline timestamptz; v_late boolean:=false;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'COMPLAINT_ACTOR_REQUIRED' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  IF NOT FOUND OR v_order.company_id IS NULL THEN RAISE EXCEPTION 'COMPLAINT_ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  v_internal:=public.is_internal_staff(v_actor);
  IF NOT v_internal AND v_order.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN RAISE EXCEPTION 'COMPLAINT_COMPANY_SCOPE_REQUIRED' USING ERRCODE='42501'; END IF;
  v_role:=coalesce(public.get_user_role(v_actor),CASE WHEN NOT v_internal THEN 'b2b_buyer' ELSE 'unknown' END);
  IF v_type NOT IN('SHORTAGE','WRONG_PRODUCT','DAMAGE','QUALITY','EXPIRY','PACKAGING_DAMAGE','TRANSIT_DAMAGE','INVOICE_MISMATCH','PRICE_MISMATCH','TAX_ERROR','DELIVERY_DISPUTE')
     OR length(btrim(coalesce(p_description,'')))<5 OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN RAISE EXCEPTION 'COMPLAINT_EVIDENCE_REQUIRED' USING ERRCODE='P0001'; END IF;
  SELECT * INTO v_dispatch FROM public.dispatch_proof_packets WHERE order_id=p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMPLAINT_DISPATCH_PROOF_REQUIRED' USING ERRCODE='55000'; END IF;
  SELECT * INTO v_delivery FROM public.delivery_proofs WHERE order_id=p_order_id;
  IF FOUND THEN
    v_deadline:=v_delivery.delivered_at+interval '10 days';
    IF statement_timestamp()>v_deadline THEN
      IF NOT v_internal THEN RAISE EXCEPTION 'COMPLAINT_WINDOW_EXPIRED' USING ERRCODE='55000'; END IF;
      IF nullif(btrim(p_late_exception_reason),'') IS NULL OR NOT public.has_step_up_auth() THEN RAISE EXCEPTION 'COMPLAINT_LATE_EXCEPTION_AAL2_REQUIRED' USING ERRCODE='42501'; END IF;
      v_late:=true;
    END IF;
  ELSE
    -- No delivery proof means the 10-day clock has not started. Accept a complaint
    -- and keep the deadline diagnostically NULL rather than silently expiring it.
    v_deadline:=NULL;
  END IF;
  SELECT * INTO v_existing FROM public.commercial_complaints WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.filed_by IS DISTINCT FROM v_actor OR v_existing.order_id IS DISTINCT FROM p_order_id OR v_existing.complaint_type IS DISTINCT FROM v_type THEN RAISE EXCEPTION 'COMPLAINT_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505'; END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.complaint_deadline,v_existing.late_exception_reason IS NOT NULL,true; RETURN;
  END IF;
  INSERT INTO public.commercial_complaints(order_id,company_id,dispatch_proof_id,delivery_proof_id,complaint_type,description,evidence_references,
    complaint_deadline,late_exception_reason,filed_by,filed_role,correlation_id,idempotency_key)
  VALUES(p_order_id,v_order.company_id,v_dispatch.id,v_delivery.id,v_type,btrim(p_description),p_evidence_references,v_deadline,
    CASE WHEN v_late THEN btrim(p_late_exception_reason) ELSE NULL END,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  INSERT INTO public.commercial_complaint_events(complaint_id,status,notes,actor_id,actor_role)
  VALUES(v_existing.id,'OPEN',CASE WHEN v_late THEN 'Late complaint accepted under AAL2 exception: '||btrim(p_late_exception_reason) ELSE 'Complaint filed' END,v_actor,v_role);
  RETURN QUERY SELECT v_existing.id,v_deadline,v_late,false;
END;
$$;
REVOKE ALL ON FUNCTION public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid) TO authenticated;

CREATE TABLE IF NOT EXISTS public.commercial_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  complaint_id uuid NOT NULL REFERENCES public.commercial_complaints(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  final_invoice_id uuid NOT NULL REFERENCES public.final_invoices(id),
  adjustment_type text NOT NULL CHECK(adjustment_type IN('NO_FINANCIAL_ACTION','CREDIT_NOTE','DEBIT_NOTE','REFUND_TO_BANK','REFUND_TO_WALLET','REPLACEMENT_NO_CHARGE','REPLACEMENT_CHARGEABLE','PARTIAL_WRITE_OFF','CUSTOMER_DEBIT','TRANSPORTER_RECOVERY','EMPLOYEE_RECOVERY','VENDOR_RECOVERY')),
  amount numeric NOT NULL CHECK(amount>=0),
  document_number text,
  document_reference text,
  payment_reference text,
  wallet_entry_id uuid REFERENCES public.wallet_transactions(id),
  decision_reason text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.commercial_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.commercial_adjustments FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.commercial_adjustments TO authenticated,service_role;
CREATE POLICY commercial_adjustments_internal_read ON public.commercial_adjustments FOR SELECT TO authenticated USING(public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_commercial_adjustment_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN RAISE EXCEPTION 'COMMERCIAL_ADJUSTMENT_APPEND_ONLY' USING ERRCODE='42501'; END; $$;
CREATE TRIGGER trg_commercial_adjustments_immutable BEFORE UPDATE OR DELETE ON public.commercial_adjustments FOR EACH ROW EXECUTE FUNCTION public.prevent_commercial_adjustment_mutation();
REVOKE ALL ON FUNCTION public.prevent_commercial_adjustment_mutation() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.resolve_commercial_complaint_v1(
  p_complaint_id uuid,p_adjustment_type text,p_amount numeric,p_document_number text,p_document_reference text,p_payment_reference text,
  p_decision_reason text,p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(adjustment_id uuid,wallet_entry_id uuid,already_resolved boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_complaint public.commercial_complaints%rowtype; v_invoice public.final_invoices%rowtype;
  v_type text:=upper(btrim(coalesce(p_adjustment_type,''))); v_existing public.commercial_adjustments%rowtype; v_wallet uuid; v_balance numeric; v_dup boolean;
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF v_type NOT IN('NO_FINANCIAL_ACTION','CREDIT_NOTE','DEBIT_NOTE','REFUND_TO_BANK','REFUND_TO_WALLET','REPLACEMENT_NO_CHARGE','REPLACEMENT_CHARGEABLE','PARTIAL_WRITE_OFF','CUSTOMER_DEBIT','TRANSPORTER_RECOVERY','EMPLOYEE_RECOVERY','VENDOR_RECOVERY')
     OR p_amount IS NULL OR p_amount<0 OR length(btrim(coalesce(p_decision_reason,'')))<5
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN RAISE EXCEPTION 'COMPLAINT_RESOLUTION_EVIDENCE_REQUIRED' USING ERRCODE='P0001'; END IF;
  IF v_type IN('CREDIT_NOTE','DEBIT_NOTE') AND (p_amount<=0 OR nullif(btrim(p_document_number),'') IS NULL OR nullif(btrim(p_document_reference),'') IS NULL) THEN RAISE EXCEPTION 'TAX_ADJUSTMENT_DOCUMENT_REQUIRED' USING ERRCODE='P0001'; END IF;
  IF v_type='REFUND_TO_BANK' AND (p_amount<=0 OR nullif(btrim(p_payment_reference),'') IS NULL) THEN RAISE EXCEPTION 'BANK_REFUND_REFERENCE_REQUIRED' USING ERRCODE='P0001'; END IF;
  IF v_type='REFUND_TO_WALLET' AND p_amount<=0 THEN RAISE EXCEPTION 'WALLET_REFUND_AMOUNT_REQUIRED' USING ERRCODE='P0001'; END IF;
  IF v_type IN('NO_FINANCIAL_ACTION','REPLACEMENT_NO_CHARGE') AND p_amount<>0 THEN RAISE EXCEPTION 'ZERO_VALUE_REMEDY_AMOUNT_MUST_BE_ZERO' USING ERRCODE='P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('complaint-resolution:'||p_complaint_id::text,0));
  SELECT * INTO v_existing FROM public.commercial_adjustments WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.complaint_id IS DISTINCT FROM p_complaint_id OR v_existing.adjustment_type IS DISTINCT FROM v_type OR v_existing.amount IS DISTINCT FROM p_amount THEN RAISE EXCEPTION 'COMPLAINT_RESOLUTION_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505'; END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.wallet_entry_id,true; RETURN;
  END IF;
  SELECT * INTO v_complaint FROM public.commercial_complaints WHERE id=p_complaint_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMPLAINT_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  IF EXISTS(SELECT 1 FROM public.commercial_adjustments WHERE complaint_id=p_complaint_id) THEN RAISE EXCEPTION 'COMPLAINT_ALREADY_RESOLVED' USING ERRCODE='55000'; END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=v_complaint.order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  IF v_type='REFUND_TO_WALLET' THEN
    SELECT entry_id,balance,already_applied INTO v_wallet,v_balance,v_dup FROM public.record_wallet_entry_v1(v_complaint.company_id,'credit',p_amount,'INR',
      v_invoice.order_id,v_invoice.proforma_invoice_id,v_invoice.commercial_version_id,'COMPLAINT_REMEDY',p_complaint_id::text,btrim(p_decision_reason),
      btrim(p_correlation_id),btrim(p_idempotency_key)||':wallet',v_actor);
  END IF;
  INSERT INTO public.commercial_adjustments(complaint_id,order_id,final_invoice_id,adjustment_type,amount,document_number,document_reference,
    payment_reference,wallet_entry_id,decision_reason,actor_id,actor_role,correlation_id,idempotency_key)
  VALUES(p_complaint_id,v_complaint.order_id,v_invoice.id,v_type,p_amount,nullif(btrim(p_document_number),''),nullif(btrim(p_document_reference),''),
    nullif(btrim(p_payment_reference),''),v_wallet,btrim(p_decision_reason),v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  INSERT INTO public.commercial_complaint_events(complaint_id,status,notes,actor_id,actor_role)
  VALUES(p_complaint_id,'RESOLVED',btrim(p_decision_reason)||' ['||v_type||']',v_actor,v_role);
  RETURN QUERY SELECT v_existing.id,v_existing.wallet_entry_id,false;
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE VIEW public.commercial_complaint_window_v1 WITH(security_invoker=true) AS
SELECT d.order_id,d.id delivery_proof_id,d.delivered_at,d.delivered_at+interval '10 days' complaint_deadline,
  CASE
    WHEN EXISTS(SELECT 1 FROM public.commercial_complaints c WHERE c.order_id=d.order_id AND NOT EXISTS(SELECT 1 FROM public.commercial_adjustments a WHERE a.complaint_id=c.id)) THEN 'RESOLUTION_PENDING'
    WHEN statement_timestamp()<=d.delivered_at+interval '10 days' THEN 'OPEN'
    WHEN EXISTS(SELECT 1 FROM public.commercial_complaints c WHERE c.order_id=d.order_id) THEN 'RESOLVED'
    ELSE 'EXPIRED_NO_COMPLAINT'
  END window_status,
  (SELECT count(*) FROM public.commercial_complaints c WHERE c.order_id=d.order_id) complaint_count
FROM public.delivery_proofs d;
REVOKE ALL ON public.commercial_complaint_window_v1 FROM PUBLIC,anon;
GRANT SELECT ON public.commercial_complaint_window_v1 TO authenticated,service_role;

COMMENT ON VIEW public.commercial_complaint_window_v1 IS '10 calendar days from recorded delivery proof. Day 10 is included; without delivery proof no row/deadline exists and the clock has not started.';
