-- Finance Exit F6-F8: canonical final invoice and settlement facts.
-- Final invoice quantities come only from the immutable Finance DPL receipt;
-- prices/tax rates come only from the exact frozen commercial version.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.final_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  proforma_invoice_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id),
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id),
  finance_dpl_receipt_id uuid NOT NULL REFERENCES public.finance_dpl_receipts(id),
  invoice_number text NOT NULL UNIQUE,
  invoice_date date NOT NULL,
  currency text NOT NULL DEFAULT 'INR' CHECK (currency ~ '^[A-Z]{3}$'),
  taxable_total numeric NOT NULL CHECK (taxable_total >= 0),
  tax_total numeric NOT NULL CHECK (tax_total >= 0),
  gross_total numeric NOT NULL CHECK (gross_total >= 0),
  status text NOT NULL CHECK (status IN ('ISSUED','VOIDED_BY_COMPENSATING_DOCUMENT')),
  document_reference text NOT NULL,
  invoice_fingerprint text NOT NULL CHECK (invoice_fingerprint ~ '^[0-9a-f]{64}$'),
  issued_by uuid NOT NULL REFERENCES auth.users(id),
  issued_role text NOT NULL,
  reason text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX IF NOT EXISTS final_invoices_order_idx ON public.final_invoices(order_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.final_invoice_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  final_invoice_id uuid NOT NULL REFERENCES public.final_invoices(id),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id),
  product_id uuid NOT NULL REFERENCES public.products(id),
  sku text,
  description text,
  actual_dispatch_qty numeric NOT NULL CHECK (actual_dispatch_qty > 0),
  uom text NOT NULL,
  unit_price numeric NOT NULL CHECK (unit_price >= 0),
  gst_rate numeric NOT NULL CHECK (gst_rate >= 0),
  tax_inclusive boolean NOT NULL,
  taxable_value numeric NOT NULL CHECK (taxable_value >= 0),
  tax_amount numeric NOT NULL CHECK (tax_amount >= 0),
  line_total numeric NOT NULL CHECK (line_total >= 0),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(final_invoice_id, order_item_id)
);

ALTER TABLE public.final_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.final_invoice_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.final_invoices FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.final_invoice_lines FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.final_invoices, public.final_invoice_lines TO authenticated, service_role;
CREATE POLICY final_invoices_internal_read ON public.final_invoices FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
CREATE POLICY final_invoice_lines_internal_read ON public.final_invoice_lines FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE TABLE IF NOT EXISTS public.final_invoice_idempotency (
  idempotency_key text PRIMARY KEY,
  request_fingerprint text NOT NULL,
  final_invoice_id uuid NOT NULL REFERENCES public.final_invoices(id),
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.final_invoice_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.final_invoice_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_final_invoice_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN RAISE EXCEPTION 'FINAL_INVOICE_IMMUTABLE_USE_COMPENSATING_DOCUMENT' USING ERRCODE='42501'; END; $$;
DROP TRIGGER IF EXISTS trg_final_invoices_immutable ON public.final_invoices;
CREATE TRIGGER trg_final_invoices_immutable BEFORE UPDATE OR DELETE ON public.final_invoices
  FOR EACH ROW EXECUTE FUNCTION public.prevent_final_invoice_mutation();
DROP TRIGGER IF EXISTS trg_final_invoice_lines_immutable ON public.final_invoice_lines;
CREATE TRIGGER trg_final_invoice_lines_immutable BEFORE UPDATE OR DELETE ON public.final_invoice_lines
  FOR EACH ROW EXECUTE FUNCTION public.prevent_final_invoice_mutation();
REVOKE ALL ON FUNCTION public.prevent_final_invoice_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.issue_final_invoice_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_finance_dpl_receipt_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  p_document_reference text,
  p_reason text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(final_invoice_id uuid, invoice_number text, gross_total numeric, already_issued boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id,auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_dpl public.finance_dpl_receipts%rowtype;
  v_existing public.final_invoice_idempotency%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_taxable numeric := 0;
  v_tax numeric := 0;
  v_gross numeric := 0;
  v_request_fingerprint text;
  v_invoice_fingerprint text;
  v_invalid integer;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF p_order_id IS NULL OR p_pi_id IS NULL OR p_commercial_version_id IS NULL OR p_finance_dpl_receipt_id IS NULL
     OR nullif(btrim(p_invoice_number),'') IS NULL OR length(btrim(p_invoice_number)) > 64
     OR p_invoice_date IS NULL OR p_invoice_date > current_date
     OR nullif(btrim(p_document_reference),'') IS NULL OR length(btrim(coalesce(p_reason,''))) < 5
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'FINAL_INVOICE_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('final-invoice:'||p_order_id::text,0));
  PERFORM public.assert_order_payment_binding_v1(p_order_id,p_pi_id,p_commercial_version_id);
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR SHARE;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id=p_pi_id AND order_id=p_order_id AND commercial_version_id=p_commercial_version_id;
  SELECT * INTO v_version FROM public.sales_order_commercial_versions WHERE id=p_commercial_version_id AND order_id=p_order_id;
  SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE id=p_finance_dpl_receipt_id AND order_id=p_order_id AND commercial_version_id=p_commercial_version_id;
  IF v_order.company_id IS NULL OR v_pi.id IS NULL OR v_version.id IS NULL OR v_dpl.id IS NULL
     OR v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'FINAL_INVOICE_BINDING_MISMATCH' USING ERRCODE='40001';
  END IF;
  IF v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
     OR v_pi.frozen_snapshot_fingerprint IS DISTINCT FROM v_version.snapshot_fingerprint THEN
    RAISE EXCEPTION 'FINAL_INVOICE_STALE_COMMERCIAL_TRUTH' USING ERRCODE='40001';
  END IF;

  -- Charges other than line prices require their own final tax authority. Fail
  -- closed rather than guessing tax treatment.
  IF coalesce((v_version.commercial_snapshot->>'packing_charge')::numeric,0) <> 0
     OR coalesce((v_version.commercial_snapshot->>'other_approved_charges')::numeric,0) <> 0
     OR coalesce((v_version.commercial_snapshot->>'discount_total')::numeric,0) <> 0 THEN
    RAISE EXCEPTION 'FINAL_INVOICE_NON_LINE_CHARGE_TAX_AUTHORITY_REQUIRED' USING ERRCODE='55000';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM jsonb_to_recordset(v_dpl.dpl_snapshot->'lines') d(order_item_id uuid,product_id uuid,actual_dispatch_qty numeric,uom text)
  LEFT JOIN LATERAL (
    SELECT x.* FROM jsonb_to_recordset(v_version.commercial_snapshot->'lines')
      x(order_item_id uuid,product_id uuid,sku text,product_name text,quantity numeric,uom text,unit_price numeric,gst_rate numeric,tax_inclusive boolean)
    WHERE x.order_item_id=d.order_item_id AND x.product_id=d.product_id LIMIT 1
  ) c ON true
  WHERE c.order_item_id IS NULL OR d.actual_dispatch_qty IS NULL OR d.actual_dispatch_qty<=0
     OR d.actual_dispatch_qty>c.quantity OR c.unit_price IS NULL OR c.gst_rate IS NULL;
  IF v_invalid>0 THEN RAISE EXCEPTION 'FINAL_INVOICE_DPL_COMMERCIAL_LINE_MISMATCH' USING ERRCODE='40001'; END IF;

  WITH priced AS (
    SELECT d.order_item_id,d.product_id,d.actual_dispatch_qty,d.uom,
      c.sku,c.product_name,c.unit_price,coalesce(c.gst_rate,0) gst_rate,coalesce(c.tax_inclusive,false) tax_inclusive,
      round(CASE WHEN coalesce(c.tax_inclusive,false) AND coalesce(c.gst_rate,0)>0
        THEN d.actual_dispatch_qty*c.unit_price/(1+c.gst_rate/100)
        ELSE d.actual_dispatch_qty*c.unit_price END,2) taxable_value,
      round(d.actual_dispatch_qty*c.unit_price*CASE WHEN coalesce(c.tax_inclusive,false) THEN 1 ELSE 1+coalesce(c.gst_rate,0)/100 END,2) line_total
    FROM jsonb_to_recordset(v_dpl.dpl_snapshot->'lines') d(order_item_id uuid,product_id uuid,actual_dispatch_qty numeric,uom text)
    JOIN LATERAL (
      SELECT x.* FROM jsonb_to_recordset(v_version.commercial_snapshot->'lines')
        x(order_item_id uuid,product_id uuid,sku text,product_name text,quantity numeric,uom text,unit_price numeric,gst_rate numeric,tax_inclusive boolean)
      WHERE x.order_item_id=d.order_item_id AND x.product_id=d.product_id LIMIT 1
    ) c ON true
  )
  SELECT coalesce(sum(taxable_value),0),coalesce(sum(line_total-taxable_value),0),coalesce(sum(line_total),0)
    INTO v_taxable,v_tax,v_gross FROM priced;

  v_request_fingerprint:=encode(extensions.digest(jsonb_build_object(
    'order_id',p_order_id,'pi_id',p_pi_id,'commercial_version_id',p_commercial_version_id,
    'finance_dpl_receipt_id',p_finance_dpl_receipt_id,'invoice_number',btrim(p_invoice_number),
    'invoice_date',p_invoice_date,'document_reference',btrim(p_document_reference),
    'reason',btrim(p_reason),'correlation_id',btrim(p_correlation_id),'gross_total',v_gross
  )::text,'sha256'),'hex');

  SELECT * INTO v_existing FROM public.final_invoice_idempotency WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_request_fingerprint THEN
      RAISE EXCEPTION 'FINAL_INVOICE_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    SELECT * INTO v_invoice FROM public.final_invoices WHERE id=v_existing.final_invoice_id;
    RETURN QUERY SELECT v_invoice.id,v_invoice.invoice_number,v_invoice.gross_total,true; RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.final_invoices f WHERE f.order_id=p_order_id AND f.status='ISSUED') THEN
    RAISE EXCEPTION 'FINAL_INVOICE_ALREADY_ISSUED' USING ERRCODE='55000';
  END IF;

  v_invoice_fingerprint:=encode(extensions.digest(jsonb_build_object(
    'order_id',p_order_id,'pi_id',p_pi_id,'commercial_version_id',p_commercial_version_id,
    'dpl_fingerprint',v_dpl.dpl_fingerprint,'invoice_number',btrim(p_invoice_number),'invoice_date',p_invoice_date,
    'taxable_total',v_taxable,'tax_total',v_tax,'gross_total',v_gross
  )::text,'sha256'),'hex');

  INSERT INTO public.final_invoices(order_id,company_id,proforma_invoice_id,commercial_version_id,finance_dpl_receipt_id,
    invoice_number,invoice_date,currency,taxable_total,tax_total,gross_total,status,document_reference,invoice_fingerprint,
    issued_by,issued_role,reason,correlation_id,idempotency_key)
  VALUES(p_order_id,v_order.company_id,p_pi_id,p_commercial_version_id,p_finance_dpl_receipt_id,btrim(p_invoice_number),p_invoice_date,
    'INR',v_taxable,v_tax,v_gross,'ISSUED',btrim(p_document_reference),v_invoice_fingerprint,v_actor,v_role,btrim(p_reason),
    btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_invoice;

  INSERT INTO public.final_invoice_lines(final_invoice_id,order_item_id,product_id,sku,description,actual_dispatch_qty,uom,
    unit_price,gst_rate,tax_inclusive,taxable_value,tax_amount,line_total)
  SELECT v_invoice.id,d.order_item_id,d.product_id,c.sku,c.product_name,d.actual_dispatch_qty,d.uom,c.unit_price,
    coalesce(c.gst_rate,0),coalesce(c.tax_inclusive,false),
    round(CASE WHEN coalesce(c.tax_inclusive,false) AND coalesce(c.gst_rate,0)>0
      THEN d.actual_dispatch_qty*c.unit_price/(1+c.gst_rate/100) ELSE d.actual_dispatch_qty*c.unit_price END,2),
    round((d.actual_dispatch_qty*c.unit_price*CASE WHEN coalesce(c.tax_inclusive,false) THEN 1 ELSE 1+coalesce(c.gst_rate,0)/100 END)
      -(CASE WHEN coalesce(c.tax_inclusive,false) AND coalesce(c.gst_rate,0)>0 THEN d.actual_dispatch_qty*c.unit_price/(1+c.gst_rate/100)
        ELSE d.actual_dispatch_qty*c.unit_price END),2),
    round(d.actual_dispatch_qty*c.unit_price*CASE WHEN coalesce(c.tax_inclusive,false) THEN 1 ELSE 1+coalesce(c.gst_rate,0)/100 END,2)
  FROM jsonb_to_recordset(v_dpl.dpl_snapshot->'lines') d(order_item_id uuid,product_id uuid,actual_dispatch_qty numeric,uom text)
  JOIN LATERAL (
    SELECT x.* FROM jsonb_to_recordset(v_version.commercial_snapshot->'lines')
      x(order_item_id uuid,product_id uuid,sku text,product_name text,quantity numeric,uom text,unit_price numeric,gst_rate numeric,tax_inclusive boolean)
    WHERE x.order_item_id=d.order_item_id AND x.product_id=d.product_id LIMIT 1
  ) c ON true;

  INSERT INTO public.final_invoice_idempotency(idempotency_key,request_fingerprint,final_invoice_id,actor_id,response)
  VALUES(btrim(p_idempotency_key),v_request_fingerprint,v_invoice.id,v_actor,
    jsonb_build_object('final_invoice_id',v_invoice.id,'invoice_number',v_invoice.invoice_number,'gross_total',v_invoice.gross_total));

  RETURN QUERY SELECT v_invoice.id,v_invoice.invoice_number,v_invoice.gross_total,false;
END;
$$;

REVOKE ALL ON FUNCTION public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_final_settlement_facts_v1(p_final_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE v_invoice public.final_invoices%rowtype; v_payment jsonb; v_verified numeric; v_wallet numeric; v_credit numeric; v_net numeric; v_excess numeric;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN RAISE EXCEPTION 'FINAL_SETTLEMENT_INTERNAL_ONLY' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE id=p_final_invoice_id AND status='ISSUED';
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  v_payment:=public.get_order_payment_facts_v1(v_invoice.proforma_invoice_id);
  v_verified:=coalesce((v_payment->>'verified_total')::numeric,0);
  SELECT coalesce(sum(amount),0) INTO v_wallet FROM public.wallet_transactions
   WHERE order_id=v_invoice.order_id AND proforma_invoice_id=v_invoice.proforma_invoice_id
     AND commercial_version_id=v_invoice.commercial_version_id AND direction='debit';
  SELECT coalesce(sum(requested_amount),0) INTO v_credit FROM public.credit_requests
   WHERE order_id=v_invoice.order_id AND proforma_invoice_id=v_invoice.proforma_invoice_id
     AND commercial_version_id=v_invoice.commercial_version_id AND status='approved'
     AND (expires_at IS NULL OR expires_at>statement_timestamp());
  v_net:=greatest(0,round(v_invoice.gross_total-v_verified-v_wallet-v_credit,2));
  v_excess:=greatest(0,round(v_verified+v_wallet+v_credit-v_invoice.gross_total,2));
  RETURN jsonb_build_object('final_invoice_id',v_invoice.id,'order_id',v_invoice.order_id,'pi_id',v_invoice.proforma_invoice_id,
    'commercial_version_id',v_invoice.commercial_version_id,'invoice_gross_total',v_invoice.gross_total,
    'verified_payment_total',v_verified,'wallet_applied_total',v_wallet,'approved_credit_total',v_credit,
    'net_due',v_net,'excess_coverage',v_excess,'settled_for_dispatch',(v_net<=0.01),'payment_facts',v_payment,
    'facts_as_of',statement_timestamp(),'settlement_facts_only',true);
END;
$$;
REVOKE ALL ON FUNCTION public.get_final_settlement_facts_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_final_settlement_facts_v1(uuid) TO authenticated,service_role;

COMMENT ON TABLE public.final_invoices IS 'Canonical immutable final tax/commercial invoice derived from frozen DPL quantities and frozen SO commercial prices/tax rates.';
COMMENT ON FUNCTION public.get_final_settlement_facts_v1(uuid) IS 'Factual final balance only; does not grant dispatch clearance.';
