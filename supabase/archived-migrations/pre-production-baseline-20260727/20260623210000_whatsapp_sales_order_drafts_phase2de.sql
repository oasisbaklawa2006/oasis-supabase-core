-- Phase 2D/2E: operator-created WhatsApp sales order drafts from inbound messages.
-- Draft only — no final sales order, stock, finance, or dispatch.
-- Uses whatsapp_sales_order_drafts (does not alter any existing sales_order_drafts table).

CREATE TABLE IF NOT EXISTS public.whatsapp_sales_order_drafts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source TEXT NOT NULL DEFAULT 'whatsapp_inbound'
    CHECK (source = 'whatsapp_inbound'),
  source_message_id UUID NOT NULL
    REFERENCES public.whatsapp_inbound_messages(id) ON DELETE RESTRICT,
  sender_phone TEXT NOT NULL,
  customer_name TEXT,
  message_body TEXT NOT NULL,
  resolved_product_id UUID REFERENCES public.products(id),
  resolved_sku TEXT NOT NULL,
  resolved_product_name TEXT,
  confidence_band TEXT NOT NULL
    CHECK (confidence_band IN ('HIGH', 'MEDIUM', 'LOW')),
  operator_decision TEXT NOT NULL
    CHECK (operator_decision IN ('confirmed', 'alternative_selected')),
  status TEXT NOT NULL DEFAULT 'UNDER_REVIEW'
    CHECK (status IN ('AI_DRAFT', 'UNDER_REVIEW', 'CANCELLED')),
  quantity NUMERIC NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_by UUID NOT NULL REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT whatsapp_sales_order_drafts_one_per_message UNIQUE (source_message_id)
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_sales_order_drafts_status
  ON public.whatsapp_sales_order_drafts (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_whatsapp_sales_order_drafts_source_message
  ON public.whatsapp_sales_order_drafts (source_message_id);

COMMENT ON TABLE public.whatsapp_sales_order_drafts IS
  'Phase 2E reviewable WhatsApp sales order drafts from operator confirm. Not a final sales order.';

ALTER TABLE public.whatsapp_sales_order_drafts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Team read whatsapp sales order drafts"
  ON public.whatsapp_sales_order_drafts
  FOR SELECT
  TO authenticated
  USING (public.is_team_member(auth.uid()));

CREATE TABLE IF NOT EXISTS public.whatsapp_operator_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_message_id UUID NOT NULL
    REFERENCES public.whatsapp_inbound_messages(id) ON DELETE CASCADE,
  action TEXT NOT NULL
    CHECK (action IN ('confirm', 'reject', 'select_alternative')),
  sku TEXT,
  product_name TEXT,
  confidence_band TEXT,
  whatsapp_sales_order_draft_id UUID REFERENCES public.whatsapp_sales_order_drafts(id),
  decided_by UUID NOT NULL REFERENCES auth.users(id),
  decided_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_operator_decisions_message
  ON public.whatsapp_operator_decisions (source_message_id, decided_at DESC);

ALTER TABLE public.whatsapp_operator_decisions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Team read whatsapp operator decisions"
  ON public.whatsapp_operator_decisions
  FOR SELECT
  TO authenticated
  USING (public.is_team_member(auth.uid()));

CREATE OR REPLACE FUNCTION public.create_whatsapp_sales_order_draft_from_operator(
  _source_message_id UUID,
  _resolved_sku TEXT,
  _resolved_product_name TEXT,
  _resolved_product_id UUID,
  _confidence_band TEXT,
  _operator_decision TEXT
)
RETURNS public.whatsapp_sales_order_drafts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  msg public.whatsapp_inbound_messages;
  existing public.whatsapp_sales_order_drafts;
  inserted public.whatsapp_sales_order_drafts;
  draft_status TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_team_member(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized to create whatsapp sales order drafts';
  END IF;

  IF _source_message_id IS NULL THEN
    RAISE EXCEPTION 'source_message_id is required';
  END IF;

  IF _resolved_sku IS NULL OR btrim(_resolved_sku) = '' THEN
    RAISE EXCEPTION 'resolved_sku is required';
  END IF;

  IF _confidence_band NOT IN ('HIGH', 'MEDIUM', 'LOW') THEN
    RAISE EXCEPTION 'invalid confidence_band';
  END IF;

  IF _operator_decision NOT IN ('confirmed', 'alternative_selected') THEN
    RAISE EXCEPTION 'invalid operator_decision';
  END IF;

  IF _confidence_band = 'LOW' AND _operator_decision <> 'alternative_selected' THEN
    RAISE EXCEPTION 'LOW confidence requires alternative_selected operator decision';
  END IF;

  SELECT * INTO msg
  FROM public.whatsapp_inbound_messages
  WHERE id = _source_message_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source message not found';
  END IF;

  SELECT * INTO existing
  FROM public.whatsapp_sales_order_drafts
  WHERE source_message_id = _source_message_id
  LIMIT 1;

  IF FOUND THEN
    RETURN existing;
  END IF;

  draft_status := CASE
    WHEN _confidence_band = 'HIGH' THEN 'AI_DRAFT'
    ELSE 'UNDER_REVIEW'
  END;

  INSERT INTO public.whatsapp_sales_order_drafts (
    source_message_id,
    sender_phone,
    customer_name,
    message_body,
    resolved_product_id,
    resolved_sku,
    resolved_product_name,
    confidence_band,
    operator_decision,
    status,
    created_by
  )
  VALUES (
    msg.id,
    msg.sender_phone,
    msg.sender_name,
    msg.message_body,
    _resolved_product_id,
    btrim(_resolved_sku),
    NULLIF(btrim(_resolved_product_name), ''),
    _confidence_band,
    _operator_decision,
    draft_status,
    auth.uid()
  )
  RETURNING * INTO inserted;

  INSERT INTO public.whatsapp_operator_decisions (
    source_message_id,
    action,
    sku,
    product_name,
    confidence_band,
    whatsapp_sales_order_draft_id,
    decided_by
  )
  VALUES (
    msg.id,
    'confirm',
    inserted.resolved_sku,
    inserted.resolved_product_name,
    inserted.confidence_band,
    inserted.id,
    auth.uid()
  );

  RETURN inserted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_whatsapp_sales_order_draft_from_operator(
  UUID, TEXT, TEXT, UUID, TEXT, TEXT
) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_whatsapp_operator_decision(
  _source_message_id UUID,
  _action TEXT,
  _sku TEXT,
  _product_name TEXT,
  _confidence_band TEXT
)
RETURNS public.whatsapp_operator_decisions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inserted public.whatsapp_operator_decisions;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_team_member(auth.uid()) THEN
    RAISE EXCEPTION 'not authorized to record operator decisions';
  END IF;

  IF _action NOT IN ('reject', 'select_alternative') THEN
    RAISE EXCEPTION 'invalid action for this RPC';
  END IF;

  INSERT INTO public.whatsapp_operator_decisions (
    source_message_id,
    action,
    sku,
    product_name,
    confidence_band,
    decided_by
  )
  VALUES (
    _source_message_id,
    _action,
    NULLIF(btrim(_sku), ''),
    NULLIF(btrim(_product_name), ''),
    _confidence_band,
    auth.uid()
  )
  RETURNING * INTO inserted;

  RETURN inserted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_whatsapp_operator_decision(
  UUID, TEXT, TEXT, TEXT, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.create_whatsapp_sales_order_draft_from_operator IS
  'Phase 2E operator confirm → whatsapp_sales_order_drafts only. Idempotent per source_message_id.';

COMMENT ON FUNCTION public.record_whatsapp_operator_decision IS
  'Phase 2E durable reject/alternative operator audit. No order side effects.';
