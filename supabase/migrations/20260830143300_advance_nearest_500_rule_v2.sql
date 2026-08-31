-- PF-4 commercial-policy correction: future governed Sales Order versions use
-- 30% advance rounded to the nearest INR 500, with a minimum INR 500 advance
-- for any positive governed SO. Existing immutable commercial versions are not
-- rewritten; their frozen advance_required and rule version remain historical truth.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.calculate_sales_order_advance_v1(p_sales_order_value numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN p_sales_order_value IS NULL OR p_sales_order_value <= 0 THEN 0::numeric
    ELSE greatest(500::numeric, round((p_sales_order_value * 0.30) / 500) * 500)
  END;
$$;

COMMENT ON FUNCTION public.calculate_sales_order_advance_v1(numeric) IS
  'Canonical governed Sales Order advance for new/recalculated commercial versions: 30% of approved SO value, rounded to nearest INR 500, minimum INR 500 for a positive SO. Historical frozen versions retain their original advance requirement.';

ALTER TABLE public.sales_order_commercial_versions
  ALTER COLUMN advance_rule_version SET DEFAULT 'advance-30pct-nearest-inr-500/v2';

CREATE OR REPLACE FUNCTION public.build_sales_order_commercial_snapshot_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_company public.companies%rowtype;
  v_lines jsonb := '[]'::jsonb;
  v_unavailable_product uuid;
  v_source_reference text;
  v_source_draft_id uuid;
  v_expected_advance numeric;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_company FROM public.companies WHERE id = v_order.company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_COMPANY_REQUIRED' USING ERRCODE = 'P0001'; END IF;

  -- A v2 marker may only be frozen with the v2 amount. Fail closed rather than
  -- silently stamping stale financial state with a newer policy version.
  v_expected_advance := public.calculate_sales_order_advance_v1(v_order.sales_order_value);
  IF v_order.advance_required IS DISTINCT FROM v_expected_advance THEN
    RAISE EXCEPTION 'GOVERNED_ADVANCE_STALE: stored %, expected % for sales order value %',
      v_order.advance_required, v_expected_advance, v_order.sales_order_value
      USING ERRCODE = 'P0001';
  END IF;

  -- Preserve the canonical immutable WhatsApp draft lineage established by PF-4
  -- historical-boundary hardening. This policy migration changes advance semantics
  -- only; it must never collapse a WhatsApp source reference back to an SO number.
  IF v_order.order_origin = 'WHATSAPP' THEN
    SELECT source_reference INTO v_source_reference
      FROM public.sales_order_commercial_versions
     WHERE order_id = p_order_id
     ORDER BY version_number DESC
     LIMIT 1;
    IF v_source_reference IS NULL THEN
      SELECT d.id INTO v_source_draft_id
        FROM public.sales_order_drafts d
       WHERE d.promoted_order_id = p_order_id
       ORDER BY d.id
       LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'WHATSAPP_SOURCE_REFERENCE_REQUIRED' USING ERRCODE = 'P0001';
      END IF;
      IF EXISTS (
        SELECT 1 FROM public.sales_order_drafts d
         WHERE d.promoted_order_id = p_order_id AND d.id <> v_source_draft_id
      ) THEN
        RAISE EXCEPTION 'WHATSAPP_SOURCE_REFERENCE_AMBIGUOUS' USING ERRCODE = 'P0001';
      END IF;
      v_source_reference := 'wa-draft:' || v_source_draft_id::text;
    END IF;
  ELSE
    v_source_reference := coalesce(v_order.checkout_idempotency_key, v_order.order_number);
  END IF;

  SELECT oi.product_id INTO v_unavailable_product
    FROM public.order_items oi
    LEFT JOIN LATERAL public.customer_resolve_buyer_product_authority_v1(v_order.company_id, oi.product_id) a ON true
   WHERE oi.order_id = p_order_id AND NOT coalesce(a.is_available, false)
   ORDER BY oi.id LIMIT 1;
  IF v_unavailable_product IS NOT NULL THEN
    RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = 'P0001';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'order_item_id', q.id,
      'product_id', q.product_id,
      'sku', q.sku,
      'product_name', q.product_name,
      'quantity', q.quantity,
      'uom', coalesce(q.pack_size, q.uom),
      'pack_size', q.pack_size,
      'carton_type', q.carton_type,
      'unit_price', q.selling_price,
      'discount_amount', 0,
      'taxable_value', round(q.taxable_value, 2),
      'tax_amount', round(q.line_total - q.taxable_value, 2),
      'currency', q.currency,
      'gst_rate', q.gst_rate,
      'tax_inclusive', q.tax_inclusive,
      'line_total', round(q.line_total, 2)
    ) ORDER BY q.id), '[]'::jsonb) INTO v_lines
  FROM (
    SELECT oi.id, oi.product_id, oi.quantity, oi.pack_size, oi.carton_type,
      p.sku, p.product_name, a.uom, a.selling_price, a.currency,
      coalesce(a.gst_rate, 0) AS gst_rate,
      coalesce(a.tax_inclusive, false) AS tax_inclusive,
      CASE WHEN coalesce(a.tax_inclusive, false) AND coalesce(a.gst_rate, 0) > 0
        THEN coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0) / (1 + a.gst_rate / 100)
        ELSE coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0)
      END AS taxable_value,
      coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0) *
        CASE WHEN coalesce(a.tax_inclusive, false) THEN 1 ELSE 1 + coalesce(a.gst_rate, 0) / 100 END AS line_total
      FROM public.order_items oi
      JOIN public.products p ON p.id = oi.product_id
      LEFT JOIN LATERAL public.customer_resolve_buyer_product_authority_v1(v_order.company_id, oi.product_id) a ON true
     WHERE oi.order_id = p_order_id
  ) q;

  IF jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'ORDER_HAS_NO_COMMERCIAL_LINES' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'source_channel', v_order.order_origin,
    'source_reference', v_source_reference,
    'company_id', v_company.id,
    'company_name', v_company.business_name,
    'branch_reference', null,
    'contact_reference', null,
    'payment_terms', v_company.payment_terms,
    'requested_dispatch_date', v_order.requested_dispatch_date,
    'lines', v_lines,
    'packing_charge', 0,
    'other_approved_charges', 0,
    'discount_total', 0,
    'sales_order_value', v_order.sales_order_value,
    'advance_required', v_order.advance_required,
    'advance_rule_version', 'advance-30pct-nearest-inr-500/v2'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.build_sales_order_commercial_snapshot_v1(uuid) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.build_sales_order_commercial_snapshot_v1(uuid) IS
  'Builds immutable governed SO commercial snapshot while preserving canonical source lineage. A v2 snapshot is emitted only when stored advance_required matches the canonical nearest-INR-500 v2 calculation; historical snapshots remain unchanged.';
