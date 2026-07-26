CREATE OR REPLACE FUNCTION public.get_public_catalogue_channel_data(_slug text)
RETURNS TABLE (
  catalogue_id uuid,
  target_customer_channel text,
  product_id uuid,
  sku text,
  public_price numeric,
  currency text,
  uom text,
  discount_percent numeric,
  mrp numeric,
  price_label text,
  price_display_text text,
  moq_display_text text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cat record;
  v_channel text;
  v_safe boolean;
  v_show_price boolean;
  v_show_mrp boolean;
  v_show_discount boolean;
  v_label text;
  SAFE_CHANNELS text[] := ARRAY['retail','b2c','bulk','wholesale','horeca','b2b','distributor','export','private_label','corporate_gifting','wedding','price_hidden'];
BEGIN
  SELECT c.id, c.target_customer_channel, c.show_price, c.show_mrp, c.show_discount, c.show_price_label, c.status
    INTO v_cat
  FROM public.catalogues c
  WHERE c.public_slug = _slug AND c.status = 'published'
  LIMIT 1;

  IF v_cat.id IS NULL THEN
    RETURN;
  END IF;

  v_channel := COALESCE(v_cat.target_customer_channel, 'price_hidden');
  v_safe := v_channel = ANY(SAFE_CHANNELS);
  v_show_price := COALESCE(v_cat.show_price, false) AND v_channel <> 'price_hidden' AND v_safe;
  v_show_mrp := COALESCE(v_cat.show_mrp, false);
  v_show_discount := COALESCE(v_cat.show_discount, false);
  v_label := COALESCE(v_cat.show_price_label,
                      CASE WHEN v_channel <> 'price_hidden' THEN replace(v_channel, '_', ' ') || ' price' ELSE 'Price' END);

  RETURN QUERY
  WITH cp AS (
    SELECT p.id AS pid, p.sku AS psku, p.mrp AS pmrp
    FROM public.catalogue_products xp
    JOIN public.products p ON p.id = xp.product_id
    WHERE xp.catalogue_id = v_cat.id
  ),
  pr AS (
    SELECT r.product_id, r.calculated_price, r.currency, r.uom, r.discount_percent
    FROM public.product_pricing_rules r
    WHERE v_safe
      AND r.price_channel = v_channel
      AND r.approval_status = 'approved'
      AND r.product_id IN (SELECT pid FROM cp)
  ),
  mr AS (
    SELECT m.product_id, m.moq_applicable, m.moq_value, m.moq_uom
    FROM public.product_moq_rules m
    WHERE v_safe
      AND m.channel = v_channel
      AND m.product_id IN (SELECT pid FROM cp)
  )
  SELECT
    v_cat.id,
    v_channel,
    cp.pid,
    cp.psku,
    CASE WHEN v_show_price THEN pr.calculated_price ELSE NULL END,
    CASE WHEN v_show_price THEN COALESCE(pr.currency, 'INR') ELSE NULL END,
    CASE WHEN v_show_price THEN pr.uom ELSE NULL END,
    CASE WHEN v_show_discount THEN pr.discount_percent ELSE NULL END,
    CASE WHEN v_show_mrp THEN cp.pmrp ELSE NULL END,
    v_label,
    CASE
      WHEN v_show_price AND pr.calculated_price IS NOT NULL THEN
        COALESCE(pr.currency, 'INR') || ' ' || pr.calculated_price::text
      WHEN v_show_mrp AND cp.pmrp IS NOT NULL THEN
        '₹ ' || cp.pmrp::text || ' MRP'
      ELSE 'Price on request'
    END,
    CASE
      WHEN mr.product_id IS NULL THEN 'MOQ depends on order type. Contact sales for details.'
      WHEN mr.moq_applicable = false THEN 'MOQ not applicable'
      WHEN mr.moq_value IS NOT NULL THEN 'MOQ: ' || mr.moq_value::text || ' ' || COALESCE(mr.moq_uom, '')
      ELSE 'MOQ depends on order type. Contact sales for details.'
    END
  FROM cp
  LEFT JOIN pr ON pr.product_id = cp.pid
  LEFT JOIN mr ON mr.product_id = cp.pid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_public_catalogue_channel_data(text) TO anon, authenticated;