-- Buyer full-feel backend projections.
-- Programme routes:
--   * Point 100 macro integration mission (Buyer catalogue/account journey)
--   * ASM-OC-01 / Point 54a Oasis Connect (staff readiness projection)
--
-- Additive only: no table mutation, no seed/data mutation, no production deployment.
-- Reuses canonical Buyer identity authority and existing product/account tables.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- -----------------------------------------------------------------------------
-- 1. Buyer-safe saved delivery-address projection.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_delivery_addresses_v1()
RETURNS TABLE (
  address_id uuid,
  label text,
  street_address text,
  city text,
  state text,
  pincode text,
  contact_person text,
  contact_phone text,
  is_default boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    da.id AS address_id,
    da.label,
    da.street_address,
    da.city,
    da.state,
    da.pincode,
    nullif(btrim(da.contact_person), '') AS contact_person,
    nullif(btrim(da.contact_phone), '') AS contact_phone,
    coalesce(da.is_default, false) AS is_default,
    da.created_at
  FROM eligible e
  JOIN public.delivery_addresses da
    ON da.company_id = e.company_id
       OR (da.company_id IS NULL AND da.user_id = auth.uid())
  WHERE e.company_id IS NOT NULL
  ORDER BY coalesce(da.is_default, false) DESC, da.created_at DESC, da.id;
$$;

COMMENT ON FUNCTION public.customer_delivery_addresses_v1() IS
  'Buyer-safe saved delivery addresses for the canonical authenticated approved Buyer company, plus caller-owned legacy rows with no company_id. No client-supplied tenant identifier.';

REVOKE ALL ON FUNCTION public.customer_delivery_addresses_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_delivery_addresses_v1() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. Buyer-safe current shipping/transporter preference projection.
-- Existing authority is companies.preferred_courier + courier_account_number.
-- This deliberately exposes a single current preference; it does not invent a
-- multi-transporter master that does not exist yet.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_shipping_preferences_v1()
RETURNS TABLE (
  company_id uuid,
  preferred_transporter text,
  transporter_account_number text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    c.id AS company_id,
    nullif(btrim(c.preferred_courier), '') AS preferred_transporter,
    nullif(btrim(c.courier_account_number), '') AS transporter_account_number
  FROM eligible e
  JOIN public.companies c ON c.id = e.company_id
  WHERE e.company_id IS NOT NULL;
$$;

COMMENT ON FUNCTION public.customer_shipping_preferences_v1() IS
  'Buyer-safe read projection of the existing single company shipping preference. Preferred transporter is an alias of companies.preferred_courier; no multi-transporter authority is implied.';

REVOKE ALL ON FUNCTION public.customer_shipping_preferences_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_shipping_preferences_v1() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. Buyer-safe private-label catalogue.
-- Only already-published products may appear. Internal private-label costs are
-- intentionally never selected. Price remains nullable until business data is
-- populated/approved; the backend does not derive or invent a selling price.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_private_label_products_v1()
RETURNS TABLE (
  product_id uuid,
  sku text,
  product_name text,
  hero_image_url text,
  private_label_moq numeric,
  private_label_moq_uom text,
  private_label_price numeric,
  currency text,
  customization_allowed boolean,
  customization_note text,
  customization_caution text,
  lead_time_days integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    pp.product_id,
    pp.sku,
    pp.product_name,
    pp.hero_image_url,
    p.private_label_moq::numeric,
    nullif(btrim(p.private_label_moq_uom), '') AS private_label_moq_uom,
    CASE
      WHEN p.private_label_price IS NOT NULL AND p.private_label_price > 0
        THEN p.private_label_price::numeric
      ELSE NULL
    END AS private_label_price,
    coalesce(nullif(btrim(p.currency), ''), 'INR') AS currency,
    coalesce(p.customization_allowed, false) AS customization_allowed,
    nullif(btrim(p.customization_note), '') AS customization_note,
    nullif(btrim(p.customization_caution), '') AS customization_caution,
    pp.lead_time_days
  FROM eligible e
  CROSS JOIN public.published_products_v1() pp
  JOIN public.products p ON p.id = pp.product_id
  WHERE e.company_id IS NOT NULL
    AND p.private_label_allowed IS TRUE
  ORDER BY pp.product_name, pp.product_id;
$$;

COMMENT ON FUNCTION public.customer_private_label_products_v1() IS
  'Published Buyer-safe private-label eligibility/MOQ/terms projection. Internal private-label cost columns are excluded. Selling price is returned only when the explicit customer-facing private_label_price field is populated.';

REVOKE ALL ON FUNCTION public.customer_private_label_products_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_private_label_products_v1() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Buyer-safe packaging/decoration offers.
-- Packaging products must pass the same publication gate as the ordinary
-- catalogue. Commercial facts come only from buyer_product_prices_v1(); legacy
-- products.price_b2b is intentionally not exposed/bypassed.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_packaging_offers_v1()
RETURNS TABLE (
  product_id uuid,
  sku text,
  product_name text,
  short_description text,
  hero_image_url text,
  category text,
  primary_uom text,
  selling_price numeric,
  currency text,
  gst_rate numeric,
  tax_inclusive boolean,
  minimum_order_quantity numeric,
  minimum_order_uom text,
  order_increment numeric,
  order_increment_uom text,
  lead_time_days integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  ),
  price AS (
    SELECT * FROM public.buyer_product_prices_v1()
  )
  SELECT
    pp.product_id,
    pp.sku,
    pp.product_name,
    pp.short_description,
    pp.hero_image_url,
    pp.category,
    pp.primary_uom,
    pr.selling_price,
    pr.currency,
    pr.gst_rate,
    pr.tax_inclusive,
    pr.minimum_order_quantity,
    pr.minimum_order_uom,
    pr.order_increment,
    pr.order_increment_uom,
    pp.lead_time_days
  FROM eligible e
  CROSS JOIN public.published_products_v1() pp
  JOIN public.products p ON p.id = pp.product_id
  LEFT JOIN price pr ON pr.product_id = pp.product_id
  WHERE e.company_id IS NOT NULL
    AND (
      lower(coalesce(p.category, '')) = 'packaging & decoration material'
      OR lower(coalesce(p.product_type, '')) = 'packaging_material'
      OR lower(coalesce(p.product_class, '')) = 'packaging_material'
    )
  ORDER BY pp.product_name, pp.product_id;
$$;

COMMENT ON FUNCTION public.customer_packaging_offers_v1() IS
  'Published Buyer-safe packaging/decoration projection. Pricing/MOQ is sourced only from buyer_product_prices_v1; legacy direct product price fields are never exposed. Rows may truthfully carry NULL commercial fields when governed pricing is not yet available.';

REVOKE ALL ON FUNCTION public.customer_packaging_offers_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_packaging_offers_v1() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. Staff-safe Buyer/Connect readiness summary for AI Studio.
-- No token ids, hashes, plaintext tokens, customer PII or internal product costs.
-- Catalogue reviewers/admins can see only aggregate readiness counts.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.connect_staff_readiness_v1()
RETURNS TABLE (
  published_product_count integer,
  approved_b2b_price_rule_count integer,
  b2b_priced_published_product_count integer,
  published_private_label_count integer,
  private_label_price_ready_count integer,
  published_packaging_count integer,
  packaging_price_ready_count integer,
  connect_profile_count integer,
  active_connect_consumer_count integer,
  active_connect_binding_count integer,
  active_connect_token_count integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT (coalesce(public.is_admin(), false) OR coalesce(public.is_catalogue_reviewer(), false)) THEN
    RAISE EXCEPTION 'catalogue reviewer or admin permission required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    (SELECT count(*)::integer FROM public.published_products_v1()),
    (
      SELECT count(*)::integer
      FROM public.product_pricing_rules r
      WHERE lower(coalesce(r.price_channel, '')) = 'b2b'
        AND lower(coalesce(r.approval_status, '')) = 'approved'
        AND coalesce(r.calculated_price, r.base_price) > 0
        AND (r.valid_from IS NULL OR r.valid_from <= current_date)
        AND (r.valid_until IS NULL OR r.valid_until >= current_date)
    ),
    (
      SELECT count(DISTINCT r.product_id)::integer
      FROM public.product_pricing_rules r
      JOIN public.published_products_v1() pp ON pp.product_id = r.product_id
      WHERE lower(coalesce(r.price_channel, '')) = 'b2b'
        AND lower(coalesce(r.approval_status, '')) = 'approved'
        AND coalesce(r.calculated_price, r.base_price) > 0
        AND (r.valid_from IS NULL OR r.valid_from <= current_date)
        AND (r.valid_until IS NULL OR r.valid_until >= current_date)
    ),
    (
      SELECT count(*)::integer
      FROM public.published_products_v1() pp
      JOIN public.products p ON p.id = pp.product_id
      WHERE p.private_label_allowed IS TRUE
    ),
    (
      SELECT count(*)::integer
      FROM public.published_products_v1() pp
      JOIN public.products p ON p.id = pp.product_id
      WHERE p.private_label_allowed IS TRUE
        AND p.private_label_price IS NOT NULL
        AND p.private_label_price > 0
    ),
    (
      SELECT count(*)::integer
      FROM public.published_products_v1() pp
      JOIN public.products p ON p.id = pp.product_id
      WHERE lower(coalesce(p.category, '')) = 'packaging & decoration material'
         OR lower(coalesce(p.product_type, '')) = 'packaging_material'
         OR lower(coalesce(p.product_class, '')) = 'packaging_material'
    ),
    (
      SELECT count(DISTINCT r.product_id)::integer
      FROM public.product_pricing_rules r
      JOIN public.published_products_v1() pp ON pp.product_id = r.product_id
      JOIN public.products p ON p.id = pp.product_id
      WHERE lower(coalesce(r.price_channel, '')) = 'b2b'
        AND lower(coalesce(r.approval_status, '')) = 'approved'
        AND coalesce(r.calculated_price, r.base_price) > 0
        AND (r.valid_from IS NULL OR r.valid_from <= current_date)
        AND (r.valid_until IS NULL OR r.valid_until >= current_date)
        AND (
          lower(coalesce(p.category, '')) = 'packaging & decoration material'
          OR lower(coalesce(p.product_type, '')) = 'packaging_material'
          OR lower(coalesce(p.product_class, '')) = 'packaging_material'
        )
    ),
    (SELECT count(*)::integer FROM public.connect_profiles WHERE status = 'active'),
    (SELECT count(*)::integer FROM public.connect_consumers WHERE status = 'active'),
    (SELECT count(*)::integer FROM public.connect_bindings WHERE status = 'active'),
    (
      SELECT count(*)::integer
      FROM public.connect_tokens
      WHERE revoked_at IS NULL
        AND (expires_at IS NULL OR expires_at > statement_timestamp())
    );
END;
$$;

COMMENT ON FUNCTION public.connect_staff_readiness_v1() IS
  'Aggregate Buyer/Oasis Connect readiness facts for authenticated catalogue reviewers/admins. Never returns token material, customer PII, cost or margin fields.';

REVOKE ALL ON FUNCTION public.connect_staff_readiness_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.connect_staff_readiness_v1() TO authenticated, service_role;
