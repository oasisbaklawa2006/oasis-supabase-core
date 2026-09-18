-- Governed reconciliation for ready-pack titles that explicitly encode pack quantity.
-- Contract coverage: 20260919121000_explicit_pack_count_title_backfill.sql
--
-- This migration never defaults quantity to 1 and never infers from weight or SKU.
-- It copies only explicit existing truth into products.pcs_per_pack when that field
-- is absent: either "Pack of N Pcs/Pieces" in the canonical title, or an exact
-- integer ratio of persisted pack weight to persisted per-piece weight for a
-- retail-pack/B2B-carton product. Existing non-zero pack quantities are immutable
-- to this repair. No default quantity is introduced.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.reconcile_explicit_pack_count_from_title_v1()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_title_updated integer := 0;
  v_weight_updated integer := 0;
BEGIN
  WITH candidates AS (
    SELECT
      p.id,
      ((regexp_match(
        coalesce(p.product_name, p.name, ''),
        '(?i)pack[[:space:]]+of[[:space:]]+([0-9]+)[[:space:]]*(pc|pcs|piece|pieces)'
      ))[1])::numeric AS explicit_count
    FROM public.products p
    WHERE coalesce(p.is_active, true) IS TRUE
      AND coalesce(p.pcs_per_pack, 0) <= 0
      AND lower(coalesce(p.product_type, p.product_family, '')) = 'retail_pack'
      AND lower(coalesce(p.category, '')) = 'ready packs'
      AND coalesce(p.product_name, p.name, '') ~*
        'pack[[:space:]]+of[[:space:]]+[0-9]+[[:space:]]*(pc|pcs|piece|pieces)'
  )
  UPDATE public.products p
  SET pcs_per_pack = c.explicit_count
  FROM candidates c
  WHERE p.id = c.id
    AND c.explicit_count > 0
    AND c.explicit_count <= 1000;

  GET DIAGNOSTICS v_title_updated = ROW_COUNT;

  WITH candidates AS (
    SELECT
      p.id,
      coalesce(p.net_weight_g, p.net_weight_grams) AS pack_weight_g,
      coalesce(p.weight_per_pc_grams, p.grams_per_piece) AS piece_weight_g
    FROM public.products p
    WHERE coalesce(p.is_active, true) IS TRUE
      AND coalesce(p.pcs_per_pack, 0) <= 0
      AND lower(coalesce(p.retail_uom, '')) = 'pack'
      AND lower(coalesce(p.b2b_uom, '')) = 'carton'
      AND coalesce(p.net_weight_g, p.net_weight_grams, 0) > 0
      AND coalesce(p.weight_per_pc_grams, p.grams_per_piece, 0) > 0
  ),
  exact_counts AS (
    SELECT
      id,
      pack_weight_g / piece_weight_g AS explicit_count
    FROM candidates
    WHERE pack_weight_g / piece_weight_g > 1
      AND pack_weight_g / piece_weight_g <= 1000
      AND abs(
        (pack_weight_g / piece_weight_g)
        - round(pack_weight_g / piece_weight_g)
      ) < 0.0001
  )
  UPDATE public.products p
  SET pcs_per_pack = round(c.explicit_count)
  FROM exact_counts c
  WHERE p.id = c.id;

  GET DIAGNOSTICS v_weight_updated = ROW_COUNT;

  RETURN jsonb_build_object(
    'title_updated_products', v_title_updated,
    'weight_ratio_updated_products', v_weight_updated,
    'updated_products', v_title_updated + v_weight_updated
  );
END;
$$;

REVOKE ALL ON FUNCTION public.reconcile_explicit_pack_count_from_title_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_explicit_pack_count_from_title_v1()
TO service_role;

COMMENT ON FUNCTION public.reconcile_explicit_pack_count_from_title_v1() IS
  'Service-role-only idempotent backfill of pcs_per_pack from explicit Pack of N Pcs/Pieces title truth or an exact integer persisted pack-weight/per-piece-weight ratio for retail-pack/carton products. Never defaults or overwrites a positive existing value.';

SELECT public.reconcile_explicit_pack_count_from_title_v1();
