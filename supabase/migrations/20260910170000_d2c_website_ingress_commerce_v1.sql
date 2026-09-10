-- Website D2C backend ingress v1.
-- Mission Control: Oasis-Baklawa-Central#493.
--
-- This migration deliberately does NOT create products and does NOT insert into
-- public.orders.  AI Studio/publication selects an EXISTING product; Finance or
-- another governed authority supplies a D2C price; the website may then quote,
-- checkout and capture a paid order intent.  A separate handoff worker links that
-- intent to the canonical Appverse order once operational intake accepts it.
--
-- No provider credential is stored here.  External payment/courier/webhook adapters
-- remain server-side and fail closed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- -----------------------------------------------------------------------------
-- 1. Public presentation approval: AI Studio output for EXISTING products only.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.d2c_catalogue_publications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  version integer NOT NULL CHECK (version > 0),
  slug text NOT NULL CHECK (btrim(slug) <> ''),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  presentation jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_reference text NOT NULL CHECK (btrim(source_reference) <> ''),
  status text NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','APPROVED','PUBLISHED','RETIRED')),
  approved_by uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at timestamptz NULL,
  published_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT d2c_catalogue_publications_product_version_unique UNIQUE (product_id, version),
  CONSTRAINT d2c_catalogue_publications_state_check CHECK (
    (status = 'DRAFT' AND approved_at IS NULL AND published_at IS NULL)
    OR (status = 'APPROVED' AND approved_at IS NOT NULL AND published_at IS NULL)
    OR (status = 'PUBLISHED' AND approved_at IS NOT NULL AND published_at IS NOT NULL)
    OR status = 'RETIRED'
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_d2c_catalogue_one_published_per_product
  ON public.d2c_catalogue_publications(product_id)
  WHERE status = 'PUBLISHED';
CREATE UNIQUE INDEX IF NOT EXISTS uq_d2c_catalogue_published_slug
  ON public.d2c_catalogue_publications(lower(slug))
  WHERE status = 'PUBLISHED';
CREATE INDEX IF NOT EXISTS idx_d2c_catalogue_status
  ON public.d2c_catalogue_publications(status, updated_at DESC);

COMMENT ON TABLE public.d2c_catalogue_publications IS
  'AI Studio governed public presentation for an EXISTING Core product. No row creates a product or grants commerce authority.';

-- -----------------------------------------------------------------------------
-- 2. Explicit D2C commerce authority.  Empty by default; no product is made
--    purchasable by this migration.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.d2c_product_commerce_authority (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  current_price numeric(12,2) NOT NULL CHECK (current_price > 0),
  compare_at_price numeric(12,2) NULL CHECK (compare_at_price IS NULL OR compare_at_price >= current_price),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  tax_rate numeric(7,4) NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100),
  tax_inclusive boolean NOT NULL DEFAULT true,
  uom text NULL,
  sale_enabled boolean NOT NULL DEFAULT false,
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_until timestamptz NULL CHECK (valid_until IS NULL OR valid_until > valid_from),
  source_reference text NOT NULL CHECK (btrim(source_reference) <> ''),
  approved_by uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_d2c_commerce_product_active
  ON public.d2c_product_commerce_authority(product_id, sale_enabled, valid_from DESC);

COMMENT ON TABLE public.d2c_product_commerce_authority IS
  'Explicit D2C price/tax/sale authority for existing products. AI Studio presentation alone cannot make a product purchasable.';

-- -----------------------------------------------------------------------------
-- 3. Account conveniences.  These do not create operational customer/company rows.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.d2c_customer_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NULL,
  phone text NULL,
  marketing_preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.d2c_saved_addresses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label text NULL,
  recipient_name text NOT NULL CHECK (btrim(recipient_name) <> ''),
  phone text NOT NULL CHECK (btrim(phone) <> ''),
  address jsonb NOT NULL CHECK (jsonb_typeof(address) = 'object'),
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_d2c_saved_addresses_user ON public.d2c_saved_addresses(user_id, updated_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_d2c_saved_address_one_default
  ON public.d2c_saved_addresses(user_id) WHERE is_default;

CREATE TABLE IF NOT EXISTS public.d2c_saved_items (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, product_id)
);

-- -----------------------------------------------------------------------------
-- 4. Cart.  Browser never supplies authoritative price; lines carry identity/qty.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.d2c_cart_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  guest_session_hash text NULL,
  status text NOT NULL DEFAULT 'ACTIVE'
    CHECK (status IN ('ACTIVE','CHECKED_OUT','ABANDONED','EXPIRED','CANCELLED')),
  attribution jsonb NOT NULL DEFAULT '{}'::jsonb,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT d2c_cart_has_owner CHECK (owner_user_id IS NOT NULL OR nullif(btrim(guest_session_hash),'') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_d2c_cart_user ON public.d2c_cart_sessions(owner_user_id, updated_at DESC) WHERE owner_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_d2c_cart_guest ON public.d2c_cart_sessions(guest_session_hash, updated_at DESC) WHERE guest_session_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.d2c_cart_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id uuid NOT NULL REFERENCES public.d2c_cart_sessions(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity integer NOT NULL CHECK (quantity > 0 AND quantity <= 999),
  customer_configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT d2c_cart_line_unique_product UNIQUE (cart_id, product_id)
);
CREATE INDEX IF NOT EXISTS idx_d2c_cart_lines_cart ON public.d2c_cart_lines(cart_id);

-- -----------------------------------------------------------------------------
-- 5. Checkout + payment attempts.  Provider creation/capture remains in an Edge/
--    server adapter after provider signature/authentication has been verified.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.d2c_checkout_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id uuid NOT NULL REFERENCES public.d2c_cart_sessions(id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> ''),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  contact jsonb NOT NULL CHECK (jsonb_typeof(contact) = 'object'),
  shipping_address jsonb NOT NULL CHECK (jsonb_typeof(shipping_address) = 'object'),
  quote_snapshot jsonb NOT NULL,
  subtotal numeric(12,2) NOT NULL CHECK (subtotal >= 0),
  tax_total numeric(12,2) NOT NULL CHECK (tax_total >= 0),
  total numeric(12,2) NOT NULL CHECK (total > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  status text NOT NULL DEFAULT 'QUOTED'
    CHECK (status IN ('QUOTED','PAYMENT_PENDING','PAID_AWAITING_HANDOFF','COMPLETED','EXPIRED','CANCELLED')),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 minutes'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT d2c_checkout_cart_idempotency_unique UNIQUE (cart_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_d2c_checkout_cart ON public.d2c_checkout_sessions(cart_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.d2c_payment_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checkout_id uuid NOT NULL REFERENCES public.d2c_checkout_sessions(id) ON DELETE RESTRICT,
  provider text NOT NULL CHECK (btrim(provider) <> ''),
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> ''),
  provider_payment_id text NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  status text NOT NULL DEFAULT 'CREATED'
    CHECK (status IN ('CREATED','PENDING','AUTHORIZED','CAPTURED','FAILED','CANCELLED','REFUNDED')),
  safe_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT d2c_payment_attempt_provider_key_unique UNIQUE (provider, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_d2c_payment_checkout ON public.d2c_payment_attempts(checkout_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.d2c_integration_webhook_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL CHECK (btrim(provider) <> ''),
  provider_event_id text NOT NULL CHECK (btrim(provider_event_id) <> ''),
  payload_hash text NOT NULL CHECK (btrim(payload_hash) <> ''),
  signature_verified boolean NOT NULL DEFAULT false,
  processed boolean NOT NULL DEFAULT false,
  processing_result jsonb NOT NULL DEFAULT '{}'::jsonb,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz NULL,
  CONSTRAINT d2c_webhook_event_unique UNIQUE (provider, provider_event_id)
);

-- -----------------------------------------------------------------------------
-- 6. Website order intent + safe tracking + Appverse outbox.
--    canonical_order_id is nullable: this layer never manufactures a Core order.
-- -----------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.d2c_web_order_reference_seq;
REVOKE ALL ON SEQUENCE public.d2c_web_order_reference_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.d2c_web_order_reference_seq TO service_role;

CREATE TABLE IF NOT EXISTS public.d2c_order_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checkout_id uuid NOT NULL UNIQUE REFERENCES public.d2c_checkout_sessions(id) ON DELETE RESTRICT,
  web_order_reference text NOT NULL UNIQUE DEFAULT (
    'WEB-' || to_char(current_date,'YYYYMMDD') || '-' || lpad(nextval('public.d2c_web_order_reference_seq')::text,6,'0')
  ),
  public_tracking_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  canonical_order_id uuid NULL UNIQUE REFERENCES public.orders(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'PAID_AWAITING_HANDOFF'
    CHECK (status IN ('PAID_AWAITING_HANDOFF','HANDED_OFF','PROCESSING','READY_TO_DISPATCH','DISPATCHED','DELIVERED','CANCELLED','FAILED')),
  line_snapshot jsonb NOT NULL,
  contact_snapshot jsonb NOT NULL,
  delivery_snapshot jsonb NOT NULL,
  subtotal numeric(12,2) NOT NULL CHECK (subtotal >= 0),
  tax_total numeric(12,2) NOT NULL CHECK (tax_total >= 0),
  total numeric(12,2) NOT NULL CHECK (total > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  paid_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_d2c_order_intents_status ON public.d2c_order_intents(status, updated_at DESC);

CREATE TABLE IF NOT EXISTS public.d2c_order_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_intent_id uuid NOT NULL REFERENCES public.d2c_order_intents(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (btrim(event_type) <> ''),
  status text NOT NULL,
  public_message text NULL,
  public_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  internal_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_d2c_order_events_timeline ON public.d2c_order_events(order_intent_id, occurred_at, id);

CREATE TABLE IF NOT EXISTS public.d2c_outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type text NOT NULL,
  aggregate_id uuid NOT NULL,
  event_type text NOT NULL,
  dedupe_key text NOT NULL UNIQUE,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING','PROCESSING','SENT','FAILED','DEAD_LETTER')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error text NULL,
  available_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_d2c_outbox_delivery ON public.d2c_outbox_events(status, available_at, created_at);

CREATE TABLE IF NOT EXISTS public.d2c_cart_recovery_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id uuid NOT NULL REFERENCES public.d2c_cart_sessions(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE CHECK (btrim(token_hash) <> ''),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REDEEMED','EXPIRED','REVOKED')),
  expires_at timestamptz NOT NULL,
  redeem_count integer NOT NULL DEFAULT 0 CHECK (redeem_count >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_d2c_cart_recovery_expiry ON public.d2c_cart_recovery_sessions(status, expires_at);

CREATE TABLE IF NOT EXISTS public.d2c_support_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_intent_id uuid NULL REFERENCES public.d2c_order_intents(id) ON DELETE SET NULL,
  request_type text NOT NULL CHECK (request_type IN ('GENERAL','CANCEL_REQUEST','ADDRESS_CHANGE','DELIVERY_HELP','PAYMENT_HELP')),
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_REVIEW','RESOLVED','REJECTED','CANCELLED')),
  contact jsonb NOT NULL DEFAULT '{}'::jsonb,
  message text NOT NULL CHECK (btrim(message) <> ''),
  idempotency_key text NOT NULL UNIQUE CHECK (btrim(idempotency_key) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 7. Updated-at triggers.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
    'd2c_catalogue_publications','d2c_product_commerce_authority','d2c_customer_profiles',
    'd2c_saved_addresses','d2c_cart_sessions','d2c_cart_lines','d2c_checkout_sessions',
    'd2c_payment_attempts','d2c_order_intents','d2c_outbox_events',
    'd2c_cart_recovery_sessions','d2c_support_requests'
  ]) AS table_name
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%I_touch ON public.%I', r.table_name, r.table_name);
    EXECUTE format('CREATE TRIGGER trg_%I_touch BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at()', r.table_name, r.table_name);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 8. RLS/ACL.  Commerce/order/payment surfaces are server-only.  Only personal
--    profile/address/saved-item convenience tables are directly owner-scoped.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
    'd2c_catalogue_publications','d2c_product_commerce_authority','d2c_cart_sessions',
    'd2c_cart_lines','d2c_checkout_sessions','d2c_payment_attempts',
    'd2c_integration_webhook_events','d2c_order_intents','d2c_order_events',
    'd2c_outbox_events','d2c_cart_recovery_sessions','d2c_support_requests'
  ]) AS table_name
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.table_name);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', r.table_name);
    EXECUTE format('GRANT ALL ON TABLE public.%I TO service_role', r.table_name);
  END LOOP;
END $$;

ALTER TABLE public.d2c_customer_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.d2c_saved_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.d2c_saved_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.d2c_customer_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.d2c_saved_addresses FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.d2c_saved_items FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.d2c_customer_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.d2c_saved_addresses TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.d2c_saved_items TO authenticated;
GRANT ALL ON TABLE public.d2c_customer_profiles TO service_role;
GRANT ALL ON TABLE public.d2c_saved_addresses TO service_role;
GRANT ALL ON TABLE public.d2c_saved_items TO service_role;

DROP POLICY IF EXISTS d2c_profile_owner_select ON public.d2c_customer_profiles;
CREATE POLICY d2c_profile_owner_select ON public.d2c_customer_profiles FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS d2c_profile_owner_insert ON public.d2c_customer_profiles;
CREATE POLICY d2c_profile_owner_insert ON public.d2c_customer_profiles FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS d2c_profile_owner_update ON public.d2c_customer_profiles;
CREATE POLICY d2c_profile_owner_update ON public.d2c_customer_profiles FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS d2c_address_owner_all ON public.d2c_saved_addresses;
CREATE POLICY d2c_address_owner_all ON public.d2c_saved_addresses FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS d2c_saved_item_owner_all ON public.d2c_saved_items;
CREATE POLICY d2c_saved_item_owner_all ON public.d2c_saved_items FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 9. Commerce resolver and public catalogue projection.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.d2c_resolve_product_offer_v1(p_product_id uuid)
RETURNS TABLE(
  product_id uuid,
  publication_id uuid,
  slug text,
  display_name text,
  presentation jsonb,
  price numeric,
  compare_at_price numeric,
  currency text,
  tax_rate numeric,
  tax_inclusive boolean,
  uom text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT
    p.product_id,
    p.id,
    p.slug,
    p.display_name,
    p.presentation,
    c.current_price,
    c.compare_at_price,
    c.currency,
    c.tax_rate,
    c.tax_inclusive,
    c.uom
  FROM public.d2c_catalogue_publications p
  JOIN public.published_products_v1() live ON live.product_id = p.product_id
  JOIN LATERAL (
    SELECT ca.*
    FROM public.d2c_product_commerce_authority ca
    WHERE ca.product_id = p.product_id
      AND ca.sale_enabled
      AND ca.valid_from <= now()
      AND (ca.valid_until IS NULL OR ca.valid_until > now())
    ORDER BY ca.approved_at DESC, ca.id DESC
    LIMIT 1
  ) c ON true
  WHERE p.product_id = p_product_id
    AND p.status = 'PUBLISHED'
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.d2c_resolve_product_offer_v1(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_resolve_product_offer_v1(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_public_catalogue_v1()
RETURNS TABLE(
  product_id uuid,
  slug text,
  display_name text,
  presentation jsonb,
  price numeric,
  compare_at_price numeric,
  currency text,
  tax_rate numeric,
  tax_inclusive boolean,
  uom text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT r.product_id, r.slug, r.display_name, r.presentation, r.price,
         r.compare_at_price, r.currency, r.tax_rate, r.tax_inclusive, r.uom
  FROM public.d2c_catalogue_publications p
  CROSS JOIN LATERAL public.d2c_resolve_product_offer_v1(p.product_id) r
  WHERE p.status = 'PUBLISHED'
  ORDER BY r.display_name, r.product_id;
$$;
REVOKE ALL ON FUNCTION public.d2c_public_catalogue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.d2c_public_catalogue_v1() TO anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 10. Server-authoritative cart quotation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.d2c_quote_cart_v1(p_cart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_cart public.d2c_cart_sessions%rowtype;
  v_line record;
  v_offer record;
  v_currency text := NULL;
  v_line_gross numeric;
  v_line_net numeric;
  v_line_tax numeric;
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_total numeric := 0;
  v_lines jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_cart FROM public.d2c_cart_sessions WHERE id = p_cart_id FOR UPDATE;
  IF NOT FOUND OR v_cart.status <> 'ACTIVE' OR v_cart.expires_at <= now() THEN
    RAISE EXCEPTION 'D2C_CART_NOT_ACTIVE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.d2c_cart_lines WHERE cart_id = p_cart_id) THEN
    RAISE EXCEPTION 'D2C_CART_EMPTY';
  END IF;

  FOR v_line IN SELECT * FROM public.d2c_cart_lines WHERE cart_id = p_cart_id ORDER BY created_at, id
  LOOP
    SELECT * INTO v_offer FROM public.d2c_resolve_product_offer_v1(v_line.product_id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'D2C_PRODUCT_NOT_PURCHASABLE:%', v_line.product_id;
    END IF;
    IF v_currency IS NULL THEN v_currency := v_offer.currency;
    ELSIF v_currency <> v_offer.currency THEN RAISE EXCEPTION 'D2C_MIXED_CURRENCY_CART';
    END IF;

    v_line_gross := round(v_offer.price * v_line.quantity, 2);
    IF v_offer.tax_inclusive THEN
      v_line_net := CASE WHEN v_offer.tax_rate = 0 THEN v_line_gross ELSE round(v_line_gross / (1 + v_offer.tax_rate / 100), 2) END;
      v_line_tax := v_line_gross - v_line_net;
    ELSE
      v_line_net := v_line_gross;
      v_line_tax := round(v_line_net * v_offer.tax_rate / 100, 2);
      v_line_gross := v_line_net + v_line_tax;
    END IF;

    v_subtotal := v_subtotal + v_line_net;
    v_tax := v_tax + v_line_tax;
    v_total := v_total + v_line_gross;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id', v_line.product_id,
      'publication_id', v_offer.publication_id,
      'slug', v_offer.slug,
      'display_name', v_offer.display_name,
      'quantity', v_line.quantity,
      'unit_price', v_offer.price,
      'currency', v_offer.currency,
      'tax_rate', v_offer.tax_rate,
      'tax_inclusive', v_offer.tax_inclusive,
      'uom', v_offer.uom,
      'configuration', v_line.customer_configuration,
      'line_subtotal', v_line_net,
      'line_tax', v_line_tax,
      'line_total', v_line_gross
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'cart_id', p_cart_id,
    'currency', v_currency,
    'subtotal', round(v_subtotal,2),
    'tax_total', round(v_tax,2),
    'total', round(v_total,2),
    'lines', v_lines,
    'quoted_at', now()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_quote_cart_v1(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_quote_cart_v1(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_create_checkout_v1(
  p_cart_id uuid,
  p_idempotency_key text,
  p_contact jsonb,
  p_shipping_address jsonb,
  p_user_id uuid DEFAULT NULL
)
RETURNS TABLE(checkout_id uuid, total numeric, currency text, duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_existing public.d2c_checkout_sessions%rowtype;
  v_quote jsonb;
  v_checkout public.d2c_checkout_sessions%rowtype;
BEGIN
  IF nullif(btrim(p_idempotency_key),'') IS NULL THEN RAISE EXCEPTION 'D2C_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF jsonb_typeof(p_contact) <> 'object' OR p_contact = '{}'::jsonb THEN RAISE EXCEPTION 'D2C_CONTACT_REQUIRED'; END IF;
  IF jsonb_typeof(p_shipping_address) <> 'object' OR p_shipping_address = '{}'::jsonb THEN RAISE EXCEPTION 'D2C_SHIPPING_ADDRESS_REQUIRED'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('d2c_checkout:' || p_cart_id::text || ':' || btrim(p_idempotency_key),0));
  SELECT * INTO v_existing FROM public.d2c_checkout_sessions
   WHERE cart_id = p_cart_id AND idempotency_key = btrim(p_idempotency_key) LIMIT 1;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.id, v_existing.total, v_existing.currency, true;
    RETURN;
  END IF;

  v_quote := public.d2c_quote_cart_v1(p_cart_id);
  INSERT INTO public.d2c_checkout_sessions(
    cart_id,idempotency_key,user_id,contact,shipping_address,quote_snapshot,subtotal,tax_total,total,currency
  ) VALUES (
    p_cart_id,btrim(p_idempotency_key),p_user_id,p_contact,p_shipping_address,v_quote,
    (v_quote->>'subtotal')::numeric,(v_quote->>'tax_total')::numeric,(v_quote->>'total')::numeric,v_quote->>'currency'
  ) RETURNING * INTO v_checkout;

  UPDATE public.d2c_cart_sessions SET status='CHECKED_OUT' WHERE id=p_cart_id;
  RETURN QUERY SELECT v_checkout.id, v_checkout.total, v_checkout.currency, false;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_create_checkout_v1(uuid,text,jsonb,jsonb,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_create_checkout_v1(uuid,text,jsonb,jsonb,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_register_payment_attempt_v1(
  p_checkout_id uuid,
  p_provider text,
  p_idempotency_key text
)
RETURNS TABLE(payment_attempt_id uuid, amount numeric, currency text, duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_checkout public.d2c_checkout_sessions%rowtype;
  v_attempt public.d2c_payment_attempts%rowtype;
BEGIN
  IF nullif(btrim(p_provider),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'D2C_PAYMENT_PROVIDER_AND_KEY_REQUIRED';
  END IF;
  SELECT * INTO v_checkout FROM public.d2c_checkout_sessions WHERE id=p_checkout_id FOR UPDATE;
  IF NOT FOUND OR v_checkout.status NOT IN ('QUOTED','PAYMENT_PENDING') OR v_checkout.expires_at <= now() THEN
    RAISE EXCEPTION 'D2C_CHECKOUT_NOT_PAYABLE';
  END IF;
  SELECT * INTO v_attempt FROM public.d2c_payment_attempts
    WHERE provider=upper(btrim(p_provider)) AND idempotency_key=btrim(p_idempotency_key) LIMIT 1;
  IF FOUND THEN
    IF v_attempt.checkout_id <> p_checkout_id THEN RAISE EXCEPTION 'D2C_PAYMENT_IDEMPOTENCY_COLLISION'; END IF;
    RETURN QUERY SELECT v_attempt.id,v_attempt.amount,v_attempt.currency,true; RETURN;
  END IF;
  INSERT INTO public.d2c_payment_attempts(checkout_id,provider,idempotency_key,amount,currency,status)
  VALUES(p_checkout_id,upper(btrim(p_provider)),btrim(p_idempotency_key),v_checkout.total,v_checkout.currency,'CREATED')
  RETURNING * INTO v_attempt;
  UPDATE public.d2c_checkout_sessions SET status='PAYMENT_PENDING' WHERE id=p_checkout_id AND status='QUOTED';
  RETURN QUERY SELECT v_attempt.id,v_attempt.amount,v_attempt.currency,false;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_register_payment_attempt_v1(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_register_payment_attempt_v1(uuid,text,text) TO service_role;

-- Called only AFTER the provider adapter has cryptographically verified the webhook.
CREATE OR REPLACE FUNCTION public.d2c_record_verified_payment_v1(
  p_payment_attempt_id uuid,
  p_provider_payment_id text,
  p_provider_event_id text,
  p_payload_hash text,
  p_result text,
  p_signature_verified boolean
)
RETURNS TABLE(order_intent_id uuid, web_order_reference text, public_tracking_id uuid, duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_attempt public.d2c_payment_attempts%rowtype;
  v_checkout public.d2c_checkout_sessions%rowtype;
  v_existing_event public.d2c_integration_webhook_events%rowtype;
  v_order public.d2c_order_intents%rowtype;
  v_status text := upper(btrim(coalesce(p_result,'')));
BEGIN
  IF NOT p_signature_verified THEN RAISE EXCEPTION 'D2C_WEBHOOK_SIGNATURE_NOT_VERIFIED'; END IF;
  IF nullif(btrim(p_provider_event_id),'') IS NULL OR nullif(btrim(p_payload_hash),'') IS NULL THEN
    RAISE EXCEPTION 'D2C_WEBHOOK_IDENTITY_REQUIRED';
  END IF;
  IF v_status NOT IN ('AUTHORIZED','CAPTURED','FAILED','CANCELLED') THEN RAISE EXCEPTION 'D2C_PAYMENT_RESULT_INVALID'; END IF;

  SELECT * INTO v_attempt FROM public.d2c_payment_attempts WHERE id=p_payment_attempt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'D2C_PAYMENT_ATTEMPT_NOT_FOUND'; END IF;

  SELECT * INTO v_existing_event FROM public.d2c_integration_webhook_events
   WHERE provider=v_attempt.provider AND provider_event_id=btrim(p_provider_event_id) LIMIT 1;
  IF FOUND THEN
    IF v_existing_event.payload_hash <> btrim(p_payload_hash) THEN RAISE EXCEPTION 'D2C_WEBHOOK_REPLAY_HASH_MISMATCH'; END IF;
    SELECT * INTO v_order FROM public.d2c_order_intents WHERE checkout_id=v_attempt.checkout_id LIMIT 1;
    RETURN QUERY SELECT v_order.id,v_order.web_order_reference,v_order.public_tracking_id,true;
    RETURN;
  END IF;

  INSERT INTO public.d2c_integration_webhook_events(provider,provider_event_id,payload_hash,signature_verified)
  VALUES(v_attempt.provider,btrim(p_provider_event_id),btrim(p_payload_hash),true);

  SELECT * INTO v_checkout FROM public.d2c_checkout_sessions WHERE id=v_attempt.checkout_id FOR UPDATE;
  IF NOT FOUND OR v_attempt.amount <> v_checkout.total OR v_attempt.currency <> v_checkout.currency THEN
    RAISE EXCEPTION 'D2C_PAYMENT_AMOUNT_AUTHORITY_MISMATCH';
  END IF;

  UPDATE public.d2c_payment_attempts SET
    provider_payment_id=nullif(btrim(p_provider_payment_id),''), status=v_status
  WHERE id=v_attempt.id;

  IF v_status = 'CAPTURED' THEN
    INSERT INTO public.d2c_order_intents(
      checkout_id,line_snapshot,contact_snapshot,delivery_snapshot,subtotal,tax_total,total,currency,paid_at
    ) VALUES(
      v_checkout.id,v_checkout.quote_snapshot->'lines',v_checkout.contact,v_checkout.shipping_address,
      v_checkout.subtotal,v_checkout.tax_total,v_checkout.total,v_checkout.currency,now()
    ) ON CONFLICT(checkout_id) DO NOTHING;
    SELECT * INTO v_order FROM public.d2c_order_intents WHERE checkout_id=v_checkout.id;
    UPDATE public.d2c_checkout_sessions SET status='PAID_AWAITING_HANDOFF' WHERE id=v_checkout.id;
    INSERT INTO public.d2c_order_events(order_intent_id,event_type,status,public_message)
      VALUES(v_order.id,'PAYMENT_CAPTURED','PAID_AWAITING_HANDOFF','Payment received. Your order is being prepared for processing.')
      ON CONFLICT DO NOTHING;
    INSERT INTO public.d2c_outbox_events(aggregate_type,aggregate_id,event_type,dedupe_key,payload)
      VALUES('D2C_ORDER_INTENT',v_order.id,'D2C_ORDER_PAID','d2c-order-paid:'||v_order.id::text,
        jsonb_build_object('order_intent_id',v_order.id,'web_order_reference',v_order.web_order_reference,'checkout_id',v_checkout.id))
      ON CONFLICT(dedupe_key) DO NOTHING;
  END IF;

  UPDATE public.d2c_integration_webhook_events SET processed=true,processed_at=now(),
    processing_result=jsonb_build_object('payment_attempt_id',v_attempt.id,'result',v_status,'order_intent_id',v_order.id)
  WHERE provider=v_attempt.provider AND provider_event_id=btrim(p_provider_event_id);

  RETURN QUERY SELECT v_order.id,v_order.web_order_reference,v_order.public_tracking_id,false;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_record_verified_payment_v1(uuid,text,text,text,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_record_verified_payment_v1(uuid,text,text,text,text,boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_link_canonical_order_v1(p_order_intent_id uuid, p_canonical_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_order public.d2c_order_intents%rowtype;
BEGIN
  PERFORM 1 FROM public.orders WHERE id=p_canonical_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'D2C_CANONICAL_ORDER_NOT_FOUND'; END IF;
  SELECT * INTO v_order FROM public.d2c_order_intents WHERE id=p_order_intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'D2C_ORDER_INTENT_NOT_FOUND'; END IF;
  IF v_order.canonical_order_id IS NOT NULL AND v_order.canonical_order_id <> p_canonical_order_id THEN
    RAISE EXCEPTION 'D2C_CANONICAL_ORDER_LINK_IMMUTABLE';
  END IF;
  UPDATE public.d2c_order_intents SET canonical_order_id=p_canonical_order_id,status='HANDED_OFF' WHERE id=p_order_intent_id;
  INSERT INTO public.d2c_order_events(order_intent_id,event_type,status,public_message,internal_metadata)
    VALUES(p_order_intent_id,'APPVERSE_HANDOFF','HANDED_OFF','Your order has entered fulfilment.',jsonb_build_object('canonical_order_id',p_canonical_order_id));
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_link_canonical_order_v1(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_link_canonical_order_v1(uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_append_order_event_v1(
  p_order_intent_id uuid,
  p_event_type text,
  p_status text,
  p_public_message text DEFAULT NULL,
  p_public_metadata jsonb DEFAULT '{}'::jsonb,
  p_internal_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_id uuid;
BEGIN
  IF upper(btrim(p_status)) NOT IN ('PAID_AWAITING_HANDOFF','HANDED_OFF','PROCESSING','READY_TO_DISPATCH','DISPATCHED','DELIVERED','CANCELLED','FAILED') THEN
    RAISE EXCEPTION 'D2C_ORDER_STATUS_INVALID';
  END IF;
  UPDATE public.d2c_order_intents SET status=upper(btrim(p_status)) WHERE id=p_order_intent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'D2C_ORDER_INTENT_NOT_FOUND'; END IF;
  INSERT INTO public.d2c_order_events(order_intent_id,event_type,status,public_message,public_metadata,internal_metadata)
  VALUES(p_order_intent_id,btrim(p_event_type),upper(btrim(p_status)),nullif(btrim(p_public_message),''),coalesce(p_public_metadata,'{}'::jsonb),coalesce(p_internal_metadata,'{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_append_order_event_v1(uuid,text,text,text,jsonb,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_append_order_event_v1(uuid,text,text,text,jsonb,jsonb) TO service_role;

-- Anonymous tracking is bearer-ID based and exposes no customer/payment/internal data.
CREATE OR REPLACE FUNCTION public.d2c_track_order_v1(p_public_tracking_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'web_order_reference', o.web_order_reference,
    'status', o.status,
    'updated_at', o.updated_at,
    'events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'event_type', e.event_type,
        'status', e.status,
        'message', e.public_message,
        'metadata', e.public_metadata,
        'occurred_at', e.occurred_at
      ) ORDER BY e.occurred_at,e.id)
      FROM public.d2c_order_events e WHERE e.order_intent_id=o.id
    ),'[]'::jsonb)
  )
  FROM public.d2c_order_intents o
  WHERE o.public_tracking_id=p_public_tracking_id;
$$;
REVOKE ALL ON FUNCTION public.d2c_track_order_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.d2c_track_order_v1(uuid) TO anon, authenticated, service_role;

-- Recovery token is generated/hashed outside the DB and only the hash is stored.
CREATE OR REPLACE FUNCTION public.d2c_redeem_cart_recovery_v1(p_token_hash text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_recovery public.d2c_cart_recovery_sessions%rowtype;
BEGIN
  SELECT * INTO v_recovery FROM public.d2c_cart_recovery_sessions
   WHERE token_hash=btrim(p_token_hash) FOR UPDATE;
  IF NOT FOUND OR v_recovery.status <> 'ACTIVE' OR v_recovery.expires_at <= now() THEN
    RAISE EXCEPTION 'D2C_RECOVERY_TOKEN_INVALID_OR_EXPIRED';
  END IF;
  UPDATE public.d2c_cart_recovery_sessions SET status='REDEEMED',redeem_count=redeem_count+1 WHERE id=v_recovery.id;
  -- No price is restored here.  The cart must be quoted again before checkout.
  UPDATE public.d2c_cart_sessions SET status='ACTIVE',expires_at=GREATEST(expires_at,now()+interval '24 hours') WHERE id=v_recovery.cart_id;
  RETURN v_recovery.cart_id;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_redeem_cart_recovery_v1(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_redeem_cart_recovery_v1(text) TO service_role;

COMMENT ON FUNCTION public.d2c_track_order_v1(uuid) IS
  'Public-safe D2C tracking projection. Returns only reference/status/public timeline; no PII, payment IDs, internal metadata, prices or canonical order IDs.';
COMMENT ON FUNCTION public.d2c_record_verified_payment_v1(uuid,text,text,text,text,boolean) IS
  'Provider-neutral post-signature payment result recorder. CAPTURED creates a D2C order intent/outbox event but never creates public.orders.';
COMMENT ON TABLE public.d2c_outbox_events IS
  'Reliable server-side handoff queue. D2C_ORDER_PAID is consumed by the future Appverse adapter; Core canonical order creation remains separate authority.';
