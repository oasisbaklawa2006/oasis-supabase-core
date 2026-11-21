-- Core #484 follow-up forward migration: scope all private-route detection to the actual request path.
-- All five previously Preview-applied migrations 20261121160000-20261121160400 remain immutable.
-- Preserve existing staging metadata checks, fragment/query retention, and canonical reviewer security.
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
  v_path text;
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
    IF rtrim(v_host, '.') ~* '(^|\.)(0x[0-9a-z]*|[0-9]+)$' THEN
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

  -- The URL fragment and query are not request path segments. Preserve the
  -- conservative signed/private route hold, while not treating arbitrary
  -- public CDN filenames containing a staging-like word as Storage buckets.
  v_path := coalesce(substring(v_file_url FROM '(?i)^https?://[^/?#]+([^?#]*)'), '');
  IF position(chr(92) IN v_file_url) > 0
     OR v_path ~ '(^|/)\.{1,2}(/|$)'
     OR lower(v_path) ~ 'storage/v1/(object|render/image)/(sign|authenticated)/'
     OR lower(v_path) ~ 'storage/v1/(object|render/image)/(public|sign|authenticated)/product-media-staging(/|$)'
     OR position('%' IN v_file_url) > 0 THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb) IS
  'Core #484 containment: blocks private object/image Storage paths and staging buckets, noncanonical numeric IPv4, encoded/malformed references; URL path checks exclude harmless query or fragment content.';
COMMIT;
