-- GFT-100 / Central #677: Gifting website enquiry receiver (Core persistence authority).
--
-- The Gifting website persists an enquiry in its own Website Supabase first and then
-- forwards it here, server to server, with the website row UUID as the idempotency key
-- (contract recorded in oasis-baklawa-gifting PR #37). Core owns the canonical enquiry
-- record; Central owns the staff queue that reads it (separate Central work item).
--
-- Contract (see docs/programme/GIFTING_ENQUIRY_RECEIVER_CONTRACT.md):
--   * authentication: a Connect bearer token whose consumer is bound to the write-only
--     `gifting_enquiries_v1` profile and whose scopes include `enquiries:gifting:write`;
--   * one row per (consumer, source_lead_id); an exact replay returns the same
--     enquiryId; a different payload for the same source_lead_id is rejected;
--   * the receiver never emits marketing events and never reads other Core data.
--
-- Forward-only. This migration registers no consumer and issues no token.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- -----------------------------------------------------------------------------
-- 1. Write-only channel profile (read profiles stay untouched)
-- -----------------------------------------------------------------------------
INSERT INTO public.connect_profiles (
  profile_key,
  label,
  consumer_type,
  allowed_resources,
  allowed_fields,
  denied_fields,
  status,
  version
) VALUES (
  'gifting_enquiries_v1',
  'Gifting website enquiry intake (write-only)',
  'b2c_website',
  ARRAY['enquiries.gifting']::text[],
  ARRAY[]::text[],
  ARRAY[]::text[],
  'active',
  1
)
ON CONFLICT (profile_key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. Persistence
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gifting_enquiries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consumer_id uuid NOT NULL REFERENCES public.connect_consumers(id) ON DELETE RESTRICT,
  environment text NOT NULL,
  source_lead_id uuid NOT NULL,
  payload_hash text NOT NULL,
  kind text NOT NULL,
  email text,
  phone text,
  name text,
  company text,
  message text,
  source text NOT NULL,
  marketing_consent boolean NOT NULL,
  consent_recorded_at timestamptz,
  attribution jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'received',
  receipt_count integer NOT NULL DEFAULT 1,
  first_received_at timestamptz NOT NULL DEFAULT now(),
  last_received_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gifting_enquiries_consumer_source_uniq UNIQUE (consumer_id, source_lead_id),
  CONSTRAINT gifting_enquiries_environment_check CHECK (
    environment IN ('production', 'staging', 'preview')
  ),
  CONSTRAINT gifting_enquiries_kind_check CHECK (
    kind IN ('contact', 'corporate', 'wedding', 'partnership')
  ),
  CONSTRAINT gifting_enquiries_status_check CHECK (
    status IN ('received', 'triaged', 'closed', 'spam')
  ),
  CONSTRAINT gifting_enquiries_receipt_count_check CHECK (receipt_count >= 1)
);

CREATE INDEX IF NOT EXISTS gifting_enquiries_status_received_idx
  ON public.gifting_enquiries (status, first_received_at);

COMMENT ON TABLE public.gifting_enquiries IS
  'Canonical Gifting website enquiries accepted from a bound Connect consumer. Personal data: service_role only; staff access is granted by a separate governed Central change.';

ALTER TABLE public.gifting_enquiries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.gifting_enquiries FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.gifting_enquiries TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Receiver
-- -----------------------------------------------------------------------------
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
  IF NOT (c_scope = ANY (coalesce(v_auth.scopes, ARRAY[]::text[]))) THEN
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

COMMENT ON FUNCTION public.gifting_enquiry_receive_v1(text, uuid, jsonb) IS
  'Idempotent Gifting enquiry intake. Authenticates a Connect bearer token (profile gifting_enquiries_v1, scope enquiries:gifting:write); exact replay returns the stable enquiryId, a different payload for the same source_lead_id raises GIFTING_ENQUIRY_PAYLOAD_CONFLICT.';

REVOKE ALL ON FUNCTION public.gifting_enquiry_receive_v1(text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gifting_enquiry_receive_v1(text, uuid, jsonb) TO service_role;
