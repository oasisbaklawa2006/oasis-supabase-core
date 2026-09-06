-- POINT36-CORE: canonical product-level dispatch lead-time authority on public.products.
--
-- Census (20260906100000):
--   products.lead_time_days — absent from active Core authority; added here.
--   product_bom_items.lead_time_days — existed only on the archived pre-baseline
--     BOM surface (20260506102051); active public.product_bom has no component
--     lead-time column. Component lead times are not canonical product authority.
--
-- Semantics:
--   lead_time_days   Canonical explicit product-level dispatch lead time in whole
--                    calendar days from order acceptance to dispatch-ready. Nullable;
--                    NULL means deferred/unknown — no invented default.
--
-- BOM / component relationship:
--   products.lead_time_days is authoritative for catalogue and dispatch promises
--   when set. It is NOT derived from BOM component lead times and MUST NOT be
--   silently overwritten or inferred from MAX(component lead times). When NULL,
--   consumers MUST treat dispatch lead time as unknown/deferred unless a future
--   governed contract explicitly marks a value as derived.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS lead_time_days integer;

COMMENT ON COLUMN public.products.lead_time_days IS
  'Canonical explicit product-level dispatch lead time in whole calendar days from order acceptance to dispatch-ready. NULL = deferred/unknown (no default). Authoritative when set; not derived from public.product_bom or archived product_bom_items component lead times.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'products_lead_time_days_nonnegative_check'
      AND conrelid = 'public.products'::regclass
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_lead_time_days_nonnegative_check
      CHECK (lead_time_days IS NULL OR lead_time_days >= 0);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.published_products_v1()
RETURNS TABLE(
  product_id uuid,
  sku text,
  product_name text,
  short_description text,
  long_description text,
  category text,
  subcategory text,
  hero_image_url text,
  pack_size text,
  storage_type text,
  shelf_life text,
  shelf_life_days integer,
  lead_time_days integer,
  dietary_tags text[],
  allergen_warnings text,
  primary_uom text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $$
  SELECT
    p.id AS product_id,
    p.sku,
    coalesce(nullif(btrim(p.product_name), ''), p.name) AS product_name,
    nullif(btrim(p.short_description), '') AS short_description,
    nullif(btrim(p.description), '') AS long_description,
    p.category,
    coalesce(nullif(btrim(p.subcategory), ''), nullif(btrim(p.sub_category), '')) AS subcategory,
    coalesce(nullif(btrim(p.hero_image_url), ''), nullif(btrim(p.image_url), '')) AS hero_image_url,
    p.pack_size,
    p.storage_type,
    p.shelf_life,
    p.shelf_life_days,
    p.lead_time_days,
    p.dietary_tags,
    p.allergen_warnings,
    coalesce(nullif(btrim(p.primary_uom), ''), nullif(btrim(p.uom), '')) AS primary_uom,
    p.created_at
  FROM public.products p
  WHERE p.is_active IS TRUE
    AND p.visible_in_catalog IS TRUE
    AND p.is_catalogue_ready IS TRUE
    AND nullif(btrim(p.sku), '') IS NOT NULL
    AND coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), '')) IS NOT NULL
  ORDER BY coalesce(nullif(btrim(p.product_name), ''), p.name), p.id;
$$;

COMMENT ON FUNCTION public.published_products_v1() IS
  'Customer-safe product catalogue projection v1. Returns only active, visible, catalogue-ready products and excludes pricing, cost, MOQ, and draft-only fields. Includes canonical products.lead_time_days dispatch lead-time authority when set.';

REVOKE ALL ON FUNCTION public.published_products_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.published_products_v1() TO anon, authenticated, service_role;
