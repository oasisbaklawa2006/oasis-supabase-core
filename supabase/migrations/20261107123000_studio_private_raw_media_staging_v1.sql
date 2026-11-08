-- Core #484 / AI Studio #240: provision a PRIVATE immutable raw-media staging
-- bucket without changing the public product-media or product-images buckets.
-- Source authority: existing Core is_internal_staff(), is_catalogue_reviewer(),
-- and can_write_product_master() functions. This migration never copies, exposes,
-- approves, publishes or deletes product images or changes existing objects.
-- Future Studio staged uploads must use authenticated/private signed delivery;
-- getPublicUrl() MUST NEVER be used for files stored in this bucket.

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
DROP POLICY IF EXISTS studio_staging_upload_staff_owned_v1 ON storage.objects;
CREATE POLICY studio_staging_upload_staff_owned_v1
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'product-media-staging'
    AND public.is_team_member(auth.uid())
    AND auth.uid() IS NOT NULL
    AND (
      public.can_write_product_master()
      OR public.is_catalogue_reviewer()
      OR public.has_catalogue_permission('catalogue.media.submit')
    )
    AND owner_id = auth.uid()::text
    AND (storage.foldername(name))[1] = 'products'
  );

DROP POLICY IF EXISTS studio_staging_read_owner_or_reviewer_v1 ON storage.objects;
CREATE POLICY studio_staging_read_owner_or_reviewer_v1
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'product-media-staging'
    AND public.is_team_member(auth.uid())
    AND auth.uid() IS NOT NULL
    AND (
      (owner_id = auth.uid()::text AND (
        public.can_write_product_master()
        OR public.is_catalogue_reviewer()
        OR public.has_catalogue_permission('catalogue.media.submit')
      ))
      OR public.is_catalogue_reviewer()
      OR public.can_write_product_master()
    )
  );

-- Draft attachments are immutable: no UPDATE/upsert policy. Only a
-- specifically authorised reviewer or Product Master writer can remove
-- staging objects; an ordinary contributor cannot silently replace evidence.
DROP POLICY IF EXISTS studio_staging_delete_reviewer_v1 ON storage.objects;
CREATE POLICY studio_staging_delete_reviewer_v1
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'product-media-staging'
    AND public.is_team_member(auth.uid())
    AND (
      public.is_catalogue_reviewer()
      OR public.can_write_product_master()
    )
  );

-- No anonymous SELECT/INSERT/UPDATE/DELETE policy for this bucket. Private
-- object GET and signed URL creation require authorised Storage SELECT RLS.
