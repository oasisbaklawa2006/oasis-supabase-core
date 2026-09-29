-- Point100 final-invoice calendar authority repair.
-- Preserve the canonical production issue_final_invoice_v1 implementation and
-- align only its future-date validation with the India business calendar.
--
-- This prevents valid India-local invoice dates after 00:00 Asia/Kolkata but
-- before 00:00 UTC from being rejected as future dates.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

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
     OR p_invoice_date IS NULL OR p_invoice_date > (statement_timestamp() AT TIME ZONE 'Asia/Kolkata')::date
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

COMMENT ON FUNCTION public.issue_final_invoice_v1(uuid,uuid,uuid,uuid,text,date,text,text,text,text,uuid) IS
  'Issues the governed final invoice from Finance-verified commercial/DPL authority. Future-date validation uses the Asia/Kolkata business date.';
