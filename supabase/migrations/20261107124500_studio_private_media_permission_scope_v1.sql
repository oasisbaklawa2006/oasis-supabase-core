-- Core #484: refine new private-staging Storage RLS for catalogue
-- contributors. Immutable forward correction of the earlier unmerged
-- 20261107123000 staging foundation. Never edit existing applied/pending
-- migration history in place. Both files execute on clean preview before
-- any production release, and no existing public-media policies change.
--
-- Verified live Core: is_team_member(uuid) intentionally excludes the
-- catalogue_contributor role. Using that staff-only predicate in the new
-- staging bucket would silently reject explicitly permitted media drafts.
-- Instead require a CURRENT active, non-deleted public.users identity and
-- scoped author/reviewer/media-submit authority. Existing own-row SELECT
-- RLS on public.users permits a contributor to prove their active identity.

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
