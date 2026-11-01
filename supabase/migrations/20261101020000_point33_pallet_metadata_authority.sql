-- POINT33 — canonical optional pallet metadata for each sellable product SKU.
-- Adds the minimum shared Core persistence required by AI Studio's hierarchy.
-- No product/price authorizations, existing rows, or RLS policies change.
-- Null means "not supplied"; never infer pallet counts from carton sizes.
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS cartons_per_pallet integer,
  ADD COLUMN IF NOT EXISTS master_cartons_per_pallet integer,
  ADD COLUMN IF NOT EXISTS pallet_uom text;

COMMENT ON COLUMN public.products.cartons_per_pallet IS
  'Optional number of case/inner cartons per pallet; positive integer. Do not derive from master-carton count.';
COMMENT ON COLUMN public.products.master_cartons_per_pallet IS
  'Optional number of master cartons per pallet; positive integer. Independently asserted from case count.';
COMMENT ON COLUMN public.products.pallet_uom IS
  'Explicit operator-specified pallet unit/type. Missing or unknown remains NULL; not derived from carton count.';

-- This additive constraint preserves old rows (all three fields are initially NULL)
-- and prevents incomplete pallet metadata. Quantities at different levels may
-- coexist; the relationship is governed separately by the packaging hierarchy.
ALTER TABLE public.products
  ADD CONSTRAINT products_point33_pallet_metadata_valid CHECK (
    (cartons_per_pallet IS NULL OR cartons_per_pallet BETWEEN 1 AND 10000)
    AND (master_cartons_per_pallet IS NULL OR master_cartons_per_pallet BETWEEN 1 AND 10000)
    AND (pallet_uom IS NULL OR (
      char_length(btrim(pallet_uom)) BETWEEN 1 AND 64
      AND pallet_uom = btrim(pallet_uom)
    ))
    AND (
      (cartons_per_pallet IS NULL AND master_cartons_per_pallet IS NULL)
      OR pallet_uom IS NOT NULL
    )
  );

-- Existing products INSERT/UPDATE and product_variants rules remain unchanged.
-- This migration does not grant new permission to any AI Studio role.
