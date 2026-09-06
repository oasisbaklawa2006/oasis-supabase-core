-- P106-CORE-QUOTE-01: governed customer quotation authority.
--
-- Census (20260906140000):
--   customer_quotations / customer_quotation_versions / customer_quotation_lines —
--     absent; no quotation/estimate/proposal tables in active Core authority.
--   commercial_document_number_counters — SO/PI only; QT added here.
--   orders.order_origin APPROVED_QUOTE — intake provenance exists (PF-4) but no
--     governed quotation lifecycle or customer-safe projections.
--   customer_order_drafts — buyer cart/checkout only; not a quotation model.
--   sales_order_commercial_versions — SO commercial snapshots; not quotations.
--
-- Stacks strictly after migration train #209→#215→#226→#228 (20260906130000).
-- Customer contracts: customer_quotations_v1, customer_quotation_detail_v1,
-- customer_quotation_lines_v1, submit_customer_quotation_request_v1,
-- accept_customer_quotation_v1, decline_customer_quotation_v1.
-- accept creates only a governed P107 handoff; no shadow Sales Order path.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- -----------------------------------------------------------------------------
-- Governed quotation schema
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.customer_quotations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  quotation_number text NOT NULL,
  status text NOT NULL DEFAULT 'issued'
    CHECK (status IN ('issued', 'accepted', 'declined', 'expired', 'superseded')),
  current_version integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
  expires_at timestamptz NOT NULL,
  request_idempotency_key text NOT NULL,
  request_notes text,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT uq_customer_quotations_number UNIQUE (quotation_number),
  CONSTRAINT uq_customer_quotations_company_idempotency UNIQUE (company_id, request_idempotency_key)
);

COMMENT ON TABLE public.customer_quotations IS
  'Buyer-company quotation spine. Mutations via governed RPCs only; company isolation enforced server-side.';

CREATE INDEX IF NOT EXISTS idx_customer_quotations_company_status
  ON public.customer_quotations (company_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.customer_quotation_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL REFERENCES public.customer_quotations(id),
  version_number integer NOT NULL CHECK (version_number > 0),
  supersedes_version_id uuid REFERENCES public.customer_quotation_versions(id),
  quotation_value numeric NOT NULL CHECK (quotation_value >= 0),
  advance_required numeric NOT NULL CHECK (advance_required >= 0),
  commercial_snapshot jsonb NOT NULL,
  terms_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  issued_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  expires_at timestamptz NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT uq_customer_quotation_versions_quotation_version UNIQUE (quotation_id, version_number),
  CONSTRAINT uq_customer_quotation_versions_idempotency UNIQUE (idempotency_key)
);

COMMENT ON TABLE public.customer_quotation_versions IS
  'Immutable versioned commercial snapshots for customer quotations. Append-only; revisions create new rows.';

CREATE TABLE IF NOT EXISTS public.customer_quotation_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id uuid NOT NULL REFERENCES public.customer_quotation_versions(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id),
  quantity numeric NOT NULL CHECK (quantity > 0),
  unit_price numeric NOT NULL CHECK (unit_price >= 0),
  line_total numeric NOT NULL CHECK (line_total >= 0),
  currency text NOT NULL DEFAULT 'INR',
  uom text,
  gst_rate numeric,
  tax_inclusive boolean NOT NULL DEFAULT false,
  minimum_order_quantity numeric,
  order_increment numeric,
  min_carton_qty numeric,
  sku text,
  product_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT uq_customer_quotation_lines_version_product UNIQUE (version_id, product_id)
);

COMMENT ON TABLE public.customer_quotation_lines IS
  'Denormalized line facts per quotation version for customer-safe projections.';

CREATE TABLE IF NOT EXISTS public.customer_quotation_acceptance_handoffs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL REFERENCES public.customer_quotations(id),
  quotation_version_id uuid NOT NULL REFERENCES public.customer_quotation_versions(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  idempotency_key text NOT NULL,
  handoff_status text NOT NULL DEFAULT 'pending'
    CHECK (handoff_status IN ('pending', 'consumed', 'cancelled')),
  commercial_snapshot jsonb NOT NULL,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CONSTRAINT uq_customer_quotation_handoffs_quotation UNIQUE (quotation_id),
  CONSTRAINT uq_customer_quotation_handoffs_company_idempotency UNIQUE (company_id, idempotency_key)
);

COMMENT ON TABLE public.customer_quotation_acceptance_handoffs IS
  'Governed P107 handoff surface. Acceptance records intent only; no Sales Order is created here.';

CREATE TABLE IF NOT EXISTS public.customer_quotation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL REFERENCES public.customer_quotations(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  event_type text NOT NULL
    CHECK (event_type IN ('REQUESTED', 'REVISED', 'ACCEPTED', 'DECLINED', 'EXPIRED')),
  actor_id uuid REFERENCES auth.users(id),
  version_number integer,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  correlation_id text,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

COMMENT ON TABLE public.customer_quotation_events IS
  'Append-only quotation lifecycle audit trail.';

-- Immutability guards
CREATE OR REPLACE FUNCTION public.prevent_customer_quotation_version_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'CUSTOMER_QUOTATION_VERSION_IMMUTABLE' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_quotation_versions_immutable ON public.customer_quotation_versions;
CREATE TRIGGER trg_customer_quotation_versions_immutable
  BEFORE UPDATE OR DELETE ON public.customer_quotation_versions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_quotation_version_mutation();

CREATE OR REPLACE FUNCTION public.prevent_customer_quotation_line_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'CUSTOMER_QUOTATION_LINE_IMMUTABLE' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_quotation_lines_immutable ON public.customer_quotation_lines;
CREATE TRIGGER trg_customer_quotation_lines_immutable
  BEFORE UPDATE OR DELETE ON public.customer_quotation_lines
  FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_quotation_line_mutation();

CREATE OR REPLACE FUNCTION public.prevent_customer_quotation_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'CUSTOMER_QUOTATION_EVENT_IMMUTABLE' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_quotation_events_immutable ON public.customer_quotation_events;
CREATE TRIGGER trg_customer_quotation_events_immutable
  BEFORE UPDATE OR DELETE ON public.customer_quotation_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_quotation_event_mutation();

-- RLS: company-scoped read; no direct client writes
ALTER TABLE public.customer_quotations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_quotation_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_quotation_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_quotation_acceptance_handoffs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_quotation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_quotations_buyer_select ON public.customer_quotations;
CREATE POLICY customer_quotations_buyer_select ON public.customer_quotations
  FOR SELECT TO authenticated
  USING (company_id = public.customer_buyer_eligible_company_id());

DROP POLICY IF EXISTS customer_quotation_versions_buyer_select ON public.customer_quotation_versions;
CREATE POLICY customer_quotation_versions_buyer_select ON public.customer_quotation_versions
  FOR SELECT TO authenticated
  USING (
    quotation_id IN (
      SELECT q.id FROM public.customer_quotations q
      WHERE q.company_id = public.customer_buyer_eligible_company_id()
    )
  );

DROP POLICY IF EXISTS customer_quotation_lines_buyer_select ON public.customer_quotation_lines;
CREATE POLICY customer_quotation_lines_buyer_select ON public.customer_quotation_lines
  FOR SELECT TO authenticated
  USING (
    version_id IN (
      SELECT v.id
      FROM public.customer_quotation_versions v
      JOIN public.customer_quotations q ON q.id = v.quotation_id
      WHERE q.company_id = public.customer_buyer_eligible_company_id()
    )
  );

DROP POLICY IF EXISTS customer_quotation_handoffs_buyer_select ON public.customer_quotation_acceptance_handoffs;
CREATE POLICY customer_quotation_handoffs_buyer_select ON public.customer_quotation_acceptance_handoffs
  FOR SELECT TO authenticated
  USING (company_id = public.customer_buyer_eligible_company_id());

DROP POLICY IF EXISTS customer_quotation_events_buyer_select ON public.customer_quotation_events;
CREATE POLICY customer_quotation_events_buyer_select ON public.customer_quotation_events
  FOR SELECT TO authenticated
  USING (company_id = public.customer_buyer_eligible_company_id());

REVOKE INSERT, UPDATE, DELETE ON public.customer_quotations FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.customer_quotation_versions FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.customer_quotation_lines FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.customer_quotation_acceptance_handoffs FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.customer_quotation_events FROM anon, authenticated;

GRANT SELECT ON public.customer_quotations TO authenticated;
GRANT SELECT ON public.customer_quotation_versions TO authenticated;
GRANT SELECT ON public.customer_quotation_lines TO authenticated;
GRANT SELECT ON public.customer_quotation_acceptance_handoffs TO authenticated;
GRANT SELECT ON public.customer_quotation_events TO authenticated;

GRANT ALL ON public.customer_quotations TO service_role;
GRANT ALL ON public.customer_quotation_versions TO service_role;
GRANT ALL ON public.customer_quotation_lines TO service_role;
GRANT ALL ON public.customer_quotation_acceptance_handoffs TO service_role;
GRANT ALL ON public.customer_quotation_events TO service_role;

-- -----------------------------------------------------------------------------
-- Canonical QT document numbering (extends APP-E2E allocator)
-- -----------------------------------------------------------------------------

ALTER TABLE public.commercial_document_number_counters
  DROP CONSTRAINT IF EXISTS commercial_document_number_counters_document_kind_check;

ALTER TABLE public.commercial_document_number_counters
  ADD CONSTRAINT commercial_document_number_counters_document_kind_check
  CHECK (document_kind IN ('SO', 'PI', 'QT'));

CREATE OR REPLACE FUNCTION public.allocate_commercial_document_number_v1(p_document_kind text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_kind text := upper(btrim(coalesce(p_document_kind, '')));
  v_business_period text := to_char(statement_timestamp() AT TIME ZONE 'Asia/Kolkata', 'YYYY/MM');
  v_existing_max integer := 0;
  v_next integer;
  v_limit integer;
BEGIN
  IF v_kind NOT IN ('SO', 'PI', 'QT') THEN
    RAISE EXCEPTION 'COMMERCIAL_DOCUMENT_KIND_INVALID' USING ERRCODE = '22023';
  END IF;

  v_limit := CASE v_kind WHEN 'SO' THEN 9999 WHEN 'PI' THEN 999 ELSE 9999 END;
  PERFORM pg_advisory_xact_lock(hashtextextended('commercial-document-number:' || v_kind || ':' || v_business_period, 0));

  IF v_kind = 'SO' THEN
    SELECT coalesce(max((regexp_match(o.order_number, '^SO' || v_business_period || '-([0-9]{4})$'))[1]::integer), 0)
      INTO v_existing_max
      FROM public.orders o
     WHERE o.order_number ~ ('^SO' || v_business_period || '-[0-9]{4}$');
  ELSIF v_kind = 'PI' THEN
    SELECT coalesce(max((regexp_match(p.customer_visible_pi_number, '^PI' || v_business_period || '-([0-9]{3})$'))[1]::integer), 0)
      INTO v_existing_max
      FROM public.sales_order_proforma_invoices p
     WHERE p.customer_visible_pi_number ~ ('^PI' || v_business_period || '-[0-9]{3}$');
  ELSE
    SELECT coalesce(max((regexp_match(q.quotation_number, '^QT' || v_business_period || '-([0-9]{4})$'))[1]::integer), 0)
      INTO v_existing_max
      FROM public.customer_quotations q
     WHERE q.quotation_number ~ ('^QT' || v_business_period || '-[0-9]{4}$');
  END IF;

  INSERT INTO public.commercial_document_number_counters(document_kind, business_period, last_value)
  VALUES (v_kind, v_business_period, v_existing_max)
  ON CONFLICT (document_kind, business_period) DO UPDATE
    SET last_value = greatest(public.commercial_document_number_counters.last_value, EXCLUDED.last_value),
        updated_at = statement_timestamp();

  UPDATE public.commercial_document_number_counters
     SET last_value=last_value+1,
         updated_at=statement_timestamp()
   WHERE document_kind=v_kind
     AND business_period=v_business_period
     AND last_value<v_limit
  RETURNING last_value INTO v_next;

  IF v_next IS NULL THEN
    RAISE EXCEPTION '%_MONTHLY_SEQUENCE_EXHAUSTED: %', v_kind, v_business_period USING ERRCODE = '54000';
  END IF;

  RETURN CASE v_kind
    WHEN 'SO' THEN 'SO'||v_business_period||'-'||lpad(v_next::text,4,'0')
    WHEN 'PI' THEN 'PI'||v_business_period||'-'||lpad(v_next::text,3,'0')
    ELSE 'QT'||v_business_period||'-'||lpad(v_next::text,4,'0')
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.allocate_commercial_document_number_v1(text)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.allocate_commercial_document_number_v1(text) IS
  'Private transactional allocator for SO, PI, and QT document kinds. QT added by P106-CORE-QUOTE-01.';

-- -----------------------------------------------------------------------------
-- Internal helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.customer_quotation_default_expiry_v1()
RETURNS timestamptz
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT (statement_timestamp() AT TIME ZONE 'Asia/Kolkata' + interval '30 days')
    AT TIME ZONE 'Asia/Kolkata';
$$;

REVOKE ALL ON FUNCTION public.customer_quotation_default_expiry_v1() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_quotation_is_actionable_v1(
  p_status text,
  p_expires_at timestamptz
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT lower(btrim(coalesce(p_status, ''))) = 'issued'
    AND p_expires_at > statement_timestamp();
$$;

REVOKE ALL ON FUNCTION public.customer_quotation_is_actionable_v1(text, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_assert_quotation_company_scope_v1(p_quotation_id uuid)
RETURNS public.customer_quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_company_id uuid;
  v_row public.customer_quotations%rowtype;
BEGIN
  v_company_id := public.customer_buyer_eligible_company_id();
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'BUYER_NOT_ELIGIBLE' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.customer_quotations q
  WHERE q.id = p_quotation_id
    AND q.company_id = v_company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QUOTATION_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_assert_quotation_company_scope_v1(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_build_quotation_lines_v1(
  p_company_id uuid,
  p_lines jsonb
)
RETURNS TABLE(
  product_id uuid,
  quantity numeric,
  unit_price numeric,
  line_total numeric,
  currency text,
  uom text,
  gst_rate numeric,
  tax_inclusive boolean,
  minimum_order_quantity numeric,
  order_increment numeric,
  min_carton_qty numeric,
  sku text,
  product_name text,
  line_snapshot jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric;
  v_auth record;
  v_line_base numeric;
  v_line_total numeric;
BEGIN
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'QUOTATION_LINES_REQUIRED' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;

    IF v_product_id IS NULL OR v_quantity IS NULL OR v_quantity <= 0 THEN
      RAISE EXCEPTION 'QUOTATION_LINE_INVALID' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_auth
    FROM public.customer_resolve_buyer_product_authority_v1(p_company_id, v_product_id);

    IF NOT coalesce(v_auth.is_available, false) THEN
      RAISE EXCEPTION 'PRODUCT_UNAVAILABLE: product % is not commercially available', v_product_id
        USING ERRCODE = 'P0001';
    END IF;

    IF NOT public.customer_validate_order_quantity_v1(
      v_quantity,
      v_auth.minimum_order_quantity,
      v_auth.order_increment,
      v_auth.min_carton_qty
    ) THEN
      RAISE EXCEPTION 'QUANTITY_RULE_VIOLATION: product % failed MOQ/increment/carton validation', v_product_id
        USING ERRCODE = 'P0001';
    END IF;

    v_line_base := v_quantity * coalesce(v_auth.selling_price, 0);
    IF coalesce(v_auth.tax_inclusive, false) THEN
      v_line_total := v_line_base;
    ELSE
      v_line_total := v_line_base * (1 + coalesce(v_auth.gst_rate, 0) / 100);
    END IF;
    v_line_total := round(v_line_total, 2);

    product_id := v_product_id;
    quantity := v_quantity;
    unit_price := v_auth.selling_price;
    line_total := v_line_total;
    currency := coalesce(v_auth.currency, 'INR');
    uom := v_auth.uom;
    gst_rate := v_auth.gst_rate;
    tax_inclusive := coalesce(v_auth.tax_inclusive, false);
    minimum_order_quantity := v_auth.minimum_order_quantity;
    order_increment := v_auth.order_increment;
    min_carton_qty := v_auth.min_carton_qty;
    sku := v_auth.sku;
    product_name := v_auth.product_name;
    line_snapshot := jsonb_build_object(
      'product_id', v_product_id,
      'quantity', v_quantity,
      'selling_price', v_auth.selling_price,
      'currency', v_auth.currency,
      'uom', v_auth.uom,
      'gst_rate', v_auth.gst_rate,
      'tax_inclusive', v_auth.tax_inclusive,
      'sku', v_auth.sku,
      'product_name', v_auth.product_name,
      'minimum_order_quantity', v_auth.minimum_order_quantity,
      'order_increment', v_auth.order_increment,
      'min_carton_qty', v_auth.min_carton_qty,
      'line_total', v_line_total
    );
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_build_quotation_lines_v1(uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- submit_customer_quotation_request_v1
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.submit_customer_quotation_request_v1(
  p_idempotency_key text,
  p_lines jsonb,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(
  quotation_id uuid,
  quotation_number text,
  version_number integer,
  quotation_value numeric,
  advance_required numeric,
  status text,
  expires_at timestamptz,
  already_applied boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_existing public.customer_quotations%rowtype;
  v_version public.customer_quotation_versions%rowtype;
  v_quotation_id uuid;
  v_quotation_number text;
  v_expires_at timestamptz;
  v_total numeric := 0;
  v_advance numeric;
  v_snapshot jsonb := '[]'::jsonb;
  v_line record;
  v_version_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF coalesce(btrim(p_idempotency_key), '') = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  v_company_id := public.customer_buyer_eligible_company_id();
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'BUYER_NOT_ELIGIBLE' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('customer_quotation_request:' || v_company_id::text || ':' || btrim(p_idempotency_key), 0)
  );

  SELECT * INTO v_existing
  FROM public.customer_quotations q
  WHERE q.company_id = v_company_id
    AND q.request_idempotency_key = btrim(p_idempotency_key);

  IF FOUND THEN
    SELECT * INTO v_version
    FROM public.customer_quotation_versions v
    WHERE v.quotation_id = v_existing.id
      AND v.version_number = v_existing.current_version;

    RETURN QUERY SELECT
      v_existing.id,
      v_existing.quotation_number,
      v_existing.current_version,
      v_version.quotation_value,
      v_version.advance_required,
      v_existing.status,
      v_existing.expires_at,
      true;
    RETURN;
  END IF;

  v_expires_at := public.customer_quotation_default_expiry_v1();

  FOR v_line IN
    SELECT * FROM public.customer_build_quotation_lines_v1(v_company_id, p_lines)
  LOOP
    v_total := v_total + v_line.line_total;
    v_snapshot := v_snapshot || v_line.line_snapshot;
  END LOOP;

  v_total := round(v_total, 2);
  v_advance := public.calculate_customer_advance_v1(v_total);
  v_quotation_number := public.allocate_commercial_document_number_v1('QT');

  INSERT INTO public.customer_quotations (
    company_id, quotation_number, status, current_version, expires_at,
    request_idempotency_key, request_notes, created_by
  ) VALUES (
    v_company_id, v_quotation_number, 'issued', 1, v_expires_at,
    btrim(p_idempotency_key), nullif(btrim(p_notes), ''), v_uid
  )
  RETURNING id INTO v_quotation_id;

  INSERT INTO public.customer_quotation_versions (
    quotation_id, version_number, quotation_value, advance_required,
    commercial_snapshot, terms_snapshot, issued_at, expires_at,
    correlation_id, idempotency_key, created_by
  ) VALUES (
    v_quotation_id, 1, v_total, v_advance,
    v_snapshot,
    jsonb_build_object('validity_days', 30, 'currency', 'INR'),
    statement_timestamp(), v_expires_at,
    btrim(p_idempotency_key), 'submit:' || v_quotation_id::text || ':v1', v_uid
  )
  RETURNING id INTO v_version_id;

  FOR v_line IN
    SELECT * FROM public.customer_build_quotation_lines_v1(v_company_id, p_lines)
  LOOP
    INSERT INTO public.customer_quotation_lines (
      version_id, product_id, quantity, unit_price, line_total,
      currency, uom, gst_rate, tax_inclusive,
      minimum_order_quantity, order_increment, min_carton_qty,
      sku, product_name
    ) VALUES (
      v_version_id, v_line.product_id, v_line.quantity, v_line.unit_price, v_line.line_total,
      v_line.currency, v_line.uom, v_line.gst_rate, v_line.tax_inclusive,
      v_line.minimum_order_quantity, v_line.order_increment, v_line.min_carton_qty,
      v_line.sku, v_line.product_name
    );
  END LOOP;

  INSERT INTO public.customer_quotation_events (
    quotation_id, company_id, event_type, actor_id, version_number, detail, correlation_id
  ) VALUES (
    v_quotation_id, v_company_id, 'REQUESTED', v_uid, 1,
    jsonb_build_object('line_count', jsonb_array_length(p_lines), 'notes', nullif(btrim(p_notes), '')),
    btrim(p_idempotency_key)
  );

  RETURN QUERY SELECT
    v_quotation_id,
    v_quotation_number,
    1,
    v_total,
    v_advance,
    'issued',
    v_expires_at,
    false;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_customer_quotation_request_v1(text, jsonb, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_customer_quotation_request_v1(text, jsonb, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.submit_customer_quotation_request_v1(text, jsonb, text) IS
  'Idempotent buyer quotation request. Resolves canonical pricing/MOQ/tax facts and issues version 1 with expiry.';

-- -----------------------------------------------------------------------------
-- revise_customer_quotation_v1 (service_role only — version bump for sales revision)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.revise_customer_quotation_v1(
  p_quotation_id uuid,
  p_lines jsonb,
  p_idempotency_key text,
  p_expires_at timestamptz DEFAULT NULL
)
RETURNS TABLE(
  quotation_id uuid,
  version_number integer,
  quotation_value numeric,
  status text,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_row public.customer_quotations%rowtype;
  v_new_version integer;
  v_version_id uuid;
  v_total numeric := 0;
  v_advance numeric;
  v_snapshot jsonb := '[]'::jsonb;
  v_line record;
  v_expires timestamptz;
  v_uid uuid := auth.uid();
BEGIN
  IF current_user NOT IN ('postgres', 'service_role') AND NOT public.is_internal_staff(v_uid) THEN
    RAISE EXCEPTION 'QUOTATION_REVISION_UNAUTHORIZED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.customer_quotations WHERE id = p_quotation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'QUOTATION_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF v_row.status NOT IN ('issued', 'superseded') THEN
    RAISE EXCEPTION 'QUOTATION_NOT_REVISABLE: status %', v_row.status USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.customer_quotation_acceptance_handoffs h
    WHERE h.quotation_id = p_quotation_id AND h.handoff_status = 'pending'
  ) THEN
    RAISE EXCEPTION 'QUOTATION_ACCEPTANCE_PENDING' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('customer_quotation_revise:' || p_quotation_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM public.customer_quotation_versions v
    WHERE v.idempotency_key = btrim(p_idempotency_key)
  ) THEN
    SELECT v.quotation_id, v.version_number, v.quotation_value, q.status, q.expires_at
    INTO quotation_id, version_number, quotation_value, status, expires_at
    FROM public.customer_quotation_versions v
    JOIN public.customer_quotations q ON q.id = v.quotation_id
    WHERE v.idempotency_key = btrim(p_idempotency_key);
    RETURN NEXT;
    RETURN;
  END IF;

  v_new_version := v_row.current_version + 1;
  v_expires := coalesce(p_expires_at, public.customer_quotation_default_expiry_v1());

  FOR v_line IN
    SELECT * FROM public.customer_build_quotation_lines_v1(v_row.company_id, p_lines)
  LOOP
    v_total := v_total + v_line.line_total;
    v_snapshot := v_snapshot || v_line.line_snapshot;
  END LOOP;

  v_total := round(v_total, 2);
  v_advance := public.calculate_customer_advance_v1(v_total);

  INSERT INTO public.customer_quotation_versions (
    quotation_id, version_number, supersedes_version_id,
    quotation_value, advance_required, commercial_snapshot, terms_snapshot,
    issued_at, expires_at, correlation_id, idempotency_key, created_by
  )
  SELECT
    p_quotation_id, v_new_version, prev.id,
    v_total, v_advance, v_snapshot,
    jsonb_build_object('validity_days', 30, 'currency', 'INR'),
    statement_timestamp(), v_expires, btrim(p_idempotency_key), btrim(p_idempotency_key), v_uid
  FROM public.customer_quotation_versions prev
  WHERE prev.quotation_id = p_quotation_id AND prev.version_number = v_row.current_version
  RETURNING id INTO v_version_id;

  FOR v_line IN
    SELECT * FROM public.customer_build_quotation_lines_v1(v_row.company_id, p_lines)
  LOOP
    INSERT INTO public.customer_quotation_lines (
      version_id, product_id, quantity, unit_price, line_total,
      currency, uom, gst_rate, tax_inclusive,
      minimum_order_quantity, order_increment, min_carton_qty,
      sku, product_name
    ) VALUES (
      v_version_id, v_line.product_id, v_line.quantity, v_line.unit_price, v_line.line_total,
      v_line.currency, v_line.uom, v_line.gst_rate, v_line.tax_inclusive,
      v_line.minimum_order_quantity, v_line.order_increment, v_line.min_carton_qty,
      v_line.sku, v_line.product_name
    );
  END LOOP;

  UPDATE public.customer_quotations
  SET status = 'issued',
      current_version = v_new_version,
      expires_at = v_expires,
      updated_at = statement_timestamp()
  WHERE id = p_quotation_id;

  INSERT INTO public.customer_quotation_events (
    quotation_id, company_id, event_type, actor_id, version_number, detail, correlation_id
  ) VALUES (
    p_quotation_id, v_row.company_id, 'REVISED', v_uid, v_new_version,
    jsonb_build_object('supersedes_version', v_row.current_version),
    btrim(p_idempotency_key)
  );

  RETURN QUERY SELECT p_quotation_id, v_new_version, v_total, 'issued', v_expires;
END;
$$;

REVOKE ALL ON FUNCTION public.revise_customer_quotation_v1(uuid, jsonb, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revise_customer_quotation_v1(uuid, jsonb, text, timestamptz)
  TO service_role;

-- -----------------------------------------------------------------------------
-- Customer-safe projections
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.customer_quotations_v1()
RETURNS TABLE(
  quotation_id uuid,
  quotation_number text,
  status text,
  current_version integer,
  quotation_value numeric,
  advance_required numeric,
  expires_at timestamptz,
  is_actionable boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  WITH buyer AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  ), current_versions AS (
    SELECT v.*
    FROM public.customer_quotation_versions v
    JOIN public.customer_quotations q ON q.id = v.quotation_id
    JOIN buyer b ON b.company_id = q.company_id
    WHERE v.version_number = q.current_version
  )
  SELECT
    q.id,
    q.quotation_number,
    CASE
      WHEN q.status = 'issued' AND q.expires_at <= statement_timestamp() THEN 'expired'
      ELSE q.status
    END,
    q.current_version,
    cv.quotation_value,
    cv.advance_required,
    q.expires_at,
    public.customer_quotation_is_actionable_v1(q.status, q.expires_at),
    q.created_at,
    q.updated_at
  FROM public.customer_quotations q
  JOIN buyer b ON b.company_id IS NOT NULL AND b.company_id = q.company_id
  JOIN current_versions cv ON cv.quotation_id = q.id
  ORDER BY q.created_at DESC, q.id;
$$;

REVOKE ALL ON FUNCTION public.customer_quotations_v1() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.customer_quotations_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_quotation_detail_v1(p_quotation_id uuid)
RETURNS TABLE(
  quotation_id uuid,
  quotation_number text,
  status text,
  current_version integer,
  version_id uuid,
  quotation_value numeric,
  advance_required numeric,
  expires_at timestamptz,
  is_actionable boolean,
  request_notes text,
  terms_snapshot jsonb,
  commercial_snapshot jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_row public.customer_quotations%rowtype;
  v_version public.customer_quotation_versions%rowtype;
BEGIN
  v_row := public.customer_assert_quotation_company_scope_v1(p_quotation_id);

  SELECT * INTO v_version
  FROM public.customer_quotation_versions v
  WHERE v.quotation_id = p_quotation_id
    AND v.version_number = v_row.current_version;

  RETURN QUERY SELECT
    v_row.id,
    v_row.quotation_number,
    CASE
      WHEN v_row.status = 'issued' AND v_row.expires_at <= statement_timestamp() THEN 'expired'
      ELSE v_row.status
    END,
    v_row.current_version,
    v_version.id,
    v_version.quotation_value,
    v_version.advance_required,
    v_row.expires_at,
    public.customer_quotation_is_actionable_v1(v_row.status, v_row.expires_at),
    v_row.request_notes,
    v_version.terms_snapshot,
    v_version.commercial_snapshot,
    v_row.created_at,
    v_row.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_quotation_detail_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.customer_quotation_detail_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_quotation_lines_v1(p_quotation_id uuid)
RETURNS TABLE(
  line_id uuid,
  product_id uuid,
  sku text,
  product_name text,
  quantity numeric,
  unit_price numeric,
  line_total numeric,
  currency text,
  uom text,
  gst_rate numeric,
  tax_inclusive boolean,
  minimum_order_quantity numeric,
  order_increment numeric,
  min_carton_qty numeric,
  version_number integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_row public.customer_quotations%rowtype;
BEGIN
  v_row := public.customer_assert_quotation_company_scope_v1(p_quotation_id);

  RETURN QUERY
  SELECT
    l.id,
    l.product_id,
    l.sku,
    l.product_name,
    l.quantity,
    l.unit_price,
    l.line_total,
    l.currency,
    l.uom,
    l.gst_rate,
    l.tax_inclusive,
    l.minimum_order_quantity,
    l.order_increment,
    l.min_carton_qty,
    v_row.current_version
  FROM public.customer_quotation_lines l
  JOIN public.customer_quotation_versions v ON v.id = l.version_id
  WHERE v.quotation_id = p_quotation_id
    AND v.version_number = v_row.current_version
  ORDER BY l.created_at, l.id;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_quotation_lines_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.customer_quotation_lines_v1(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- accept_customer_quotation_v1 / decline_customer_quotation_v1
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accept_customer_quotation_v1(
  p_quotation_id uuid,
  p_version_number integer,
  p_idempotency_key text
)
RETURNS TABLE(
  quotation_id uuid,
  handoff_id uuid,
  version_number integer,
  handoff_status text,
  already_applied boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.customer_quotations%rowtype;
  v_version public.customer_quotation_versions%rowtype;
  v_existing public.customer_quotation_acceptance_handoffs%rowtype;
  v_handoff_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF coalesce(btrim(p_idempotency_key), '') = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  v_row := public.customer_assert_quotation_company_scope_v1(p_quotation_id);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('customer_quotation_accept:' || v_row.company_id::text || ':' || btrim(p_idempotency_key), 0)
  );

  SELECT * INTO v_existing
  FROM public.customer_quotation_acceptance_handoffs h
  WHERE h.company_id = v_row.company_id
    AND h.idempotency_key = btrim(p_idempotency_key);

  IF FOUND THEN
    RETURN QUERY SELECT
      v_existing.quotation_id,
      v_existing.id,
      (SELECT version_number FROM public.customer_quotation_versions WHERE id = v_existing.quotation_version_id),
      v_existing.handoff_status,
      true;
    RETURN;
  END IF;

  IF v_row.status = 'accepted' THEN
    SELECT * INTO v_existing FROM public.customer_quotation_acceptance_handoffs WHERE quotation_id = p_quotation_id;
    RETURN QUERY SELECT v_row.id, v_existing.id, p_version_number, v_existing.handoff_status, true;
    RETURN;
  END IF;

  IF NOT public.customer_quotation_is_actionable_v1(v_row.status, v_row.expires_at) THEN
    IF v_row.expires_at <= statement_timestamp() THEN
      UPDATE public.customer_quotations SET status = 'expired', updated_at = statement_timestamp()
      WHERE id = p_quotation_id AND status = 'issued';
      RAISE EXCEPTION 'QUOTATION_EXPIRED' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'QUOTATION_NOT_ACTIONABLE: status %', v_row.status USING ERRCODE = 'P0001';
  END IF;

  IF p_version_number IS DISTINCT FROM v_row.current_version THEN
    RAISE EXCEPTION 'QUOTATION_VERSION_STALE: current version is %', v_row.current_version
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_version
  FROM public.customer_quotation_versions v
  WHERE v.quotation_id = p_quotation_id
    AND v.version_number = p_version_number;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QUOTATION_VERSION_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.customer_quotation_acceptance_handoffs (
    quotation_id, quotation_version_id, company_id, idempotency_key,
    handoff_status, commercial_snapshot, created_by
  ) VALUES (
    p_quotation_id, v_version.id, v_row.company_id, btrim(p_idempotency_key),
    'pending', v_version.commercial_snapshot, v_uid
  )
  RETURNING id INTO v_handoff_id;

  UPDATE public.customer_quotations
  SET status = 'accepted', updated_at = statement_timestamp()
  WHERE id = p_quotation_id;

  INSERT INTO public.customer_quotation_events (
    quotation_id, company_id, event_type, actor_id, version_number, detail, correlation_id
  ) VALUES (
    p_quotation_id, v_row.company_id, 'ACCEPTED', v_uid, p_version_number,
    jsonb_build_object('handoff_id', v_handoff_id),
    btrim(p_idempotency_key)
  );

  RETURN QUERY SELECT p_quotation_id, v_handoff_id, p_version_number, 'pending', false;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_customer_quotation_v1(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_customer_quotation_v1(uuid, integer, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.decline_customer_quotation_v1(
  p_quotation_id uuid,
  p_version_number integer,
  p_idempotency_key text,
  p_reason text DEFAULT NULL
)
RETURNS TABLE(
  quotation_id uuid,
  status text,
  version_number integer,
  already_applied boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.customer_quotations%rowtype;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF coalesce(btrim(p_idempotency_key), '') = '' THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  v_row := public.customer_assert_quotation_company_scope_v1(p_quotation_id);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('customer_quotation_decline:' || v_row.company_id::text || ':' || btrim(p_idempotency_key), 0)
  );

  IF v_row.status = 'declined' THEN
    RETURN QUERY SELECT p_quotation_id, 'declined', p_version_number, true;
    RETURN;
  END IF;

  IF v_row.status = 'accepted' THEN
    RAISE EXCEPTION 'QUOTATION_ALREADY_ACCEPTED' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.customer_quotation_is_actionable_v1(v_row.status, v_row.expires_at) THEN
    IF v_row.expires_at <= statement_timestamp() THEN
      UPDATE public.customer_quotations SET status = 'expired', updated_at = statement_timestamp()
      WHERE id = p_quotation_id AND status = 'issued';
      RAISE EXCEPTION 'QUOTATION_EXPIRED' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'QUOTATION_NOT_ACTIONABLE: status %', v_row.status USING ERRCODE = 'P0001';
  END IF;

  IF p_version_number IS DISTINCT FROM v_row.current_version THEN
    RAISE EXCEPTION 'QUOTATION_VERSION_STALE: current version is %', v_row.current_version
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.customer_quotations
  SET status = 'declined', updated_at = statement_timestamp()
  WHERE id = p_quotation_id;

  INSERT INTO public.customer_quotation_events (
    quotation_id, company_id, event_type, actor_id, version_number, detail, correlation_id
  ) VALUES (
    p_quotation_id, v_row.company_id, 'DECLINED', v_uid, p_version_number,
    jsonb_build_object('reason', nullif(btrim(p_reason), '')),
    btrim(p_idempotency_key)
  );

  RETURN QUERY SELECT p_quotation_id, 'declined', p_version_number, false;
END;
$$;

REVOKE ALL ON FUNCTION public.decline_customer_quotation_v1(uuid, integer, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decline_customer_quotation_v1(uuid, integer, text, text) TO authenticated, service_role;

COMMENT ON FUNCTION public.accept_customer_quotation_v1(uuid, integer, text) IS
  'Buyer acceptance of current issued quotation version. Creates governed P107 handoff only; no Sales Order.';

COMMENT ON FUNCTION public.decline_customer_quotation_v1(uuid, integer, text, text) IS
  'Buyer decline of current issued quotation version. Fail-closed on stale/expired/unauthorized state.';
