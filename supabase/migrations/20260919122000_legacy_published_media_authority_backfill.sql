-- Governed reconciliation of legacy published hero-image authority.
-- Contract coverage: 20260919122000_legacy_published_media_authority_backfill.sql
--
-- Historical catalogue rows can have a trusted hero URL and visible_in_catalog=true
-- while predating public.product_media. AI Studio intentionally treats product_media
-- as authoritative when rows exist, and refuses to invent approval for unpublished
-- products. This service-role-only reconciliation promotes only the narrow historical
-- case where catalogue publication itself is existing approval evidence.
--
-- Safety boundaries:
--   * active products only
--   * visible_in_catalog=true only
--   * existing non-PDF hero/image URL required
--   * absolutely no existing product_media rows for the product
--   * idempotent on repeat execution
--   * no approval of hidden/unpublished rows
--   * no replacement of existing media authority

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.reconcile_legacy_published_product_media_authority_v1()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_inserted integer := 0;
  v_synced integer := 0;
BEGIN
  INSERT INTO public.product_media (
    product_id,
    file_url,
    type,
    status,
    alt_text
  )
  SELECT
    p.id,
    coalesce(nullif(btrim(p.hero_image_url), ''), nullif(btrim(p.image_url), '')),
    'hero_image',
    'approved',
    'legacy_published_catalogue_hero_backfill'
  FROM public.products p
  WHERE p.is_active IS TRUE
    AND coalesce(p.visible_in_catalog, false) IS TRUE
    AND coalesce(nullif(btrim(p.hero_image_url), ''), nullif(btrim(p.image_url), '')) IS NOT NULL
    AND coalesce(nullif(btrim(p.hero_image_url), ''), nullif(btrim(p.image_url), ''))
          NOT ILIKE '%/\_pdf\_pages/%'
    AND NOT EXISTS (
      SELECT 1
      FROM public.product_media pm
      WHERE pm.product_id = p.id
    );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  UPDATE public.products p
  SET media_status = 'approved'
  WHERE p.is_active IS TRUE
    AND coalesce(p.visible_in_catalog, false) IS TRUE
    AND EXISTS (
      SELECT 1
      FROM public.product_media pm
      WHERE pm.product_id = p.id
        AND pm.type = 'hero_image'
        AND pm.status = 'approved'
        AND pm.alt_text = 'legacy_published_catalogue_hero_backfill'
        AND pm.file_url = coalesce(
          nullif(btrim(p.hero_image_url), ''),
          nullif(btrim(p.image_url), '')
        )
    )
    AND coalesce(p.media_status, '') IS DISTINCT FROM 'approved';

  GET DIAGNOSTICS v_synced = ROW_COUNT;

  RETURN jsonb_build_object(
    'inserted_media_rows', v_inserted,
    'synced_product_rows', v_synced
  );
END;
$$;

REVOKE ALL ON FUNCTION public.reconcile_legacy_published_product_media_authority_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_legacy_published_product_media_authority_v1()
TO service_role;

COMMENT ON FUNCTION public.reconcile_legacy_published_product_media_authority_v1() IS
  'Service-role-only, idempotent reconciliation of historically published catalogue hero URLs into governed product_media authority. Never approves inactive/unknown-activity, hidden products, PDF-page fallbacks, or products with any existing product_media authority.';

-- One-time governed reconciliation for the production-history gap.
SELECT public.reconcile_legacy_published_product_media_authority_v1();
