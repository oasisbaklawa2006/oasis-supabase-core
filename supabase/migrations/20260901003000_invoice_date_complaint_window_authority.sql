-- Finance/Security scope correction: the 10-calendar-day ticket-raise window
-- is anchored to the canonical final invoice date, never delivery time.
--
-- Business rule: invoice date is Day 1. The window remains available through
-- Day 10 and expires at 00:00 Asia/Kolkata at the start of Day 11.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE OR REPLACE FUNCTION public.complaint_deadline_from_invoice_v1(p_invoice_date date)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path=pg_catalog,public
AS $$
  SELECT ((p_invoice_date::timestamp + interval '10 days') AT TIME ZONE 'Asia/Kolkata');
$$;
REVOKE ALL ON FUNCTION public.complaint_deadline_from_invoice_v1(date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.complaint_deadline_from_invoice_v1(date) TO authenticated,service_role;
COMMENT ON FUNCTION public.complaint_deadline_from_invoice_v1(date) IS
  'Canonical exclusive complaint deadline: invoice date is Day 1; Days 1-10 are included; expiry is 00:00 Asia/Kolkata at the start of Day 11.';

-- Delivery proof remains an immutable logistics/POD fact, but it no longer
-- starts or extends the ticket-raise clock. Preserve the RPC return shape while
-- returning the invoice-derived deadline.
CREATE OR REPLACE FUNCTION public.record_delivery_proof_v1(
  p_order_id uuid,p_delivered_at timestamptz,p_recipient_reference text,p_evidence_references jsonb,
  p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(delivery_proof_id uuid,complaint_deadline timestamptz,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_role text;
  v_dispatch public.dispatch_proof_packets%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_existing public.delivery_proofs%rowtype;
  v_fp text;
  v_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;
  PERFORM public.assert_order_transition_role('gate_release');
  v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');
  IF p_delivered_at IS NULL OR p_delivered_at>statement_timestamp()+interval '5 minutes'
     OR nullif(btrim(p_recipient_reference),'') IS NULL
     OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references)=0
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  SELECT * INTO v_dispatch FROM public.dispatch_proof_packets WHERE order_id=p_order_id;
  IF NOT FOUND OR p_delivered_at<v_dispatch.dispatched_at THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_DISPATCH_BINDING_INVALID' USING ERRCODE='40001';
  END IF;
  SELECT * INTO v_invoice FROM public.final_invoices
   WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_PROOF_FINAL_INVOICE_REQUIRED' USING ERRCODE='55000'; END IF;
  v_deadline:=public.complaint_deadline_from_invoice_v1(v_invoice.invoice_date);

  v_fp:=encode(extensions.digest(jsonb_build_object(
    'order_id',p_order_id,'dispatch_proof_id',v_dispatch.id,'delivered_at',p_delivered_at,
    'recipient_reference',btrim(p_recipient_reference),'evidence_references',p_evidence_references
  )::text,'sha256'),'hex');

  SELECT * INTO v_existing FROM public.delivery_proofs WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.recorded_by IS DISTINCT FROM v_actor OR v_existing.proof_fingerprint IS DISTINCT FROM v_fp THEN
      RAISE EXCEPTION 'DELIVERY_PROOF_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_deadline,true;
    RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.delivery_proofs WHERE order_id=p_order_id) THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_ALREADY_RECORDED' USING ERRCODE='55000';
  END IF;

  INSERT INTO public.delivery_proofs(
    order_id,dispatch_proof_id,delivered_at,recipient_reference,evidence_references,
    proof_fingerprint,recorded_by,recorded_role,correlation_id,idempotency_key
  ) VALUES(
    p_order_id,v_dispatch.id,p_delivered_at,btrim(p_recipient_reference),p_evidence_references,
    v_fp,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)
  ) RETURNING * INTO v_existing;

  RETURN QUERY SELECT v_existing.id,v_deadline,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid) TO authenticated;

-- Ticket intake belongs to CRM/cross-department handling, but its eligibility
-- clock must consume the canonical invoice-date rule. Dispatch proof remains the
-- shipment-lineage prerequisite; delivery proof is optional evidence only.
CREATE OR REPLACE FUNCTION public.file_commercial_complaint_v1(
  p_order_id uuid,p_complaint_type text,p_description text,p_evidence_references jsonb,p_late_exception_reason text,
  p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(complaint_id uuid,complaint_deadline timestamptz,late_exception boolean,already_filed boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_order public.orders%rowtype;
  v_dispatch public.dispatch_proof_packets%rowtype;
  v_delivery public.delivery_proofs%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_internal boolean;
  v_role text;
  v_type text:=upper(btrim(coalesce(p_complaint_type,'')));
  v_existing public.commercial_complaints%rowtype;
  v_deadline timestamptz;
  v_late boolean:=false;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'COMPLAINT_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  IF NOT FOUND OR v_order.company_id IS NULL THEN RAISE EXCEPTION 'COMPLAINT_ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  v_internal:=public.is_internal_staff(v_actor);
  IF NOT v_internal AND v_order.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'COMPLAINT_COMPANY_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_role:=coalesce(public.get_user_role(v_actor),CASE WHEN NOT v_internal THEN 'b2b_buyer' ELSE 'unknown' END);
  IF v_type NOT IN('SHORTAGE','WRONG_PRODUCT','DAMAGE','QUALITY','EXPIRY','PACKAGING_DAMAGE','TRANSIT_DAMAGE','INVOICE_MISMATCH','PRICE_MISMATCH','TAX_ERROR','DELIVERY_DISPUTE')
     OR length(btrim(coalesce(p_description,'')))<5
     OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'COMPLAINT_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  SELECT * INTO v_dispatch FROM public.dispatch_proof_packets WHERE order_id=p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMPLAINT_DISPATCH_PROOF_REQUIRED' USING ERRCODE='55000'; END IF;
  SELECT * INTO v_invoice FROM public.final_invoices
   WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMPLAINT_FINAL_INVOICE_REQUIRED' USING ERRCODE='55000'; END IF;
  SELECT * INTO v_delivery FROM public.delivery_proofs WHERE order_id=p_order_id;

  v_deadline:=public.complaint_deadline_from_invoice_v1(v_invoice.invoice_date);
  IF statement_timestamp()>=v_deadline THEN
    IF NOT v_internal THEN RAISE EXCEPTION 'COMPLAINT_WINDOW_EXPIRED' USING ERRCODE='55000'; END IF;
    IF nullif(btrim(p_late_exception_reason),'') IS NULL OR NOT public.has_step_up_auth() THEN
      RAISE EXCEPTION 'COMPLAINT_LATE_EXCEPTION_AAL2_REQUIRED' USING ERRCODE='42501';
    END IF;
    v_late:=true;
  END IF;

  SELECT * INTO v_existing FROM public.commercial_complaints WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.filed_by IS DISTINCT FROM v_actor
       OR v_existing.order_id IS DISTINCT FROM p_order_id
       OR v_existing.complaint_type IS DISTINCT FROM v_type THEN
      RAISE EXCEPTION 'COMPLAINT_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_deadline,v_existing.late_exception_reason IS NOT NULL,true;
    RETURN;
  END IF;

  INSERT INTO public.commercial_complaints(
    order_id,company_id,dispatch_proof_id,delivery_proof_id,complaint_type,description,evidence_references,
    complaint_deadline,late_exception_reason,filed_by,filed_role,correlation_id,idempotency_key
  ) VALUES(
    p_order_id,v_order.company_id,v_dispatch.id,v_delivery.id,v_type,btrim(p_description),p_evidence_references,
    v_deadline,CASE WHEN v_late THEN btrim(p_late_exception_reason) ELSE NULL END,
    v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)
  ) RETURNING * INTO v_existing;
  INSERT INTO public.commercial_complaint_events(complaint_id,status,notes,actor_id,actor_role)
  VALUES(v_existing.id,'OPEN',CASE WHEN v_late THEN 'Late complaint accepted under AAL2 exception: '||btrim(p_late_exception_reason) ELSE 'Complaint filed' END,v_actor,v_role);
  RETURN QUERY SELECT v_existing.id,v_deadline,v_late,false;
END;
$$;
REVOKE ALL ON FUNCTION public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid) TO authenticated;

-- Preserve the established view shape for downstream consumers, but make the
-- canonical final invoice the row source. Delivery proof may be absent and does
-- not control the window.
CREATE OR REPLACE VIEW public.commercial_complaint_window_v1 WITH(security_invoker=true) AS
SELECT
  f.order_id,
  d.id AS delivery_proof_id,
  d.delivered_at,
  public.complaint_deadline_from_invoice_v1(f.invoice_date) AS complaint_deadline,
  CASE
    WHEN EXISTS(
      SELECT 1 FROM public.commercial_complaints c
      WHERE c.order_id=f.order_id
        AND NOT EXISTS(SELECT 1 FROM public.commercial_adjustments a WHERE a.complaint_id=c.id)
    ) THEN 'RESOLUTION_PENDING'
    WHEN statement_timestamp()<public.complaint_deadline_from_invoice_v1(f.invoice_date) THEN 'OPEN'
    WHEN EXISTS(SELECT 1 FROM public.commercial_complaints c WHERE c.order_id=f.order_id) THEN 'RESOLVED'
    ELSE 'EXPIRED_NO_COMPLAINT'
  END AS window_status,
  (SELECT count(*) FROM public.commercial_complaints c WHERE c.order_id=f.order_id) AS complaint_count
FROM public.final_invoices f
LEFT JOIN public.delivery_proofs d ON d.order_id=f.order_id
WHERE f.status='ISSUED';
REVOKE ALL ON public.commercial_complaint_window_v1 FROM PUBLIC,anon;
GRANT SELECT ON public.commercial_complaint_window_v1 TO authenticated,service_role;
COMMENT ON VIEW public.commercial_complaint_window_v1 IS
  'Canonical ticket-raise clock from final invoice date. Invoice date is Day 1; Days 1-10 are included. Delivery proof is optional evidence and never starts or extends the clock.';

-- Keep Central's read-only Finance/Exit facts aligned with the same clock.
CREATE OR REPLACE FUNCTION public.get_finance_exit_facts_v1(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth AS $$
DECLARE
  v_order public.orders%rowtype;
  v_dpl public.finance_dpl_receipts%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_eway public.eway_bill_evidence%rowtype;
  v_clear public.finance_dispatch_clearance_authority_v1%rowtype;
  v_dispatch public.dispatch_proof_packets%rowtype;
  v_delivery public.delivery_proofs%rowtype;
  v_closure public.commercial_closures%rowtype;
  v_settlement jsonb;
  v_complaints jsonb:='[]'::jsonb;
  v_commercial_version_id uuid;
  v_open_complaints integer;
  v_unresolved_complaints integer;
  v_complaint_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'FINANCE_EXIT_FACTS_INTERNAL_ONLY' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_EXIT_ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE order_id=p_order_id ORDER BY created_at DESC LIMIT 1;
  v_commercial_version_id:=v_dpl.commercial_version_id;
  IF v_commercial_version_id IS NULL AND v_order.commercial_current_version IS NOT NULL THEN
    SELECT id INTO v_commercial_version_id FROM public.sales_order_commercial_versions
     WHERE order_id=p_order_id AND version_number=v_order.commercial_current_version;
  END IF;
  IF v_commercial_version_id IS NOT NULL THEN
    SELECT * INTO v_pi FROM public.sales_order_proforma_invoices
     WHERE order_id=p_order_id AND commercial_version_id=v_commercial_version_id AND status='ISSUED'
     ORDER BY created_at DESC LIMIT 1;
  END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF v_invoice.id IS NOT NULL THEN
    v_settlement:=public.get_final_settlement_facts_v1(v_invoice.id);
    v_complaint_deadline:=public.complaint_deadline_from_invoice_v1(v_invoice.invoice_date);
    SELECT * INTO v_eway FROM public.eway_bill_evidence WHERE final_invoice_id=v_invoice.id ORDER BY created_at DESC LIMIT 1;
  END IF;
  SELECT * INTO v_clear FROM public.finance_dispatch_clearance_authority_v1 WHERE order_id=p_order_id;
  SELECT * INTO v_dispatch FROM public.dispatch_proof_packets WHERE order_id=p_order_id;
  SELECT * INTO v_delivery FROM public.delivery_proofs WHERE order_id=p_order_id;
  SELECT * INTO v_closure FROM public.commercial_closures WHERE order_id=p_order_id;

  SELECT
    count(*)::int,
    count(*) FILTER(WHERE coalesce(latest.status,'OPEN')<>'RESOLVED')::int,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'complaint_id',c.id,'complaint_type',c.complaint_type,'description',c.description,
        'filed_at',c.filed_at,'complaint_deadline',v_complaint_deadline,
        'late_exception',c.late_exception_reason IS NOT NULL,
        'status',coalesce(latest.status,'OPEN'),'latest_notes',latest.notes,
        'adjustment_id',adj.id,'adjustment_type',adj.adjustment_type,'adjustment_amount',adj.amount,
        'document_number',adj.document_number,'document_reference',adj.document_reference,
        'payment_reference',adj.payment_reference,'decision_reason',adj.decision_reason
      ) ORDER BY c.filed_at,c.id
    ),'[]'::jsonb)
  INTO v_open_complaints,v_unresolved_complaints,v_complaints
  FROM public.commercial_complaints c
  LEFT JOIN LATERAL(
    SELECT e.status,e.notes FROM public.commercial_complaint_events e
    WHERE e.complaint_id=c.id ORDER BY e.created_at DESC,e.id DESC LIMIT 1
  ) latest ON true
  LEFT JOIN LATERAL(
    SELECT a.* FROM public.commercial_adjustments a
    WHERE a.complaint_id=c.id ORDER BY a.created_at DESC,a.id DESC LIMIT 1
  ) adj ON true
  WHERE c.order_id=p_order_id;

  RETURN jsonb_build_object(
    'order_id',v_order.id,'company_id',v_order.company_id,'order_status',v_order.status,
    'finance_dpl_receipt_id',v_dpl.id,'finance_dpl_fingerprint',v_dpl.dpl_fingerprint,
    'finance_dpl_source_authority',v_dpl.dpl_snapshot->>'source_authority',
    'commercial_version_id',coalesce(v_invoice.commercial_version_id,v_commercial_version_id),
    'pi_id',coalesce(v_invoice.proforma_invoice_id,v_pi.id),
    'final_invoice_id',v_invoice.id,'invoice_number',v_invoice.invoice_number,'invoice_date',v_invoice.invoice_date,
    'invoice_gross_total',v_invoice.gross_total,'settlement',v_settlement,
    'eway_evidence_id',v_eway.id,'eway_status',v_eway.status,'eway_bill_number',v_eway.eway_bill_number,'eway_valid_until',v_eway.valid_until,
    'dispatch_clearance_event_id',v_clear.clearance_event_id,'dispatch_clearance_decision',v_clear.decision,
    'dispatch_cleared',coalesce(v_clear.dispatch_cleared,false),
    'dispatch_proof_id',v_dispatch.id,'dispatched_at',v_dispatch.dispatched_at,
    'delivery_proof_id',v_delivery.id,'delivered_at',v_delivery.delivered_at,
    'complaint_clock_basis','FINAL_INVOICE_DATE',
    'complaint_deadline',v_complaint_deadline,
    'complaint_window_open',CASE WHEN v_invoice.id IS NULL THEN NULL ELSE statement_timestamp()<v_complaint_deadline END,
    'complaint_count',coalesce(v_open_complaints,0),'unresolved_complaint_count',coalesce(v_unresolved_complaints,0),
    'complaints',coalesce(v_complaints,'[]'::jsonb),
    'commercial_closure_id',v_closure.id,'commercially_closed',v_closure.id IS NOT NULL,
    'payment_verified_is_not_clearance',true,'facts_as_of',statement_timestamp()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_finance_exit_facts_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_exit_facts_v1(uuid) TO authenticated,service_role;
