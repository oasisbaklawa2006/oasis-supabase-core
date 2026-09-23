-- CONNECT-2 (Point 54a / ASM-OC-01): governed Oasis Connect consumer/channel contract.
-- Adds consumer identity, hashed scoped tokens, profile bindings, read-only projection
-- authorization, and idempotent delivery logging. Reuses published_products_v1() as the
-- base catalogue projection; B2B pricing overlay remains dependency-bound for CONNECT-4.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. Persistence
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.connect_consumers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consumer_key text NOT NULL,
  consumer_type text NOT NULL,
  environment text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  display_name text,
  version integer NOT NULL DEFAULT 1,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  CONSTRAINT connect_consumers_consumer_key_uniq UNIQUE (consumer_key),
  CONSTRAINT connect_consumers_status_check CHECK (
    status IN ('active', 'suspended', 'disabled')
  ),
  CONSTRAINT connect_consumers_environment_check CHECK (
    environment IN ('production', 'staging', 'preview')
  ),
  CONSTRAINT connect_consumers_type_check CHECK (
    consumer_type IN (
      'b2c_website',
      'b2b_website',
      'whatsapp_catalogue',
      'buyer_app',
      'b2c_app',
      'trace_label',
      'marketplace_api',
      'crm',
      'catalogue_pdf',
      'generic_api'
    )
  )
);

CREATE INDEX IF NOT EXISTS connect_consumers_status_environment_idx
  ON public.connect_consumers (status, environment);

COMMENT ON TABLE public.connect_consumers IS
  'Registered Oasis Connect consumer/application/channel identities. Status and environment are enforced on every authorization call.';

CREATE TABLE IF NOT EXISTS public.connect_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_key text NOT NULL,
  label text NOT NULL,
  consumer_type text NOT NULL,
  allowed_resources text[] NOT NULL DEFAULT ARRAY['catalogue.products']::text[],
  allowed_fields text[] NOT NULL,
  denied_fields text[] NOT NULL DEFAULT ARRAY[]::text[],
  status text NOT NULL DEFAULT 'active',
  version integer NOT NULL DEFAULT 1,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT connect_profiles_profile_key_uniq UNIQUE (profile_key),
  CONSTRAINT connect_profiles_status_check CHECK (
    status IN ('active', 'disabled')
  )
);

COMMENT ON TABLE public.connect_profiles IS
  'Server-governed channel profile allowlists. Callers cannot expand fields beyond allowed_fields or request undeclared resources.';

CREATE TABLE IF NOT EXISTS public.connect_bindings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consumer_id uuid NOT NULL REFERENCES public.connect_consumers(id) ON DELETE RESTRICT,
  profile_id uuid NOT NULL REFERENCES public.connect_profiles(id) ON DELETE RESTRICT,
  environment text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT connect_bindings_status_check CHECK (
    status IN ('active', 'disabled')
  ),
  CONSTRAINT connect_bindings_environment_check CHECK (
    environment IN ('production', 'staging', 'preview')
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS connect_bindings_consumer_env_active_uniq
  ON public.connect_bindings (consumer_id, environment)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS connect_bindings_consumer_env_status_idx
  ON public.connect_bindings (consumer_id, environment, status);

COMMENT ON TABLE public.connect_bindings IS
  'Governed mapping from consumer identity to channel profile within an environment.';

CREATE TABLE IF NOT EXISTS public.connect_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consumer_id uuid NOT NULL REFERENCES public.connect_consumers(id) ON DELETE RESTRICT,
  token_hash text NOT NULL,
  token_prefix text,
  scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
  environment text NOT NULL,
  rate_limit_per_minute integer,
  expires_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  CONSTRAINT connect_tokens_token_hash_uniq UNIQUE (token_hash),
  CONSTRAINT connect_tokens_environment_check CHECK (
    environment IN ('production', 'staging', 'preview')
  )
);

CREATE INDEX IF NOT EXISTS connect_tokens_consumer_revocation_idx
  ON public.connect_tokens (consumer_id, revoked_at, expires_at);

CREATE INDEX IF NOT EXISTS connect_tokens_environment_hash_idx
  ON public.connect_tokens (environment, token_hash);

COMMENT ON TABLE public.connect_tokens IS
  'Hashed Oasis Connect bearer tokens. Plaintext tokens are never persisted; only SHA-256 digests are stored.';

CREATE TABLE IF NOT EXISTS public.connect_delivery_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consumer_id uuid NOT NULL REFERENCES public.connect_consumers(id) ON DELETE RESTRICT,
  profile_id uuid REFERENCES public.connect_profiles(id) ON DELETE RESTRICT,
  resource text NOT NULL,
  idempotency_key text NOT NULL,
  request_fingerprint text NOT NULL,
  response_fingerprint text,
  status text NOT NULL,
  error_category text,
  correlation_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT connect_delivery_log_consumer_idempotency_key_uniq
    UNIQUE (consumer_id, idempotency_key),
  CONSTRAINT connect_delivery_log_status_check CHECK (
    status IN ('success', 'failure')
  )
);

CREATE INDEX IF NOT EXISTS connect_delivery_log_consumer_created_idx
  ON public.connect_delivery_log (consumer_id, created_at DESC);

COMMENT ON TABLE public.connect_delivery_log IS
  'Idempotent Oasis Connect delivery/audit log. Does not store full sensitive payloads.';

-- -----------------------------------------------------------------------------
-- 2. Immutability and touch triggers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.connect_immutable_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'CONNECT_IMMUTABLE: % rejected on %', TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END;
$$;

CREATE OR REPLACE FUNCTION public.connect_touch_updated_at_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_connect_delivery_log_immutable ON public.connect_delivery_log;
CREATE TRIGGER trg_connect_delivery_log_immutable
  BEFORE UPDATE OR DELETE ON public.connect_delivery_log
  FOR EACH ROW EXECUTE FUNCTION public.connect_immutable_v1();

DROP TRIGGER IF EXISTS trg_connect_consumers_touch ON public.connect_consumers;
CREATE TRIGGER trg_connect_consumers_touch
  BEFORE UPDATE ON public.connect_consumers
  FOR EACH ROW EXECUTE FUNCTION public.connect_touch_updated_at_v1();

DROP TRIGGER IF EXISTS trg_connect_profiles_touch ON public.connect_profiles;
CREATE TRIGGER trg_connect_profiles_touch
  BEFORE UPDATE ON public.connect_profiles
  FOR EACH ROW EXECUTE FUNCTION public.connect_touch_updated_at_v1();

DROP TRIGGER IF EXISTS trg_connect_bindings_touch ON public.connect_bindings;
CREATE TRIGGER trg_connect_bindings_touch
  BEFORE UPDATE ON public.connect_bindings
  FOR EACH ROW EXECUTE FUNCTION public.connect_touch_updated_at_v1();

DROP TRIGGER IF EXISTS trg_connect_tokens_touch ON public.connect_tokens;
CREATE TRIGGER trg_connect_tokens_touch
  BEFORE UPDATE ON public.connect_tokens
  FOR EACH ROW EXECUTE FUNCTION public.connect_touch_updated_at_v1();

-- -----------------------------------------------------------------------------
-- 3. RLS and table privileges (fail closed for direct access)
-- -----------------------------------------------------------------------------

ALTER TABLE public.connect_consumers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connect_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connect_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connect_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connect_delivery_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.connect_consumers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.connect_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.connect_bindings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.connect_tokens FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.connect_delivery_log FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.connect_consumers TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.connect_profiles TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.connect_bindings TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.connect_tokens TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.connect_delivery_log TO service_role;

-- -----------------------------------------------------------------------------
-- 4. Internal helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.connect_internal_hash_token_v1(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

COMMENT ON FUNCTION public.connect_internal_hash_token_v1(text) IS
  'Internal SHA-256 hex digest helper for Oasis Connect bearer tokens.';

CREATE OR REPLACE FUNCTION public.connect_internal_allowed_resources_v1()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT ARRAY[
    'catalogue.products',
    'catalogue.pricing.b2b',
    'trace.label.fields'
  ]::text[];
$$;

CREATE OR REPLACE FUNCTION public.connect_internal_resource_scope_v1(p_resource text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE btrim(coalesce(p_resource, ''))
    WHEN 'catalogue.products' THEN 'catalogue:read'
    WHEN 'catalogue.pricing.b2b' THEN 'pricing:b2b'
    WHEN 'trace.label.fields' THEN 'trace:label:read'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.connect_internal_validate_field_name_v1(p_field text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT coalesce(p_field, '') ~ '^[a-z][a-z0-9_]*$';
$$;

CREATE OR REPLACE FUNCTION public.connect_internal_filter_row_v1(
  p_row jsonb,
  p_allowed_fields text[],
  p_denied_fields text[]
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_key text;
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF p_row IS NULL THEN
    RETURN NULL;
  END IF;

  FOR v_key IN SELECT unnest(p_allowed_fields)
  LOOP
    IF NOT public.connect_internal_validate_field_name_v1(v_key) THEN
      RAISE EXCEPTION 'CONNECT_INVALID_FIELD_NAME' USING ERRCODE = '22023';
    END IF;
    IF v_key = ANY (coalesce(p_denied_fields, ARRAY[]::text[])) THEN
      CONTINUE;
    END IF;
    IF p_row ? v_key THEN
      v_out := v_out || jsonb_build_object(v_key, p_row -> v_key);
    END IF;
  END LOOP;

  RETURN v_out;
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

  IF NOT (v_required_scope = ANY (v_row.token_scopes)) THEN
    RAISE EXCEPTION 'CONNECT_SCOPE_DENIED' USING ERRCODE = 'P0001';
  END IF;

  IF p_require_delivery_scope AND NOT ('delivery:record' = ANY (v_row.token_scopes)) THEN
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

REVOKE ALL ON FUNCTION public.connect_internal_hash_token_v1(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.connect_internal_hash_token_v1(text) TO service_role;
REVOKE ALL ON FUNCTION public.connect_internal_allowed_resources_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_internal_resource_scope_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_internal_validate_field_name_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_internal_filter_row_v1(jsonb, text[], text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_internal_resolve_authorization_v1(text, text, boolean) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. Public read projection RPC
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.connect_authorize_and_project_v1(
  p_token text,
  p_resource text,
  p_params jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth record;
  v_params jsonb := coalesce(p_params, '{}'::jsonb);
  v_requested_fields text[];
  v_field text;
  v_limit integer := 100;
  v_offset integer := 0;
  v_rows jsonb := '[]'::jsonb;
  v_row jsonb;
  v_filtered jsonb;
  v_product_id uuid;
BEGIN
  IF octet_length(v_params::text) > 8192 THEN
    RAISE EXCEPTION 'CONNECT_PAYLOAD_TOO_LARGE' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_auth
    FROM public.connect_internal_resolve_authorization_v1(p_token, p_resource, false);

  IF v_params ? 'limit' THEN
    v_limit := coalesce((v_params ->> 'limit')::integer, 100);
  END IF;
  IF v_params ? 'offset' THEN
    v_offset := coalesce((v_params ->> 'offset')::integer, 0);
  END IF;
  IF v_limit < 1 OR v_limit > 500 OR v_offset < 0 OR v_offset > 100000 THEN
    RAISE EXCEPTION 'CONNECT_PAGINATION_INVALID' USING ERRCODE = '22023';
  END IF;

  IF v_params ? 'fields' THEN
    IF jsonb_typeof(v_params -> 'fields') <> 'array' THEN
      RAISE EXCEPTION 'CONNECT_FIELDS_INVALID' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(v_params -> 'fields') > 50 THEN
      RAISE EXCEPTION 'CONNECT_FIELDS_TOO_MANY' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(value), ARRAY[]::text[])
      INTO v_requested_fields
      FROM jsonb_array_elements_text(v_params -> 'fields') AS value;
    FOREACH v_field IN ARRAY v_requested_fields
    LOOP
      IF NOT public.connect_internal_validate_field_name_v1(v_field) THEN
        RAISE EXCEPTION 'CONNECT_FIELD_FORBIDDEN' USING ERRCODE = 'P0001';
      END IF;
      IF NOT (v_field = ANY (v_auth.allowed_fields)) THEN
        RAISE EXCEPTION 'CONNECT_FIELD_FORBIDDEN' USING ERRCODE = 'P0001';
      END IF;
      IF v_field = ANY (coalesce(v_auth.denied_fields, ARRAY[]::text[])) THEN
        RAISE EXCEPTION 'CONNECT_FIELD_FORBIDDEN' USING ERRCODE = 'P0001';
      END IF;
    END LOOP;
  ELSE
    v_requested_fields := v_auth.allowed_fields;
  END IF;

  IF v_params ? 'product_id' THEN
    BEGIN
      v_product_id := (v_params ->> 'product_id')::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'CONNECT_PRODUCT_ID_INVALID' USING ERRCODE = '22023';
    END;
  END IF;

  IF p_resource = 'catalogue.pricing.b2b' THEN
    RAISE EXCEPTION 'CONNECT_PRICING_OVERLAY_PENDING: Central commercial overlay (CONNECT-4) required'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_resource IN ('catalogue.products', 'trace.label.fields') THEN
    FOR v_row IN
      SELECT to_jsonb(pp)
        FROM public.published_products_v1() pp
       WHERE v_product_id IS NULL OR pp.product_id = v_product_id
       ORDER BY pp.product_name, pp.product_id
       OFFSET v_offset
       LIMIT v_limit
    LOOP
      v_filtered := public.connect_internal_filter_row_v1(
        v_row,
        v_requested_fields,
        v_auth.denied_fields
      );
      IF v_filtered IS NOT NULL AND v_filtered <> '{}'::jsonb THEN
        v_rows := v_rows || jsonb_build_array(v_filtered);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'resource', p_resource,
    'consumer_id', v_auth.consumer_id,
    'consumer_key', v_auth.consumer_key,
    'profile_key', v_auth.profile_key,
    'environment', v_auth.environment,
    'contract_version', 1,
    'row_count', jsonb_array_length(v_rows),
    'data', v_rows
  );
END;
$$;

COMMENT ON FUNCTION public.connect_authorize_and_project_v1(text, text, jsonb) IS
  'Read-only Oasis Connect authorization and projection gate. Validates hashed bearer token, consumer/profile binding, scope and field allowlist, then projects from published_products_v1(). B2B pricing overlay remains CONNECT-4 dependency-bound.';

REVOKE ALL ON FUNCTION public.connect_authorize_and_project_v1(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.connect_authorize_and_project_v1(text, text, jsonb) TO anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. Idempotent delivery logging RPC
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.connect_record_delivery_v1(
  p_token text,
  p_idempotency_key text,
  p_resource text,
  p_response_fingerprint text,
  p_status text DEFAULT 'success',
  p_error_category text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth record;
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_fingerprint text;
  v_prior record;
  v_delivery_id uuid;
  v_result jsonb;
BEGIN
  IF v_key IS NULL OR length(v_key) < 8 OR length(v_key) > 128 THEN
    RAISE EXCEPTION 'CONNECT_IDEMPOTENCY_INVALID' USING ERRCODE = '22023';
  END IF;
  IF v_status NOT IN ('success', 'failure') THEN
    RAISE EXCEPTION 'CONNECT_STATUS_INVALID' USING ERRCODE = '22023';
  END IF;
  IF octet_length(coalesce(p_response_fingerprint, '')) > 512 THEN
    RAISE EXCEPTION 'CONNECT_PAYLOAD_TOO_LARGE' USING ERRCODE = '22023';
  END IF;

  SELECT *
    INTO v_auth
    FROM public.connect_internal_resolve_authorization_v1(p_token, p_resource, true);

  v_fingerprint := encode(
    extensions.digest(
      jsonb_build_object(
        'consumer_id', v_auth.consumer_id,
        'profile_id', v_auth.profile_id,
        'resource', btrim(p_resource),
        'response_fingerprint', coalesce(p_response_fingerprint, ''),
        'status', v_status,
        'error_category', coalesce(p_error_category, '')
      )::text,
      'sha256'
    ),
    'hex'
  );

  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_auth.consumer_id::text || ':' || v_key, 0)
  );

  SELECT id, request_fingerprint, status, response_fingerprint
    INTO v_prior
    FROM public.connect_delivery_log
   WHERE consumer_id = v_auth.consumer_id
     AND idempotency_key = v_key;

  IF FOUND THEN
    IF v_prior.request_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'CONNECT_IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object(
      'delivery_id', v_prior.id,
      'consumer_id', v_auth.consumer_id,
      'resource', p_resource,
      'status', v_prior.status,
      'idempotency_replayed', true
    );
  END IF;

  INSERT INTO public.connect_delivery_log (
    consumer_id,
    profile_id,
    resource,
    idempotency_key,
    request_fingerprint,
    response_fingerprint,
    status,
    error_category,
    correlation_id
  ) VALUES (
    v_auth.consumer_id,
    v_auth.profile_id,
    btrim(p_resource),
    v_key,
    v_fingerprint,
    nullif(btrim(coalesce(p_response_fingerprint, '')), ''),
    v_status,
    nullif(btrim(coalesce(p_error_category, '')), ''),
    v_key
  )
  RETURNING id INTO v_delivery_id;

  v_result := jsonb_build_object(
    'delivery_id', v_delivery_id,
    'consumer_id', v_auth.consumer_id,
    'resource', p_resource,
    'status', v_status,
    'idempotency_replayed', false
  );

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.connect_record_delivery_v1(text, text, text, text, text, text) IS
  'Idempotent Oasis Connect delivery audit recorder. Requires delivery:record scope and mirrors advisory-lock plus fingerprint replay semantics used by ols_trace_mutation_receipts.';

REVOKE ALL ON FUNCTION public.connect_record_delivery_v1(text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.connect_record_delivery_v1(text, text, text, text, text, text) TO anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Service-role administration RPCs (CONNECT-3 will consume these)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.connect_admin_register_consumer_v1(
  p_consumer_key text,
  p_consumer_type text,
  p_environment text,
  p_display_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.connect_consumers%ROWTYPE;
BEGIN
  INSERT INTO public.connect_consumers (
    consumer_key, consumer_type, environment, display_name, status
  ) VALUES (
    btrim(p_consumer_key),
    btrim(p_consumer_type),
    btrim(p_environment),
    nullif(btrim(coalesce(p_display_name, '')), ''),
    'active'
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'consumer_id', v_row.id,
    'consumer_key', v_row.consumer_key,
    'consumer_type', v_row.consumer_type,
    'environment', v_row.environment,
    'status', v_row.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.connect_admin_issue_token_v1(
  p_consumer_id uuid,
  p_scopes text[],
  p_environment text,
  p_expires_at timestamptz DEFAULT NULL,
  p_rate_limit_per_minute integer DEFAULT 120
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_consumer public.connect_consumers%ROWTYPE;
  v_plaintext text;
  v_hash text;
  v_row public.connect_tokens%ROWTYPE;
BEGIN
  SELECT * INTO v_consumer FROM public.connect_consumers WHERE id = p_consumer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECT_CONSUMER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_consumer.status <> 'active' THEN
    RAISE EXCEPTION 'CONNECT_CONSUMER_INACTIVE' USING ERRCODE = 'P0001';
  END IF;
  IF btrim(coalesce(p_environment, '')) <> v_consumer.environment THEN
    RAISE EXCEPTION 'CONNECT_ENVIRONMENT_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(array_length(p_scopes, 1), 0) = 0 THEN
    RAISE EXCEPTION 'CONNECT_SCOPE_EMPTY' USING ERRCODE = 'P0001';
  END IF;

  v_plaintext := 'oc_' || btrim(p_environment) || '_' || encode(extensions.gen_random_bytes(24), 'hex');
  v_hash := public.connect_internal_hash_token_v1(v_plaintext);

  INSERT INTO public.connect_tokens (
    consumer_id,
    token_hash,
    token_prefix,
    scopes,
    environment,
    rate_limit_per_minute,
    expires_at
  ) VALUES (
    p_consumer_id,
    v_hash,
    left(v_plaintext, 12),
    p_scopes,
    btrim(p_environment),
    p_rate_limit_per_minute,
    p_expires_at
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'token_id', v_row.id,
    'consumer_id', v_row.consumer_id,
    'environment', v_row.environment,
    'scopes', v_row.scopes,
    'expires_at', v_row.expires_at,
    'token', v_plaintext
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.connect_admin_bind_profile_v1(
  p_consumer_id uuid,
  p_profile_id uuid,
  p_environment text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.connect_bindings%ROWTYPE;
  v_consumer public.connect_consumers%ROWTYPE;
  v_environment text := btrim(coalesce(p_environment, ''));
BEGIN
  SELECT * INTO v_consumer
    FROM public.connect_consumers
   WHERE id = p_consumer_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECT_CONSUMER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_consumer.status <> 'active' THEN
    RAISE EXCEPTION 'CONNECT_CONSUMER_INACTIVE' USING ERRCODE = 'P0001';
  END IF;
  IF v_environment <> v_consumer.environment THEN
    RAISE EXCEPTION 'CONNECT_ENVIRONMENT_MISMATCH' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.connect_bindings
     SET status = 'disabled'
   WHERE consumer_id = p_consumer_id
     AND environment = v_environment
     AND status = 'active';

  INSERT INTO public.connect_bindings (
    consumer_id, profile_id, environment, status
  ) VALUES (
    p_consumer_id, p_profile_id, v_environment, 'active'
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'binding_id', v_row.id,
    'consumer_id', v_row.consumer_id,
    'profile_id', v_row.profile_id,
    'environment', v_row.environment
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.connect_admin_revoke_token_v1(p_token_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.connect_tokens%ROWTYPE;
BEGIN
  UPDATE public.connect_tokens
     SET revoked_at = statement_timestamp()
   WHERE id = p_token_id
     AND revoked_at IS NULL
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECT_TOKEN_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object('token_id', v_row.id, 'revoked_at', v_row.revoked_at);
END;
$$;

REVOKE ALL ON FUNCTION public.connect_admin_register_consumer_v1(text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_admin_issue_token_v1(uuid, text[], text, timestamptz, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_admin_bind_profile_v1(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.connect_admin_revoke_token_v1(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.connect_admin_register_consumer_v1(text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.connect_admin_issue_token_v1(uuid, text[], text, timestamptz, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.connect_admin_bind_profile_v1(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.connect_admin_revoke_token_v1(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 8. Reference profiles (server templates for CONNECT-3)
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
) VALUES
  (
    'b2c_india_v1',
    'B2C India public catalogue',
    'b2c_website',
    ARRAY['catalogue.products']::text[],
    ARRAY[
      'product_id', 'sku', 'product_name', 'short_description', 'long_description',
      'category', 'subcategory', 'hero_image_url', 'pack_size', 'storage_type',
      'shelf_life', 'shelf_life_days', 'lead_time_days', 'dietary_tags',
      'allergen_warnings', 'primary_uom', 'created_at'
    ]::text[],
    ARRAY['cost', 'margin', 'base_price', 'calculated_price']::text[],
    'active',
    1
  ),
  (
    'b2b_india_v1',
    'B2B India catalogue with pricing overlay slot',
    'b2b_website',
    ARRAY['catalogue.products', 'catalogue.pricing.b2b']::text[],
    ARRAY[
      'product_id', 'sku', 'product_name', 'short_description', 'long_description',
      'category', 'subcategory', 'hero_image_url', 'pack_size', 'primary_uom'
    ]::text[],
    ARRAY['cost', 'margin']::text[],
    'active',
    1
  ),
  (
    'whatsapp_retail_v1',
    'WhatsApp retail mini-catalogue',
    'whatsapp_catalogue',
    ARRAY['catalogue.products']::text[],
    ARRAY[
      'product_id', 'sku', 'product_name', 'short_description', 'hero_image_url',
      'pack_size', 'primary_uom', 'dietary_tags', 'allergen_warnings'
    ]::text[],
    ARRAY['cost', 'margin', 'base_price', 'calculated_price', 'lead_time_days']::text[],
    'active',
    1
  ),
  (
    'website_retail_v1',
    'Public website retail catalogue',
    'b2c_website',
    ARRAY['catalogue.products']::text[],
    ARRAY[
      'product_id', 'sku', 'product_name', 'short_description', 'long_description',
      'category', 'subcategory', 'hero_image_url', 'pack_size', 'storage_type',
      'shelf_life', 'shelf_life_days', 'dietary_tags', 'allergen_warnings', 'primary_uom'
    ]::text[],
    ARRAY['cost', 'margin', 'base_price', 'calculated_price']::text[],
    'active',
    1
  ),
  (
    'trace_label_v1',
    'Trace label-safe product subset',
    'trace_label',
    ARRAY['trace.label.fields']::text[],
    ARRAY[
      'product_id', 'sku', 'product_name', 'pack_size', 'allergen_warnings',
      'dietary_tags', 'shelf_life', 'shelf_life_days', 'primary_uom'
    ]::text[],
    ARRAY['cost', 'margin', 'hero_image_url', 'long_description']::text[],
    'active',
    1
  )
ON CONFLICT (profile_key) DO NOTHING;
