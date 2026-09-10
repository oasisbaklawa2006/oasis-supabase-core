-- D2C website operational support v1.
-- Mission Control: Oasis-Baklawa-Central#493.
-- Extends 20260910170000 without creating products, prices or canonical orders.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Create or recover one active cart for exactly one server-authenticated identity.
-- Guest tokens are generated client/server-side; only their hash reaches Core.
CREATE OR REPLACE FUNCTION public.d2c_create_or_get_cart_v1(
  p_owner_user_id uuid DEFAULT NULL,
  p_guest_session_hash text DEFAULT NULL,
  p_attribution jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(cart_id uuid, created boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_hash text := nullif(btrim(p_guest_session_hash),'');
  v_cart public.d2c_cart_sessions%rowtype;
  v_lock_key text;
BEGIN
  IF (p_owner_user_id IS NULL) = (v_hash IS NULL) THEN
    RAISE EXCEPTION 'D2C_CART_EXACTLY_ONE_OWNER_REQUIRED';
  END IF;
  IF v_hash IS NOT NULL AND length(v_hash) < 32 THEN
    RAISE EXCEPTION 'D2C_GUEST_SESSION_HASH_TOO_SHORT';
  END IF;
  IF jsonb_typeof(coalesce(p_attribution,'{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'D2C_ATTRIBUTION_MUST_BE_OBJECT';
  END IF;

  v_lock_key := coalesce('user:'||p_owner_user_id::text,'guest:'||v_hash);
  PERFORM pg_advisory_xact_lock(hashtextextended('d2c_cart:'||v_lock_key,0));

  IF p_owner_user_id IS NOT NULL THEN
    SELECT * INTO v_cart
    FROM public.d2c_cart_sessions
    WHERE owner_user_id=p_owner_user_id AND status='ACTIVE' AND expires_at>now()
    ORDER BY updated_at DESC,id DESC LIMIT 1 FOR UPDATE;
  ELSE
    SELECT * INTO v_cart
    FROM public.d2c_cart_sessions
    WHERE guest_session_hash=v_hash AND status='ACTIVE' AND expires_at>now()
    ORDER BY updated_at DESC,id DESC LIMIT 1 FOR UPDATE;
  END IF;

  IF FOUND THEN
    RETURN QUERY SELECT v_cart.id,false;
    RETURN;
  END IF;

  INSERT INTO public.d2c_cart_sessions(owner_user_id,guest_session_hash,attribution)
  VALUES(p_owner_user_id,v_hash,coalesce(p_attribution,'{}'::jsonb))
  RETURNING * INTO v_cart;
  RETURN QUERY SELECT v_cart.id,true;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_create_or_get_cart_v1(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_create_or_get_cart_v1(uuid,text,jsonb) TO service_role;

-- Set quantity for a line. Quantity zero removes the line. Pricing is never accepted
-- as input; a positive line requires a currently governed D2C offer.
CREATE OR REPLACE FUNCTION public.d2c_set_cart_line_v1(
  p_cart_id uuid,
  p_product_id uuid,
  p_quantity integer,
  p_customer_configuration jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_cart public.d2c_cart_sessions%rowtype;
BEGIN
  IF p_quantity < 0 OR p_quantity > 999 THEN RAISE EXCEPTION 'D2C_CART_QUANTITY_INVALID'; END IF;
  IF jsonb_typeof(coalesce(p_customer_configuration,'{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'D2C_CART_CONFIGURATION_MUST_BE_OBJECT';
  END IF;

  SELECT * INTO v_cart FROM public.d2c_cart_sessions WHERE id=p_cart_id FOR UPDATE;
  IF NOT FOUND OR v_cart.status <> 'ACTIVE' OR v_cart.expires_at<=now() THEN
    RAISE EXCEPTION 'D2C_CART_NOT_ACTIVE';
  END IF;

  IF p_quantity = 0 THEN
    DELETE FROM public.d2c_cart_lines WHERE cart_id=p_cart_id AND product_id=p_product_id;
    RETURN;
  END IF;

  IF NOT EXISTS(SELECT 1 FROM public.d2c_resolve_product_offer_v1(p_product_id)) THEN
    RAISE EXCEPTION 'D2C_PRODUCT_NOT_PURCHASABLE:%',p_product_id;
  END IF;

  INSERT INTO public.d2c_cart_lines(cart_id,product_id,quantity,customer_configuration)
  VALUES(p_cart_id,p_product_id,p_quantity,coalesce(p_customer_configuration,'{}'::jsonb))
  ON CONFLICT(cart_id,product_id) DO UPDATE SET
    quantity=excluded.quantity,
    customer_configuration=excluded.customer_configuration;

  UPDATE public.d2c_cart_sessions SET expires_at=GREATEST(expires_at,now()+interval '30 days') WHERE id=p_cart_id;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_set_cart_line_v1(uuid,uuid,integer,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_set_cart_line_v1(uuid,uuid,integer,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_create_cart_recovery_v1(
  p_cart_id uuid,
  p_token_hash text,
  p_expires_at timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_id uuid; v_hash text:=btrim(coalesce(p_token_hash,''));
BEGIN
  IF length(v_hash)<32 THEN RAISE EXCEPTION 'D2C_RECOVERY_HASH_TOO_SHORT'; END IF;
  IF p_expires_at<=now() OR p_expires_at>now()+interval '30 days' THEN
    RAISE EXCEPTION 'D2C_RECOVERY_EXPIRY_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.d2c_cart_sessions WHERE id=p_cart_id AND status='ACTIVE' AND expires_at>now()) THEN
    RAISE EXCEPTION 'D2C_CART_NOT_ACTIVE';
  END IF;
  INSERT INTO public.d2c_cart_recovery_sessions(cart_id,token_hash,expires_at)
  VALUES(p_cart_id,v_hash,p_expires_at)
  ON CONFLICT(token_hash) DO UPDATE SET updated_at=now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_create_cart_recovery_v1(uuid,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_create_cart_recovery_v1(uuid,text,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_create_support_request_v1(
  p_request_type text,
  p_contact jsonb,
  p_message text,
  p_idempotency_key text,
  p_order_intent_id uuid DEFAULT NULL
)
RETURNS TABLE(request_id uuid, duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_existing uuid; v_type text:=upper(btrim(coalesce(p_request_type,''))); v_key text:=btrim(coalesce(p_idempotency_key,''));
BEGIN
  IF v_type NOT IN ('GENERAL','CANCEL_REQUEST','ADDRESS_CHANGE','DELIVERY_HELP','PAYMENT_HELP') THEN
    RAISE EXCEPTION 'D2C_SUPPORT_REQUEST_TYPE_INVALID';
  END IF;
  IF jsonb_typeof(coalesce(p_contact,'{}'::jsonb))<>'object' THEN RAISE EXCEPTION 'D2C_SUPPORT_CONTACT_INVALID'; END IF;
  IF nullif(btrim(coalesce(p_message,'')),'') IS NULL THEN RAISE EXCEPTION 'D2C_SUPPORT_MESSAGE_REQUIRED'; END IF;
  IF v_key='' THEN RAISE EXCEPTION 'D2C_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_order_intent_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.d2c_order_intents WHERE id=p_order_intent_id) THEN
    RAISE EXCEPTION 'D2C_ORDER_INTENT_NOT_FOUND';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('d2c_support:'||v_key,0));
  SELECT id INTO v_existing FROM public.d2c_support_requests WHERE idempotency_key=v_key;
  IF FOUND THEN RETURN QUERY SELECT v_existing,true; RETURN; END IF;

  INSERT INTO public.d2c_support_requests(order_intent_id,request_type,contact,message,idempotency_key)
  VALUES(p_order_intent_id,v_type,coalesce(p_contact,'{}'::jsonb),btrim(p_message),v_key)
  RETURNING id INTO v_existing;
  RETURN QUERY SELECT v_existing,false;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_create_support_request_v1(text,jsonb,text,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_create_support_request_v1(text,jsonb,text,text,uuid) TO service_role;

-- Reliable outbox worker controls. Claim uses SKIP LOCKED so parallel workers cannot
-- deliver the same event concurrently.
CREATE OR REPLACE FUNCTION public.d2c_claim_outbox_v1(p_limit integer DEFAULT 25)
RETURNS TABLE(id uuid,aggregate_type text,aggregate_id uuid,event_type text,dedupe_key text,payload jsonb,attempts integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_limit<1 OR p_limit>100 THEN RAISE EXCEPTION 'D2C_OUTBOX_LIMIT_INVALID'; END IF;
  RETURN QUERY
  WITH claim AS (
    SELECT o.id FROM public.d2c_outbox_events o
    WHERE o.status IN ('PENDING','FAILED') AND o.available_at<=now() AND o.attempts<10
    ORDER BY o.available_at,o.created_at,o.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ), updated AS (
    UPDATE public.d2c_outbox_events o SET status='PROCESSING',attempts=o.attempts+1,last_error=NULL
    FROM claim WHERE o.id=claim.id
    RETURNING o.*
  )
  SELECT u.id,u.aggregate_type,u.aggregate_id,u.event_type,u.dedupe_key,u.payload,u.attempts FROM updated u;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_claim_outbox_v1(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_claim_outbox_v1(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_complete_outbox_v1(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  UPDATE public.d2c_outbox_events SET status='SENT',sent_at=now(),last_error=NULL WHERE id=p_event_id AND status='PROCESSING';
  IF NOT FOUND THEN RAISE EXCEPTION 'D2C_OUTBOX_EVENT_NOT_PROCESSING'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_complete_outbox_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_complete_outbox_v1(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_fail_outbox_v1(p_event_id uuid,p_error text,p_retry_after interval DEFAULT interval '5 minutes')
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_attempts integer;
BEGIN
  IF p_retry_after<interval '0 seconds' OR p_retry_after>interval '24 hours' THEN RAISE EXCEPTION 'D2C_OUTBOX_RETRY_INVALID'; END IF;
  UPDATE public.d2c_outbox_events SET
    status=CASE WHEN attempts>=10 THEN 'DEAD_LETTER' ELSE 'FAILED' END,
    last_error=left(coalesce(nullif(btrim(p_error),''),'unspecified error'),1000),
    available_at=CASE WHEN attempts>=10 THEN available_at ELSE now()+p_retry_after END
  WHERE id=p_event_id AND status='PROCESSING'
  RETURNING attempts INTO v_attempts;
  IF NOT FOUND THEN RAISE EXCEPTION 'D2C_OUTBOX_EVENT_NOT_PROCESSING'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_fail_outbox_v1(uuid,text,interval) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_fail_outbox_v1(uuid,text,interval) TO service_role;

-- Status expiry only; historical payment/order/audit evidence is never deleted.
CREATE OR REPLACE FUNCTION public.d2c_maintenance_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_carts integer:=0; v_checkouts integer:=0; v_recoveries integer:=0;
BEGIN
  UPDATE public.d2c_cart_sessions SET status='EXPIRED' WHERE status='ACTIVE' AND expires_at<=now();
  GET DIAGNOSTICS v_carts=ROW_COUNT;
  UPDATE public.d2c_checkout_sessions SET status='EXPIRED' WHERE status IN ('QUOTED','PAYMENT_PENDING') AND expires_at<=now();
  GET DIAGNOSTICS v_checkouts=ROW_COUNT;
  UPDATE public.d2c_cart_recovery_sessions SET status='EXPIRED' WHERE status='ACTIVE' AND expires_at<=now();
  GET DIAGNOSTICS v_recoveries=ROW_COUNT;
  RETURN jsonb_build_object('expired_carts',v_carts,'expired_checkouts',v_checkouts,'expired_recoveries',v_recoveries,'ran_at',now());
END;
$$;
REVOKE ALL ON FUNCTION public.d2c_maintenance_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_maintenance_v1() TO service_role;

CREATE OR REPLACE FUNCTION public.d2c_backend_readiness_v1()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'catalogue',jsonb_build_object(
      'published_presentations',(SELECT count(*) FROM public.d2c_catalogue_publications WHERE status='PUBLISHED'),
      'sale_enabled_authorities',(SELECT count(*) FROM public.d2c_product_commerce_authority WHERE sale_enabled AND valid_from<=now() AND (valid_until IS NULL OR valid_until>now())),
      'public_offers',(SELECT count(*) FROM public.d2c_public_catalogue_v1())
    ),
    'commerce',jsonb_build_object(
      'active_carts',(SELECT count(*) FROM public.d2c_cart_sessions WHERE status='ACTIVE' AND expires_at>now()),
      'payable_checkouts',(SELECT count(*) FROM public.d2c_checkout_sessions WHERE status IN ('QUOTED','PAYMENT_PENDING') AND expires_at>now()),
      'captured_unhanded_orders',(SELECT count(*) FROM public.d2c_order_intents WHERE status='PAID_AWAITING_HANDOFF'),
      'open_support_requests',(SELECT count(*) FROM public.d2c_support_requests WHERE status IN ('OPEN','IN_REVIEW'))
    ),
    'integrations',jsonb_build_object(
      'outbox_pending',(SELECT count(*) FROM public.d2c_outbox_events WHERE status IN ('PENDING','FAILED','PROCESSING')),
      'outbox_dead_letter',(SELECT count(*) FROM public.d2c_outbox_events WHERE status='DEAD_LETTER'),
      'verified_webhooks_unprocessed',(SELECT count(*) FROM public.d2c_integration_webhook_events WHERE signature_verified AND NOT processed)
    ),
    'hard_boundaries',jsonb_build_object(
      'product_creation_authority',false,
      'canonical_order_creation_authority',false,
      'browser_authoritative_totals',false
    ),
    'generated_at',now()
  );
$$;
REVOKE ALL ON FUNCTION public.d2c_backend_readiness_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.d2c_backend_readiness_v1() TO service_role;

COMMENT ON FUNCTION public.d2c_create_or_get_cart_v1(uuid,text,jsonb) IS 'Server-only cart identity resolver. Raw guest tokens are never stored; caller supplies only a hash.';
COMMENT ON FUNCTION public.d2c_set_cart_line_v1(uuid,uuid,integer,jsonb) IS 'Server-only cart mutation. Accepts identity/quantity/configuration only; never accepts a browser price.';
COMMENT ON FUNCTION public.d2c_backend_readiness_v1() IS 'Private D2C readiness telemetry for admin/Appverse status surfaces. Contains counts and hard-boundary states, not secrets.';
