-- GFT-100 / Central #677: deny unknown scope comparisons and relative consent dates.
-- Forward correction; existing preview migrations remain immutable.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE FUNCTION public.gifting_enquiry_receive_v1(
  p_token text,
  p_source_lead_id uuid,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  c_resource constant text := 'enquiries.gifting';
  c_scope constant text := 'enquiries:gifting:write';
  v_token text := btrim(coalesce(p_token, ''));
  v_auth record;
  v_key text;
  v_value jsonb;
  v_kind text;
  v_email text;
  v_phone text;
  v_name text;
  v_company text;
  v_message text;
  v_source text;
  v_consent jsonb;
  v_marketing boolean;
  v_consent_at timestamptz;
  v_attribution jsonb;
  v_normalized jsonb;
  v_hash text;
  v_row public.gifting_enquiries%ROWTYPE;
  v_replayed boolean := false;
BEGIN
  -- Authentication / authorization (same token store and rules as CONNECT-2).
  IF length(v_token) < 32 OR length(v_token) > 256 THEN
    RAISE EXCEPTION 'CONNECT_TOKEN_INVALID' USING ERRCODE = 'P0001';
  END IF;

  SELECT c.id AS consumer_id, c.environment, t.id AS token_id, t.scopes
    INTO v_auth
    FROM public.connect_tokens t
    JOIN public.connect_consumers c ON c.id = t.consumer_id
    JOIN public.connect_bindings b
      ON b.consumer_id = c.id
     AND b.environment = t.environment
     AND c.environment = t.environment
     AND b.status = 'active'
    JOIN public.connect_profiles p ON p.id = b.profile_id AND p.status = 'active'
   WHERE t.token_hash = public.connect_internal_hash_token_v1(v_token)
     AND t.revoked_at IS NULL
     AND (t.expires_at IS NULL OR t.expires_at > statement_timestamp())
     AND c.status = 'active'
     AND c_resource = ANY (p.allowed_resources)
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECT_AUTHORIZATION_DENIED' USING ERRCODE = 'P0001';
  END IF;
  IF (c_scope = ANY (coalesce(v_auth.scopes, ARRAY[]::text[]))) IS NOT TRUE THEN
    RAISE EXCEPTION 'CONNECT_SCOPE_DENIED' USING ERRCODE = 'P0001';
  END IF;

  -- Payload validation. Limits mirror the website's own lead schema.
  IF p_source_lead_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR octet_length(p_payload::text) > 16384 THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    IF v_key NOT IN (
      'kind', 'email', 'phone', 'name', 'company', 'message', 'source', 'consent', 'attribution'
    ) THEN
      RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Optional text fields: JSON null/absent -> NULL; anything else must be a string.
  FOREACH v_key IN ARRAY ARRAY['email', 'phone', 'name', 'company', 'message']::text[] LOOP
    v_value := p_payload -> v_key;
    IF v_value IS NOT NULL AND jsonb_typeof(v_value) NOT IN ('null', 'string') THEN
      RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_kind := p_payload ->> 'kind';
  v_email := nullif(p_payload ->> 'email', '');
  v_phone := nullif(p_payload ->> 'phone', '');
  v_name := nullif(p_payload ->> 'name', '');
  v_company := nullif(p_payload ->> 'company', '');
  v_message := nullif(p_payload ->> 'message', '');
  v_source := p_payload ->> 'source';

  IF jsonb_typeof(p_payload -> 'kind') IS DISTINCT FROM 'string'
     OR v_kind NOT IN ('contact', 'corporate', 'wedding', 'partnership')
     OR jsonb_typeof(p_payload -> 'source') IS DISTINCT FROM 'string'
     OR char_length(v_source) NOT BETWEEN 2 AND 80
     OR (v_email IS NOT NULL AND (char_length(v_email) > 254 OR v_email !~ '^[^@\s]+@[^@\s]+$'))
     OR (v_phone IS NOT NULL AND char_length(v_phone) NOT BETWEEN 6 AND 24)
     OR (v_name IS NOT NULL AND char_length(v_name) > 120)
     OR (v_company IS NOT NULL AND char_length(v_company) > 160)
     OR (v_message IS NOT NULL AND char_length(v_message) > 2000) THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;

  v_consent := p_payload -> 'consent';
  IF jsonb_typeof(v_consent) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(v_consent -> 'marketing') IS DISTINCT FROM 'boolean'
     OR coalesce(jsonb_typeof(v_consent -> 'timestamp'), 'null') NOT IN ('null', 'string')
     OR EXISTS (
       SELECT 1 FROM jsonb_object_keys(v_consent) k WHERE k NOT IN ('marketing', 'timestamp')
     ) THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;

  -- Only absolute ISO timestamps with an explicit timezone have stable replay semantics.
  IF (v_consent ->> 'timestamp') IS NOT NULL AND
     (v_consent ->> 'timestamp') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;

  v_marketing := (v_consent ->> 'marketing')::boolean;
  BEGIN
    v_consent_at := (v_consent ->> 'timestamp')::timestamptz;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END;

  v_attribution := coalesce(p_payload -> 'attribution', '{}'::jsonb);
  IF jsonb_typeof(v_attribution) <> 'object' THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(v_attribution)) > 20
     OR EXISTS (
       SELECT 1
         FROM jsonb_each(v_attribution) a
        WHERE char_length(a.key) > 64
           OR jsonb_typeof(a.value) <> 'string'
           OR char_length(a.value #>> '{}') > 512
     ) THEN
    RAISE EXCEPTION 'GIFTING_ENQUIRY_INVALID' USING ERRCODE = '22023';
  END IF;

  -- jsonb text form is key-order independent, so equal payloads hash equally.
  v_normalized := jsonb_build_object(
    'kind', v_kind,
    'email', v_email,
    'phone', v_phone,
    'name', v_name,
    'company', v_company,
    'message', v_message,
    'source', v_source,
    'marketing', v_marketing,
    'consent_at', v_consent_at,
    'attribution', v_attribution
  );
  v_hash := encode(extensions.digest(v_normalized::text, 'sha256'), 'hex');

  UPDATE public.connect_tokens SET last_used_at = now() WHERE id = v_auth.token_id;

  INSERT INTO public.gifting_enquiries (
    consumer_id, environment, source_lead_id, payload_hash, kind, email, phone, name,
    company, message, source, marketing_consent, consent_recorded_at, attribution
  ) VALUES (
    v_auth.consumer_id, v_auth.environment, p_source_lead_id, v_hash, v_kind, v_email, v_phone,
    v_name, v_company, v_message, v_source, v_marketing, v_consent_at, v_attribution
  )
  ON CONFLICT (consumer_id, source_lead_id) DO NOTHING
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    -- A concurrent or earlier delivery committed first: replay, never duplicate.
    SELECT * INTO v_row
      FROM public.gifting_enquiries
     WHERE consumer_id = v_auth.consumer_id
       AND source_lead_id = p_source_lead_id
       FOR UPDATE;

    IF v_row.payload_hash <> v_hash THEN
      RAISE EXCEPTION 'GIFTING_ENQUIRY_PAYLOAD_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.gifting_enquiries
       SET receipt_count = receipt_count + 1,
           last_received_at = now()
     WHERE id = v_row.id;
    v_replayed := true;
  END IF;

  RETURN jsonb_build_object(
    'status', 'accepted',
    'queue', 'gifting_enquiries',
    'sourceLeadId', p_source_lead_id,
    'enquiryId', v_row.id,
    'replayed', v_replayed
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.connect_internal_resolve_authorization_v1(
  p_token text,
  p_resource text,
  p_require_delivery_scope boolean DEFAULT false
)
RETURNS TABLE (
  consumer_id uuid,
  consumer_key text,
  consumer_type text,
  consumer_status text,
  token_id uuid,
  token_scopes text[],
  environment text,
  profile_id uuid,
  profile_key text,
  allowed_resources text[],
  allowed_fields text[],
  denied_fields text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token text := btrim(coalesce(p_token, ''));
  v_resource text := btrim(coalesce(p_resource, ''));
  v_hash text;
  v_required_scope text;
  v_row record;
BEGIN
  IF length(v_token) < 32 OR length(v_token) > 256 THEN
    RAISE EXCEPTION 'CONNECT_TOKEN_INVALID' USING ERRCODE = 'P0001';
  END IF;

  IF v_resource IS NULL OR NOT (v_resource = ANY (public.connect_internal_allowed_resources_v1())) THEN
    RAISE EXCEPTION 'CONNECT_RESOURCE_UNSUPPORTED' USING ERRCODE = '22023';
  END IF;

  v_required_scope := public.connect_internal_resource_scope_v1(v_resource);
  IF v_required_scope IS NULL THEN
    RAISE EXCEPTION 'CONNECT_RESOURCE_UNSUPPORTED' USING ERRCODE = '22023';
  END IF;

  v_hash := public.connect_internal_hash_token_v1(v_token);

  SELECT
    c.id AS consumer_id,
    c.consumer_key,
    c.consumer_type,
    c.status AS consumer_status,
    t.id AS token_id,
    t.scopes AS token_scopes,
    t.environment,
    p.id AS profile_id,
    p.profile_key,
    p.allowed_resources,
    p.allowed_fields,
    p.denied_fields
    INTO v_row
  FROM public.connect_tokens t
  JOIN public.connect_consumers c ON c.id = t.consumer_id
  JOIN public.connect_bindings b
    ON b.consumer_id = c.id
   AND b.environment = t.environment
   AND c.environment = t.environment
   AND b.status = 'active'
  JOIN public.connect_profiles p ON p.id = b.profile_id AND p.status = 'active'
  WHERE t.token_hash = v_hash
    AND t.revoked_at IS NULL
    AND (t.expires_at IS NULL OR t.expires_at > statement_timestamp())
    AND c.status = 'active'
    AND v_resource = ANY (p.allowed_resources)
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECT_AUTHORIZATION_DENIED' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(array_length(v_row.token_scopes, 1), 0) = 0 THEN
    RAISE EXCEPTION 'CONNECT_SCOPE_EMPTY' USING ERRCODE = 'P0001';
  END IF;

  IF (v_required_scope = ANY (v_row.token_scopes)) IS NOT TRUE THEN
    RAISE EXCEPTION 'CONNECT_SCOPE_DENIED' USING ERRCODE = 'P0001';
  END IF;

  IF p_require_delivery_scope AND ('delivery:record' = ANY (v_row.token_scopes)) IS NOT TRUE THEN
    RAISE EXCEPTION 'CONNECT_SCOPE_DENIED' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    v_row.consumer_id,
    v_row.consumer_key,
    v_row.consumer_type,
    v_row.consumer_status,
    v_row.token_id,
    v_row.token_scopes,
    v_row.environment,
    v_row.profile_id,
    v_row.profile_key,
    v_row.allowed_resources,
    v_row.allowed_fields,
    v_row.denied_fields;
END;
$$;

REVOKE ALL ON FUNCTION public.gifting_enquiry_receive_v1(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gifting_enquiry_receive_v1(text, uuid, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.connect_internal_resolve_authorization_v1(text, text, boolean) FROM PUBLIC, anon, authenticated;
