-- AI Studio #240 / Core #484: NEW forward-versioned, source-only private staging foundation.
-- This is NOT restoration of withdrawn Core #492 migration versions 20261107123000/20261107124500.
-- Review current production migration ledger, policies and Core migration chronology before any deployment.
-- No existing public bucket, object, media row, URL or published asset is modified.
-- No upload caller switch, signed preview, approval promotion or legacy raw-media cleanup occurs here.

INSERT INTO storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
VALUES (
  'product-media-staging',
  'product-media-staging',
  false,
  52428800,
  ARRAY[
    'image/jpeg','image/png','image/webp','image/gif','image/avif',
    'video/mp4','video/webm','application/pdf'
  ]::text[]
)
ON CONFLICT (id) DO NOTHING;

-- Fail closed if a pre-existing colliding bucket has public delivery or
-- weaker upload limits. Never silently convert a shared bucket in-place.
DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'product-media-staging'
      AND name = 'product-media-staging'
      AND public IS FALSE
      AND file_size_limit = 52428800
      AND allowed_mime_types @> ARRAY[
        'image/jpeg','image/png','image/webp','image/gif','image/avif',
        'video/mp4','video/webm','application/pdf'
      ]::text[]
      AND cardinality(allowed_mime_types) = 8
  ) THEN
    RAISE EXCEPTION 'Private raw-media staging bucket does not meet fixed privacy and upload limits';
  END IF;
END;
$guard$;

INSERT INTO public.storage_bucket_contracts (
  bucket_id, classification, owning_application, public_delivery,
  write_authority, path_convention, retention_notes, migration_status
)
VALUES (
  'product-media-staging', 'private_internal', 'AI Studio', false,
  'governed_product_author_or_catalogue_media_submit',
  'products/{product_id_or_sku}/submissions/{unique_filename}',
  'Unapproved product evidence only. Reviewer-only promotion to a public approved asset required; never expose getPublicUrl. Retention and old exposed URL retirement governed by Core #484.',
  'active'
)
ON CONFLICT (bucket_id) DO NOTHING;

-- Existing public object SELECT policies name the legacy public buckets
-- explicitly; do not add staging to any of those permissive lists.

-- Effective scoped contributor/reviewer policies from the final withdrawn source,
-- consolidated into ONE fresh forward migration; no temporary broader policies.
DROP POLICY IF EXISTS studio_staging_upload_staff_owned_v1 ON storage.objects;
CREATE POLICY studio_staging_upload_staff_owned_v1
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'product-media-staging'
    AND auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active IS TRUE
        AND u.deleted_at IS NULL
    )
    AND (
      public.can_write_product_master()
      OR public.is_catalogue_reviewer()
      OR public.has_catalogue_permission('catalogue.media.submit')
    )
    AND owner_id = auth.uid()::text
    AND (storage.foldername(name))[1] = 'products'
    -- Require the documented products/{id_or_sku}/submissions/{file}
    -- layout. Prevent staging into misleading cross-workflow subfolders.
    AND cardinality(storage.foldername(name)) = 3
    AND NULLIF((storage.foldername(name))[2], '') IS NOT NULL
    AND (storage.foldername(name))[3] = 'submissions'
    AND NULLIF(storage.filename(name), '') IS NOT NULL
  );

DROP POLICY IF EXISTS studio_staging_read_owner_or_reviewer_v1 ON storage.objects;
CREATE POLICY studio_staging_read_owner_or_reviewer_v1
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'product-media-staging'
    AND auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active IS TRUE
        AND u.deleted_at IS NULL
    )
    AND (
      public.is_catalogue_reviewer()
      OR public.can_write_product_master()
      OR (
        owner_id = auth.uid()::text
        AND public.has_catalogue_permission('catalogue.media.submit')
      )
    )
  );

DROP POLICY IF EXISTS studio_staging_delete_reviewer_v1 ON storage.objects;
CREATE POLICY studio_staging_delete_reviewer_v1
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'product-media-staging'
    AND auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active IS TRUE
        AND u.deleted_at IS NULL
    )
    AND (
      public.is_catalogue_reviewer()
      OR public.can_write_product_master()
    )
  );

-- No anonymous SELECT/INSERT/UPDATE/DELETE policy and no ungoverned
-- upsert. The bucket remains PRIVATE. This is not a public-URL
-- revocation or legacy-media byte migration.
