-- Forward-only Core #484 correction: preserve every previously applied Preview migration.\n-- Block noncanonical browser numeric-host authority before media approval.
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
    -- Browser host parsing interprets numeric final labels as IPv4: hex, octal,
    -- short forms, and mixed labels must never pass as ordinary DNS.
    IF rtrim(v_host, '.') ~* '(^|\.)(0x[0-9a-z]+|[0-9]+)
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

COMMENT ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb) IS
  'Core #484 containment: blocks private object/image-transformation routes, browser-style numeric URL authorities including hex/octal, temporary, encoded, path-normalized and malformed media references before approval.';
COMMIT;
 THEN
      -- Require canonical four dotted decimal octets and no trailing dot or
      -- leading zeros; inet independently rejects octets above 255.
      IF v_host !~ '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}
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

COMMENT ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb) IS
  'Core #484 containment: blocks private object/image-transformation routes, invalid numeric IPv4, temporary, encoded, path-normalized and malformed media references before approval.';
COMMIT;
 THEN
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

COMMENT ON FUNCTION public.catalogue_media_reference_requires_publication_v1(jsonb) IS
  'Core #484 containment: blocks private object/image-transformation routes, invalid numeric IPv4, temporary, encoded, path-normalized and malformed media references before approval.';
COMMIT;
