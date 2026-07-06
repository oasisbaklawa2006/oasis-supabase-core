-- Phase 2F: draft quantity from resolver + realtime publication for operator inbox.

DROP FUNCTION IF EXISTS public.create_whatsapp_sales_order_draft_from_operator(UUID, TEXT, TEXT, UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.create_whatsapp_sales_order_draft_from_operator(
  _source_message_id UUID,
  _resolved_sku TEXT,
  _resolved_product_name TEXT,
  _resolved_product_id UUID,
  _confidence_band TEXT,
  _operator_decision TEXT,
  _quantity NUMERIC DEFAULT 1
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
  draft_quantity NUMERIC;
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

  draft_quantity := COALESCE(_quantity, 1);
  IF draft_quantity <= 0 THEN
    RAISE EXCEPTION 'quantity must be positive';
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
    quantity,
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
    draft_quantity,
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
  UUID, TEXT, TEXT, UUID, TEXT, TEXT, NUMERIC
) TO authenticated;

COMMENT ON FUNCTION public.create_whatsapp_sales_order_draft_from_operator IS
  'Phase 2E/2F operator confirm → whatsapp_sales_order_drafts only. Idempotent per source_message_id.';

-- Realtime feeds for operator inbox (read-only UI refresh).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'whatsapp_inbound_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.whatsapp_inbound_messages;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'whatsapp_sales_order_drafts'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.whatsapp_sales_order_drafts;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'whatsapp_operator_decisions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.whatsapp_operator_decisions;
  END IF;
END $$;
