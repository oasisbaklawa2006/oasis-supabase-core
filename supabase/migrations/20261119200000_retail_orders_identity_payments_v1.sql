-- GFT-100: shared governed Core B2C (retail) quote / order / payment contracts and retail guest identity.
--
-- Owner direction recorded 19 Nov 2026 (IST): approved items 1 (one governed Core B2C order surface),
-- 2 (Razorpay, India/INR, SANDBOX integration only), 3 (GST-inclusive display from approved Core settings) and
-- 6 (guest checkout with phone OTP, optional account). Items 4, 5, 7 and 8 (shipping/serviceability,
-- refund/cancellation, quote validity/stock reservation, enquiry PII roles/retention) are NOT decided here:
-- their values are read from retail_commerce_settings and every action that needs one stays blocked until an
-- administrator approves it with a recorded reference. This migration approves nothing, sets no setting, and
-- carries no price, rate, fee, serviceable PIN or policy value. It is NOT live-payment activation.
--
-- Stacked on 20261118230000_retail_commerce_configuration_v1.sql.
--
-- Reuses existing authority rather than creating a parallel one:
--   * prices      -> public.product_pricing_rules (price_channel 'retail', approved, tax_inclusive) for products
--                    that public.published_products_v1() publishes;
--   * GST rate    -> the pricing rule and public.products (gst_percentage, gst_rate); any disagreement or
--                    unrecognised scale blocks the quote (RETAIL_TAX_RATE_CONFLICT) instead of guessing;
--   * identity    -> the MSG91 verified-widget phone verification already used by msg91-otp (verification happens
--                    in the edge function; this database only stores a verified phone and a hashed session);
--   * payments    -> the provider-event conventions of 20260907141000 (append-only, payload hash, idempotent).
-- Retail identity is deliberately separate from B2B accounts: no table here references companies, B2B claims or
-- the B2B customer tables, and a retail session is not a Supabase JWT.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- -----------------------------------------------------------------------------
-- 1. Retail identity: verified phone guests, optional linked account
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.retail_customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_e164 text NOT NULL UNIQUE,
  phone_verified_at timestamptz NOT NULL,
  auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT retail_customers_phone_check CHECK (phone_e164 ~ '^91[6-9][0-9]{9}$')
);

CREATE TABLE IF NOT EXISTS public.retail_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.retail_customers(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT retail_sessions_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$')
);
CREATE INDEX IF NOT EXISTS retail_sessions_customer_idx ON public.retail_sessions (customer_id);

-- -----------------------------------------------------------------------------
-- 2. Shipping configuration infrastructure (item 4): empty until an administrator supplies approved data
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.retail_serviceable_pincodes (
  policy_ref text NOT NULL,
  pincode text NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (policy_ref, pincode),
  CONSTRAINT retail_serviceable_pincodes_pin_check CHECK (pincode ~ '^[1-9][0-9]{5}$')
);

CREATE TABLE IF NOT EXISTS public.retail_shipping_fee_slabs (
  table_ref text NOT NULL,
  slab_no integer NOT NULL,
  min_subtotal_inr numeric(14,2) NOT NULL CHECK (min_subtotal_inr >= 0),
  below_subtotal_inr numeric(14,2),
  fee_inr numeric(14,2) NOT NULL CHECK (fee_inr >= 0),
  gst_rate_percent numeric(5,2) NOT NULL CHECK (gst_rate_percent IN (0, 0.25, 3, 5, 12, 18, 28)),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (table_ref, slab_no),
  CONSTRAINT retail_shipping_fee_slabs_range_check CHECK (below_subtotal_inr IS NULL OR below_subtotal_inr > min_subtotal_inr)
);

-- -----------------------------------------------------------------------------
-- 3. Quotes, orders, payment intents, provider events
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.retail_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.retail_customers(id),
  idempotency_key text NOT NULL,
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb NOT NULL,
  total_inr numeric(14,2) NOT NULL CHECK (total_inr > 0),
  currency text NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
  settings_snapshot jsonb NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS public.retail_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.retail_customers(id),
  quote_id uuid NOT NULL UNIQUE REFERENCES public.retail_quotes(id),
  idempotency_key text NOT NULL,
  status text NOT NULL DEFAULT 'pending_payment'
    CHECK (status IN ('pending_payment', 'paid', 'cancelled')),
  total_inr numeric(14,2) NOT NULL CHECK (total_inr > 0),
  currency text NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
  snapshot jsonb NOT NULL,
  reservation_expires_at timestamptz NOT NULL,
  -- The reservation window is recorded; physical stock is NOT decremented by this migration.
  stock_reservation_enforced boolean NOT NULL DEFAULT false CHECK (stock_reservation_enforced = false),
  paid_at timestamptz,
  paid_after_reservation_expiry boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS retail_orders_customer_idx ON public.retail_orders (customer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.retail_payment_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.retail_orders(id),
  provider_code text NOT NULL CHECK (provider_code = 'razorpay'),
  amount_paise bigint NOT NULL CHECK (amount_paise > 0),
  currency text NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
  settlement_account_ref text NOT NULL,
  status text NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'associated', 'captured', 'failed')),
  provider_order_id text UNIQUE,
  provider_payment_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT retail_payment_intents_provider_order_check
    CHECK (provider_order_id IS NULL OR provider_order_id ~ '^order_[A-Za-z0-9]{6,40}$')
);
CREATE INDEX IF NOT EXISTS retail_payment_intents_order_idx ON public.retail_payment_intents (order_id);

CREATE TABLE IF NOT EXISTS public.retail_payment_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_event_id text NOT NULL UNIQUE,
  event_type text NOT NULL,
  intent_id uuid REFERENCES public.retail_payment_intents(id),
  provider_order_id text,
  provider_payment_id text,
  amount_paise bigint,
  currency text,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  payload jsonb NOT NULL,
  processing_status text NOT NULL CHECK (processing_status IN
    ('applied', 'failure_recorded', 'amount_mismatch', 'unknown_intent', 'ignored_event_type', 'order_not_payable')),
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.retail_payment_event_rejections (
  id bigserial PRIMARY KEY,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  reason text NOT NULL CHECK (reason IN ('signature_invalid', 'signature_missing', 'event_id_missing', 'payload_invalid')),
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.retail_payment_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'RETAIL_PAYMENT_EVENTS_APPEND_ONLY' USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS retail_payment_events_no_mutation ON public.retail_payment_events;
CREATE TRIGGER retail_payment_events_no_mutation
  BEFORE UPDATE OR DELETE ON public.retail_payment_events
  FOR EACH ROW EXECUTE FUNCTION public.retail_payment_events_append_only();
DROP TRIGGER IF EXISTS retail_payment_rejections_no_mutation ON public.retail_payment_event_rejections;
CREATE TRIGGER retail_payment_rejections_no_mutation
  BEFORE UPDATE OR DELETE ON public.retail_payment_event_rejections
  FOR EACH ROW EXECUTE FUNCTION public.retail_payment_events_append_only();

COMMENT ON TABLE public.retail_customers IS
  'Retail (B2C) identity: a phone verified through the MSG91 widget. Separate from B2B companies and claims; no reference to either.';
COMMENT ON TABLE public.retail_orders IS
  'Retail order surface. stock_reservation_enforced is false: the reservation window is recorded, inventory is not yet decremented.';

-- RLS: nobody reads or writes directly except a linked account reading its own rows.
ALTER TABLE public.retail_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_serviceable_pincodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_shipping_fee_slabs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_payment_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_payment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retail_payment_event_rejections ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.retail_customers, public.retail_sessions, public.retail_serviceable_pincodes,
  public.retail_shipping_fee_slabs, public.retail_quotes, public.retail_orders, public.retail_payment_intents,
  public.retail_payment_events, public.retail_payment_event_rejections
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE public.retail_payment_event_rejections_id_seq FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE public.retail_customers, public.retail_quotes, public.retail_orders TO authenticated;

DROP POLICY IF EXISTS retail_customers_own ON public.retail_customers;
CREATE POLICY retail_customers_own ON public.retail_customers
  FOR SELECT TO authenticated USING (auth_user_id = auth.uid());
DROP POLICY IF EXISTS retail_quotes_own ON public.retail_quotes;
CREATE POLICY retail_quotes_own ON public.retail_quotes
  FOR SELECT TO authenticated
  USING (customer_id IN (SELECT c.id FROM public.retail_customers c WHERE c.auth_user_id = auth.uid()));
DROP POLICY IF EXISTS retail_orders_own ON public.retail_orders;
CREATE POLICY retail_orders_own ON public.retail_orders
  FOR SELECT TO authenticated
  USING (customer_id IN (SELECT c.id FROM public.retail_customers c WHERE c.auth_user_id = auth.uid()));

-- -----------------------------------------------------------------------------
-- 4. Helpers
-- -----------------------------------------------------------------------------
-- The approved value of a setting, or NULL when it is missing or merely proposed.
CREATE OR REPLACE FUNCTION public.retail_setting_approved_v1(p_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT s.value FROM public.retail_commerce_settings s WHERE s.setting_key = p_key AND s.status = 'approved'
$$;

CREATE OR REPLACE FUNCTION public.retail_session_resolve_v1(p_token text)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_customer uuid;
BEGIN
  IF p_token IS NULL OR p_token !~ '^rsess_[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'RETAIL_SESSION_INVALID' USING ERRCODE = '28000';
  END IF;
  SELECT s.customer_id INTO v_customer
    FROM public.retail_sessions s
   WHERE s.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     AND s.revoked_at IS NULL AND s.expires_at > now();
  IF v_customer IS NULL THEN
    RAISE EXCEPTION 'RETAIL_SESSION_INVALID' USING ERRCODE = '28000';
  END IF;
  RETURN v_customer;
END;
$$;

-- Resolve the retail price and GST rate for one product from existing Core authority. Never returns a guess.
CREATE OR REPLACE FUNCTION public.retail_price_resolve_v1(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_rule public.product_pricing_rules%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_price numeric;
  v_rates numeric[];
  v_rate numeric;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.published_products_v1() pp WHERE pp.product_id = p_product_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_published');
  END IF;
  SELECT * INTO v_rule
    FROM public.product_pricing_rules r
   WHERE r.product_id = p_product_id
     AND lower(coalesce(r.price_channel, '')) = 'retail'
     AND lower(coalesce(r.approval_status, '')) = 'approved'
     AND r.tax_inclusive IS TRUE
     AND r.currency = 'INR'
     AND coalesce(r.calculated_price, r.base_price) > 0
     AND (r.valid_from IS NULL OR r.valid_from <= current_date)
     AND (r.valid_until IS NULL OR r.valid_until >= current_date)
   ORDER BY r.valid_from DESC NULLS LAST, r.approved_at DESC NULLS LAST, r.updated_at DESC NULLS LAST, r.id DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_approved_retail_price');
  END IF;
  v_price := coalesce(v_rule.calculated_price, v_rule.base_price);
  IF round(v_price, 2) <> v_price THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'price_invalid');
  END IF;

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  -- Core stores GST on several columns and, in places, on two scales. Every present value must agree and be a
  -- recognised percentage; otherwise the product cannot be sold until Finance corrects the data.
  SELECT array_agg(x) INTO v_rates
    FROM unnest(ARRAY[v_rule.gst_rate, v_product.gst_percentage, v_product.gst_rate]) AS x
   WHERE x IS NOT NULL;
  IF v_rates IS NULL OR (SELECT count(DISTINCT x) FROM unnest(v_rates) AS x) <> 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'tax_rate_conflict');
  END IF;
  v_rate := v_rates[1];
  IF v_rate NOT IN (0, 0.25, 3, 5, 12, 18, 28) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'tax_rate_conflict');
  END IF;
  IF nullif(btrim(v_product.hsn_code), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'hsn_missing');
  END IF;
  RETURN jsonb_build_object('ok', true, 'unitPriceInclusive', v_price, 'gstRatePercent', v_rate, 'hsn', v_product.hsn_code);
END;
$$;

-- GST breakdown of a GST-inclusive amount. Tax = inclusive - taxable; CGST/SGST split intra-state, else IGST.
CREATE OR REPLACE FUNCTION public.retail_tax_breakdown_v1(p_inclusive numeric, p_rate numeric, p_intra_state boolean)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  WITH t AS (
    SELECT p_inclusive AS inclusive,
           round(p_inclusive * 100 / (100 + p_rate), 2) AS taxable
  ), u AS (
    SELECT inclusive, taxable, inclusive - taxable AS tax FROM t
  )
  SELECT jsonb_build_object(
    'inclusive', inclusive,
    'taxable', taxable,
    'tax', tax,
    'cgst', CASE WHEN p_intra_state THEN round(tax / 2, 2) ELSE 0 END,
    'sgst', CASE WHEN p_intra_state THEN tax - round(tax / 2, 2) ELSE 0 END,
    'igst', CASE WHEN p_intra_state THEN 0 ELSE tax END
  ) FROM u
$$;

-- -----------------------------------------------------------------------------
-- 5. Identity RPCs
-- -----------------------------------------------------------------------------
-- Called by the edge function AFTER it verified the MSG91 widget access token. Issues a guest session.
CREATE OR REPLACE FUNCTION public.retail_session_issue_v1(p_verified_phone text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_customer uuid;
  v_token text;
  v_expires timestamptz := now() + interval '12 hours';
BEGIN
  IF p_verified_phone IS NULL OR p_verified_phone !~ '^91[6-9][0-9]{9}$' THEN
    RAISE EXCEPTION 'RETAIL_PHONE_INVALID' USING ERRCODE = '22023';
  END IF;
  IF public.retail_setting_approved_v1('checkout.guest_allowed') IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'RETAIL_COMMERCE_BLOCKED' USING ERRCODE = 'P0001',
      DETAIL = '{"missingOrUnapproved":["checkout.guest_allowed"]}';
  END IF;

  INSERT INTO public.retail_customers AS c (phone_e164, phone_verified_at)
  VALUES (p_verified_phone, now())
  ON CONFLICT (phone_e164) DO UPDATE SET phone_verified_at = now()
  RETURNING c.id INTO v_customer;

  v_token := 'rsess_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO public.retail_sessions (customer_id, token_hash, expires_at)
  VALUES (v_customer, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), v_expires);

  RETURN jsonb_build_object('sessionToken', v_token, 'expiresAt', v_expires);
END;
$$;

CREATE OR REPLACE FUNCTION public.retail_session_revoke_v1(p_session_token text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM public.retail_session_resolve_v1(p_session_token);
  UPDATE public.retail_sessions
     SET revoked_at = now()
   WHERE token_hash = encode(sha256(convert_to(p_session_token, 'UTF8')), 'hex');
END;
$$;

-- Optional account: an authenticated user proves control of the verified phone by presenting a live session.
CREATE OR REPLACE FUNCTION public.retail_customer_link_account_v1(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_customer uuid;
  v_linked uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'RETAIL_ACCOUNT_LINK_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  v_customer := public.retail_session_resolve_v1(p_session_token);
  SELECT auth_user_id INTO v_linked FROM public.retail_customers WHERE id = v_customer FOR UPDATE;
  IF v_linked IS NOT NULL AND v_linked <> v_user THEN
    RAISE EXCEPTION 'RETAIL_ACCOUNT_LINK_CONFLICT' USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM public.retail_customers WHERE auth_user_id = v_user AND id <> v_customer) THEN
    RAISE EXCEPTION 'RETAIL_ACCOUNT_LINK_CONFLICT' USING ERRCODE = '23505';
  END IF;
  UPDATE public.retail_customers SET auth_user_id = v_user WHERE id = v_customer;
  RETURN jsonb_build_object('linked', true);
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. Shipping configuration setters (administrator only; replace the whole set atomically)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_serviceable_pincodes_replace_v1(p_policy_ref text, p_pincodes text[])
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_actor IS NULL OR NOT coalesce(public.is_admin(), false) THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(coalesce(p_policy_ref, '')), '') IS NULL OR p_pincodes IS NULL
     OR cardinality(p_pincodes) NOT BETWEEN 1 AND 20000
     OR EXISTS (SELECT 1 FROM unnest(p_pincodes) AS x WHERE x IS NULL OR x !~ '^[1-9][0-9]{5}$') THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.retail_serviceable_pincodes WHERE policy_ref = p_policy_ref;
  INSERT INTO public.retail_serviceable_pincodes (policy_ref, pincode, created_by)
  SELECT p_policy_ref, x, v_actor FROM unnest(p_pincodes) AS x ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('policyRef', p_policy_ref, 'pincodes', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.retail_shipping_rate_card_replace_v1(p_table_ref text, p_slabs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_slab jsonb;
  v_no integer := 0;
  v_prev_below numeric;
  v_min numeric;
  v_below numeric;
BEGIN
  IF v_actor IS NULL OR NOT coalesce(public.is_admin(), false) THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(coalesce(p_table_ref, '')), '') IS NULL OR jsonb_typeof(p_slabs) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_slabs) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.retail_shipping_fee_slabs WHERE table_ref = p_table_ref;
  FOR v_slab IN SELECT * FROM jsonb_array_elements(p_slabs) LOOP
    v_no := v_no + 1;
    IF jsonb_typeof(v_slab -> 'minSubtotalInr') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_slab -> 'feeInr') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_slab -> 'gstRatePercent') IS DISTINCT FROM 'number'
       OR (v_slab ? 'belowSubtotalInr' AND jsonb_typeof(v_slab -> 'belowSubtotalInr') NOT IN ('number', 'null')) THEN
      RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
    END IF;
    v_min := (v_slab ->> 'minSubtotalInr')::numeric;
    v_below := CASE WHEN jsonb_typeof(v_slab -> 'belowSubtotalInr') = 'number' THEN (v_slab ->> 'belowSubtotalInr')::numeric END;
    -- Contiguous, ascending, non-overlapping; the first slab starts at 0 and only the last may be open-ended.
    IF (v_no = 1 AND v_min <> 0) OR (v_no > 1 AND (v_prev_below IS NULL OR v_min <> v_prev_below)) THEN
      RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.retail_shipping_fee_slabs
      (table_ref, slab_no, min_subtotal_inr, below_subtotal_inr, fee_inr, gst_rate_percent, created_by)
    VALUES (p_table_ref, v_no, v_min, v_below, (v_slab ->> 'feeInr')::numeric, (v_slab ->> 'gstRatePercent')::numeric, v_actor);
    v_prev_below := v_below;
  END LOOP;
  IF v_prev_below IS NOT NULL THEN
    RAISE EXCEPTION 'RETAIL_CONFIG_INVALID' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object('tableRef', p_table_ref, 'slabs', v_no);
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. GST-inclusive price display
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_price_display_v1(p_product_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_id uuid;
  v_price jsonb;
  v_items jsonb := '[]'::jsonb;
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF public.retail_setting_approved_v1('architecture_approved') IS DISTINCT FROM 'true'::jsonb THEN
    v_missing := array_append(v_missing, 'architecture_approved');
  END IF;
  IF public.retail_setting_approved_v1('tax.price_display_mode') IS DISTINCT FROM '"inclusive"'::jsonb THEN
    v_missing := array_append(v_missing, 'tax.price_display_mode');
  END IF;
  IF public.retail_setting_approved_v1('tax.seller_state_code') IS NULL THEN
    v_missing := array_append(v_missing, 'tax.seller_state_code');
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'RETAIL_COMMERCE_BLOCKED' USING ERRCODE = 'P0001',
      DETAIL = jsonb_build_object('missingOrUnapproved', to_jsonb(v_missing))::text;
  END IF;
  IF p_product_ids IS NULL OR cardinality(p_product_ids) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
  END IF;
  FOREACH v_id IN ARRAY p_product_ids LOOP
    v_price := public.retail_price_resolve_v1(v_id);
    v_items := v_items || jsonb_build_array(
      CASE WHEN (v_price ->> 'ok')::boolean
        THEN jsonb_build_object('productId', v_id, 'available', true,
               'unitPriceInclusive', v_price -> 'unitPriceInclusive',
               'gstRatePercent', v_price -> 'gstRatePercent',
               'taxIncludedPerUnit', (public.retail_tax_breakdown_v1(
                  (v_price ->> 'unitPriceInclusive')::numeric, (v_price ->> 'gstRatePercent')::numeric, true) -> 'tax'))
        ELSE jsonb_build_object('productId', v_id, 'available', false, 'reason', v_price ->> 'reason') END);
  END LOOP;
  RETURN jsonb_build_object('priceDisplayMode', 'inclusive', 'currency', 'INR', 'items', v_items);
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. Quote (GST-inclusive, from approved settings and existing pricing authority)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_quote_create_v2(p_session_token text, p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_customer uuid := public.retail_session_resolve_v1(p_session_token);
  v_req jsonb := public.retail_quote_request_validate_v1(p_request);
  v_key text := v_req ->> 'idempotencyKey';
  v_hash text := encode(sha256(convert_to(v_req::text, 'UTF8')), 'hex');
  v_existing public.retail_quotes%ROWTYPE;
  v_seller_state text;
  v_intra boolean;
  v_model text;
  v_policy_ref text;
  v_table_ref text;
  v_validity integer;
  v_pin text := v_req -> 'shipTo' ->> 'pincode';
  v_item record;
  v_price jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_line_incl numeric;
  v_bd jsonb;
  v_subtotal numeric := 0;
  v_taxable numeric := 0;
  v_tax numeric := 0;
  v_cgst numeric := 0;
  v_sgst numeric := 0;
  v_igst numeric := 0;
  v_slab public.retail_shipping_fee_slabs%ROWTYPE;
  v_fee numeric;
  v_ship_bd jsonb;
  v_free_above numeric;
  v_total numeric;
  v_expires timestamptz;
  v_id uuid := gen_random_uuid();
  v_response jsonb;
  v_snapshot jsonb;
  v_bad text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO v_existing FROM public.retail_quotes WHERE customer_id = v_customer AND idempotency_key = v_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash THEN
      RAISE EXCEPTION 'RETAIL_QUOTE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.response || jsonb_build_object('replayed', true);
  END IF;

  PERFORM public.retail_commerce_assert_action_v1('quote');

  -- Only GST-inclusive display is implemented; an approved 'exclusive' mode blocks rather than being mis-rendered.
  IF public.retail_setting_approved_v1('tax.price_display_mode') IS DISTINCT FROM '"inclusive"'::jsonb THEN
    RAISE EXCEPTION 'RETAIL_PRICE_MODE_UNSUPPORTED' USING ERRCODE = '0A000';
  END IF;
  v_seller_state := public.retail_setting_approved_v1('tax.seller_state_code') #>> '{}';
  v_intra := v_seller_state = v_req -> 'shipTo' ->> 'stateCode';
  v_model := public.retail_setting_approved_v1('shipping.model') #>> '{}';
  v_policy_ref := public.retail_setting_approved_v1('shipping.serviceable_pin_policy_ref') #>> '{}';
  v_table_ref := public.retail_setting_approved_v1('shipping.fee_table_ref') #>> '{}';
  v_validity := (public.retail_setting_approved_v1('quote.validity_minutes') #>> '{}')::integer;

  IF NOT EXISTS (SELECT 1 FROM public.retail_serviceable_pincodes WHERE policy_ref = v_policy_ref AND pincode = v_pin) THEN
    RAISE EXCEPTION 'RETAIL_PIN_NOT_SERVICEABLE' USING ERRCODE = 'P0001';
  END IF;

  FOR v_item IN
    SELECT (i ->> 'productId')::uuid AS product_id, sum((i ->> 'quantity')::int)::int AS quantity
      FROM jsonb_array_elements(v_req -> 'items') i GROUP BY 1 ORDER BY 1
  LOOP
    IF v_item.quantity > 99 THEN
      RAISE EXCEPTION 'RETAIL_QUOTE_REQUEST_INVALID' USING ERRCODE = '22023';
    END IF;
    v_price := public.retail_price_resolve_v1(v_item.product_id);
    IF NOT (v_price ->> 'ok')::boolean THEN
      v_bad := v_bad || (v_item.product_id::text || ':' || (v_price ->> 'reason'));
      CONTINUE;
    END IF;
    v_line_incl := (v_price ->> 'unitPriceInclusive')::numeric * v_item.quantity;
    v_bd := public.retail_tax_breakdown_v1(v_line_incl, (v_price ->> 'gstRatePercent')::numeric, v_intra);
    v_subtotal := v_subtotal + v_line_incl;
    v_taxable := v_taxable + (v_bd ->> 'taxable')::numeric;
    v_tax := v_tax + (v_bd ->> 'tax')::numeric;
    v_cgst := v_cgst + (v_bd ->> 'cgst')::numeric;
    v_sgst := v_sgst + (v_bd ->> 'sgst')::numeric;
    v_igst := v_igst + (v_bd ->> 'igst')::numeric;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'productId', v_item.product_id, 'quantity', v_item.quantity, 'hsn', v_price -> 'hsn',
      'unitPriceInclusive', v_price -> 'unitPriceInclusive', 'gstRatePercent', v_price -> 'gstRatePercent',
      'lineTotalInclusive', v_line_incl, 'taxableValue', v_bd -> 'taxable',
      'tax', jsonb_build_object('cgst', v_bd -> 'cgst', 'sgst', v_bd -> 'sgst', 'igst', v_bd -> 'igst')));
  END LOOP;
  IF cardinality(v_bad) > 0 THEN
    RAISE EXCEPTION 'RETAIL_PRODUCT_NOT_SELLABLE' USING ERRCODE = 'P0001',
      DETAIL = jsonb_build_object('products', to_jsonb(v_bad))::text;
  END IF;

  -- Shipping from the approved rate card. No card, no matching slab, or an unsupported model -> blocked.
  SELECT * INTO v_slab FROM public.retail_shipping_fee_slabs s
   WHERE s.table_ref = v_table_ref AND s.min_subtotal_inr <= v_subtotal
     AND (s.below_subtotal_inr IS NULL OR v_subtotal < s.below_subtotal_inr)
   ORDER BY s.slab_no LIMIT 1;
  IF NOT FOUND OR (v_model = 'flat' AND (SELECT count(*) FROM public.retail_shipping_fee_slabs WHERE table_ref = v_table_ref) <> 1) THEN
    RAISE EXCEPTION 'RETAIL_SHIPPING_UNPRICED' USING ERRCODE = 'P0001';
  END IF;
  v_fee := v_slab.fee_inr;
  IF v_model = 'free_above' THEN
    v_free_above := (public.retail_setting_approved_v1('shipping.free_above_amount_inr') #>> '{}')::numeric;
    IF v_subtotal >= v_free_above THEN v_fee := 0; END IF;
  END IF;
  v_ship_bd := public.retail_tax_breakdown_v1(v_fee, v_slab.gst_rate_percent, v_intra);
  v_taxable := v_taxable + (v_ship_bd ->> 'taxable')::numeric;
  v_tax := v_tax + (v_ship_bd ->> 'tax')::numeric;
  v_cgst := v_cgst + (v_ship_bd ->> 'cgst')::numeric;
  v_sgst := v_sgst + (v_ship_bd ->> 'sgst')::numeric;
  v_igst := v_igst + (v_ship_bd ->> 'igst')::numeric;
  v_total := v_subtotal + v_fee;
  v_expires := now() + make_interval(mins => v_validity);

  SELECT jsonb_object_agg(s.setting_key, s.approval_reference) INTO v_snapshot
    FROM public.retail_commerce_settings s
   WHERE s.status = 'approved'
     AND s.setting_key IN (SELECT r.setting_key FROM public.retail_commerce_action_requirements_v1() r WHERE r.action = 'quote');

  v_response := jsonb_build_object(
    'quoteId', v_id, 'currency', 'INR', 'priceDisplayMode', 'inclusive',
    'lines', v_lines,
    'shipping', jsonb_build_object('feeInclusive', v_fee, 'gstRatePercent', v_slab.gst_rate_percent,
      'taxableValue', v_ship_bd -> 'taxable',
      'tax', jsonb_build_object('cgst', v_ship_bd -> 'cgst', 'sgst', v_ship_bd -> 'sgst', 'igst', v_ship_bd -> 'igst')),
    'totals', jsonb_build_object('inclusiveTotal', v_total, 'taxableTotal', v_taxable, 'taxTotal', v_tax,
      'cgst', v_cgst, 'sgst', v_sgst, 'igst', v_igst, 'supply', CASE WHEN v_intra THEN 'intra_state' ELSE 'inter_state' END),
    'shipTo', v_req -> 'shipTo',
    'expiresAt', v_expires,
    'replayed', false);

  INSERT INTO public.retail_quotes (id, customer_id, idempotency_key, request_hash, response, total_inr, settings_snapshot, expires_at)
  VALUES (v_id, v_customer, v_key, v_hash, v_response - 'replayed', v_total, coalesce(v_snapshot, '{}'::jsonb), v_expires);
  RETURN v_response;
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. Order
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_order_create_v1(p_session_token text, p_quote_id uuid, p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_customer uuid := public.retail_session_resolve_v1(p_session_token);
  v_quote public.retail_quotes%ROWTYPE;
  v_existing public.retail_orders%ROWTYPE;
  v_reservation integer;
  v_order public.retail_orders%ROWTYPE;
BEGIN
  IF p_quote_id IS NULL OR p_idempotency_key IS NULL
     OR p_idempotency_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'RETAIL_ORDER_REQUEST_INVALID' USING ERRCODE = '22023';
  END IF;
  p_idempotency_key := lower(p_idempotency_key);

  SELECT * INTO v_existing FROM public.retail_orders WHERE customer_id = v_customer AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.quote_id <> p_quote_id THEN
      RAISE EXCEPTION 'RETAIL_ORDER_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('orderId', v_existing.id, 'status', v_existing.status, 'totalInr', v_existing.total_inr,
      'reservationExpiresAt', v_existing.reservation_expires_at, 'stockReservationEnforced', false, 'replayed', true);
  END IF;

  PERFORM public.retail_commerce_assert_action_v1('order');

  -- A quote that is not the caller's is indistinguishable from one that does not exist.
  SELECT * INTO v_quote FROM public.retail_quotes WHERE id = p_quote_id AND customer_id = v_customer FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;
  IF v_quote.expires_at <= now() THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_EXPIRED' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.retail_orders WHERE quote_id = p_quote_id) THEN
    RAISE EXCEPTION 'RETAIL_QUOTE_ALREADY_ORDERED' USING ERRCODE = '23505';
  END IF;

  v_reservation := (public.retail_setting_approved_v1('stock.reservation_minutes') #>> '{}')::integer;
  INSERT INTO public.retail_orders (customer_id, quote_id, idempotency_key, total_inr, snapshot, reservation_expires_at)
  VALUES (v_customer, p_quote_id, p_idempotency_key, v_quote.total_inr, v_quote.response,
          now() + make_interval(mins => v_reservation))
  RETURNING * INTO v_order;

  RETURN jsonb_build_object('orderId', v_order.id, 'status', v_order.status, 'totalInr', v_order.total_inr,
    'reservationExpiresAt', v_order.reservation_expires_at, 'stockReservationEnforced', false, 'replayed', false);
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. Payment intent, Razorpay association, durable signed-webhook application
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retail_payment_intent_create_v1(p_session_token text, p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_customer uuid := public.retail_session_resolve_v1(p_session_token);
  v_order public.retail_orders%ROWTYPE;
  v_intent public.retail_payment_intents%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.retail_orders WHERE id = p_order_id AND customer_id = v_customer FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RETAIL_ORDER_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  PERFORM public.retail_commerce_assert_action_v1('payment');
  IF public.retail_setting_approved_v1('payment.provider') IS DISTINCT FROM '"razorpay"'::jsonb THEN
    RAISE EXCEPTION 'RETAIL_PAYMENT_PROVIDER_UNSUPPORTED' USING ERRCODE = '0A000';
  END IF;
  IF v_order.status <> 'pending_payment' THEN
    RAISE EXCEPTION 'RETAIL_ORDER_NOT_PAYABLE' USING ERRCODE = 'P0001';
  END IF;
  IF v_order.reservation_expires_at <= now() THEN
    RAISE EXCEPTION 'RETAIL_ORDER_EXPIRED' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_intent FROM public.retail_payment_intents
   WHERE order_id = p_order_id AND status IN ('created', 'associated') ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO public.retail_payment_intents (order_id, provider_code, amount_paise, settlement_account_ref)
    VALUES (p_order_id, 'razorpay', (v_order.total_inr * 100)::bigint,
            public.retail_setting_approved_v1('payment.settlement_account_ref') #>> '{}')
    RETURNING * INTO v_intent;
  END IF;

  RETURN jsonb_build_object('intentId', v_intent.id, 'orderId', p_order_id, 'providerCode', 'razorpay',
    'amountPaise', v_intent.amount_paise, 'currency', 'INR', 'receipt', v_intent.id::text,
    'providerOrderId', v_intent.provider_order_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.retail_payment_intent_associate_v1(
  p_intent_id uuid, p_provider_order_id text, p_amount_paise bigint, p_currency text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_intent public.retail_payment_intents%ROWTYPE;
BEGIN
  SELECT * INTO v_intent FROM public.retail_payment_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RETAIL_PAYMENT_INTENT_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;
  IF p_provider_order_id IS NULL OR p_provider_order_id !~ '^order_[A-Za-z0-9]{6,40}$'
     OR p_amount_paise IS DISTINCT FROM v_intent.amount_paise OR p_currency IS DISTINCT FROM v_intent.currency THEN
    RAISE EXCEPTION 'RETAIL_PAYMENT_ASSOCIATION_INVALID' USING ERRCODE = '22023';
  END IF;
  IF v_intent.provider_order_id IS NOT NULL AND v_intent.provider_order_id <> p_provider_order_id THEN
    RAISE EXCEPTION 'RETAIL_PAYMENT_ASSOCIATION_CONFLICT' USING ERRCODE = '23505';
  END IF;
  IF v_intent.status NOT IN ('created', 'associated') THEN
    RAISE EXCEPTION 'RETAIL_PAYMENT_ASSOCIATION_INVALID' USING ERRCODE = '22023';
  END IF;
  UPDATE public.retail_payment_intents
     SET provider_order_id = p_provider_order_id, status = 'associated', updated_at = now()
   WHERE id = p_intent_id;
  RETURN jsonb_build_object('intentId', p_intent_id, 'providerOrderId', p_provider_order_id, 'status', 'associated');
END;
$$;

CREATE OR REPLACE FUNCTION public.retail_payment_event_reject_v1(p_payload_hash text, p_reason text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  INSERT INTO public.retail_payment_event_rejections (payload_hash, reason) VALUES (p_payload_hash, p_reason)
$$;

-- Applies a provider event that the edge function has ALREADY verified against the webhook secret. Idempotent on
-- the provider event id: a redelivery changes nothing and reports the original outcome.
CREATE OR REPLACE FUNCTION public.retail_payment_event_apply_v1(
  p_provider_event_id text, p_event_type text, p_provider_order_id text, p_provider_payment_id text,
  p_amount_paise bigint, p_currency text, p_payload jsonb, p_payload_hash text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_event public.retail_payment_events%ROWTYPE;
  v_intent public.retail_payment_intents%ROWTYPE;
  v_order public.retail_orders%ROWTYPE;
  v_status text;
  v_late boolean := false;
BEGIN
  IF nullif(btrim(coalesce(p_provider_event_id, '')), '') IS NULL OR char_length(p_provider_event_id) > 200
     OR p_payload_hash IS NULL OR p_payload_hash !~ '^[0-9a-f]{64}$'
     OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'RETAIL_PAYMENT_EVENT_INVALID' USING ERRCODE = '22023';
  END IF;

  -- Serialise redeliveries of the same event.
  PERFORM pg_advisory_xact_lock(hashtextextended('retail_payment_event:' || p_provider_event_id, 0));
  SELECT * INTO v_event FROM public.retail_payment_events WHERE provider_event_id = p_provider_event_id;
  IF FOUND THEN
    IF v_event.payload_hash <> p_payload_hash THEN
      RAISE EXCEPTION 'RETAIL_PAYMENT_EVENT_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('outcome', v_event.processing_status, 'duplicate', true);
  END IF;

  SELECT * INTO v_intent FROM public.retail_payment_intents WHERE provider_order_id = p_provider_order_id FOR UPDATE;

  IF p_event_type NOT IN ('payment.captured', 'order.paid', 'payment.failed') THEN
    v_status := 'ignored_event_type';
  ELSIF NOT FOUND THEN
    v_status := 'unknown_intent';
  ELSIF p_amount_paise IS DISTINCT FROM v_intent.amount_paise OR p_currency IS DISTINCT FROM v_intent.currency THEN
    -- Money that does not match the intent never marks an order paid.
    v_status := 'amount_mismatch';
  ELSIF p_event_type = 'payment.failed' THEN
    IF v_intent.status <> 'captured' THEN
      UPDATE public.retail_payment_intents SET status = 'failed', provider_payment_id = p_provider_payment_id, updated_at = now()
       WHERE id = v_intent.id;
    END IF;
    v_status := 'failure_recorded';
  ELSE
    SELECT * INTO v_order FROM public.retail_orders WHERE id = v_intent.order_id FOR UPDATE;
    IF v_order.status = 'cancelled' THEN
      v_status := 'order_not_payable';
    ELSE
      v_late := v_order.reservation_expires_at <= now();
      UPDATE public.retail_payment_intents SET status = 'captured', provider_payment_id = p_provider_payment_id, updated_at = now()
       WHERE id = v_intent.id;
      UPDATE public.retail_orders
         SET status = 'paid', paid_at = coalesce(paid_at, now()),
             paid_after_reservation_expiry = paid_after_reservation_expiry OR (status <> 'paid' AND v_late)
       WHERE id = v_order.id;
      v_status := 'applied';
    END IF;
  END IF;

  INSERT INTO public.retail_payment_events (provider_event_id, event_type, intent_id, provider_order_id, provider_payment_id,
    amount_paise, currency, payload_hash, payload, processing_status)
  VALUES (p_provider_event_id, p_event_type, v_intent.id, p_provider_order_id, p_provider_payment_id,
    p_amount_paise, p_currency, p_payload_hash, p_payload, v_status);

  RETURN jsonb_build_object('outcome', v_status, 'duplicate', false);
END;
$$;

-- -----------------------------------------------------------------------------
-- 11. Privileges: only service_role (edge functions) and, for account linking, authenticated
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.retail_payment_events_append_only() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.retail_setting_approved_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_session_resolve_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_price_resolve_v1(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_tax_breakdown_v1(numeric, numeric, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_session_issue_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_session_revoke_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_customer_link_account_v1(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retail_serviceable_pincodes_replace_v1(text, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retail_shipping_rate_card_replace_v1(text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.retail_price_display_v1(uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_quote_create_v2(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_order_create_v1(text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_payment_intent_create_v1(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_payment_intent_associate_v1(uuid, text, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_payment_event_reject_v1(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retail_payment_event_apply_v1(text, text, text, text, bigint, text, jsonb, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.retail_session_issue_v1(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_session_revoke_v1(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_customer_link_account_v1(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.retail_serviceable_pincodes_replace_v1(text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.retail_shipping_rate_card_replace_v1(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.retail_price_display_v1(uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_quote_create_v2(text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_order_create_v1(text, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_payment_intent_create_v1(text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_payment_intent_associate_v1(uuid, text, bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_payment_event_reject_v1(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.retail_payment_event_apply_v1(text, text, text, text, bigint, text, jsonb, text) TO service_role;
