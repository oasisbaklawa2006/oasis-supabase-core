-- UAT #561 / Core PR #269 security hardening.
-- Durable guard for the public MSG91 endpoint.
-- Raw access tokens, phone numbers and IP addresses are never persisted here;
-- the Edge function supplies SHA-256 digests only.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE public.msg91_otp_security_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type text NOT NULL CHECK (event_type IN ('ATTEMPT','VERIFIED','LEGACY_OTP')),
  token_digest text,
  phone_digest text,
  ip_digest text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT msg91_otp_security_events_ip_digest_chk
    CHECK (ip_digest ~ '^[0-9a-f]{64}$'),
  CONSTRAINT msg91_otp_security_events_token_digest_chk
    CHECK (token_digest IS NULL OR token_digest ~ '^[0-9a-f]{64}$'),
  CONSTRAINT msg91_otp_security_events_phone_digest_chk
    CHECK (phone_digest IS NULL OR phone_digest ~ '^[0-9a-f]{64}$'),
  CONSTRAINT msg91_otp_security_events_shape_chk CHECK (
    (event_type = 'ATTEMPT' AND token_digest IS NULL AND phone_digest IS NULL)
    OR
    (event_type = 'VERIFIED' AND token_digest IS NOT NULL AND phone_digest IS NOT NULL)
    OR
    (event_type = 'LEGACY_OTP' AND token_digest IS NULL AND phone_digest IS NOT NULL)
  )
);

CREATE UNIQUE INDEX msg91_otp_security_events_verified_token_uidx
  ON public.msg91_otp_security_events(token_digest)
  WHERE event_type = 'VERIFIED';

CREATE INDEX msg91_otp_security_events_ip_window_idx
  ON public.msg91_otp_security_events(event_type, ip_digest, created_at DESC);

CREATE INDEX msg91_otp_security_events_phone_window_idx
  ON public.msg91_otp_security_events(event_type, phone_digest, created_at DESC)
  WHERE phone_digest IS NOT NULL;

ALTER TABLE public.msg91_otp_security_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.msg91_otp_security_events FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE public.msg91_otp_security_events_id_seq FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.msg91_otp_security_events IS
  'Private MSG91 rate/replay ledger. Stores SHA-256 digests only; writes are governed by service-role-only RPCs.';

CREATE OR REPLACE FUNCTION public.check_msg91_widget_attempt_v1(
  p_ip_digest text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_count integer;
BEGIN
  IF p_ip_digest IS NULL OR p_ip_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'MSG91_SECURITY_DIGEST_INVALID' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('msg91-attempt:' || p_ip_digest, 0));

  SELECT count(*)::integer INTO v_count
  FROM public.msg91_otp_security_events e
  WHERE e.event_type = 'ATTEMPT'
    AND e.ip_digest = p_ip_digest
    AND e.created_at >= now() - interval '10 minutes';

  IF v_count >= 20 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;

  INSERT INTO public.msg91_otp_security_events(event_type, ip_digest)
  VALUES ('ATTEMPT', p_ip_digest);

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_msg91_widget_token_v1(
  p_token_digest text,
  p_phone_digest text,
  p_ip_digest text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_phone_count integer;
  v_ip_count integer;
BEGIN
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$'
     OR p_phone_digest IS NULL OR p_phone_digest !~ '^[0-9a-f]{64}$'
     OR p_ip_digest IS NULL OR p_ip_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'MSG91_SECURITY_DIGEST_INVALID' USING ERRCODE = '22023';
  END IF;

  -- Consistent lock order: token -> phone -> verified-IP.
  PERFORM pg_advisory_xact_lock(hashtextextended('msg91-token:' || p_token_digest, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('msg91-phone:' || p_phone_digest, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('msg91-verified-ip:' || p_ip_digest, 0));

  IF EXISTS (
    SELECT 1 FROM public.msg91_otp_security_events e
    WHERE e.event_type = 'VERIFIED' AND e.token_digest = p_token_digest
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'access_token_replayed');
  END IF;

  SELECT count(*)::integer INTO v_phone_count
  FROM public.msg91_otp_security_events e
  WHERE e.event_type = 'VERIFIED'
    AND e.phone_digest = p_phone_digest
    AND e.created_at >= now() - interval '10 minutes';

  SELECT count(*)::integer INTO v_ip_count
  FROM public.msg91_otp_security_events e
  WHERE e.event_type = 'VERIFIED'
    AND e.ip_digest = p_ip_digest
    AND e.created_at >= now() - interval '10 minutes';

  IF v_phone_count >= 5 OR v_ip_count >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;

  INSERT INTO public.msg91_otp_security_events(event_type, token_digest, phone_digest, ip_digest)
  VALUES ('VERIFIED', p_token_digest, p_phone_digest, p_ip_digest);

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.check_msg91_legacy_otp_attempt_v1(
  p_phone_digest text,
  p_ip_digest text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_phone_count integer;
  v_ip_count integer;
BEGIN
  IF p_phone_digest IS NULL OR p_phone_digest !~ '^[0-9a-f]{64}$'
     OR p_ip_digest IS NULL OR p_ip_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'MSG91_SECURITY_DIGEST_INVALID' USING ERRCODE = '22023';
  END IF;

  -- Consistent lock order: phone -> legacy-IP.
  PERFORM pg_advisory_xact_lock(hashtextextended('msg91-legacy-phone:' || p_phone_digest, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('msg91-legacy-ip:' || p_ip_digest, 0));

  SELECT count(*)::integer INTO v_phone_count
  FROM public.msg91_otp_security_events e
  WHERE e.event_type = 'LEGACY_OTP'
    AND e.phone_digest = p_phone_digest
    AND e.created_at >= now() - interval '10 minutes';

  SELECT count(*)::integer INTO v_ip_count
  FROM public.msg91_otp_security_events e
  WHERE e.event_type = 'LEGACY_OTP'
    AND e.ip_digest = p_ip_digest
    AND e.created_at >= now() - interval '10 minutes';

  IF v_phone_count >= 5 OR v_ip_count >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;

  INSERT INTO public.msg91_otp_security_events(event_type, phone_digest, ip_digest)
  VALUES ('LEGACY_OTP', p_phone_digest, p_ip_digest);

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.check_msg91_widget_attempt_v1(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_msg91_widget_token_v1(text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.check_msg91_legacy_otp_attempt_v1(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_msg91_widget_attempt_v1(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_msg91_widget_token_v1(text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.check_msg91_legacy_otp_attempt_v1(text,text) TO service_role;

COMMENT ON FUNCTION public.check_msg91_widget_attempt_v1(text) IS
  'Atomically records/rate-limits public MSG91 verification attempts by hashed request origin.';
COMMENT ON FUNCTION public.claim_msg91_widget_token_v1(text,text,text) IS
  'Atomically claims one verified MSG91 access-token digest and enforces hashed phone/IP verification windows before identity/session work.';
COMMENT ON FUNCTION public.check_msg91_legacy_otp_attempt_v1(text,text) IS
  'Atomically rate-limits legacy MSG91 OTP delivery by hashed phone and request origin.';
