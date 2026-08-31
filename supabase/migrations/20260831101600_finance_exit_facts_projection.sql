-- Finance Exit caller projection: one internal facts RPC for Central. This is
-- read-only and does not infer authority from legacy order booleans/URLs.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

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
        'complaint_id',c.id,
        'complaint_type',c.complaint_type,
        'description',c.description,
        'filed_at',c.filed_at,
        'complaint_deadline',c.complaint_deadline,
        'late_exception',c.late_exception_reason IS NOT NULL,
        'status',coalesce(latest.status,'OPEN'),
        'latest_notes',latest.notes,
        'adjustment_id',adj.id,
        'adjustment_type',adj.adjustment_type,
        'adjustment_amount',adj.amount,
        'document_number',adj.document_number,
        'document_reference',adj.document_reference,
        'payment_reference',adj.payment_reference,
        'decision_reason',adj.decision_reason
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
    'final_invoice_id',v_invoice.id,'invoice_number',v_invoice.invoice_number,'invoice_gross_total',v_invoice.gross_total,
    'settlement',v_settlement,
    'eway_evidence_id',v_eway.id,'eway_status',v_eway.status,'eway_bill_number',v_eway.eway_bill_number,'eway_valid_until',v_eway.valid_until,
    'dispatch_clearance_event_id',v_clear.clearance_event_id,'dispatch_clearance_decision',v_clear.decision,'dispatch_cleared',coalesce(v_clear.dispatch_cleared,false),
    'dispatch_proof_id',v_dispatch.id,'dispatched_at',v_dispatch.dispatched_at,
    'delivery_proof_id',v_delivery.id,'delivered_at',v_delivery.delivered_at,
    'complaint_deadline',CASE WHEN v_delivery.id IS NULL THEN NULL ELSE v_delivery.delivered_at+interval '10 days' END,
    'complaint_window_open',CASE WHEN v_delivery.id IS NULL THEN NULL ELSE statement_timestamp()<=v_delivery.delivered_at+interval '10 days' END,
    'complaint_count',coalesce(v_open_complaints,0),'unresolved_complaint_count',coalesce(v_unresolved_complaints,0),
    'complaints',coalesce(v_complaints,'[]'::jsonb),
    'commercial_closure_id',v_closure.id,'commercially_closed',v_closure.id IS NOT NULL,
    'payment_verified_is_not_clearance',true,'facts_as_of',statement_timestamp()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_finance_exit_facts_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_exit_facts_v1(uuid) TO authenticated,service_role;
