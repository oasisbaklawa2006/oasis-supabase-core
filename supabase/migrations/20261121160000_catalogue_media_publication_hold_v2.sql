-- Studio #240 / Core #484: containment until governed private-media promotion exists.
-- Additive only: retain the canonical approval dispatcher and all current RBAC.
BEGIN;

CREATE OR REPLACE FUNCTION public.catalogue_media_reference_requires_publication_v1(p_payload jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT
    nullif(p_payload ->> 'storage_path', '') IS NOT NULL
    OR nullif(p_payload ->> 'storagePath', '') IS NOT NULL
    OR lower(btrim(coalesce(p_payload ->> 'bucket_id', ''))) = 'product-media-staging'
    OR lower(btrim(coalesce(p_payload ->> 'storage_bucket', ''))) = 'product-media-staging'
    OR CASE
      WHEN nullif(btrim(coalesce(p_payload ->> 'file_url', p_payload ->> 'fileUrl', '')), '') IS NULL THEN false
      ELSE
        btrim(coalesce(p_payload ->> 'file_url', p_payload ->> 'fileUrl')) !~* '^https?://[^[:space:]]+$'
        OR lower(coalesce(p_payload ->> 'file_url', p_payload ->> 'fileUrl')) ~ '(storage/v1/object/(sign|authenticated)/|product-media-staging)'
        -- Conservatively hold encoded references; do not permit encoded private-route bypasses.
        OR position('%' in coalesce(p_payload ->> 'file_url', p_payload ->> 'fileUrl')) > 0
    END;
$$;
REVOKE ALL ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_catalogue_media_publication_hold_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_effective_url text;
BEGIN
  IF NEW.status = 'approved' AND NEW.operation IN ('create', 'update') THEN
    -- The dispatcher writes the master row before updating the draft. An exception
    -- here rolls back the entire approval statement, including that master write.
    SELECT pm.file_url INTO v_effective_url
      FROM public.product_media pm WHERE pm.id = NEW.target_record_id;
    IF public.catalogue_media_reference_requires_publication_v1(NEW.payload)
       OR public.catalogue_media_reference_requires_publication_v1(
         jsonb_build_object('file_url', v_effective_url)
       ) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001',
        MESSAGE = 'Media requires governed publication before approval';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.enforce_catalogue_media_publication_hold_v1()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER catalogue_media_publication_hold_v1
  BEFORE INSERT OR UPDATE OF status, payload, target_record_id
  ON public.catalogue_media_submissions
  FOR EACH ROW EXECUTE FUNCTION public.enforce_catalogue_media_publication_hold_v1();

COMMENT ON FUNCTION public.enforce_catalogue_media_publication_hold_v1() IS
  'Core #484 containment: blocks approval of private, temporary or encoded media references atomically. Does not implement Storage promotion. Durable URL-only approvals and delete/reject operations retain canonical RBAC.';
COMMIT;
