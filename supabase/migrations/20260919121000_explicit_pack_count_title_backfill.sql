-- Governed reconciliation for catalogue products whose canonical title explicitly encodes pack quantity.
-- Contract coverage: 20260919121000_explicit_pack_count_title_backfill.sql
--
-- This migration never defaults quantity to 1 and never infers from weight or SKU.
-- It copies only explicit "Pack of N Pcs/Pieces" truth from the canonical title
-- into products.pcs_per_pack when that field is absent. Eligible products are
-- active products classified either as Ready packs or as retail_pack. Existing
-- positive pack quantities are immutable to this repair.

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
BEGIN
  WITH candidates AS (
    SELECT
      p.id,
      ((regexp_match(
        coalesce(p.product_name, p.name, ''),
        '(?i)pack[[:space:]]+of[[:space:]]+([0-9]+)[[:space:]]*(pc|pcs|piece|pieces)'
      ))[1])::numeric AS explicit_count
    FROM public.products p
    WHERE p.is_active IS TRUE
      AND coalesce(p.pcs_per_pack, 0) <= 0
      AND (
        lower(coalesce(p.product_type, p.product_family, '')) = 'retail_pack'
        OR lower(coalesce(p.category, '')) = 'ready packs'
      )
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

  RETURN jsonb_build_object(
    'title_updated_products', v_title_updated,
    'updated_products', v_title_updated
  );
END;
$$;

REVOKE ALL ON FUNCTION public.reconcile_explicit_pack_count_from_title_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_explicit_pack_count_from_title_v1()
TO service_role;

COMMENT ON FUNCTION public.reconcile_explicit_pack_count_from_title_v1() IS
  'Service-role-only idempotent backfill of pcs_per_pack from explicit Pack of N Pcs/Pieces canonical-title truth for active Ready packs or retail_pack products. Never infers from weight/SKU, defaults quantity, or overwrites a positive existing value.';

SELECT public.reconcile_explicit_pack_count_from_title_v1();
