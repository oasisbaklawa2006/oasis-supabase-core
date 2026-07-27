-- Phase 2C: read-only WhatsApp inbound message capture.
-- No orders, stock, finance, or outbound reply paths.

CREATE TABLE IF NOT EXISTS public.whatsapp_inbound_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_message_id TEXT UNIQUE,
  sender_phone TEXT NOT NULL,
  sender_name TEXT,
  message_body TEXT NOT NULL,
  message_type TEXT NOT NULL DEFAULT 'text',
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  raw_payload JSONB,
  resolver_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (resolver_status IN ('pending', 'resolved', 'failed')),
  resolver_result_json JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_inbound_messages_received_at
  ON public.whatsapp_inbound_messages (received_at DESC);

CREATE INDEX IF NOT EXISTS idx_whatsapp_inbound_messages_sender_phone
  ON public.whatsapp_inbound_messages (sender_phone);

COMMENT ON TABLE public.whatsapp_inbound_messages IS
  'Phase 2C read-only inbound WhatsApp messages. Resolver output stored at ingest; no order side effects.';

ALTER TABLE public.whatsapp_inbound_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read whatsapp inbound messages" ON public.whatsapp_inbound_messages;
CREATE POLICY "Team read whatsapp inbound messages"
  ON public.whatsapp_inbound_messages
  FOR SELECT
  TO authenticated
  USING (public.is_team_member(auth.uid()));

-- Inserts are performed via SECURITY DEFINER RPC (team) or service role (future webhook).
-- No direct INSERT/UPDATE/DELETE policies for authenticated users.

CREATE OR REPLACE FUNCTION public.ingest_whatsapp_inbound_message(
  _provider_message_id TEXT,
  _sender_phone TEXT,
  _sender_name TEXT,
  _message_body TEXT,
  _message_type TEXT DEFAULT 'text',
  _received_at TIMESTAMPTZ DEFAULT now(),
  _raw_payload JSONB DEFAULT NULL,
  _resolver_status TEXT DEFAULT 'pending',
  _resolver_result_json JSONB DEFAULT NULL
)
RETURNS public.whatsapp_inbound_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing public.whatsapp_inbound_messages;
  inserted public.whatsapp_inbound_messages;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_team_member(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized to ingest whatsapp messages';
  END IF;

  IF _sender_phone IS NULL OR btrim(_sender_phone) = '' THEN
    RAISE EXCEPTION 'sender_phone is required';
  END IF;

  IF _message_body IS NULL OR btrim(_message_body) = '' THEN
    RAISE EXCEPTION 'message_body is required';
  END IF;

  IF _provider_message_id IS NOT NULL AND btrim(_provider_message_id) <> '' THEN
    SELECT * INTO existing
    FROM public.whatsapp_inbound_messages
    WHERE provider_message_id = _provider_message_id
    LIMIT 1;

    IF FOUND THEN
      RETURN existing;
    END IF;
  END IF;

  INSERT INTO public.whatsapp_inbound_messages (
    provider_message_id,
    sender_phone,
    sender_name,
    message_body,
    message_type,
    received_at,
    raw_payload,
    resolver_status,
    resolver_result_json
  )
  VALUES (
    NULLIF(btrim(_provider_message_id), ''),
    btrim(_sender_phone),
    NULLIF(btrim(_sender_name), ''),
    btrim(_message_body),
    COALESCE(NULLIF(btrim(_message_type), ''), 'text'),
    COALESCE(_received_at, now()),
    _raw_payload,
    COALESCE(NULLIF(btrim(_resolver_status), ''), 'pending'),
    _resolver_result_json
  )
  RETURNING * INTO inserted;

  RETURN inserted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ingest_whatsapp_inbound_message(
  TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, JSONB, TEXT, JSONB
) TO authenticated;

COMMENT ON FUNCTION public.ingest_whatsapp_inbound_message IS
  'Phase 2C internal ingestion. Idempotent on provider_message_id. Team members or service role only.';
