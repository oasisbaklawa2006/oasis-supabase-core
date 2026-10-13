-- New forward-only migration. No changes to immutable migration history.
-- Draft implementation: must pass governed security and migration CI before deployment.
CREATE OR REPLACE FUNCTION public.customer_checkout_quote_v1()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
DECLARE
 v_uid uuid:=auth.uid(); v_company_id uuid; v_draft public.customer_order_drafts%rowtype;
 v_line record; v_auth record; v_snapshot jsonb:='[]'::jsonb; v_total numeric:=0; v_advance numeric; v_quote jsonb;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE='28000'; END IF;
 v_company_id:=public.customer_buyer_eligible_company_id();
 IF v_company_id IS NULL THEN RAISE EXCEPTION 'BUYER_NOT_ELIGIBLE' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_draft FROM public.customer_order_drafts d WHERE d.company_id=v_company_id AND d.status='active'
 ORDER BY d.updated_at DESC,d.created_at DESC,d.id LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF v_draft.readiness_status IS DISTINCT FROM 'ready' THEN RAISE EXCEPTION 'DRAFT_NOT_READY' USING ERRCODE='22023'; END IF;
 FOR v_line IN SELECT l.* FROM public.customer_order_draft_lines l WHERE l.draft_id=v_draft.id ORDER BY l.product_id,l.id LOOP
   SELECT * INTO v_auth FROM public.customer_resolve_buyer_product_authority_v1(v_company_id,v_line.product_id);
   IF NOT coalesce(v_auth.is_available,false) THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE='22023'; END IF;
   IF NOT public.customer_validate_order_quantity_v1(v_line.quantity,v_auth.minimum_order_quantity,v_auth.order_increment,v_auth.min_carton_qty)
   THEN RAISE EXCEPTION 'QUANTITY_RULE_VIOLATION' USING ERRCODE='22023'; END IF;
   IF v_line.quantity IS NULL OR v_line.quantity<=0 OR v_auth.selling_price IS NULL OR v_auth.selling_price<=0
      OR nullif(btrim(v_auth.currency),'') IS NULL OR nullif(btrim(v_auth.uom),'') IS NULL
      OR v_auth.gst_rate IS NULL OR v_auth.gst_rate<0 OR v_auth.gst_rate>100 OR v_auth.tax_inclusive IS NULL
      OR nullif(btrim(v_auth.sku),'') IS NULL OR nullif(btrim(v_auth.product_name),'') IS NULL
   THEN RAISE EXCEPTION 'CHECKOUT_COMMERCIAL_AUTHORITY_INCOMPLETE' USING ERRCODE='22023'; END IF;
   v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object(
     'product_id',v_line.product_id,'quantity',v_line.quantity,'selling_price',v_auth.selling_price,'currency',v_auth.currency,
     'uom',v_auth.uom,'gst_rate',v_auth.gst_rate,'tax_inclusive',v_auth.tax_inclusive,'sku',v_auth.sku,'product_name',v_auth.product_name,
     'minimum_order_quantity',v_auth.minimum_order_quantity,'order_increment',v_auth.order_increment,'min_carton_qty',v_auth.min_carton_qty));
   v_total:=v_total+(v_line.quantity*v_auth.selling_price*
     CASE WHEN v_auth.tax_inclusive THEN 1::numeric ELSE 1::numeric+(v_auth.gst_rate/100::numeric) END);
 END LOOP;
 IF jsonb_array_length(v_snapshot)=0 THEN RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_INVALID' USING ERRCODE='22023'; END IF;
 v_total:=round(v_total,2);
 IF v_total<=0 THEN RAISE EXCEPTION 'CHECKOUT_TOTAL_INVALID' USING ERRCODE='22023'; END IF;
 v_advance:=public.calculate_sales_order_advance_v1(v_total);
 IF v_advance<=0 THEN RAISE EXCEPTION 'CHECKOUT_ADVANCE_INVALID' USING ERRCODE='22023'; END IF;
 v_quote:=jsonb_build_object('draft_id',v_draft.id,'lines',v_snapshot,'sales_order_value',v_total,'advance_required',v_advance);
 RETURN v_quote||jsonb_build_object('fingerprint',md5(v_quote::text));
END $$;

-- Reconciled immutable production migration history.
-- This exact version/name is already recorded in production.
CREATE OR REPLACE FUNCTION public.submit_customer_order_v1(p_idempotency_key text,p_requested_dispatch_date date DEFAULT NULL)
RETURNS TABLE(order_id uuid,order_number text,sales_order_value numeric,advance_required numeric,draft_id uuid,is_duplicate_submission boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
#variable_conflict use_column
DECLARE
 v_uid uuid:=auth.uid(); v_company_id uuid; v_draft public.customer_order_drafts%rowtype;
 v_existing_order_id uuid; v_existing_order_number text; v_existing_so_value numeric; v_existing_advance numeric; v_promoted_draft_id uuid;
 v_approved_fingerprint text:=nullif(current_setting('app.customer_quote_fingerprint',true),''); v_quote jsonb; v_order_id uuid; v_order_number text; v_snapshot jsonb:='[]'::jsonb; v_total numeric:=0; v_advance numeric; v_line record; v_auth record;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED: authentication is required' USING ERRCODE='28000'; END IF;
 IF v_approved_fingerprint IS NULL THEN RAISE EXCEPTION 'QUOTE_APPROVAL_REQUIRED' USING ERRCODE='22023'; END IF;
 IF coalesce(btrim(p_idempotency_key),'')='' THEN RAISE EXCEPTION 'VALIDATION_FAILED: idempotency_key is required'; END IF;
 v_company_id:=public.customer_buyer_eligible_company_id();
 IF v_company_id IS NULL THEN RAISE EXCEPTION 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('customer_checkout:'||v_company_id::text||':'||btrim(p_idempotency_key),0));
 SELECT o.id,o.order_number,o.sales_order_value,o.advance_required INTO v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance
 FROM public.orders o WHERE o.company_id=v_company_id AND o.order_origin='CUSTOMER_APP' AND o.checkout_idempotency_key=btrim(p_idempotency_key) LIMIT 1;
 IF v_existing_order_id IS NOT NULL THEN
   SELECT jsonb_build_object('draft_id',d.id,'lines',o.checkout_snapshot,'sales_order_value',o.sales_order_value,'advance_required',o.advance_required) INTO v_quote FROM public.orders o JOIN public.customer_order_drafts d ON d.promoted_order_id=o.id WHERE o.id=v_existing_order_id LIMIT 1;
   IF v_quote IS NULL OR md5(v_quote::text) IS DISTINCT FROM v_approved_fingerprint THEN RAISE EXCEPTION 'QUOTE_RETRY_MISMATCH' USING ERRCODE='22023'; END IF;
   SELECT d.id INTO v_promoted_draft_id FROM public.customer_order_drafts d WHERE d.promoted_order_id=v_existing_order_id LIMIT 1;
   RETURN QUERY SELECT v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance,v_promoted_draft_id,true; RETURN;
 END IF;
 SELECT * INTO v_draft FROM public.customer_order_drafts d WHERE d.company_id=v_company_id AND d.status='active'
 ORDER BY d.updated_at DESC,d.created_at DESC,d.id LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND: no active customer order draft exists for checkout' USING ERRCODE='P0002'; END IF;
 PERFORM public.customer_order_draft_audit_v1(v_draft.id,v_company_id,v_uid,'SUBMIT_ATTEMPT',jsonb_build_object('idempotency_key',btrim(p_idempotency_key)));
 PERFORM public.customer_recompute_draft_readiness_v1(v_draft.id);
 SELECT * INTO v_draft FROM public.customer_order_drafts WHERE id=v_draft.id AND status='active';
 IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF v_draft.readiness_status IS DISTINCT FROM 'ready' THEN RAISE EXCEPTION 'DRAFT_NOT_READY: draft cannot be submitted (issues: %)',v_draft.readiness_issues::text; END IF;
 FOR v_line IN SELECT l.* FROM public.customer_order_draft_lines l WHERE l.draft_id=v_draft.id ORDER BY l.product_id,l.id LOOP
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
 v_quote:=jsonb_build_object('draft_id',v_draft.id,'lines',v_snapshot,'sales_order_value',v_total,'advance_required',v_advance);
 IF md5(v_quote::text) IS DISTINCT FROM v_approved_fingerprint THEN RAISE EXCEPTION 'QUOTE_CHANGED_REFRESH_REQUIRED' USING ERRCODE='22023'; END IF;
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
 SELECT jsonb_build_object('draft_id',d.id,'lines',o.checkout_snapshot,'sales_order_value',o.sales_order_value,'advance_required',o.advance_required) INTO v_quote FROM public.orders o JOIN public.customer_order_drafts d ON d.promoted_order_id=o.id WHERE o.id=v_existing_order_id LIMIT 1;
 IF v_quote IS NULL OR md5(v_quote::text) IS DISTINCT FROM v_approved_fingerprint THEN RAISE EXCEPTION 'QUOTE_RETRY_MISMATCH' USING ERRCODE='22023'; END IF;
 SELECT d.id INTO v_promoted_draft_id FROM public.customer_order_drafts d WHERE d.promoted_order_id=v_existing_order_id LIMIT 1;
 RETURN QUERY SELECT v_existing_order_id,v_existing_order_number,v_existing_so_value,v_existing_advance,v_promoted_draft_id,true;
END $$;


CREATE OR REPLACE FUNCTION public.submit_customer_order_quoted_v1(p_idempotency_key text,p_quote_fingerprint text,p_requested_dispatch_date date DEFAULT NULL)
RETURNS TABLE(order_id uuid,order_number text,sales_order_value numeric,advance_required numeric,draft_id uuid,is_duplicate_submission boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE='28000'; END IF;
 IF p_quote_fingerprint !~ '^[0-9a-f]{32}$' OR p_quote_fingerprint IS NULL THEN RAISE EXCEPTION 'QUOTE_APPROVAL_REQUIRED' USING ERRCODE='22023'; END IF;
 PERFORM set_config('app.customer_quote_fingerprint',p_quote_fingerprint,true);
 RETURN QUERY SELECT * FROM public.submit_customer_order_v1(p_idempotency_key,p_requested_dispatch_date);
END $$;
REVOKE ALL ON FUNCTION public.customer_checkout_quote_v1() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_checkout_quote_v1() TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.submit_customer_order_quoted_v1(text,text,date) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_order_quoted_v1(text,text,date) TO authenticated,service_role;

REVOKE ALL ON FUNCTION public.submit_customer_order_v1(text,date) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_order_v1(text,date) TO authenticated,service_role;
