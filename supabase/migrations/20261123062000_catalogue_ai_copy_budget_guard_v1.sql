-- Studio AI-copy: opt-in, server-authoritative request reservation; OFF by default.
-- Not a USD billing cap. No provider credential, Edge deploy, or Production activation.
-- Requires a separately reviewed Edge integration and model/cost approval.
CREATE TABLE public.catalogue_ai_copy_budget_policy_v1 (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enabled boolean NOT NULL DEFAULT false,
  approved_model text NOT NULL DEFAULT 'UNAPPROVED' CHECK (length(approved_model) BETWEEN 1 AND 100),
  requested_output_token_cap integer NOT NULL DEFAULT 1400 CHECK (requested_output_token_cap BETWEEN 1 AND 1400),
  per_user_minute_limit integer NOT NULL DEFAULT 2 CHECK (per_user_minute_limit BETWEEN 1 AND 10),
  per_user_day_limit integer NOT NULL DEFAULT 10 CHECK (per_user_day_limit BETWEEN 1 AND 100),
  global_day_limit integer NOT NULL DEFAULT 40 CHECK (global_day_limit BETWEEN 1 AND 1000),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.catalogue_ai_copy_budget_policy_v1 (singleton) VALUES (true);
COMMENT ON TABLE public.catalogue_ai_copy_budget_policy_v1 IS
  'Governed, disabled-by-default request quota, NOT a monetary limit. Model approval and provider-side cost limits are separate.';

CREATE TABLE public.catalogue_ai_copy_usage_v1 (
  bucket text NOT NULL CHECK (bucket IN ('user_minute', 'user_day', 'global_day')),
  bucket_start timestamptz NOT NULL,
  actor_id uuid NOT NULL,
  requests integer NOT NULL DEFAULT 0 CHECK (requests >= 0),
  reserved_output_tokens bigint NOT NULL DEFAULT 0 CHECK (reserved_output_tokens >= 0),
  PRIMARY KEY(bucket, bucket_start, actor_id)
);
COMMENT ON TABLE public.catalogue_ai_copy_usage_v1 IS
  'Append-only reservation counters: failures consume reservations; no refund or per-request retry bypass. UTC buckets.';

ALTER TABLE public.catalogue_ai_copy_budget_policy_v1 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_ai_copy_usage_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.catalogue_ai_copy_budget_policy_v1 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.catalogue_ai_copy_usage_v1 FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reserve_catalogue_ai_copy_budget_v1(
  p_model text,
  p_requested_output_tokens integer
) RETURNS boolean
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_actor uuid := auth.uid();
  v_policy public.catalogue_ai_copy_budget_policy_v1%ROWTYPE;
  v_minute timestamptz;
  v_day timestamptz;
  v_used_minute integer;
  v_used_actor_day integer;
  v_used_global_day integer;
  v_global_actor constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
  -- Require a real authenticated, currently-authorized staff identity.
  IF v_actor IS NULL OR
     NOT public.is_internal_staff(v_actor) OR
     NOT public.has_ai_studio_permission_v1('ai_studio.ai.use')
  THEN
    RETURN false;
  END IF;
  -- Serialize all grants across every Edge worker/region, preventing racing
  -- requests from exceeding either user or global quotas.
  PERFORM pg_catalog.pg_advisory_xact_lock(194, 5812);
  SELECT * INTO v_policy FROM public.catalogue_ai_copy_budget_policy_v1
    WHERE singleton IS TRUE;
  IF NOT FOUND OR v_policy.enabled IS NOT TRUE OR
     p_model IS NULL OR p_model <> v_policy.approved_model OR
     p_requested_output_tokens IS NULL OR p_requested_output_tokens <> v_policy.requested_output_token_cap
  THEN
    RETURN false;
  END IF;
  v_minute := date_trunc('minute', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_day := date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  SELECT COALESCE((
    SELECT requests FROM public.catalogue_ai_copy_usage_v1
     WHERE bucket='user_minute' AND bucket_start=v_minute AND actor_id=v_actor
  ),0) INTO v_used_minute;
  SELECT COALESCE((
    SELECT requests FROM public.catalogue_ai_copy_usage_v1
     WHERE bucket='user_day' AND bucket_start=v_day AND actor_id=v_actor
  ),0) INTO v_used_actor_day;
  SELECT COALESCE((
    SELECT requests FROM public.catalogue_ai_copy_usage_v1
     WHERE bucket='global_day' AND bucket_start=v_day AND actor_id=v_global_actor
  ),0) INTO v_used_global_day;
  IF v_used_minute >= v_policy.per_user_minute_limit OR
     v_used_actor_day >= v_policy.per_user_day_limit OR
     v_used_global_day >= v_policy.global_day_limit
  THEN
    RETURN false;
  END IF;
  INSERT INTO public.catalogue_ai_copy_usage_v1
    (bucket, bucket_start, actor_id, requests, reserved_output_tokens)
  VALUES
    ('user_minute',v_minute,v_actor,1,p_requested_output_tokens),
    ('user_day',v_day,v_actor,1,p_requested_output_tokens),
    ('global_day',v_day,v_global_actor,1,p_requested_output_tokens)
  ON CONFLICT (bucket,bucket_start,actor_id) DO UPDATE SET
    requests=public.catalogue_ai_copy_usage_v1.requests+1,
    reserved_output_tokens=public.catalogue_ai_copy_usage_v1.reserved_output_tokens+EXCLUDED.reserved_output_tokens;
  RETURN true;
END;
$fn$;
REVOKE ALL ON FUNCTION public.reserve_catalogue_ai_copy_budget_v1(text,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_catalogue_ai_copy_budget_v1(text,integer)
  TO authenticated;
