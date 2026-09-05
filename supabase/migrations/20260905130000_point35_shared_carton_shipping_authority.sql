-- POINT35-CORE: shared master-carton shipping authority on public.products.
--
-- Census (20260905130000):
--   gross_weight_kg  — already canonical in 20260723161256 baseline; reused as-is
--                      (hamper/gift-pack shipping weight scope; comment not altered).
--   carton_dimensions_cm, cbm — absent from active Core authority; added here.
--
-- Semantics:
--   gross_weight_kg        Baseline authority preserved: total shipping weight for
--                          hampers / gift packs including packaging (20260723161256).
--   carton_dimensions_cm   Canonical free-text master-carton L×W×H (cm) for shipping/logistics.
--                          Distinct from product_dimensions_cm and structured dimension_*_cm.
--   cbm                    Master-carton cubic metres (m³). May be sourced or derived; when all
--                          dimension_l_cm, dimension_w_cm, dimension_h_cm describe the same
--                          master carton, cbm = (l * w * h) / 1000000.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS carton_dimensions_cm text,
  ADD COLUMN IF NOT EXISTS cbm numeric;

COMMENT ON COLUMN public.products.carton_dimensions_cm IS
  'Canonical free-text master-carton shipping dimensions in centimetres (e.g. "40 x 30 x 25"). Distinct from product_dimensions_cm and structured dimension_l_cm / dimension_w_cm / dimension_h_cm.';

COMMENT ON COLUMN public.products.cbm IS
  'Canonical master-carton cubic metres (m³) for shipping/logistics. When dimension_l_cm, dimension_w_cm, and dimension_h_cm describe the same master carton, cbm = (dimension_l_cm * dimension_w_cm * dimension_h_cm) / 1000000.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'products_cbm_nonnegative_check'
      AND conrelid = 'public.products'::regclass
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_cbm_nonnegative_check
      CHECK (cbm IS NULL OR (cbm >= 0 AND cbm <> 'NaN'::numeric));
  END IF;
END;
$$;
