-- APPVERSE-CORE-AI-BUDGET-01 (parent APPVERSE-AI-FINAL-01): server-authoritative, monetary,
-- fail-closed budget reservation and settlement for the Studio AI-copy provider call.
--
-- Supersedes the never-merged, never-deployed candidate 20261123062000 (closed PR #597, commit
-- ea93ce21), which was a request-count quota. This forward migration is the only budget schema.
--
-- Approved policy (owner, Revision 3): model gpt-5.4-mini-2026-03-17; $0.75/M input, $4.50/M output;
-- max 8,000 input and 1,400 output tokens; max reservation 15,000 micro-USD per request; company
-- 5,000,000 micro-USD per UTC day and 50,000,000 per UTC month; per user 1,000,000 micro-USD and 100
-- requests per UTC day and 5 per UTC minute. DISABLED by default. Every limit column is CHECK-bounded at
-- the approved value, so a later increase needs a reviewed migration; no function can raise a limit.
--
-- Every RPC is SECURITY DEFINER, search_path = '', and executable by service_role ONLY. The Edge
-- function passes the actor it verified from the caller's JWT. No role has direct table privileges.
-- No key, secret, provider call, Edge deployment or activation is part of this migration.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- -----------------------------------------------------------------------------
-- 1. Policy (singleton). Limits are bounded by CHECK at the approved values.
-- -----------------------------------------------------------------------------
CREATE TABLE public.catalogue_ai_copy_budget_policy_v1 (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enabled boolean NOT NULL DEFAULT false,
  emergency_disabled_at timestamptz,
  emergency_reason text CHECK (emergency_reason IS NULL OR length(emergency_reason) <= 200),
  approved_model text NOT NULL CHECK (length(approved_model) BETWEEN 1 AND 100),
  input_micro_usd_per_million_tokens integer NOT NULL
    CHECK (input_micro_usd_per_million_tokens BETWEEN 1 AND 750000),
  output_micro_usd_per_million_tokens integer NOT NULL
    CHECK (output_micro_usd_per_million_tokens BETWEEN 1 AND 4500000),
  max_input_tokens integer NOT NULL CHECK (max_input_tokens BETWEEN 1 AND 8000),
  max_output_tokens integer NOT NULL CHECK (max_output_tokens BETWEEN 1 AND 1400),
  max_reservation_micro_usd integer NOT NULL CHECK (max_reservation_micro_usd BETWEEN 1 AND 15000),
  per_user_minute_limit integer NOT NULL CHECK (per_user_minute_limit BETWEEN 1 AND 5),
  per_user_day_requests integer NOT NULL CHECK (per_user_day_requests BETWEEN 1 AND 100),
  per_user_day_micro_usd integer NOT NULL CHECK (per_user_day_micro_usd BETWEEN 1 AND 1000000),
  company_day_micro_usd integer NOT NULL CHECK (company_day_micro_usd BETWEEN 1 AND 5000000),
  company_month_micro_usd integer NOT NULL CHECK (company_month_micro_usd BETWEEN 1 AND 50000000),
  updated_at timestamptz NOT NULL DEFAULT now(),
  -- The reservation must always cover the worst-case provider cost at the stored prices.
  CONSTRAINT catalogue_ai_copy_reservation_covers_worst_case CHECK (
    max_reservation_micro_usd::bigint >=
      ((max_input_tokens::bigint * input_micro_usd_per_million_tokens + 999999) / 1000000) +
      ((max_output_tokens::bigint * output_micro_usd_per_million_tokens + 999999) / 1000000)
  )
);

INSERT INTO public.catalogue_ai_copy_budget_policy_v1 (
  singleton, enabled, approved_model,
  input_micro_usd_per_million_tokens, output_micro_usd_per_million_tokens,
  max_input_tokens, max_output_tokens, max_reservation_micro_usd,
  per_user_minute_limit, per_user_day_requests, per_user_day_micro_usd,
  company_day_micro_usd, company_month_micro_usd
) VALUES (
  true, false, 'gpt-5.4-mini-2026-03-17',
  750000, 4500000,
  8000, 1400, 15000,
  5, 100, 1000000,
  5000000, 50000000
);

COMMENT ON TABLE public.catalogue_ai_copy_budget_policy_v1 IS
  'Governed spending policy for Studio AI copy. Disabled by default; limits CHECK-bounded at the owner-approved values; changed only by reviewed migration. No role has direct table privileges.';

-- -----------------------------------------------------------------------------
-- 2. Reservation ledger (one row per attempt) and usage buckets (UTC)
-- -----------------------------------------------------------------------------
CREATE TABLE public.catalogue_ai_copy_reservations_v1 (
  reservation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid NOT NULL,
  model text NOT NULL,
  status text NOT NULL CHECK (status IN ('gated', 'reserved', 'settled', 'ambiguous', 'denied')),
  reserved_micro_usd integer NOT NULL DEFAULT 0 CHECK (reserved_micro_usd >= 0),
  counted_input_tokens integer,
  day_bucket date,
  month_bucket date,
  verified_input_tokens integer,
  verified_output_tokens integer,
  charged_micro_usd integer CHECK (charged_micro_usd IS NULL OR charged_micro_usd >= 0),
  provider_request_id text CHECK (provider_request_id IS NULL OR length(provider_request_id) <= 200),
  violation text CHECK (violation IS NULL OR length(violation) <= 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz
);
CREATE INDEX catalogue_ai_copy_reservations_actor_created_idx
  ON public.catalogue_ai_copy_reservations_v1 (actor_id, created_at DESC);
CREATE INDEX catalogue_ai_copy_reservations_status_idx
  ON public.catalogue_ai_copy_reservations_v1 (status);

CREATE TABLE public.catalogue_ai_copy_usage_v1 (
  bucket text NOT NULL CHECK (bucket IN ('user_minute', 'user_day', 'company_day', 'company_month')),
  bucket_start timestamptz NOT NULL,
  actor_id uuid NOT NULL,
  requests integer NOT NULL DEFAULT 0 CHECK (requests >= 0),
  micro_usd bigint NOT NULL DEFAULT 0 CHECK (micro_usd >= 0),
  PRIMARY KEY (bucket, bucket_start, actor_id)
);

COMMENT ON TABLE public.catalogue_ai_copy_reservations_v1 IS
  'Append-oriented reservation ledger. gated = rate slot taken, no money; reserved = money held; settled = charged verified usage; ambiguous = full reservation kept, never auto-released; denied = refused.';
COMMENT ON TABLE public.catalogue_ai_copy_usage_v1 IS
  'UTC usage buckets keyed by period start. The company rows use the all-zero actor id.';

ALTER TABLE public.catalogue_ai_copy_budget_policy_v1 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_ai_copy_reservations_v1 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_ai_copy_usage_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.catalogue_ai_copy_budget_policy_v1,
              public.catalogue_ai_copy_reservations_v1,
              public.catalogue_ai_copy_usage_v1
  FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. Rate-limit gate (runs BEFORE any provider call, including the token count)
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.catalogue_ai_copy_budget_gate_v1(p_actor uuid, p_model text)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_policy public.catalogue_ai_copy_budget_policy_v1%ROWTYPE;
  v_minute timestamptz;
  v_used integer;
  v_id uuid;
BEGIN
  IF p_actor IS NULL OR p_model IS NULL OR NOT public.is_internal_staff(p_actor) THEN
    RETURN NULL;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(194, 5813);
  SELECT * INTO v_policy FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton;
  IF NOT FOUND OR v_policy.enabled IS NOT TRUE OR v_policy.emergency_disabled_at IS NOT NULL
     OR p_model <> v_policy.approved_model THEN
    RETURN NULL;
  END IF;
  v_minute := date_trunc('minute', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  SELECT COALESCE((
    SELECT requests FROM public.catalogue_ai_copy_usage_v1
     WHERE bucket = 'user_minute' AND bucket_start = v_minute AND actor_id = p_actor
  ), 0) INTO v_used;
  IF v_used >= v_policy.per_user_minute_limit THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.catalogue_ai_copy_usage_v1 (bucket, bucket_start, actor_id, requests)
  VALUES ('user_minute', v_minute, p_actor, 1)
  ON CONFLICT (bucket, bucket_start, actor_id) DO UPDATE
    SET requests = public.catalogue_ai_copy_usage_v1.requests + 1;
  INSERT INTO public.catalogue_ai_copy_reservations_v1 (actor_id, model, status)
  VALUES (p_actor, p_model, 'gated')
  RETURNING reservation_id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 4. Atomic reservation: every user and company limit is checked and applied in ONE transaction
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.catalogue_ai_copy_budget_reserve_v1(
  p_reservation_id uuid,
  p_actor uuid,
  p_model text,
  p_counted_input_tokens integer
) RETURNS boolean
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_policy public.catalogue_ai_copy_budget_policy_v1%ROWTYPE;
  v_res public.catalogue_ai_copy_reservations_v1%ROWTYPE;
  v_day date;
  v_month date;
  v_day_ts timestamptz;
  v_month_ts timestamptz;
  v_reserve integer;
  v_user_day_requests integer;
  v_user_day_micro bigint;
  v_company_day_micro bigint;
  v_company_month_micro bigint;
  v_zero constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
  IF p_reservation_id IS NULL OR p_actor IS NULL OR p_model IS NULL OR p_counted_input_tokens IS NULL THEN
    RETURN false;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(194, 5813);
  SELECT * INTO v_res FROM public.catalogue_ai_copy_reservations_v1
   WHERE reservation_id = p_reservation_id FOR UPDATE;
  IF NOT FOUND OR v_res.actor_id <> p_actor OR v_res.status <> 'gated'
     OR v_res.created_at < now() - interval '5 minutes' THEN
    RETURN false;
  END IF;
  SELECT * INTO v_policy FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton;
  IF NOT FOUND OR v_policy.enabled IS NOT TRUE OR v_policy.emergency_disabled_at IS NOT NULL
     OR NOT public.is_internal_staff(p_actor)
     OR p_model <> v_policy.approved_model OR v_res.model <> p_model
     OR p_counted_input_tokens < 1 OR p_counted_input_tokens > v_policy.max_input_tokens THEN
    UPDATE public.catalogue_ai_copy_reservations_v1
       SET status = 'denied', settled_at = now() WHERE reservation_id = p_reservation_id;
    RETURN false;
  END IF;

  v_reserve := v_policy.max_reservation_micro_usd;
  v_day := (now() AT TIME ZONE 'UTC')::date;
  v_month := date_trunc('month', now() AT TIME ZONE 'UTC')::date;
  v_day_ts := v_day::timestamp AT TIME ZONE 'UTC';
  v_month_ts := v_month::timestamp AT TIME ZONE 'UTC';

  SELECT COALESCE((SELECT requests FROM public.catalogue_ai_copy_usage_v1
                    WHERE bucket = 'user_day' AND bucket_start = v_day_ts AND actor_id = p_actor), 0),
         COALESCE((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1
                    WHERE bucket = 'user_day' AND bucket_start = v_day_ts AND actor_id = p_actor), 0)
    INTO v_user_day_requests, v_user_day_micro;
  SELECT COALESCE((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1
                    WHERE bucket = 'company_day' AND bucket_start = v_day_ts AND actor_id = v_zero), 0)
    INTO v_company_day_micro;
  SELECT COALESCE((SELECT micro_usd FROM public.catalogue_ai_copy_usage_v1
                    WHERE bucket = 'company_month' AND bucket_start = v_month_ts AND actor_id = v_zero), 0)
    INTO v_company_month_micro;

  IF v_user_day_requests + 1 > v_policy.per_user_day_requests
     OR v_user_day_micro + v_reserve > v_policy.per_user_day_micro_usd
     OR v_company_day_micro + v_reserve > v_policy.company_day_micro_usd
     OR v_company_month_micro + v_reserve > v_policy.company_month_micro_usd THEN
    UPDATE public.catalogue_ai_copy_reservations_v1
       SET status = 'denied', settled_at = now() WHERE reservation_id = p_reservation_id;
    RETURN false;
  END IF;

  INSERT INTO public.catalogue_ai_copy_usage_v1 (bucket, bucket_start, actor_id, requests, micro_usd) VALUES
    ('user_day', v_day_ts, p_actor, 1, v_reserve),
    ('company_day', v_day_ts, v_zero, 1, v_reserve),
    ('company_month', v_month_ts, v_zero, 1, v_reserve)
  ON CONFLICT (bucket, bucket_start, actor_id) DO UPDATE SET
    requests = public.catalogue_ai_copy_usage_v1.requests + 1,
    micro_usd = public.catalogue_ai_copy_usage_v1.micro_usd + EXCLUDED.micro_usd;

  UPDATE public.catalogue_ai_copy_reservations_v1
     SET status = 'reserved', reserved_micro_usd = v_reserve,
         counted_input_tokens = p_counted_input_tokens,
         day_bucket = v_day, month_bucket = v_month
   WHERE reservation_id = p_reservation_id;
  RETURN true;
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 5. Idempotent settlement from verified provider usage
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.catalogue_ai_copy_budget_settle_v1(
  p_reservation_id uuid,
  p_input_tokens integer,
  p_output_tokens integer,
  p_provider_request_id text,
  p_response_model text,
  p_response_service_tier text
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_policy public.catalogue_ai_copy_budget_policy_v1%ROWTYPE;
  v_res public.catalogue_ai_copy_reservations_v1%ROWTYPE;
  v_verified bigint;
  v_delta bigint;
  v_violation text;
  v_day_ts timestamptz;
  v_month_ts timestamptz;
  v_zero constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
  IF p_reservation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'unknown');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(194, 5813);
  SELECT * INTO v_res FROM public.catalogue_ai_copy_reservations_v1
   WHERE reservation_id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unknown');
  END IF;
  -- Idempotent: a settled or ambiguous reservation never changes again; ambiguous is never auto-released.
  IF v_res.status IN ('settled', 'ambiguous') THEN
    RETURN jsonb_build_object('status', v_res.status, 'charged_micro_usd', v_res.charged_micro_usd, 'replayed', true);
  END IF;
  IF v_res.status <> 'reserved' THEN
    RETURN jsonb_build_object('status', v_res.status);
  END IF;
  SELECT * INTO v_policy FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton;

  -- Usage that cannot be verified keeps the FULL reservation (conservative).
  IF p_input_tokens IS NULL OR p_output_tokens IS NULL
     OR p_input_tokens < 0 OR p_output_tokens < 0
     OR p_input_tokens > 1000000 OR p_output_tokens > 1000000 THEN
    UPDATE public.catalogue_ai_copy_reservations_v1
       SET status = 'ambiguous', charged_micro_usd = reserved_micro_usd,
           violation = 'usage_unverifiable', settled_at = now()
     WHERE reservation_id = p_reservation_id;
    RETURN jsonb_build_object('status', 'ambiguous', 'charged_micro_usd', v_res.reserved_micro_usd, 'violation', 'usage_unverifiable');
  END IF;

  -- Charge = verified usage at the policy prices (standard input price; cached discount ignored).
  v_verified := ((p_input_tokens::bigint * v_policy.input_micro_usd_per_million_tokens + 999999) / 1000000)
              + ((p_output_tokens::bigint * v_policy.output_micro_usd_per_million_tokens + 999999) / 1000000);

  IF p_input_tokens > v_res.counted_input_tokens THEN
    v_violation := 'input_exceeds_count';
  ELSIF p_output_tokens > v_policy.max_output_tokens THEN
    v_violation := 'output_exceeds_cap';
  ELSIF p_response_model IS DISTINCT FROM v_res.model THEN
    v_violation := 'model_mismatch';
  ELSIF p_response_service_tier IS DISTINCT FROM 'default' THEN
    v_violation := 'tier_mismatch';
  ELSIF v_verified > v_res.reserved_micro_usd THEN
    v_violation := 'charge_exceeds_reservation';
  END IF;

  -- Adjust the ORIGINAL reservation periods only (no cross-period error). Charge is never below verified usage.
  v_delta := v_verified - v_res.reserved_micro_usd;
  v_day_ts := v_res.day_bucket::timestamp AT TIME ZONE 'UTC';
  v_month_ts := v_res.month_bucket::timestamp AT TIME ZONE 'UTC';
  UPDATE public.catalogue_ai_copy_usage_v1
     SET micro_usd = GREATEST(0, micro_usd + v_delta)
   WHERE (bucket = 'user_day' AND bucket_start = v_day_ts AND actor_id = v_res.actor_id)
      OR (bucket = 'company_day' AND bucket_start = v_day_ts AND actor_id = v_zero)
      OR (bucket = 'company_month' AND bucket_start = v_month_ts AND actor_id = v_zero);

  UPDATE public.catalogue_ai_copy_reservations_v1
     SET status = 'settled', charged_micro_usd = v_verified,
         verified_input_tokens = p_input_tokens, verified_output_tokens = p_output_tokens,
         provider_request_id = left(p_provider_request_id, 200),
         violation = v_violation, settled_at = now()
   WHERE reservation_id = p_reservation_id;

  -- Any tripwire disables inference. A trip is a disable, never an increase.
  IF v_violation IS NOT NULL THEN
    UPDATE public.catalogue_ai_copy_budget_policy_v1
       SET emergency_disabled_at = COALESCE(emergency_disabled_at, now()),
           emergency_reason = COALESCE(emergency_reason, left('auto:' || v_violation, 200)),
           updated_at = now()
     WHERE singleton;
  END IF;

  RETURN jsonb_build_object('status', 'settled', 'charged_micro_usd', v_verified,
                            'replayed', false, 'violation', v_violation);
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 6. Ambiguous provider outcome: keep the FULL reservation, never auto-release
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.catalogue_ai_copy_budget_mark_ambiguous_v1(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_res public.catalogue_ai_copy_reservations_v1%ROWTYPE;
BEGIN
  IF p_reservation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'unknown');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(194, 5813);
  SELECT * INTO v_res FROM public.catalogue_ai_copy_reservations_v1
   WHERE reservation_id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unknown');
  END IF;
  IF v_res.status = 'reserved' THEN
    UPDATE public.catalogue_ai_copy_reservations_v1
       SET status = 'ambiguous', charged_micro_usd = reserved_micro_usd, settled_at = now()
     WHERE reservation_id = p_reservation_id;
    RETURN jsonb_build_object('status', 'ambiguous', 'charged_micro_usd', v_res.reserved_micro_usd);
  END IF;
  RETURN jsonb_build_object('status', v_res.status, 'charged_micro_usd', v_res.charged_micro_usd);
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 7. Emergency inference disable (latch). Sets only; nothing clears it or raises a limit.
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.catalogue_ai_copy_budget_emergency_disable_v1(p_reason text)
RETURNS timestamptz
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_at timestamptz;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(194, 5813);
  UPDATE public.catalogue_ai_copy_budget_policy_v1
     SET emergency_disabled_at = COALESCE(emergency_disabled_at, now()),
         emergency_reason = COALESCE(emergency_reason, left(COALESCE(p_reason, 'manual'), 200)),
         updated_at = now()
   WHERE singleton
  RETURNING emergency_disabled_at INTO v_at;
  RETURN v_at;
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 8. Server-only authorization: service_role only; nothing for PUBLIC, anon or authenticated
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.catalogue_ai_copy_budget_gate_v1(uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.catalogue_ai_copy_budget_reserve_v1(uuid, uuid, text, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.catalogue_ai_copy_budget_settle_v1(uuid, integer, integer, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.catalogue_ai_copy_budget_mark_ambiguous_v1(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.catalogue_ai_copy_budget_emergency_disable_v1(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.catalogue_ai_copy_budget_gate_v1(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_ai_copy_budget_reserve_v1(uuid, uuid, text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_ai_copy_budget_settle_v1(uuid, integer, integer, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_ai_copy_budget_mark_ambiguous_v1(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.catalogue_ai_copy_budget_emergency_disable_v1(text) TO service_role;
