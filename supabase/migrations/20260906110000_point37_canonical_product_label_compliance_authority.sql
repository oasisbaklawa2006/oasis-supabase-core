-- POINT37-CORE: canonical product-level FSSAI / legal label-compliance authority on public.products.
--
-- Census (20260906110000):
--   products.fssai_licence_number — absent from active Core authority; added here.
--   products.country_of_origin — absent on public.products (exists only on import/staging
--     and unrelated tables); added here for legal label print.
--   products.label_manufacturer_details — absent; added here for manufacturer / marketer /
--     packed-by / imported-by block required on Indian retail labels.
--   companies.fssai_number — buyer/company registration authority only; NOT product label
--     compliance and MUST NOT be substituted for product-level FSSAI.
--   customer_import_company_candidates.fssai_number — import staging only.
--   archived public.labels.fssai_license — pre-baseline Trace/label row surface
--     (20260506044916); not active Core PIM authority.
--   products.ingredients / allergen_warnings / nutritional_info — exist on products but
--     remain separate nutrition/composition authority (not scored as Point37 closure).
--   published_products_v1 — intentionally unchanged; label-compliance fields are not
--     customer-catalogue publication data.
--
-- Semantics:
--   fssai_licence_number       Canonical 14-digit FSSAI licence for label print. Nullable;
--                              NULL = unknown/deferred — no invented default licence.
--   country_of_origin          Canonical product country-of-origin declaration for labels.
--                              Nullable; NULL = unknown/deferred — no invented default.
--   label_manufacturer_details Free-text manufacturer / marketer / packed-by / imported-by
--                              block for legal label print. Nullable.
--
-- Downstream:
--   AI Studio Point37 (#156) requires this Core authority before product-level FSSAI /
--   legal label data may be persisted. Trace label print execution remains Point95.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS fssai_licence_number text,
  ADD COLUMN IF NOT EXISTS country_of_origin text,
  ADD COLUMN IF NOT EXISTS label_manufacturer_details text;

COMMENT ON COLUMN public.products.fssai_licence_number IS
  'Canonical 14-digit FSSAI licence number for product label compliance. NULL = unknown/deferred (no default). Distinct from public.companies.fssai_number (buyer registration) and archived labels.fssai_license (Trace print row).';

COMMENT ON COLUMN public.products.country_of_origin IS
  'Canonical product country-of-origin declaration for legal label print. NULL = unknown/deferred (no default).';

COMMENT ON COLUMN public.products.label_manufacturer_details IS
  'Canonical free-text manufacturer / marketer / packed-by / imported-by block for legal label print. NULL = unknown/deferred.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'products_fssai_licence_number_format_check'
      AND conrelid = 'public.products'::regclass
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_fssai_licence_number_format_check
      CHECK (
        fssai_licence_number IS NULL
        OR fssai_licence_number ~ '^[0-9]{14}$'
      );
  END IF;
END;
$$;
