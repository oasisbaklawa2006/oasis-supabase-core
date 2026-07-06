-- PR: Product Truth MVP — additive only (do not run destructively)
-- Optional JSON snapshot for readiness metadata; app works without this column.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS product_truth_snapshot jsonb;

COMMENT ON COLUMN public.products.product_truth_snapshot IS
  'Optional Product Truth readiness/UOM snapshot from AI Studio. Nullable.';
