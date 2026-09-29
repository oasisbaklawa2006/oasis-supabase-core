-- Point100 bounded Core authority repair:
-- 1) Governed B2B carton -> ready_to_load transition (no client UPDATE bypass).
-- 2) Final invoice future-date validation aligned to Asia/Kolkata business date.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(
  p_carton_id uuid,
  p_expected_version integer,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_cartons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_carton public.b2b_dispatch_cartons%ROWTYPE;
  v_carton_out public.b2b_dispatch_cartons%ROWTYPE;
  v_cons public.b2b_dispatch_consignments%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_dpl public.b2b_dispatch_packing_list_versions%ROWTYPE;
  v_clearance uuid;
  v_item_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to mark a dispatch carton ready to load' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_expected_version IS NULL THEN
    RAISE EXCEPTION 'The expected carton version is required';
  END IF;

  SELECT * INTO v_carton FROM public.b2b_dispatch_cartons WHERE id = p_carton_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton not found';
  END IF;

  IF v_carton.status = 'ready_to_load' THEN
    RETURN v_carton;
  END IF;
  IF v_carton.status IN ('loaded', 'handed_over') THEN
    RAISE EXCEPTION 'Carton % is % and cannot be marked ready to load', p_carton_id, v_carton.status
      USING ERRCODE = '42501';
  END IF;
  IF v_carton.status NOT IN ('locked', 'finance_check_open', 'verified', 'labelled') THEN
    RAISE EXCEPTION 'Carton % is % and cannot be marked ready to load from this state', p_carton_id, v_carton.status
      USING ERRCODE = '42501';
  END IF;
  IF v_carton.current_version <> p_expected_version THEN
    RAISE EXCEPTION 'Carton % has changed since it was loaded; reload and retry', p_carton_id USING ERRCODE = '40001';
  END IF;

  SELECT count(*) INTO v_item_count FROM public.b2b_dispatch_carton_items WHERE carton_id = p_carton_id;
  IF v_item_count = 0 THEN
    RAISE EXCEPTION 'Carton % has no scanned contents and cannot be marked ready to load', p_carton_id
      USING ERRCODE = '22023';
  END IF;
  IF v_carton.open_photo_ref IS NULL OR v_carton.net_weight IS NULL OR v_carton.gross_weight IS NULL
     OR v_carton.locked_by IS NULL OR v_carton.locked_at IS NULL THEN
    RAISE EXCEPTION 'Carton % is missing required weight, photo, or lock evidence', p_carton_id
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cons FROM public.b2b_dispatch_consignments WHERE id = v_carton.consignment_id FOR UPDATE;
  SELECT * INTO v_order FROM public.orders WHERE id = v_cons.order_id FOR UPDATE;

  IF lower(coalesce(v_order.status, '')) <> 'cleared_for_dispatch' THEN
    RAISE EXCEPTION 'ORDER_NOT_CLEARED_FOR_DISPATCH' USING ERRCODE = '55000';
  END IF;

  v_clearance := public.assert_active_dispatch_clearance_v1(v_order.id);

  SELECT * INTO v_dpl
  FROM public.b2b_dispatch_packing_list_versions d
  WHERE d.consignment_id = v_carton.consignment_id
    AND d.superseded_by IS NULL
    AND d.finance_check_state = 'verified'
    AND d.status = 'finance_verified'
  ORDER BY d.version_number DESC, d.generated_at DESC
  LIMIT 1;

  IF v_dpl.id IS NULL THEN
    RAISE EXCEPTION 'CARTON_READY_TO_LOAD_FINANCE_DPL_NOT_VERIFIED' USING ERRCODE = '55000';
  END IF;

  UPDATE public.b2b_dispatch_cartons
  SET status = 'ready_to_load',
      physical_location = 'READY_TO_LOAD_BAY',
      current_version = current_version + 1
  WHERE id = p_carton_id
    AND current_version = p_expected_version
  RETURNING * INTO v_carton_out;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carton % has changed since it was loaded; reload and retry', p_carton_id USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, carton_id, event_type, old_status, new_status,
    actor_id, actor_role, source_record_type, source_record_id, correlation_id,
    evidence_refs
  )
  VALUES (
    v_order.id, v_cons.id, p_carton_id, 'carton_ready_to_load', v_carton.status, 'ready_to_load',
    v_actor_id, public.get_user_role(v_actor_id), 'b2b_dispatch_cartons', p_carton_id, v_correlation_id,
    jsonb_build_array(
      jsonb_build_object('finance_dispatch_clearance_event_id', v_clearance),
      jsonb_build_object('packing_list_version_id', v_dpl.id)
    )
  );

  RETURN v_carton_out;
END;
$$;

COMMENT ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, integer, text) IS
  'Advances a locked, evidence-complete B2B dispatch carton to ready_to_load once Finance has verified the consignment DPL, the order is cleared_for_dispatch, and active Finance dispatch clearance exists. Idempotent when already ready_to_load.';

REVOKE ALL ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, integer, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_b2b_dispatch_carton_ready_to_load_v1(uuid, integer, text) TO authenticated;

-- IST/UTC final-invoice date authority: future-date guard uses the India business
-- calendar so issue_final_invoice_v1 stays consistent with final-payment request dating.
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
  v_business_date date := (statement_timestamp() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF p_order_id IS NULL OR p_pi_id IS NULL OR p_commercial_version_id IS NULL OR p_finance_dpl_receipt_id IS NULL
     OR nullif(btrim(p_invoice_number),'') IS NULL OR length(btrim(p_invoice_number)) > 64
     OR p_invoice_date IS NULL OR p_invoice_date > v_business_date
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
