-- Pre-Factory PF-4: source provenance and commercial authority are separate.
-- Historical LEGACY_ERP rows retain their historical semantics. New governed
-- sources use one commercial engine and persist an immutable version snapshot.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_order_origin_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_order_origin_check
  CHECK (order_origin IN ('LEGACY_ERP', 'CUSTOMER_APP', 'WHATSAPP', 'SALES', 'MANUAL', 'REPEAT_ORDER', 'APPROVED_QUOTE'));

COMMENT ON COLUMN public.orders.order_origin IS
  'Truthful intake provenance only. It must not select commercial policy for new governed Sales Orders.';

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS commercial_current_version integer,
  ADD COLUMN IF NOT EXISTS commercial_versioned_at timestamptz;

CREATE TABLE IF NOT EXISTS public.sales_order_commercial_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  version_number integer NOT NULL CHECK (version_number > 0),
  supersedes_version_id uuid REFERENCES public.sales_order_commercial_versions(id),
  source_channel text NOT NULL,
  source_reference text,
  commercial_snapshot jsonb NOT NULL,
  previous_commercial_snapshot jsonb,
  snapshot_fingerprint text NOT NULL,
  sales_order_value numeric NOT NULL CHECK (sales_order_value >= 0),
  advance_required numeric NOT NULL CHECK (advance_required >= 0),
  advance_rule_version text NOT NULL DEFAULT 'advance-30pct-ceil-inr-500/v1',
  change_reason text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (order_id, version_number),
  UNIQUE (idempotency_key)
);

ALTER TABLE public.sales_order_commercial_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sales_order_commercial_versions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.sales_order_commercial_versions TO authenticated, service_role;

CREATE TABLE public.sales_order_commercial_mutation_scopes (
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  order_id uuid NOT NULL REFERENCES public.orders(id),
  PRIMARY KEY (backend_pid, transaction_id, order_id)
);
ALTER TABLE public.sales_order_commercial_mutation_scopes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sales_order_commercial_mutation_scopes FROM PUBLIC, anon, authenticated, service_role;

CREATE POLICY sales_order_commercial_versions_internal_read
  ON public.sales_order_commercial_versions FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_sales_order_commercial_version_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'SALES_ORDER_COMMERCIAL_VERSION_IMMUTABLE' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_order_commercial_versions_immutable ON public.sales_order_commercial_versions;
CREATE TRIGGER trg_sales_order_commercial_versions_immutable
  BEFORE UPDATE OR DELETE ON public.sales_order_commercial_versions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_commercial_version_mutation();
REVOKE ALL ON FUNCTION public.prevent_sales_order_commercial_version_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.calculate_sales_order_advance_v1(p_sales_order_value numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN p_sales_order_value IS NULL OR p_sales_order_value <= 0 THEN 0::numeric
    ELSE ceil((p_sales_order_value * 0.30) / 500) * 500
  END;
$$;

COMMENT ON FUNCTION public.calculate_sales_order_advance_v1(numeric) IS
  'Canonical Pre-Factory advance: 30% of the approved SO value, rounded upward to the next INR 500 increment. Source-independent.';

CREATE OR REPLACE FUNCTION public.calculate_customer_advance_v1(p_sales_order_value numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$ SELECT public.calculate_sales_order_advance_v1(p_sales_order_value); $$;

REVOKE ALL ON FUNCTION public.calculate_sales_order_advance_v1(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calculate_sales_order_advance_v1(numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.recalculate_governed_sales_order_financials_v1(p_order_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_company_id uuid;
  v_line record;
  v_authority record;
  v_total numeric := 0;
  v_line_total numeric;
BEGIN
  SELECT company_id INTO v_company_id FROM public.orders WHERE id = p_order_id FOR UPDATE;
  -- Operational-only legacy rows can have order_items without an order/company.
  -- They are not Sales Orders and must neither receive canonical nor legacy finance.
  IF v_company_id IS NULL THEN RETURN 0; END IF;
  FOR v_line IN SELECT product_id, quantity FROM public.order_items WHERE order_id = p_order_id LOOP
    SELECT * INTO v_authority
      FROM public.customer_resolve_buyer_product_authority_v1(v_company_id, v_line.product_id);
    IF NOT coalesce(v_authority.is_available, false) THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE: product % is not commercially available', v_line.product_id USING ERRCODE = 'P0001';
    END IF;
    v_line_total := coalesce(v_line.quantity, 0) * coalesce(v_authority.selling_price, 0);
    IF NOT coalesce(v_authority.tax_inclusive, false) THEN
      v_line_total := v_line_total * (1 + coalesce(v_authority.gst_rate, 0) / 100);
    END IF;
    v_total := v_total + v_line_total;
  END LOOP;
  v_total := round(v_total, 2);
  UPDATE public.orders
     SET sales_order_value = v_total,
         advance_required = public.calculate_sales_order_advance_v1(v_total)
   WHERE id = p_order_id;
  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.recalculate_governed_sales_order_financials_v1(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.recalculate_customer_app_order_financials(p_order_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_origin text;
BEGIN
  SELECT order_origin INTO v_origin FROM public.orders WHERE id = p_order_id;
  IF v_origin IS DISTINCT FROM 'CUSTOMER_APP' THEN
    RAISE EXCEPTION 'ORDER_SOURCE_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  RETURN public.recalculate_governed_sales_order_financials_v1(p_order_id);
END;
$$;

REVOKE ALL ON FUNCTION public.recalculate_customer_app_order_financials(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recalculate_customer_app_order_financials(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.recalculate_erp_order_financials()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_order_id uuid; v_origin text; v_subtotal numeric := 0; v_total numeric := 0;
BEGIN
  v_order_id := CASE WHEN tg_op = 'DELETE' THEN old.order_id ELSE new.order_id END;
  SELECT order_origin INTO v_origin FROM public.orders WHERE id = v_order_id;
  IF v_origin IS DISTINCT FROM 'LEGACY_ERP' THEN
    PERFORM public.recalculate_governed_sales_order_financials_v1(v_order_id);
    RETURN CASE WHEN tg_op = 'DELETE' THEN old ELSE new END;
  END IF;
  -- Retain the historical-only calculation; no new governed SO is created with this provenance.
  SELECT coalesce(sum(coalesce(oi.quantity, 0) * coalesce(p.price_per_kg, p.base_price, p.price_b2b, p.price_wholesale, p.wholesale_price, 0)), 0)
    INTO v_subtotal
    FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id
   WHERE oi.order_id = v_order_id;
  v_total := v_subtotal * 1.18;
  UPDATE public.orders SET sales_order_value = v_total, advance_required = v_total * 0.5 WHERE id = v_order_id;
  RETURN CASE WHEN tg_op = 'DELETE' THEN old ELSE new END;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_order_financials(_order_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_origin text; v_subtotal numeric := 0; v_total numeric := 0;
BEGIN
  SELECT order_origin INTO v_origin FROM public.orders WHERE id = _order_id;
  IF v_origin IS DISTINCT FROM 'LEGACY_ERP' THEN
    RETURN public.recalculate_governed_sales_order_financials_v1(_order_id);
  END IF;
  SELECT coalesce(sum(coalesce(oi.quantity, 0) * coalesce(p.price_per_kg, p.base_price, p.price_b2b, p.price_wholesale, p.wholesale_price, 0)), 0)
    INTO v_subtotal
    FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id
   WHERE oi.order_id = _order_id;
  v_total := v_subtotal * 1.18;
  UPDATE public.orders SET sales_order_value = v_total, advance_required = v_total * 0.5 WHERE id = _order_id;
  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.restore_order_financials(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.restore_order_financials(uuid) TO service_role;

-- Keep the established WhatsApp draft-promotion contract, but make provenance
-- truthful and send the resulting SO through the shared commercial engine.
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
  PERFORM public.create_sales_order_commercial_version_v1(
    v_order_id, 'WHATSAPP_DRAFT_PROMOTION', 'wa-draft:' || p_draft_id::text,
    'wa-so-version:' || p_draft_id::text, p_actor_id
  );
  UPDATE public.sales_order_drafts d SET status = 'APPROVED_FOR_SO', promoted_order_id = v_order_id,
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
REVOKE ALL ON FUNCTION public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.build_sales_order_commercial_snapshot_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_order public.orders%rowtype; v_company public.companies%rowtype; v_line record; v_authority record;
  v_lines jsonb := '[]'::jsonb; v_line_total numeric; v_taxable numeric; v_tax numeric;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_company FROM public.companies WHERE id = v_order.company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_COMPANY_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  FOR v_line IN SELECT oi.*, p.sku, p.product_name FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id WHERE oi.order_id = p_order_id ORDER BY oi.id LOOP
    SELECT * INTO v_authority FROM public.customer_resolve_buyer_product_authority_v1(v_order.company_id, v_line.product_id);
    IF NOT coalesce(v_authority.is_available, false) THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE' USING ERRCODE = 'P0001'; END IF;
    v_taxable := coalesce(v_line.quantity, 0) * coalesce(v_authority.selling_price, 0);
    v_line_total := v_taxable;
    IF NOT coalesce(v_authority.tax_inclusive, false) THEN v_line_total := v_line_total * (1 + coalesce(v_authority.gst_rate, 0) / 100); END IF;
    v_tax := round(v_line_total - v_taxable, 2);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('order_item_id', v_line.id, 'product_id', v_line.product_id,
      'sku', v_line.sku, 'product_name', v_line.product_name, 'quantity', v_line.quantity, 'uom', coalesce(v_line.pack_size, v_authority.uom),
      'pack_size', v_line.pack_size, 'carton_type', v_line.carton_type, 'unit_price', v_authority.selling_price,
      'discount_amount', 0, 'taxable_value', round(v_taxable, 2), 'tax_amount', v_tax,
      'currency', v_authority.currency, 'gst_rate', v_authority.gst_rate, 'tax_inclusive', v_authority.tax_inclusive, 'line_total', round(v_line_total, 2)));
  END LOOP;
  IF jsonb_array_length(v_lines) = 0 THEN RAISE EXCEPTION 'ORDER_HAS_NO_COMMERCIAL_LINES' USING ERRCODE = 'P0001'; END IF;
  RETURN jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number, 'source_channel', v_order.order_origin,
    'source_reference', coalesce(v_order.checkout_idempotency_key, v_order.order_number),
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
    v_order.order_origin, coalesce(v_order.checkout_idempotency_key, v_order.order_number), v_snapshot,
    (SELECT commercial_snapshot FROM public.sales_order_commercial_versions WHERE order_id=p_order_id ORDER BY version_number DESC LIMIT 1), md5(v_snapshot::text),
    v_order.sales_order_value, v_order.advance_required, p_change_reason, p_correlation_id, p_idempotency_key, p_actor_id) RETURNING id INTO v_id;
  UPDATE public.orders SET commercial_current_version=v_version, commercial_versioned_at=statement_timestamp() WHERE id=p_order_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.build_sales_order_commercial_snapshot_v1(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_sales_order_commercial_version_v1(uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_sales_order_commercial_version_v1(uuid, text, text, text, uuid) TO service_role;

-- Customer checkout is already idempotent at its draft/checkout boundary. Create the
-- corresponding commercial version only after that governed promotion has completed.
CREATE OR REPLACE FUNCTION public.capture_customer_checkout_commercial_version_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF new.status = 'promoted' AND old.status IS DISTINCT FROM 'promoted' AND new.promoted_order_id IS NOT NULL THEN
    PERFORM public.create_sales_order_commercial_version_v1(
      new.promoted_order_id,
      'CUSTOMER_CHECKOUT_PROMOTION',
      'customer-draft:' || new.id::text,
      'customer-so-version:' || new.promoted_order_id::text,
      new.created_by
    );
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_checkout_commercial_version ON public.customer_order_drafts;
CREATE TRIGGER trg_customer_checkout_commercial_version
  AFTER UPDATE OF status, promoted_order_id ON public.customer_order_drafts
  FOR EACH ROW EXECUTE FUNCTION public.capture_customer_checkout_commercial_version_v1();
REVOKE ALL ON FUNCTION public.capture_customer_checkout_commercial_version_v1() FROM PUBLIC, anon, authenticated, service_role;

-- No direct commercial-line edits are permitted after a version exists. The governed
-- amendment RPC below opens a transaction-local capability for its own replacement.
CREATE OR REPLACE FUNCTION public.prevent_unversioned_sales_order_commercial_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_order_id uuid; v_version integer;
BEGIN
  v_order_id := CASE WHEN tg_op = 'DELETE' THEN old.order_id ELSE new.order_id END;
  SELECT commercial_current_version INTO v_version FROM public.orders WHERE id = v_order_id;
  IF v_version IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.sales_order_commercial_mutation_scopes s
        WHERE s.backend_pid = pg_backend_pid() AND s.transaction_id = txid_current() AND s.order_id = v_order_id
     )
     AND (tg_op IN ('INSERT', 'DELETE') OR old.product_id IS DISTINCT FROM new.product_id
          OR old.quantity IS DISTINCT FROM new.quantity OR old.pack_size IS DISTINCT FROM new.pack_size
          OR old.carton_type IS DISTINCT FROM new.carton_type) THEN
    RAISE EXCEPTION 'DIRECT_COMMERCIAL_LINE_MUTATION_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  RETURN CASE WHEN tg_op = 'DELETE' THEN old ELSE new END;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_governed_commercial_mutation ON public.order_items;
CREATE TRIGGER trg_order_items_governed_commercial_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.prevent_unversioned_sales_order_commercial_mutation();
REVOKE ALL ON FUNCTION public.prevent_unversioned_sales_order_commercial_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.amend_sales_order_commercial_v1(
  p_order_id uuid,
  p_expected_version integer,
  p_lines jsonb,
  p_reason text,
  p_correlation_id text,
  p_idempotency_key text
) RETURNS TABLE(order_id uuid, version_number integer, commercial_version_id uuid, already_applied boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := auth.uid(); v_order public.orders%rowtype; v_existing public.sales_order_commercial_versions%rowtype;
  v_version_id uuid; v_line record; v_count integer := 0;
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'COMMERCIAL_AMENDMENT_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_expected_version IS NULL OR p_expected_version < 1 OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
     OR nullif(btrim(p_reason), '') IS NULL OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'COMMERCIAL_AMENDMENT_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('so-commercial-amendment:' || p_order_id::text, 0));
  SELECT v.* INTO v_existing FROM public.sales_order_commercial_versions v
   WHERE v.idempotency_key = p_idempotency_key AND v.order_id = p_order_id;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.order_id, v_existing.version_number, v_existing.id, true; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_order_commercial_versions v WHERE v.idempotency_key = p_idempotency_key) THEN
    RAISE EXCEPTION 'COMMERCIAL_VERSION_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_order.commercial_current_version IS DISTINCT FROM p_expected_version THEN
    RAISE EXCEPTION 'STALE_SALES_ORDER_VERSION' USING ERRCODE = '40001';
  END IF;
  IF v_order.order_origin = 'LEGACY_ERP' THEN
    RAISE EXCEPTION 'HISTORICAL_LEGACY_ORDER_AMENDMENT_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.sales_order_commercial_mutation_scopes(backend_pid, transaction_id, order_id)
  VALUES (pg_backend_pid(), txid_current(), p_order_id);
  DELETE FROM public.order_items oi WHERE oi.order_id = p_order_id;
  FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(product_id uuid, quantity numeric, pack_size text, carton_type text, notes text) LOOP
    IF v_line.product_id IS NULL OR v_line.quantity IS NULL OR v_line.quantity <= 0 THEN
      RAISE EXCEPTION 'INVALID_COMMERCIAL_LINE' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.order_items(order_id, product_id, quantity, pack_size, carton_type, notes)
    VALUES (p_order_id, v_line.product_id, v_line.quantity, nullif(btrim(v_line.pack_size), ''),
      nullif(btrim(v_line.carton_type), ''), nullif(left(v_line.notes, 500), ''));
    v_count := v_count + 1;
  END LOOP;
  IF v_count = 0 THEN RAISE EXCEPTION 'ORDER_HAS_NO_COMMERCIAL_LINES' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.recalculate_governed_sales_order_financials_v1(p_order_id);
  v_version_id := public.create_sales_order_commercial_version_v1(p_order_id, p_reason, p_correlation_id, p_idempotency_key, v_actor);
  DELETE FROM public.sales_order_commercial_mutation_scopes s
   WHERE s.backend_pid = pg_backend_pid() AND s.transaction_id = txid_current() AND s.order_id = p_order_id;
  RETURN QUERY SELECT p_order_id, p_expected_version + 1, v_version_id, false;
END;
$$;

REVOKE ALL ON FUNCTION public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text) TO authenticated;
