-- Finance Exit F13/F15/F18: order-level financial 360, downstream Tally
-- projection, and immutable commercial closure after the complaint window.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE IF NOT EXISTS public.commercial_closures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) UNIQUE,
  company_id uuid NOT NULL REFERENCES public.companies(id),
  final_invoice_id uuid NOT NULL REFERENCES public.final_invoices(id),
  dispatch_proof_id uuid NOT NULL REFERENCES public.dispatch_proof_packets(id),
  delivery_proof_id uuid NOT NULL REFERENCES public.delivery_proofs(id),
  closure_snapshot jsonb NOT NULL,
  closure_fingerprint text NOT NULL CHECK(closure_fingerprint~'^[0-9a-f]{64}$'),
  closed_by uuid NOT NULL REFERENCES auth.users(id),
  closed_role text NOT NULL,
  reason text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  closed_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.commercial_closures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.commercial_closures FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON TABLE public.commercial_closures TO authenticated,service_role;
DROP POLICY IF EXISTS commercial_closures_authorized_read ON public.commercial_closures;
CREATE POLICY commercial_closures_authorized_read ON public.commercial_closures FOR SELECT TO authenticated
  USING(public.is_internal_staff(auth.uid()) OR company_id=public.auth_buyer_company_id());

CREATE OR REPLACE FUNCTION public.prevent_commercial_closure_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
  RAISE EXCEPTION 'COMMERCIAL_CLOSURE_IMMUTABLE' USING ERRCODE='42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_commercial_closures_immutable ON public.commercial_closures;
CREATE TRIGGER trg_commercial_closures_immutable BEFORE UPDATE OR DELETE ON public.commercial_closures
  FOR EACH ROW EXECUTE FUNCTION public.prevent_commercial_closure_mutation();
REVOKE ALL ON FUNCTION public.prevent_commercial_closure_mutation() FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_customer_financial_360_v1(p_company_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE
  v_orders jsonb;
  v_wallet numeric;
BEGIN
  IF auth.uid() IS NULL OR (
    NOT public.is_internal_staff(auth.uid())
    AND p_company_id IS DISTINCT FROM public.auth_buyer_company_id()
  ) THEN
    RAISE EXCEPTION 'FINANCIAL_360_COMPANY_SCOPE_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_wallet:=public.get_wallet_balance_v1(p_company_id);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'order_id',f.order_id,
    'invoice_date',f.invoice_date,
    'invoice_number',f.invoice_number,
    'invoice_gross_total',f.gross_total,
    'verified_payment_total',coalesce((p.payment_facts->>'verified_total')::numeric,0),
    'wallet_applied_total',coalesce((SELECT sum(w.amount) FROM public.wallet_transactions w
      WHERE w.order_id=f.order_id AND w.proforma_invoice_id=f.proforma_invoice_id
        AND w.commercial_version_id=f.commercial_version_id AND w.direction='debit'),0),
    'approved_credit_total',coalesce((SELECT sum(c.requested_amount) FROM public.credit_requests c
      WHERE c.order_id=f.order_id AND c.proforma_invoice_id=f.proforma_invoice_id
        AND c.commercial_version_id=f.commercial_version_id AND c.status='approved'
        AND (c.expires_at IS NULL OR c.expires_at>statement_timestamp())),0),
    'credit_note_total',coalesce((SELECT sum(a.amount) FROM public.commercial_adjustments a
      WHERE a.final_invoice_id=f.id AND a.adjustment_type='CREDIT_NOTE'),0),
    'debit_note_total',coalesce((SELECT sum(a.amount) FROM public.commercial_adjustments a
      WHERE a.final_invoice_id=f.id AND a.adjustment_type='DEBIT_NOTE'),0),
    'refund_total',coalesce((SELECT sum(a.amount) FROM public.commercial_adjustments a
      WHERE a.final_invoice_id=f.id AND a.adjustment_type IN('REFUND_TO_BANK','REFUND_TO_WALLET')),0),
    'pre_dispatch_net_due',greatest(0,round(
      f.gross_total
      -coalesce((p.payment_facts->>'verified_total')::numeric,0)
      -coalesce((SELECT sum(w.amount) FROM public.wallet_transactions w
        WHERE w.order_id=f.order_id AND w.proforma_invoice_id=f.proforma_invoice_id
          AND w.commercial_version_id=f.commercial_version_id AND w.direction='debit'),0)
      -coalesce((SELECT sum(c.requested_amount) FROM public.credit_requests c
        WHERE c.order_id=f.order_id AND c.proforma_invoice_id=f.proforma_invoice_id
          AND c.commercial_version_id=f.commercial_version_id AND c.status='approved'
          AND (c.expires_at IS NULL OR c.expires_at>statement_timestamp())),0),2)),
    'complaint_window_status',cw.window_status,
    'complaint_deadline',cw.complaint_deadline,
    'commercially_closed',cl.id IS NOT NULL,
    'commercial_closure_id',cl.id
  ) ORDER BY f.invoice_date DESC,f.order_id),'[]'::jsonb)
  INTO v_orders
  FROM public.final_invoices f
  CROSS JOIN LATERAL (
    SELECT public.get_order_payment_facts_v1(f.proforma_invoice_id) AS payment_facts
  ) p
  LEFT JOIN public.commercial_complaint_window_v1 cw ON cw.order_id=f.order_id
  LEFT JOIN public.commercial_closures cl ON cl.order_id=f.order_id
  WHERE f.company_id=p_company_id AND f.status='ISSUED';

  RETURN jsonb_build_object(
    'company_id',p_company_id,
    'wallet_balance',v_wallet,
    'orders',v_orders,
    'facts_as_of',statement_timestamp(),
    'financial_facts_only',true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_customer_financial_360_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_customer_financial_360_v1(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.close_order_commercially_v1(
  p_order_id uuid,
  p_reason text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(commercial_closure_id uuid,closure_fingerprint text,already_closed boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_dispatch public.dispatch_proof_packets%rowtype;
  v_delivery public.delivery_proofs%rowtype;
  v_window public.commercial_complaint_window_v1%rowtype;
  v_unresolved integer;
  v_adjustments jsonb;
  v_snapshot jsonb;
  v_fp text;
  v_existing public.commercial_closures%rowtype;
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason,'')))<5
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'COMMERCIAL_CLOSURE_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('commercial-closure:'||p_order_id::text,0));
  SELECT * INTO v_existing FROM public.commercial_closures WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.closed_by IS DISTINCT FROM v_actor OR v_existing.order_id IS DISTINCT FROM p_order_id THEN
      RAISE EXCEPTION 'COMMERCIAL_CLOSURE_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.closure_fingerprint,true;
    RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.commercial_closures WHERE order_id=p_order_id) THEN
    RAISE EXCEPTION 'ORDER_ALREADY_COMMERCIALLY_CLOSED' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  SELECT * INTO v_dispatch FROM public.dispatch_proof_packets WHERE order_id=p_order_id;
  SELECT * INTO v_delivery FROM public.delivery_proofs WHERE order_id=p_order_id;
  SELECT * INTO v_window FROM public.commercial_complaint_window_v1 WHERE order_id=p_order_id;

  IF v_order.company_id IS NULL OR v_invoice.id IS NULL OR v_dispatch.id IS NULL OR v_delivery.id IS NULL OR v_window.order_id IS NULL THEN
    RAISE EXCEPTION 'COMMERCIAL_CLOSURE_LINEAGE_INCOMPLETE' USING ERRCODE='55000';
  END IF;
  IF statement_timestamp()<=v_window.complaint_deadline THEN
    RAISE EXCEPTION 'COMPLAINT_WINDOW_STILL_OPEN' USING ERRCODE='55000';
  END IF;

  SELECT count(*) INTO v_unresolved
  FROM public.commercial_complaints c
  WHERE c.order_id=p_order_id
    AND NOT EXISTS(SELECT 1 FROM public.commercial_adjustments a WHERE a.complaint_id=c.id);
  IF v_unresolved>0 THEN
    RAISE EXCEPTION 'COMPLAINT_RESOLUTION_PENDING' USING ERRCODE='55000';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'adjustment_id',a.id,
    'type',a.adjustment_type,
    'amount',a.amount,
    'document_number',a.document_number,
    'document_reference',a.document_reference,
    'payment_reference',a.payment_reference,
    'wallet_entry_id',a.wallet_entry_id,
    'created_at',a.created_at
  ) ORDER BY a.created_at,a.id),'[]'::jsonb)
  INTO v_adjustments
  FROM public.commercial_adjustments a WHERE a.order_id=p_order_id;

  v_snapshot:=jsonb_build_object(
    'order_id',p_order_id,
    'company_id',v_order.company_id,
    'final_invoice_id',v_invoice.id,
    'final_invoice_number',v_invoice.invoice_number,
    'final_invoice_gross_total',v_invoice.gross_total,
    'dispatch_proof_id',v_dispatch.id,
    'dispatch_proof_fingerprint',v_dispatch.proof_fingerprint,
    'delivery_proof_id',v_delivery.id,
    'delivered_at',v_delivery.delivered_at,
    'complaint_deadline',v_window.complaint_deadline,
    'complaint_window_status',v_window.window_status,
    'complaint_count',v_window.complaint_count,
    'commercial_adjustments',v_adjustments,
    'tally_projection_ready',true,
    'closed_at',statement_timestamp()
  );
  v_fp:=encode(extensions.digest(v_snapshot::text,'sha256'),'hex');

  INSERT INTO public.commercial_closures(
    order_id,company_id,final_invoice_id,dispatch_proof_id,delivery_proof_id,
    closure_snapshot,closure_fingerprint,closed_by,closed_role,reason,correlation_id,idempotency_key
  ) VALUES(
    p_order_id,v_order.company_id,v_invoice.id,v_dispatch.id,v_delivery.id,
    v_snapshot,v_fp,v_actor,v_role,btrim(p_reason),btrim(p_correlation_id),btrim(p_idempotency_key)
  ) RETURNING * INTO v_existing;

  RETURN QUERY SELECT v_existing.id,v_existing.closure_fingerprint,false;
END;
$$;
REVOKE ALL ON FUNCTION public.close_order_commercially_v1(uuid,text,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.close_order_commercially_v1(uuid,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE VIEW public.commercial_closure_authority_v1 WITH(security_invoker=true) AS
SELECT id commercial_closure_id,order_id,company_id,final_invoice_id,dispatch_proof_id,delivery_proof_id,
  closure_fingerprint,closed_by,closed_role,closed_at
FROM public.commercial_closures;
REVOKE ALL ON public.commercial_closure_authority_v1 FROM PUBLIC,anon;
GRANT SELECT ON public.commercial_closure_authority_v1 TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_tally_finance_export_v1(p_from_date date,p_to_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,auth AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_rows jsonb;
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'TALLY_EXPORT_INTERNAL_ONLY' USING ERRCODE='42501';
  END IF;
  PERFORM public.assert_order_transition_role('finance_review');
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_to_date<p_from_date OR p_to_date-p_from_date>366 THEN
    RAISE EXCEPTION 'TALLY_EXPORT_DATE_RANGE_INVALID' USING ERRCODE='P0001';
  END IF;

  SELECT coalesce(jsonb_agg(x ORDER BY x->>'voucher_date',x->>'source_id'),'[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'source_type','FINAL_INVOICE','source_id',f.id,'voucher_type','Sales','voucher_date',f.invoice_date,
      'voucher_number',f.invoice_number,'company_id',f.company_id,'order_id',f.order_id,'amount',f.gross_total,
      'taxable_amount',f.taxable_total,'tax_amount',f.tax_total,'currency',f.currency,
      'document_reference',f.document_reference,'fingerprint',f.invoice_fingerprint
    ) x
    FROM public.final_invoices f
    WHERE f.status='ISSUED' AND f.invoice_date BETWEEN p_from_date AND p_to_date
    UNION ALL
    SELECT jsonb_build_object(
      'source_type','COMMERCIAL_ADJUSTMENT','source_id',a.id,
      'voucher_type',CASE a.adjustment_type WHEN 'CREDIT_NOTE' THEN 'Credit Note' WHEN 'DEBIT_NOTE' THEN 'Debit Note'
        WHEN 'REFUND_TO_BANK' THEN 'Payment' WHEN 'REFUND_TO_WALLET' THEN 'Journal' ELSE 'Journal' END,
      'voucher_date',a.created_at::date,'voucher_number',coalesce(a.document_number,a.id::text),
      'company_id',c.company_id,'order_id',a.order_id,'amount',a.amount,'adjustment_type',a.adjustment_type,
      'document_reference',a.document_reference,'payment_reference',a.payment_reference,'wallet_entry_id',a.wallet_entry_id
    ) x
    FROM public.commercial_adjustments a
    JOIN public.commercial_complaints c ON c.id=a.complaint_id
    WHERE a.created_at::date BETWEEN p_from_date AND p_to_date
  ) q;

  RETURN jsonb_build_object(
    'schema','oasis-tally-finance-projection/v1','from_date',p_from_date,'to_date',p_to_date,
    'rows',v_rows,'projection_only',true,'operational_source_of_truth',false,'generated_at',statement_timestamp()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_tally_finance_export_v1(date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_tally_finance_export_v1(date,date) TO authenticated;

COMMENT ON TABLE public.commercial_closures IS
  'Immutable terminal commercial closure after delivery, complaint-window expiry and resolution of every filed complaint.';
COMMENT ON FUNCTION public.get_customer_financial_360_v1(uuid) IS
  'Company-scoped read-only Finance 360 over canonical invoice/payment/wallet/credit/complaint/closure facts.';
COMMENT ON FUNCTION public.get_tally_finance_export_v1(date,date) IS
  'Read-only normalized accounting projection. Tally is downstream and never operational source of truth.';
