-- Reconciled immutable production migration history.
-- This exact version/name is already recorded in production.
CREATE OR REPLACE FUNCTION public.submit_customer_order_v1(p_idempotency_key text,p_requested_dispatch_date date DEFAULT NULL)
RETURNS TABLE(order_id uuid,order_number text,sales_order_value numeric,advance_required numeric,draft_id uuid,is_duplicate_submission boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
#variable_conflict use_column
DECLARE
 v_uid uuid:=auth.uid(); v_company_id uuid; v_draft public.customer_order_drafts%rowtype;
 v_existing_order_id uuid; v_existing_order_number text; v_existing_so_value numeric; v_existing_advance numeric; v_promoted_draft_id uuid;
 v_order_id uuid; v_order_number text; v_snapshot jsonb:='[]'::jsonb; v_total numeric:=0; v_advance numeric; v_line record; v_auth record;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED: authentication is required' USING ERRCODE='28000'; END IF;
 IF coalesce(btrim(p_idempotency_key),'')='' THEN RAISE EXCEPTION 'VALIDATION_FAILED: idempotency_key is required'; END IF;
 v_company_id:=public.customer_buyer_eligible_company_id();
 IF v_company_id IS NULL THEN RAISE EXCEPTION 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('customer_checkout:'||v_company_id::text||':'||btrim(p_idempotency_key),0));
 SELECT o.id,o.order_number,o.sales_order_value,o.advance_required INTO v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance
 FROM public.orders o WHERE o.company_id=v_company_id AND o.order_origin='CUSTOMER_APP' AND o.checkout_idempotency_key=btrim(p_idempotency_key) LIMIT 1;
 IF v_existing_order_id IS NOT NULL THEN
   SELECT d.id INTO v_promoted_draft_id FROM public.customer_order_drafts d WHERE d.promoted_order_id=v_existing_order_id LIMIT 1;
   RETURN QUERY SELECT v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance,v_promoted_draft_id,true; RETURN;
 END IF;
 SELECT * INTO v_draft FROM public.customer_order_drafts d WHERE d.company_id=v_company_id AND d.status='active'
 ORDER BY d.updated_at DESC,d.created_at DESC,d.id LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND: no active customer order draft exists for checkout' USING ERRCODE='P0002'; END IF;
 PERFORM public.customer_order_draft_audit_v1(v_draft.id,v_company_id,v_uid,'SUBMIT_ATTEMPT',jsonb_build_object('idempotency_key',btrim(p_idempotency_key)));
 PERFORM public.customer_recompute_draft_readiness_v1(v_draft.id);
 SELECT * INTO v_draft FROM public.customer_order_drafts WHERE id=v_draft.id;
 IF v_draft.readiness_status<>'ready' THEN RAISE EXCEPTION 'DRAFT_NOT_READY: draft cannot be submitted (issues: %)',v_draft.readiness_issues::text; END IF;
 FOR v_line IN SELECT l.* FROM public.customer_order_draft_lines l WHERE l.draft_id=v_draft.id LOOP
   SELECT * INTO v_auth FROM public.customer_resolve_buyer_product_authority_v1(v_company_id,v_line.product_id);
   IF NOT coalesce(v_auth.is_available,false) THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE: product % is not available at checkout',v_line.product_id; END IF;
   IF NOT public.customer_validate_order_quantity_v1(v_line.quantity,v_auth.minimum_order_quantity,v_auth.order_increment,v_auth.min_carton_qty) THEN
     RAISE EXCEPTION 'QUANTITY_RULE_VIOLATION: product % failed MOQ/increment/carton validation at checkout',v_line.product_id;
   END IF;
   IF v_line.quantity IS NULL OR v_line.quantity<=0 OR v_auth.selling_price IS NULL OR v_auth.selling_price<=0
      OR nullif(btrim(v_auth.currency),'') IS NULL OR nullif(btrim(v_auth.uom),'') IS NULL
      OR v_auth.gst_rate IS NULL OR v_auth.gst_rate<0 OR v_auth.gst_rate>100 OR v_auth.tax_inclusive IS NULL
      OR nullif(btrim(v_auth.sku),'') IS NULL OR nullif(btrim(v_auth.product_name),'') IS NULL THEN
     RAISE EXCEPTION 'CHECKOUT_COMMERCIAL_AUTHORITY_INCOMPLETE: product % has incomplete pricing/tax/UOM authority',v_line.product_id USING ERRCODE='22023';
   END IF;
   v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object(
     'product_id',v_line.product_id,'quantity',v_line.quantity,'selling_price',v_auth.selling_price,'currency',v_auth.currency,
     'uom',v_auth.uom,'gst_rate',v_auth.gst_rate,'tax_inclusive',v_auth.tax_inclusive,'sku',v_auth.sku,'product_name',v_auth.product_name,
     'minimum_order_quantity',v_auth.minimum_order_quantity,'order_increment',v_auth.order_increment,'min_carton_qty',v_auth.min_carton_qty));
   v_total:=v_total+(v_line.quantity*v_auth.selling_price*
     CASE WHEN v_auth.tax_inclusive THEN 1::numeric ELSE 1::numeric+(v_auth.gst_rate/100::numeric) END);
 END LOOP;
 IF jsonb_array_length(v_snapshot)=0 THEN RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_INVALID: no checkout lines captured' USING ERRCODE='22023'; END IF;
 v_total:=round(v_total,2);
 IF v_total<=0 THEN RAISE EXCEPTION 'CHECKOUT_TOTAL_INVALID: Sales Order value must be positive' USING ERRCODE='22023'; END IF;
 v_advance:=public.calculate_sales_order_advance_v1(v_total);
 IF v_advance<=0 THEN RAISE EXCEPTION 'CHECKOUT_ADVANCE_INVALID' USING ERRCODE='22023'; END IF;
 PERFORM set_config('app.sales_order_authority','CUSTOMER_CHECKOUT',true);
 INSERT INTO public.sales_order_creation_scopes(backend_pid,transaction_id,authority) VALUES(pg_backend_pid(),txid_current(),'CUSTOMER_CHECKOUT')
 ON CONFLICT(backend_pid,transaction_id) DO UPDATE SET authority=EXCLUDED.authority,created_at=statement_timestamp();
 INSERT INTO public.orders(company_id,status,order_origin,checkout_idempotency_key,checkout_snapshot,requested_dispatch_date,tracking_token,sales_order_value,advance_required)
 VALUES(v_company_id,'submitted','CUSTOMER_APP',btrim(p_idempotency_key),v_snapshot,p_requested_dispatch_date,encode(extensions.gen_random_bytes(16),'hex'),v_total,v_advance)
 RETURNING id,orders.order_number INTO v_order_id,v_order_number;
 DELETE FROM public.sales_order_creation_scopes WHERE backend_pid=pg_backend_pid() AND transaction_id=txid_current();
 FOR v_line IN SELECT l.* FROM public.customer_order_draft_lines l WHERE l.draft_id=v_draft.id LOOP
   INSERT INTO public.order_items(order_id,product_id,quantity,pack_size) VALUES(v_order_id,v_line.product_id,v_line.quantity,v_line.uom_snapshot);
 END LOOP;
 UPDATE public.customer_order_drafts SET status='promoted',promoted_order_id=v_order_id,updated_at=now() WHERE id=v_draft.id;
 PERFORM public.customer_order_draft_audit_v1(v_draft.id,v_company_id,v_uid,'PROMOTE',jsonb_build_object('order_id',v_order_id,'idempotency_key',btrim(p_idempotency_key)));
 RETURN QUERY SELECT v_order_id,v_order_number,o.sales_order_value,o.advance_required,v_draft.id,false FROM public.orders o WHERE o.id=v_order_id;
EXCEPTION WHEN unique_violation THEN
 SELECT o.id,o.order_number,o.sales_order_value,o.advance_required INTO v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance
 FROM public.orders o WHERE o.company_id=v_company_id AND o.order_origin='CUSTOMER_APP' AND o.checkout_idempotency_key=btrim(p_idempotency_key) LIMIT 1;
 IF v_existing_order_id IS NULL THEN RAISE; END IF;
 SELECT d.id INTO v_promoted_draft_id FROM public.customer_order_drafts d WHERE d.promoted_order_id=v_existing_order_id LIMIT 1;
 RETURN QUERY SELECT v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance,v_promoted_draft_id,true;
END $$;

CREATE OR REPLACE FUNCTION public.build_sales_order_commercial_snapshot_v1(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE
 v_order public.orders%rowtype; v_company public.companies%rowtype; v_lines jsonb:='[]'::jsonb; v_unavailable_product uuid;
 v_source_reference text; v_source_draft_id uuid; v_expected_advance numeric; v_snapshot_total numeric;
BEGIN
 SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 SELECT * INTO v_company FROM public.companies WHERE id=v_order.company_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_COMPANY_REQUIRED' USING ERRCODE='P0001'; END IF;
 IF v_order.order_origin='CUSTOMER_APP' THEN
   v_snapshot_total:=public.customer_checkout_snapshot_total_v1(p_order_id);
   IF v_order.sales_order_value IS DISTINCT FROM v_snapshot_total THEN
     RAISE EXCEPTION 'CHECKOUT_ORDER_TOTAL_MISMATCH: stored %, snapshot %',v_order.sales_order_value,v_snapshot_total USING ERRCODE='P0001';
   END IF;
   v_expected_advance:=public.calculate_sales_order_advance_v1(v_snapshot_total);
   IF v_order.advance_required IS DISTINCT FROM v_expected_advance THEN
     RAISE EXCEPTION 'GOVERNED_ADVANCE_STALE: stored %, expected % for checkout value %',v_order.advance_required,v_expected_advance,v_snapshot_total USING ERRCODE='P0001';
   END IF;
   SELECT coalesce(jsonb_agg(jsonb_build_object(
     'order_item_id',q.id,'product_id',q.product_id,'sku',q.sku,'product_name',q.product_name,'quantity',q.quantity,
     'uom',q.uom,'pack_size',q.uom,'carton_type',q.carton_type,'unit_price',q.selling_price,'discount_amount',0,
     'taxable_value',round(q.taxable_value,2),'tax_amount',round(q.line_total-q.taxable_value,2),'currency',q.currency,
     'gst_rate',q.gst_rate,'tax_inclusive',q.tax_inclusive,'line_total',round(q.line_total,2)) ORDER BY q.id),'[]'::jsonb) INTO v_lines
   FROM (
     SELECT oi.id,oi.product_id,oi.carton_type,s.line->>'sku' sku,s.line->>'product_name' product_name,
       (s.line->>'quantity')::numeric quantity,s.line->>'uom' uom,(s.line->>'selling_price')::numeric selling_price,
       s.line->>'currency' currency,(s.line->>'gst_rate')::numeric gst_rate,(s.line->>'tax_inclusive')::boolean tax_inclusive,
       CASE WHEN (s.line->>'tax_inclusive')::boolean AND (s.line->>'gst_rate')::numeric>0
         THEN (s.line->>'quantity')::numeric*(s.line->>'selling_price')::numeric/(1+(s.line->>'gst_rate')::numeric/100)
         ELSE (s.line->>'quantity')::numeric*(s.line->>'selling_price')::numeric END taxable_value,
       (s.line->>'quantity')::numeric*(s.line->>'selling_price')::numeric*
       CASE WHEN (s.line->>'tax_inclusive')::boolean THEN 1 ELSE 1+(s.line->>'gst_rate')::numeric/100 END line_total
     FROM public.order_items oi JOIN LATERAL
       (SELECT x.line FROM jsonb_array_elements(v_order.checkout_snapshot) x(line) WHERE (x.line->>'product_id')::uuid=oi.product_id) s ON true
     WHERE oi.order_id=p_order_id
   ) q;
 ELSE
   v_expected_advance:=public.calculate_sales_order_advance_v1(v_order.sales_order_value);
   IF v_order.advance_required IS DISTINCT FROM v_expected_advance THEN
     RAISE EXCEPTION 'GOVERNED_ADVANCE_STALE: stored %, expected % for sales order value %',v_order.advance_required,v_expected_advance,v_order.sales_order_value USING ERRCODE='P0001';
   END IF;
   SELECT oi.product_id INTO v_unavailable_product FROM public.order_items oi LEFT JOIN LATERAL
     public.customer_resolve_buyer_product_authority_v1(v_order.company_id,oi.product_id) a ON true
     WHERE oi.order_id=p_order_id AND NOT coalesce(a.is_available,false) ORDER BY oi.id LIMIT 1;
   IF v_unavailable_product IS NOT NULL THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE='P0001'; END IF;
   SELECT coalesce(jsonb_agg(jsonb_build_object(
     'order_item_id',q.id,'product_id',q.product_id,'sku',q.sku,'product_name',q.product_name,'quantity',q.quantity,
     'uom',coalesce(q.pack_size,q.uom),'pack_size',q.pack_size,'carton_type',q.carton_type,'unit_price',q.selling_price,
     'discount_amount',0,'taxable_value',round(q.taxable_value,2),'tax_amount',round(q.line_total-q.taxable_value,2),
     'currency',q.currency,'gst_rate',q.gst_rate,'tax_inclusive',q.tax_inclusive,'line_total',round(q.line_total,2)) ORDER BY q.id),'[]'::jsonb) INTO v_lines
   FROM (
     SELECT oi.id,oi.product_id,oi.quantity,oi.pack_size,oi.carton_type,p.sku,p.product_name,a.uom,a.selling_price,a.currency,
       coalesce(a.gst_rate,0) gst_rate,coalesce(a.tax_inclusive,false) tax_inclusive,
       CASE WHEN coalesce(a.tax_inclusive,false) AND coalesce(a.gst_rate,0)>0
         THEN coalesce(oi.quantity,0)*coalesce(a.selling_price,0)/(1+a.gst_rate/100)
         ELSE coalesce(oi.quantity,0)*coalesce(a.selling_price,0) END taxable_value,
       coalesce(oi.quantity,0)*coalesce(a.selling_price,0)*
       CASE WHEN coalesce(a.tax_inclusive,false) THEN 1 ELSE 1+coalesce(a.gst_rate,0)/100 END line_total
     FROM public.order_items oi JOIN public.products p ON p.id=oi.product_id LEFT JOIN LATERAL
       public.customer_resolve_buyer_product_authority_v1(v_order.company_id,oi.product_id) a ON true WHERE oi.order_id=p_order_id
   ) q;
 END IF;
 IF jsonb_array_length(v_lines)=0 THEN RAISE EXCEPTION 'ORDER_HAS_NO_COMMERCIAL_LINES' USING ERRCODE='P0001'; END IF;
 IF v_order.order_origin='WHATSAPP' THEN
   SELECT source_reference INTO v_source_reference FROM public.sales_order_commercial_versions WHERE order_id=p_order_id ORDER BY version_number DESC LIMIT 1;
   IF v_source_reference IS NULL THEN
     SELECT d.id INTO v_source_draft_id FROM public.sales_order_drafts d WHERE d.promoted_order_id=p_order_id ORDER BY d.id LIMIT 1;
     IF NOT FOUND THEN RAISE EXCEPTION 'WHATSAPP_SOURCE_REFERENCE_REQUIRED' USING ERRCODE='P0001'; END IF;
     IF EXISTS(SELECT 1 FROM public.sales_order_drafts d WHERE d.promoted_order_id=p_order_id AND d.id<>v_source_draft_id) THEN
       RAISE EXCEPTION 'WHATSAPP_SOURCE_REFERENCE_AMBIGUOUS' USING ERRCODE='P0001';
     END IF;
     v_source_reference:='wa-draft:'||v_source_draft_id::text;
   END IF;
 ELSE v_source_reference:=coalesce(v_order.checkout_idempotency_key,v_order.order_number); END IF;
 RETURN jsonb_build_object('order_id',v_order.id,'order_number',v_order.order_number,'source_channel',v_order.order_origin,
   'source_reference',v_source_reference,'company_id',v_company.id,'company_name',v_company.business_name,'branch_reference',null,
   'contact_reference',null,'payment_terms',v_company.payment_terms,'requested_dispatch_date',v_order.requested_dispatch_date,
   'lines',v_lines,'packing_charge',0,'other_approved_charges',0,'discount_total',0,'sales_order_value',v_order.sales_order_value,
   'advance_required',v_order.advance_required,'advance_rule_version','advance-30pct-nearest-inr-500/v2');
END $$;

-- Explicit ACL closure required for SECURITY DEFINER replacements.
revoke all on function public.submit_customer_order_v1(text,date)
  from public, anon, authenticated, service_role;
grant execute on function public.submit_customer_order_v1(text,date)
  to authenticated, service_role;

revoke all on function public.build_sales_order_commercial_snapshot_v1(uuid)
  from public, anon, authenticated, service_role;



-- Explicit SECURITY DEFINER execution boundary.
REVOKE ALL ON FUNCTION public.submit_customer_order_v1(text,date)
FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_order_v1(text,date)
TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.build_sales_order_commercial_snapshot_v1(uuid)
FROM PUBLIC, anon, authenticated, service_role;
