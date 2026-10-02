-- Reconciled immutable production migration history.
-- This exact version/name is already recorded in production.
CREATE OR REPLACE FUNCTION public.customer_checkout_snapshot_total_v1(p_order_id uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_origin text; v_snapshot jsonb; v_snapshot_count integer; v_item_count integer; v_total numeric;
BEGIN
 SELECT o.order_origin,o.checkout_snapshot INTO v_origin,v_snapshot FROM public.orders o WHERE o.id=p_order_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF v_origin IS DISTINCT FROM 'CUSTOMER_APP' THEN RAISE EXCEPTION 'ORDER_SOURCE_MISMATCH' USING ERRCODE='P0001'; END IF;
 IF v_snapshot IS NULL OR jsonb_typeof(v_snapshot)<>'array' OR jsonb_array_length(v_snapshot)=0 THEN
   RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_REQUIRED: CUSTOMER_APP order has no authoritative checkout snapshot' USING ERRCODE='22023';
 END IF;
 IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot) x(line) WHERE jsonb_typeof(x.line)<>'object'
   OR nullif(btrim(x.line->>'product_id'),'') IS NULL OR nullif(btrim(x.line->>'quantity'),'') IS NULL
   OR nullif(btrim(x.line->>'selling_price'),'') IS NULL OR nullif(btrim(x.line->>'currency'),'') IS NULL
   OR nullif(btrim(x.line->>'uom'),'') IS NULL OR nullif(btrim(x.line->>'gst_rate'),'') IS NULL
   OR nullif(btrim(x.line->>'tax_inclusive'),'') IS NULL OR nullif(btrim(x.line->>'sku'),'') IS NULL
   OR nullif(btrim(x.line->>'product_name'),'') IS NULL) THEN
   RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_INVALID: required commercial line fields are missing' USING ERRCODE='22023';
 END IF;
 IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot) x(line) WHERE (x.line->>'quantity')::numeric<=0
   OR (x.line->>'selling_price')::numeric<=0 OR (x.line->>'gst_rate')::numeric<0 OR (x.line->>'gst_rate')::numeric>100
   OR lower(x.line->>'tax_inclusive') NOT IN ('true','false')) THEN
   RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_INVALID: invalid quantity, price, GST or tax-inclusive value' USING ERRCODE='22023';
 END IF;
 SELECT count(*) INTO v_snapshot_count FROM jsonb_array_elements(v_snapshot);
 IF EXISTS (SELECT 1 FROM (SELECT (x.line->>'product_id')::uuid product_id FROM jsonb_array_elements(v_snapshot) x(line)
   GROUP BY (x.line->>'product_id')::uuid HAVING count(*)>1) d) THEN
   RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_INVALID: duplicate product identity in checkout snapshot' USING ERRCODE='22023';
 END IF;
 SELECT count(*) INTO v_item_count FROM public.order_items oi WHERE oi.order_id=p_order_id;
 IF EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id=p_order_id GROUP BY oi.product_id HAVING count(*)>1) THEN
   RAISE EXCEPTION 'CHECKOUT_ORDER_ITEM_INVALID: duplicate CUSTOMER_APP product line' USING ERRCODE='22023';
 END IF;
 IF v_snapshot_count<>v_item_count THEN RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_ORDER_ITEM_MISMATCH: snapshot lines %, order lines %',v_snapshot_count,v_item_count USING ERRCODE='22023'; END IF;
 IF EXISTS (SELECT 1 FROM public.order_items oi LEFT JOIN LATERAL
   (SELECT x.line FROM jsonb_array_elements(v_snapshot) x(line) WHERE (x.line->>'product_id')::uuid=oi.product_id) s ON true
   WHERE oi.order_id=p_order_id AND (s.line IS NULL OR (s.line->>'quantity')::numeric IS DISTINCT FROM oi.quantity)) THEN
   RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_ORDER_ITEM_MISMATCH: Order Item quantity differs from Buyer checkout' USING ERRCODE='22023';
 END IF;
 SELECT round(coalesce(sum((x.line->>'quantity')::numeric*(x.line->>'selling_price')::numeric*
   CASE WHEN (x.line->>'tax_inclusive')::boolean THEN 1::numeric ELSE 1::numeric+((x.line->>'gst_rate')::numeric/100::numeric) END),0),2)
 INTO v_total FROM jsonb_array_elements(v_snapshot) x(line);
 IF v_total<=0 THEN RAISE EXCEPTION 'CHECKOUT_SNAPSHOT_INVALID: authoritative Sales Order total must be positive' USING ERRCODE='22023'; END IF;
 RETURN v_total;
END $$;
REVOKE ALL ON FUNCTION public.customer_checkout_snapshot_total_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.customer_checkout_snapshot_total_v1(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.prevent_customer_checkout_snapshot_mutation_v1()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF old.order_origin='CUSTOMER_APP' AND new.checkout_snapshot IS DISTINCT FROM old.checkout_snapshot THEN
   RAISE EXCEPTION 'CUSTOMER_CHECKOUT_SNAPSHOT_IMMUTABLE' USING ERRCODE='55000',
   DETAIL='CUSTOMER_APP commercial truth is frozen when checkout is submitted';
 END IF;
 RETURN new;
END $$;
DROP TRIGGER IF EXISTS trg_customer_checkout_snapshot_immutable ON public.orders;
CREATE TRIGGER trg_customer_checkout_snapshot_immutable BEFORE UPDATE OF checkout_snapshot ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_checkout_snapshot_mutation_v1();

CREATE OR REPLACE FUNCTION public.recalculate_customer_app_order_financials(p_order_id uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_origin text; v_total numeric;
BEGIN
 SELECT o.order_origin INTO v_origin FROM public.orders o WHERE o.id=p_order_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF v_origin IS DISTINCT FROM 'CUSTOMER_APP' THEN RAISE EXCEPTION 'ORDER_SOURCE_MISMATCH' USING ERRCODE='P0001'; END IF;
 v_total:=public.customer_checkout_snapshot_total_v1(p_order_id);
 UPDATE public.orders SET sales_order_value=v_total,advance_required=public.calculate_sales_order_advance_v1(v_total) WHERE id=p_order_id;
 RETURN v_total;
END $$;
REVOKE ALL ON FUNCTION public.recalculate_customer_app_order_financials(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.recalculate_customer_app_order_financials(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.recalculate_governed_sales_order_financials_v1(p_order_id uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_company_id uuid; v_origin text; v_total numeric:=0; v_unavailable_product uuid;
BEGIN
 SELECT o.company_id,o.order_origin INTO v_company_id,v_origin FROM public.orders o WHERE o.id=p_order_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 IF v_origin='CUSTOMER_APP' THEN RETURN public.recalculate_customer_app_order_financials(p_order_id); END IF;
 IF v_company_id IS NULL THEN RAISE EXCEPTION 'ORDER_COMPANY_REQUIRED' USING ERRCODE='P0001'; END IF;
 SELECT oi.product_id INTO v_unavailable_product FROM public.order_items oi
 LEFT JOIN LATERAL public.customer_resolve_buyer_product_authority_v1(v_company_id,oi.product_id) a ON true
 WHERE oi.order_id=p_order_id AND NOT coalesce(a.is_available,false) ORDER BY oi.id LIMIT 1;
 IF v_unavailable_product IS NOT NULL THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE: product % is not commercially available',v_unavailable_product USING ERRCODE='P0001'; END IF;
 SELECT coalesce(sum(coalesce(oi.quantity,0)*coalesce(a.selling_price,0)*
 CASE WHEN coalesce(a.tax_inclusive,false) THEN 1 ELSE 1+coalesce(a.gst_rate,0)/100 END),0)
 INTO v_total FROM public.order_items oi LEFT JOIN LATERAL
 public.customer_resolve_buyer_product_authority_v1(v_company_id,oi.product_id) a ON true WHERE oi.order_id=p_order_id;
 v_total:=round(v_total,2);
 UPDATE public.orders SET sales_order_value=v_total,advance_required=public.calculate_sales_order_advance_v1(v_total) WHERE id=p_order_id;
 RETURN v_total;
END $$;

CREATE OR REPLACE FUNCTION public.restore_order_financials(_order_id uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_origin text; v_subtotal numeric:=0; v_total numeric:=0;
BEGIN
 SELECT o.order_origin INTO v_origin FROM public.orders o WHERE o.id=_order_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF v_origin='CUSTOMER_APP' THEN RETURN public.recalculate_customer_app_order_financials(_order_id); END IF;
 IF v_origin IS DISTINCT FROM 'LEGACY_ERP' THEN RETURN public.recalculate_governed_sales_order_financials_v1(_order_id); END IF;
 SELECT coalesce(sum(coalesce(oi.quantity,0)*coalesce(p.price_per_kg,p.base_price,p.price_b2b,p.price_wholesale,p.wholesale_price,0)),0)
 INTO v_subtotal FROM public.order_items oi JOIN public.products p ON p.id=oi.product_id WHERE oi.order_id=_order_id;
 v_total:=v_subtotal*1.18;
 UPDATE public.orders SET sales_order_value=v_total,advance_required=v_total*0.5 WHERE id=_order_id;
 RETURN v_total;
END $$;
