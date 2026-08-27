-- PF-4 final hardening: historical-only LEGACY_ERP provenance, fail-closed
-- governed financials, and immutable WhatsApp draft lineage.

ALTER TABLE public.orders ALTER COLUMN order_origin DROP DEFAULT;

CREATE OR REPLACE FUNCTION public.enforce_historical_legacy_erp_origin_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF tg_op = 'INSERT' AND new.order_origin = 'LEGACY_ERP' THEN
    RAISE EXCEPTION 'LEGACY_ERP_HISTORICAL_ONLY' USING ERRCODE = '23514';
  END IF;
  IF tg_op = 'UPDATE'
     AND new.order_origin IS DISTINCT FROM old.order_origin
     AND (new.order_origin = 'LEGACY_ERP' OR old.order_origin = 'LEGACY_ERP') THEN
    RAISE EXCEPTION 'LEGACY_ERP_HISTORICAL_ONLY' USING ERRCODE = '23514';
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_historical_legacy_erp_origin ON public.orders;
CREATE TRIGGER trg_orders_historical_legacy_erp_origin
  BEFORE INSERT OR UPDATE OF order_origin ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.enforce_historical_legacy_erp_origin_v1();

REVOKE ALL ON FUNCTION public.enforce_historical_legacy_erp_origin_v1()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.enforce_historical_legacy_erp_origin_v1() IS
  'Preserves existing imported LEGACY_ERP provenance while preventing new governed orders or transitions from reaching the historical finance policy.';

CREATE OR REPLACE FUNCTION public.recalculate_governed_sales_order_financials_v1(p_order_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_company_id uuid;
  v_total numeric := 0;
  v_unavailable_product uuid;
BEGIN
  SELECT company_id INTO v_company_id
    FROM public.orders
   WHERE id = p_order_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_COMPANY_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT oi.product_id INTO v_unavailable_product
    FROM public.order_items oi
    LEFT JOIN LATERAL public.customer_resolve_buyer_product_authority_v1(v_company_id, oi.product_id) a ON true
   WHERE oi.order_id = p_order_id AND NOT coalesce(a.is_available, false)
   ORDER BY oi.id LIMIT 1;
  IF v_unavailable_product IS NOT NULL THEN
    RAISE EXCEPTION 'PRODUCT_UNAVAILABLE: product % is not commercially available', v_unavailable_product USING ERRCODE = 'P0001';
  END IF;
  SELECT coalesce(sum(
    coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0) *
    CASE WHEN coalesce(a.tax_inclusive, false) THEN 1 ELSE 1 + coalesce(a.gst_rate, 0) / 100 END
  ), 0) INTO v_total
    FROM public.order_items oi
    LEFT JOIN LATERAL public.customer_resolve_buyer_product_authority_v1(v_company_id, oi.product_id) a ON true
   WHERE oi.order_id = p_order_id;
  v_total := round(v_total, 2);
  UPDATE public.orders
     SET sales_order_value = v_total,
         advance_required = public.calculate_sales_order_advance_v1(v_total)
   WHERE id = p_order_id;
  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.recalculate_governed_sales_order_financials_v1(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.build_sales_order_commercial_snapshot_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_order public.orders%rowtype;
  v_company public.companies%rowtype;
  v_lines jsonb := '[]'::jsonb;
  v_unavailable_product uuid;
  v_source_reference text;
  v_source_draft_id uuid;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_company FROM public.companies WHERE id = v_order.company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_COMPANY_REQUIRED' USING ERRCODE = 'P0001'; END IF;

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
  IF v_unavailable_product IS NOT NULL THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = 'P0001'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'order_item_id', q.id, 'product_id', q.product_id, 'sku', q.sku, 'product_name', q.product_name,
      'quantity', q.quantity, 'uom', coalesce(q.pack_size, q.uom), 'pack_size', q.pack_size, 'carton_type', q.carton_type,
      'unit_price', q.selling_price, 'discount_amount', 0, 'taxable_value', round(q.taxable_value, 2),
      'tax_amount', round(q.line_total - q.taxable_value, 2), 'currency', q.currency, 'gst_rate', q.gst_rate,
      'tax_inclusive', q.tax_inclusive, 'line_total', round(q.line_total, 2)
    ) ORDER BY q.id), '[]'::jsonb) INTO v_lines
  FROM (
    SELECT oi.id, oi.product_id, oi.quantity, oi.pack_size, oi.carton_type, p.sku, p.product_name,
      a.uom, a.selling_price, a.currency, coalesce(a.gst_rate, 0) AS gst_rate, coalesce(a.tax_inclusive, false) AS tax_inclusive,
      CASE WHEN coalesce(a.tax_inclusive, false) AND coalesce(a.gst_rate, 0) > 0
        THEN coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0) / (1 + a.gst_rate / 100)
        ELSE coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0) END AS taxable_value,
      coalesce(oi.quantity, 0) * coalesce(a.selling_price, 0) *
        CASE WHEN coalesce(a.tax_inclusive, false) THEN 1 ELSE 1 + coalesce(a.gst_rate, 0) / 100 END AS line_total
    FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id
    LEFT JOIN LATERAL public.customer_resolve_buyer_product_authority_v1(v_order.company_id, oi.product_id) a ON true
    WHERE oi.order_id = p_order_id
  ) q;
  IF jsonb_array_length(v_lines) = 0 THEN RAISE EXCEPTION 'ORDER_HAS_NO_COMMERCIAL_LINES' USING ERRCODE = 'P0001'; END IF;
  RETURN jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'source_channel', v_order.order_origin,
    'source_reference', v_source_reference,
    'company_id', v_company.id, 'company_name', v_company.business_name, 'branch_reference', null, 'contact_reference', null,
    'payment_terms', v_company.payment_terms, 'requested_dispatch_date', v_order.requested_dispatch_date,
    'lines', v_lines, 'packing_charge', 0, 'other_approved_charges', 0, 'discount_total', 0,
    'sales_order_value', v_order.sales_order_value, 'advance_required', v_order.advance_required,
    'advance_rule_version', 'advance-30pct-ceil-inr-500/v1');
END;
$$;

CREATE OR REPLACE FUNCTION public.create_sales_order_commercial_version_v1(
  p_order_id uuid, p_change_reason text, p_correlation_id text, p_idempotency_key text, p_actor_id uuid DEFAULT auth.uid()
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_existing uuid; v_order public.orders%rowtype; v_snapshot jsonb; v_version int; v_id uuid;
BEGIN
  IF nullif(btrim(p_change_reason), '') IS NULL OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'COMMERCIAL_VERSION_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('so-commercial-version:' || p_order_id::text, 0));
  SELECT id INTO v_existing FROM public.sales_order_commercial_versions
   WHERE idempotency_key = p_idempotency_key AND order_id = p_order_id;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  IF EXISTS (SELECT 1 FROM public.sales_order_commercial_versions WHERE idempotency_key = p_idempotency_key) THEN
    RAISE EXCEPTION 'COMMERCIAL_VERSION_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  v_snapshot := public.build_sales_order_commercial_snapshot_v1(p_order_id);
  SELECT coalesce(max(version_number), 0) + 1 INTO v_version FROM public.sales_order_commercial_versions WHERE order_id = p_order_id;
  INSERT INTO public.sales_order_commercial_versions(order_id, version_number, supersedes_version_id, source_channel, source_reference,
    commercial_snapshot, previous_commercial_snapshot, snapshot_fingerprint, sales_order_value, advance_required, change_reason, correlation_id, idempotency_key, created_by)
  VALUES (p_order_id, v_version, (SELECT id FROM public.sales_order_commercial_versions WHERE order_id=p_order_id ORDER BY version_number DESC LIMIT 1),
    v_order.order_origin, v_snapshot->>'source_reference', v_snapshot,
    (SELECT commercial_snapshot FROM public.sales_order_commercial_versions WHERE order_id=p_order_id ORDER BY version_number DESC LIMIT 1), md5(v_snapshot::text),
    v_order.sales_order_value, v_order.advance_required, p_change_reason, p_correlation_id, p_idempotency_key, p_actor_id) RETURNING id INTO v_id;
  UPDATE public.orders SET commercial_current_version=v_version, commercial_versioned_at=statement_timestamp() WHERE id=p_order_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.build_sales_order_commercial_snapshot_v1(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_sales_order_commercial_version_v1(uuid, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_order_commercial_version_v1(uuid, text, text, text, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.promote_sales_order_draft_to_order_governed_v1(
  p_draft_id uuid, p_expected_extraction_request_key text, p_actor_id uuid,
  p_actor_name text, p_review_notes text DEFAULT NULL, p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (draft_id uuid, promoted_order_id uuid, order_number text, already_promoted boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
#variable_conflict use_column
DECLARE v_draft public.sales_order_drafts%rowtype; v_order_id uuid; v_order_number text;
  v_line record; v_qty numeric; v_lines int := 0;
BEGIN
  SELECT * INTO v_draft FROM public.sales_order_drafts d WHERE d.id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_draft.extraction_request_key IS DISTINCT FROM btrim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  IF v_draft.promoted_order_id IS NOT NULL THEN
    SELECT o.order_number INTO v_order_number FROM public.orders o WHERE o.id = v_draft.promoted_order_id;
    RETURN QUERY SELECT p_draft_id, v_draft.promoted_order_id, v_order_number, true; RETURN;
  END IF;
  IF v_draft.status <> 'UNDER_REVIEW' OR v_draft.company_id IS NULL THEN RAISE EXCEPTION 'DRAFT_NOT_READY' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.validate_sales_order_draft_readiness(v_draft.readiness_dimensions);
  PERFORM 1 FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id FOR UPDATE;
  SELECT count(*) INTO v_lines FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id
    AND l.product_id IS NOT NULL AND coalesce(l.operator_quantity, l.normalized_quantity, l.raw_quantity, 0) > 0;
  IF v_lines = 0 THEN RAISE EXCEPTION 'DRAFT_HAS_NO_VALID_LINES' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO public.orders(company_id, status, order_origin, payment_status, tracking_token)
  VALUES (v_draft.company_id, 'submitted', 'WHATSAPP', 'awaiting_receipt', encode(extensions.gen_random_bytes(16), 'hex'))
  RETURNING id, public.orders.order_number INTO v_order_id, v_order_number;
  FOR v_line IN SELECT l.* FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id ORDER BY l.line_index LOOP
    v_qty := coalesce(v_line.operator_quantity, v_line.normalized_quantity, v_line.raw_quantity, 0);
    IF v_line.product_id IS NOT NULL AND v_qty > 0 THEN
      INSERT INTO public.order_items(order_id, product_id, quantity, pack_size, notes)
      VALUES (v_order_id, v_line.product_id, v_qty, coalesce(v_line.normalized_unit, v_line.raw_unit), left(coalesce(v_line.product_name, ''), 500));
    END IF;
  END LOOP;
  PERFORM public.restore_order_financials(v_order_id);
  -- Establish the canonical draft link inside this transaction before freezing
  -- the version. The intermediate state is not visible outside the transaction.
  UPDATE public.sales_order_drafts d
     SET promoted_order_id = v_order_id, updated_by = p_actor_id, updated_at = statement_timestamp()
   WHERE d.id = p_draft_id;
  PERFORM public.create_sales_order_commercial_version_v1(
    v_order_id, 'WHATSAPP_DRAFT_PROMOTION', 'wa-draft:' || p_draft_id::text,
    'wa-so-version:' || p_draft_id::text, p_actor_id
  );
  UPDATE public.sales_order_drafts d SET status = 'APPROVED_FOR_SO',
    approver_id = p_actor_id, approver_name = p_actor_name, review_notes = p_review_notes,
    updated_by = p_actor_id, updated_at = statement_timestamp() WHERE d.id = p_draft_id;
  INSERT INTO public.sales_order_draft_audit_log(draft_id, action, from_status, to_status, actor_id, actor_name, metadata)
  VALUES (p_draft_id, 'APPROVE', 'UNDER_REVIEW', 'APPROVED_FOR_SO', p_actor_id, p_actor_name,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('promoted_order_id', v_order_id));
  INSERT INTO public.audit_logs(action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value)
  VALUES ('WA_DRAFT_PROMOTED_TO_SO', 'WhatsApp', 'orders', v_order_id::text, p_actor_id, 'high', jsonb_build_object('draft_id', p_draft_id));
  RETURN QUERY SELECT p_draft_id, v_order_id, v_order_number, false;
END;
$$;

REVOKE ALL ON FUNCTION public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb)
  TO service_role;

COMMENT ON FUNCTION public.build_sales_order_commercial_snapshot_v1(uuid) IS
  'Builds immutable source-neutral commercial truth; WhatsApp snapshots carry only the stable governed draft UUID reference and never raw message content.';
