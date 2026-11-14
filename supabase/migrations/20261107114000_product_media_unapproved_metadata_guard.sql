-- AI Studio G3 / Core #484: protect unapproved product-media metadata.
-- Based on read-only production policy/grant inventory on 2026-11-07.
-- This migration fixes table access only. The legacy public Storage buckets
-- and previously exposed object URLs remain PUBLIC until separately remediated
-- through protected raw-media staging/migration; do not infer URL revocation.
--
-- RLS does not govern TRUNCATE. Historical anonymous grants included TRUNCATE,
-- TRIGGER, REFERENCES and DML despite the product-media write RLS policies.
-- Retain product-author DML and service-role operations while removing bypasses.
REVOKE ALL PRIVILEGES ON TABLE public.product_media FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.product_media TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.product_media TO authenticated;
GRANT ALL PRIVILEGES ON TABLE public.product_media TO service_role;

ALTER TABLE public.product_media ENABLE ROW LEVEL SECURITY;

-- PostgreSQL permissive RLS policies OR together. Therefore the historical
-- PUBLIC SELECT USING (true) cannot coexist with a restrictive anonymous rule.
DROP POLICY IF EXISTS "Public read media" ON public.product_media;
CREATE POLICY "Public read media" ON public.product_media
  FOR SELECT TO anon
  USING (status = 'approved');

DROP POLICY IF EXISTS "Authenticated read product media" ON public.product_media;
CREATE POLICY "Authenticated read product media" ON public.product_media
  FOR SELECT TO authenticated
  USING (
    status = 'approved'
    OR public.can_write_product_master()
    OR public.is_catalogue_reviewer()
  );

-- Existing INSERT/UPDATE/DELETE RLS predicates are NOT changed:
-- public.can_write_product_master() remains Core write authority.
-- No Storage policies, buckets, rows, approved media URLs, or media files are
-- updated here. Reviewer metadata access does not grant any write privileges.
COMMENT ON TABLE public.product_media IS
  'Approved rows are public-readable. Unapproved metadata is restricted to authorized product writers/catalogue reviewers; raw Storage objects require separate private-bucket remediation (Core #484).';
