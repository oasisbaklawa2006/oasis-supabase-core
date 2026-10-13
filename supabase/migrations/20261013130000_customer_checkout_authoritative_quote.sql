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

-- Compatibility phase: preserve the deployed canonical writer and its legacy callers.
-- The quoted wrapper validates an authoritative snapshot under the same draft row lock.
-- Revoking legacy authenticated access requires a separate coordinated Buyer rollout.
CREATE OR REPLACE FUNCTION public.submit_customer_order_quoted_v1(p_idempotency_key text,p_quote_fingerprint text,p_requested_dispatch_date date DEFAULT NULL)
RETURNS TABLE(order_id uuid,order_number text,sales_order_value numeric,advance_required numeric,draft_id uuid,is_duplicate_submission boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
DECLARE v_company_id uuid; v_draft_id uuid; v_quote jsonb; v_result record;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE='28000'; END IF;
 IF p_quote_fingerprint IS NULL OR p_quote_fingerprint !~ '^[0-9a-f]{32}$' THEN RAISE EXCEPTION 'QUOTE_APPROVAL_REQUIRED' USING ERRCODE='22023'; END IF;
 SELECT c.company_id INTO v_company_id FROM public.customer_get_active_company_context_v1() c LIMIT 1;
 IF v_company_id IS NULL THEN RAISE EXCEPTION 'COMPANY_ACCESS_REQUIRED' USING ERRCODE='42501'; END IF;
 SELECT d.id INTO v_draft_id FROM public.customer_order_drafts d WHERE d.company_id=v_company_id AND d.status='active'
 ORDER BY d.updated_at DESC,d.created_at DESC,d.id LIMIT 1 FOR UPDATE;
 IF v_draft_id IS NULL THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 PERFORM public.customer_recompute_draft_readiness_v1(v_draft_id);
 IF NOT EXISTS (SELECT 1 FROM public.customer_order_drafts d WHERE d.id=v_draft_id AND d.status='active' AND d.readiness_status='ready')
 THEN RAISE EXCEPTION 'DRAFT_NOT_READY' USING ERRCODE='22023'; END IF;
 v_quote:=public.customer_checkout_quote_v1();
 IF v_quote->>'draft_id' IS DISTINCT FROM v_draft_id::text OR v_quote->>'fingerprint' IS DISTINCT FROM p_quote_fingerprint
 THEN RAISE EXCEPTION 'QUOTE_CHANGED_REFRESH_REQUIRED' USING ERRCODE='22023'; END IF;
 RETURN QUERY SELECT * FROM public.submit_customer_order_v1(p_idempotency_key,p_requested_dispatch_date);
END $$;
REVOKE ALL ON FUNCTION public.customer_checkout_quote_v1() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.customer_checkout_quote_v1() TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.submit_customer_order_quoted_v1(text,text,date) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_order_quoted_v1(text,text,date) TO authenticated,service_role;
