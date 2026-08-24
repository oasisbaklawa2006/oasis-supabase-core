-- Lane 2 C1 (Central issue #368): product_bom versioning/effective-dating
-- schema. Additive and backward-compatible -- no grant changes, no data
-- migration of the existing free-text source_department column, and no
-- change to AdminProducts.tsx's existing direct-write behaviour. That
-- client rewrite (and locking product_bom's grants down to a governed RPC)
-- is deliberately deferred to a follow-up PR once this schema is in place.
--
-- product_bom today: no version, no effective-date, no UOM conversion, no
-- yield/waste %, no substitution, and source_department is free text typed
-- per-BOM-line in AdminProducts.tsx (prefilled from the parent product's
-- production_department, then freely editable, with zero constraint).
--
-- NOT backfilling source_store_code from source_department in this
-- migration. b2b_inventory_stores' four canonical codes (B2B_RAW,
-- FINISHED_GOODS, 3PGS, PACKING_ASSEMBLY, see
-- 20260803194132_phase2_b2b_store_fulfilment_contract.sql) describe STORES
-- a component is drawn from; source_department's actual values today are
-- overwhelmingly production DEPARTMENTS (ARABIC_SWEETS, BAKERY, ...) --
-- "made in-house by this department", which has no honest equivalent among
-- the four store codes. Writing a lossy guess now (e.g. defaulting every
-- department value to FINISHED_GOODS) would silently misclassify
-- internally-produced components as store-sourced ones and corrupt exactly
-- the shortfall-routing decision this column exists to drive. That
-- reconciliation is a real product decision (does "produced in-house"
-- become a fifth store-like value, or a separate is_internal_production
-- flag alongside source_store_code?) for a human owner to make, not for a
-- migration to assume silently -- left for the PR that actually replaces
-- AdminProducts.tsx's raw text input with a constrained selector.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.product_bom
  ADD COLUMN IF NOT EXISTS bom_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS effective_from timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS effective_until timestamptz NULL,
  ADD COLUMN IF NOT EXISTS uom_conversion_factor numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS yield_pct numeric NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS waste_pct numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS substitution_group text NULL,
  ADD COLUMN IF NOT EXISTS source_store_code text NULL
    REFERENCES public.b2b_inventory_stores(store_code);

ALTER TABLE public.product_bom
  DROP CONSTRAINT IF EXISTS product_bom_version_positive_check;
ALTER TABLE public.product_bom
  ADD CONSTRAINT product_bom_version_positive_check CHECK (bom_version >= 1);

ALTER TABLE public.product_bom
  DROP CONSTRAINT IF EXISTS product_bom_effective_window_check;
ALTER TABLE public.product_bom
  ADD CONSTRAINT product_bom_effective_window_check
  CHECK (effective_until IS NULL OR effective_until > effective_from);

ALTER TABLE public.product_bom
  DROP CONSTRAINT IF EXISTS product_bom_uom_conversion_factor_positive_check;
ALTER TABLE public.product_bom
  ADD CONSTRAINT product_bom_uom_conversion_factor_positive_check CHECK (uom_conversion_factor > 0);

ALTER TABLE public.product_bom
  DROP CONSTRAINT IF EXISTS product_bom_yield_pct_range_check;
ALTER TABLE public.product_bom
  ADD CONSTRAINT product_bom_yield_pct_range_check CHECK (yield_pct > 0 AND yield_pct <= 100);

ALTER TABLE public.product_bom
  DROP CONSTRAINT IF EXISTS product_bom_waste_pct_range_check;
ALTER TABLE public.product_bom
  ADD CONSTRAINT product_bom_waste_pct_range_check CHECK (waste_pct >= 0 AND waste_pct < 100);

-- Deliberately NOT adding a "one current version per (product, component)"
-- unique index in this migration: AdminProducts.tsx currently does an
-- unconditional delete-then-reinsert of every BOM line on every save
-- (supabase.from("product_bom").delete().eq("product_id", productId), then
-- a fresh insert), so this migration has no visibility into whether live
-- data already contains rows that a naive uniqueness rule would reject --
-- and a schema-only PR is the wrong place to discover and fix that blind.
-- "One current version" enforcement belongs with the governed RPC that
-- actually drives bom_version transitions (C2/AdminProducts.tsx rewrite),
-- once we can validate it against real data first.

COMMENT ON COLUMN public.product_bom.bom_version IS
  'Monotonic version number for this (product, component) BOM line. A new version supersedes the prior one by closing its effective_until, never by editing it in place.';
COMMENT ON COLUMN public.product_bom.source_store_code IS
  'FK to b2b_inventory_stores.store_code. NULL for existing rows and for any component produced in-house rather than drawn from one of the four canonical stores -- see this migration''s header for why an automatic backfill from source_department was deliberately not attempted.';
