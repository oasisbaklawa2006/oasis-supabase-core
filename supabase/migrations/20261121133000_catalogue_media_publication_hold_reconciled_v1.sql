-- Core #484 / Studio #240: forward-only consolidated preproduction proposal.

-- Preserve original PR #580 and already-applied isolated Preview migration history.

-- No Storage promotion, published-media backfill or product/role ACL changes.

BEGIN;

CREATE OR REPLACE FUNCTION public.catalogue_media_reference_requires_publication_v1(p_payload jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_file_url text := nullif(btrim(coalesce(p_payload ->> 'file_url', p_payload ->> 'fileUrl', '')), '');
  v_authority text;
  v_host text;
  v_port text;
BEGIN
  IF nullif(p_payload ->> 'storage_path', '') IS NOT NULL
     OR nullif(p_payload ->> 'storagePath', '') IS NOT NULL
     OR lower(btrim(coalesce(p_payload ->> 'bucket_id', ''))) = 'product-media-staging'
     OR lower(btrim(coalesce(p_payload ->> 'storage_bucket', ''))) = 'product-media-staging' THEN
    RETURN true;
  END IF;

  IF v_file_url IS NULL THEN
    RETURN false;
  END IF;

  IF v_file_url !~* '^https?://(\[[0-9a-f:.]+\]|[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.?)(:[0-9]+)?(/[a-z0-9._~!$&''()*+,;=:@/-]*)?(\?[a-z0-9._~!$&''()*+,;=:@/?-]*)?(#[a-z0-9._~!$&''()*+,;=:@/?-]*)?$' THEN
    RETURN true;
  END IF;

  v_authority := substring(v_file_url FROM '(?i)^https?://([^/?#]+)');
  IF v_authority IS NULL OR position('@' IN v_authority) > 0 THEN
    RETURN true;
  END IF;

  IF v_authority ~ '^\[[^]]+\]' THEN
    v_host := substring(v_authority FROM '^\[([^]]+)\]');
    BEGIN
      PERFORM v_host::inet;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RETURN true;
    END;
    IF position(':' IN v_host) = 0 THEN
      RETURN true;
    END IF;
  ELSE
    v_host := split_part(v_authority, ':', 1);
    -- Browser-style numeric final labels (decimal, octal, hexadecimal) must
    -- never be treated as untrusted DNS. Canonical dotted IPv4 is still allowed.
    IF rtrim(v_host, '.') ~* '(^|\.)(0x[0-9a-z]+|[0-9]+)$' THEN
      -- Leading zeros, short forms, hex, octal, and trailing-dot numeric hosts
      -- are noncanonical; avoid browser URL normalization ambiguity.
      IF v_host !~ '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' THEN
        RETURN true;
      END IF;
      BEGIN
        PERFORM v_host::inet;
      EXCEPTION
        WHEN invalid_text_representation THEN
          RETURN true;
      END;
    END IF;
  END IF;

  v_port := substring(v_authority FROM ':([0-9]+)$');
  IF v_port IS NOT NULL THEN
    IF length(v_port) > 5 THEN
      RETURN true;
    END IF;
    IF v_port::integer NOT BETWEEN 1 AND 65535 THEN
      RETURN true;
    END IF;
  END IF;

  IF position(chr(92) IN v_file_url) > 0
     OR v_file_url ~ '(^|/)\.{1,2}(/|[?#]|$)'
     OR lower(v_file_url) ~ '(storage/v1/(object|render/image)/(sign|authenticated)/|product-media-staging)'
     OR position('%' IN v_file_url) > 0 THEN
    RETURN true;
  END IF;

  RETURN false;
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

COMMENT ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb) IS
  'Core #484 containment: blocks private object/image-transformation routes, noncanonical numeric IPv4 including hexadecimal/octal, temporary, encoded, path-normalized and malformed media references before approval.';

COMMIT;

