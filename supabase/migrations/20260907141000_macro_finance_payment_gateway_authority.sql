-- MACRO-FINANCE A1: provider-neutral payment gateway canonical boundary.
-- Payable amounts are derived server-side from canonical Finance facts; never
-- from client-supplied totals. Provider events are append-only evidence mapped
-- into canonical order_payments without a parallel money ledger.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

CREATE TABLE IF NOT EXISTS public.payment_gateway_payable_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  proforma_invoice_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id),
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id),
  payment_purpose text NOT NULL CHECK (payment_purpose IN ('advance','balance','final_payment')),
  provider_code text NOT NULL CHECK (provider_code IN ('razorpay','payu','cashfree','stripe','generic')),
  canonical_amount numeric(14,2) NOT NULL CHECK (canonical_amount > 0),
  currency text NOT NULL DEFAULT 'INR' CHECK (currency ~ '^[A-Z]{3}$'),
  status text NOT NULL CHECK (status IN ('created','pending','success','failed','expired','cancelled')),
  provider_order_id text,
  provider_payment_id text,
  order_payment_id uuid REFERENCES public.order_payments(id),
  facts_snapshot jsonb NOT NULL,
  expires_at timestamptz NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_role text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX IF NOT EXISTS payment_gateway_payable_intents_order_idx
  ON public.payment_gateway_payable_intents(order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS payment_gateway_payable_intents_provider_order_idx
  ON public.payment_gateway_payable_intents(provider_code, provider_order_id)
  WHERE provider_order_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.payment_gateway_provider_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  intent_id uuid NOT NULL REFERENCES public.payment_gateway_payable_intents(id),
  event_type text NOT NULL CHECK (event_type IN ('order_created','payment_pending','payment_success','payment_failed','payment_expired','refund')),
  provider_event_id text NOT NULL,
  provider_payment_id text,
  provider_amount numeric(14,2),
  provider_currency text,
  payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  payload jsonb NOT NULL,
  signature_valid boolean NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  received_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (intent_id, provider_event_id)
);

CREATE TABLE IF NOT EXISTS public.payment_gateway_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL,
  request_fingerprint text NOT NULL,
  intent_id uuid REFERENCES public.payment_gateway_payable_intents(id),
  provider_event_id uuid REFERENCES public.payment_gateway_provider_events(id),
  actor_id uuid REFERENCES auth.users(id),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

ALTER TABLE public.payment_gateway_payable_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_gateway_provider_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_gateway_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.payment_gateway_payable_intents,
  public.payment_gateway_provider_events,
  public.payment_gateway_idempotency
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.payment_gateway_payable_intents,
  public.payment_gateway_provider_events
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_payment_gateway_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'PAYMENT_GATEWAY_APPEND_ONLY' USING ERRCODE = '42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_payment_gateway_provider_events_immutable ON public.payment_gateway_provider_events;
CREATE TRIGGER trg_payment_gateway_provider_events_immutable
  BEFORE UPDATE OR DELETE ON public.payment_gateway_provider_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_payment_gateway_mutation();
REVOKE ALL ON FUNCTION public.prevent_payment_gateway_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.derive_payment_gateway_canonical_amount_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_payment_purpose text
) RETURNS TABLE(canonical_amount numeric, currency text, facts_snapshot jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_purpose text := lower(btrim(coalesce(p_payment_purpose, '')));
  v_facts jsonb;
  v_amount numeric;
  v_coverage jsonb;
  v_request public.sales_order_pi_final_payment_requests%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_payment jsonb;
  v_value numeric;
  v_required numeric;
  v_verified numeric;
  v_wallet numeric;
  v_credit numeric;
  v_covered numeric;
BEGIN
  PERFORM public.assert_order_payment_binding_v1(p_order_id, p_pi_id, p_commercial_version_id);
  IF v_purpose = 'advance' THEN
    SELECT * INTO v_pi FROM public.sales_order_proforma_invoices
     WHERE id = p_pi_id AND order_id = p_order_id AND commercial_version_id = p_commercial_version_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_PI_REQUIRED' USING ERRCODE = 'P0001'; END IF;
    SELECT * INTO v_version FROM public.sales_order_commercial_versions
     WHERE id = p_commercial_version_id AND order_id = p_order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_COMMERCIAL_VERSION_REQUIRED' USING ERRCODE = 'P0001'; END IF;
    v_value := v_version.sales_order_value;
    v_required := v_version.advance_required;
    IF v_value IS NULL OR v_value < 0 OR v_required IS NULL OR v_required < 0
       OR (v_value > 0 AND v_required <= 0)
       OR v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
       OR (v_pi.frozen_commercial_snapshot ->> 'advance_required')::numeric IS DISTINCT FROM v_required THEN
      RAISE EXCEPTION 'PAYMENT_GATEWAY_COMMERCIAL_TRUTH_INCOMPLETE' USING ERRCODE = 'P0001';
    END IF;
    v_payment := public.get_order_payment_facts_v1(p_pi_id);
    v_verified := coalesce((v_payment ->> 'verified_total')::numeric, 0);
    SELECT coalesce(sum(w.amount), 0) INTO v_wallet
      FROM public.wallet_transactions w
     WHERE w.order_id = p_order_id AND w.proforma_invoice_id = p_pi_id
       AND w.commercial_version_id = p_commercial_version_id AND w.direction = 'debit';
    SELECT coalesce(sum(c.requested_amount), 0) INTO v_credit
      FROM public.credit_requests c
     WHERE c.order_id = p_order_id AND c.proforma_invoice_id = p_pi_id
       AND c.commercial_version_id = p_commercial_version_id AND c.status = 'approved'
       AND (c.expires_at IS NULL OR c.expires_at > statement_timestamp());
    v_covered := v_verified + v_wallet + v_credit;
    v_amount := greatest(0, round(v_required - v_covered, 2));
    v_facts := jsonb_build_object(
      'required_advance', v_required, 'covered_amount', v_covered,
      'verified_payment_amount', v_verified, 'wallet_applied_amount', v_wallet,
      'approved_credit_amount', v_credit, 'payment_facts', v_payment
    );
  ELSIF v_purpose = 'balance' THEN
    v_facts := public.get_credit_exposure_facts_v1(
      (SELECT company_id FROM public.orders WHERE id = p_order_id),
      p_pi_id, p_commercial_version_id);
    v_amount := greatest(0, round(
      coalesce((v_facts ->> 'commercial_value')::numeric, 0)
      - coalesce((v_facts ->> 'verified_payment_total')::numeric, 0), 2));
  ELSIF v_purpose = 'final_payment' THEN
    SELECT * INTO v_request
      FROM public.sales_order_pi_final_payment_requests r
     WHERE r.order_id = p_order_id
       AND r.proforma_invoice_id = p_pi_id
       AND r.commercial_version_id = p_commercial_version_id
     ORDER BY r.revision_number DESC, r.created_at DESC
     LIMIT 1;
    IF FOUND THEN
      v_amount := v_request.balance_due_at_issue;
      v_facts := jsonb_build_object('final_payment_request_id', v_request.id, 'revision_number', v_request.revision_number,
        'balance_due_at_issue', v_request.balance_due_at_issue);
    ELSE
      SELECT * INTO v_invoice FROM public.final_invoices f
       WHERE f.order_id = p_order_id AND f.status = 'ISSUED'
       ORDER BY f.created_at DESC LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_FINAL_INVOICE_REQUIRED' USING ERRCODE = 'P0001'; END IF;
      v_coverage := public.get_final_settlement_facts_v1(v_invoice.id);
      v_amount := coalesce((v_coverage ->> 'net_due')::numeric, 0);
      v_facts := v_coverage;
    END IF;
  ELSE
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PURPOSE_INVALID' USING ERRCODE = 'P0001';
  END IF;
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_NO_PAYABLE_BALANCE' USING ERRCODE = '55000';
  END IF;
  RETURN QUERY SELECT v_amount, 'INR'::text, coalesce(v_facts, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text) FROM PUBLIC, anon, service_role;

CREATE OR REPLACE FUNCTION public.create_payment_gateway_payable_intent_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_payment_purpose text,
  p_provider_code text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(intent_id uuid, canonical_amount numeric, currency text, status text, already_created boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_purpose text := lower(btrim(coalesce(p_payment_purpose, '')));
  v_provider text := lower(btrim(coalesce(p_provider_code, '')));
  v_existing public.payment_gateway_idempotency%rowtype;
  v_intent public.payment_gateway_payable_intents%rowtype;
  v_derived record;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF NOT public.is_internal_staff(v_actor)
     AND v_order.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF v_purpose NOT IN ('advance','balance','final_payment')
     OR v_provider NOT IN ('razorpay','payu','cashfree','stripe','generic')
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_INTENT_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_role := coalesce(public.get_user_role(v_actor), CASE WHEN public.is_internal_staff(v_actor) THEN 'unknown' ELSE 'b2b_buyer' END);
  SELECT * INTO v_derived FROM public.derive_payment_gateway_canonical_amount_v1(
    p_order_id, p_pi_id, p_commercial_version_id, v_purpose);
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'order_id', p_order_id, 'pi_id', p_pi_id, 'commercial_version_id', p_commercial_version_id,
    'payment_purpose', v_purpose, 'provider_code', v_provider, 'canonical_amount', v_derived.canonical_amount,
    'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.payment_gateway_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'PAYMENT_GATEWAY_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT
      (v_existing.response ->> 'intent_id')::uuid,
      (v_existing.response ->> 'canonical_amount')::numeric,
      v_existing.response ->> 'currency',
      v_existing.response ->> 'status',
      true;
    RETURN;
  END IF;
  INSERT INTO public.payment_gateway_payable_intents(
    order_id, company_id, proforma_invoice_id, commercial_version_id, payment_purpose, provider_code,
    canonical_amount, currency, status, facts_snapshot, expires_at, correlation_id, idempotency_key,
    created_by, created_role
  ) VALUES (
    p_order_id, v_order.company_id, p_pi_id, p_commercial_version_id, v_purpose, v_provider,
    v_derived.canonical_amount, v_derived.currency, 'created', v_derived.facts_snapshot,
    statement_timestamp() + interval '30 minutes', btrim(p_correlation_id), btrim(p_idempotency_key),
    v_actor, v_role
  ) RETURNING * INTO v_intent;
  v_response := jsonb_build_object(
    'intent_id', v_intent.id, 'canonical_amount', v_intent.canonical_amount,
    'currency', v_intent.currency, 'status', v_intent.status
  );
  INSERT INTO public.payment_gateway_idempotency(idempotency_key, operation, request_fingerprint, intent_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'CREATE_INTENT', v_fingerprint, v_intent.id, v_actor, v_response);
  RETURN QUERY SELECT v_intent.id, v_intent.canonical_amount, v_intent.currency, v_intent.status, false;
END;
$$;
REVOKE ALL ON FUNCTION public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_payment_gateway_payable_status_v1(p_intent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_intent public.payment_gateway_payable_intents%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_STATUS_AUTH_REQUIRED' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_intent FROM public.payment_gateway_payable_intents WHERE id = p_intent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_INTENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF NOT public.is_internal_staff(auth.uid())
     AND v_intent.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'intent_id', v_intent.id, 'order_id', v_intent.order_id, 'payment_purpose', v_intent.payment_purpose,
    'provider_code', v_intent.provider_code, 'canonical_amount', v_intent.canonical_amount,
    'currency', v_intent.currency, 'status', v_intent.status, 'provider_order_id', v_intent.provider_order_id,
    'provider_payment_id', v_intent.provider_payment_id, 'order_payment_id', v_intent.order_payment_id,
    'expires_at', v_intent.expires_at, 'facts_as_of', statement_timestamp(), 'buyer_status_only', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_payment_gateway_payable_status_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_payment_gateway_payable_status_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_payment_gateway_provider_event_v1(
  p_intent_id uuid,
  p_event_type text,
  p_provider_event_id text,
  p_provider_payment_id text,
  p_provider_amount numeric,
  p_provider_currency text,
  p_payload jsonb,
  p_payload_hash text,
  p_signature_valid boolean,
  p_correlation_id text,
  p_idempotency_key text,
  p_provider_order_id text DEFAULT NULL
) RETURNS TABLE(provider_event_id uuid, already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_intent public.payment_gateway_payable_intents%rowtype;
  v_type text := lower(btrim(coalesce(p_event_type, '')));
  v_existing public.payment_gateway_provider_events%rowtype;
  v_event public.payment_gateway_provider_events%rowtype;
  v_hash text;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_EVENT_SERVICE_ONLY' USING ERRCODE = '42501';
  END IF;
  IF v_type NOT IN ('order_created','payment_pending','payment_success','payment_failed','payment_expired','refund')
     OR nullif(btrim(p_provider_event_id), '') IS NULL
     OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_EVENT_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF NOT coalesce(p_signature_valid, false) THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_SIGNATURE_INVALID' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_intent FROM public.payment_gateway_payable_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_GATEWAY_INTENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  v_hash := encode(extensions.digest(p_payload::text, 'sha256'), 'hex');
  IF v_hash IS DISTINCT FROM btrim(p_payload_hash) THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PAYLOAD_HASH_MISMATCH' USING ERRCODE = '40001';
  END IF;
  SELECT * INTO v_existing FROM public.payment_gateway_provider_events WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.intent_id IS DISTINCT FROM p_intent_id
       OR v_existing.provider_event_id IS DISTINCT FROM btrim(p_provider_event_id) THEN
      RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.id, true;
    RETURN;
  END IF;
  IF p_provider_amount IS NOT NULL
     AND abs(p_provider_amount - v_intent.canonical_amount) > 0.01 THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_AMOUNT_BINDING_MISMATCH' USING ERRCODE = '40001';
  END IF;
  IF p_provider_currency IS NOT NULL
     AND upper(btrim(p_provider_currency)) IS DISTINCT FROM v_intent.currency THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_CURRENCY_BINDING_MISMATCH' USING ERRCODE = '40001';
  END IF;
  INSERT INTO public.payment_gateway_provider_events(
    intent_id, event_type, provider_event_id, provider_payment_id, provider_amount, provider_currency,
    payload_hash, payload, signature_valid, correlation_id, idempotency_key
  ) VALUES (
    p_intent_id, v_type, btrim(p_provider_event_id), nullif(btrim(p_provider_payment_id), ''),
    p_provider_amount, nullif(upper(btrim(p_provider_currency)), ''), btrim(p_payload_hash), p_payload,
    true, btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  IF v_type = 'order_created' THEN
    UPDATE public.payment_gateway_payable_intents
       SET status = 'pending',
           provider_order_id = coalesce(nullif(btrim(p_provider_order_id), ''), provider_order_id)
     WHERE id = p_intent_id AND status = 'created';
  ELSIF v_type IN ('payment_failed','payment_expired') THEN
    UPDATE public.payment_gateway_payable_intents SET status = CASE v_type WHEN 'payment_failed' THEN 'failed' ELSE 'expired' END
     WHERE id = p_intent_id AND status IN ('created','pending');
  END IF;
  RETURN QUERY SELECT v_event.id, false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_payment_gateway_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,boolean,text,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.settle_payment_gateway_intent_v1(
  p_intent_id uuid,
  p_provider_event_id uuid,
  p_correlation_id text,
  p_idempotency_key text
) RETURNS TABLE(intent_id uuid, order_payment_id uuid, status text, already_settled boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_intent public.payment_gateway_payable_intents%rowtype;
  v_event public.payment_gateway_provider_events%rowtype;
  v_existing public.payment_gateway_idempotency%rowtype;
  v_payment public.order_payments%rowtype;
  v_scope uuid;
  v_payment_type text;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_SETTLE_SERVICE_ONLY' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_SETTLE_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_intent FROM public.payment_gateway_payable_intents WHERE id = p_intent_id FOR UPDATE;
  SELECT * INTO v_event FROM public.payment_gateway_provider_events WHERE id = p_provider_event_id FOR UPDATE;
  IF NOT FOUND OR v_event.intent_id IS DISTINCT FROM p_intent_id THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_PROVIDER_EVENT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_event.event_type <> 'payment_success' OR NOT v_event.signature_valid THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_SETTLE_REQUIRES_SUCCESS_EVENT' USING ERRCODE = '55000';
  END IF;
  IF v_intent.status = 'success' AND v_intent.order_payment_id IS NOT NULL THEN
    RETURN QUERY SELECT v_intent.id, v_intent.order_payment_id, 'success'::text, true;
    RETURN;
  END IF;
  IF v_intent.expires_at <= statement_timestamp() AND v_intent.status NOT IN ('success') THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_INTENT_EXPIRED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'intent_id', p_intent_id, 'provider_event_id', p_provider_event_id, 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.payment_gateway_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'PAYMENT_GATEWAY_SETTLE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT
      (v_existing.response ->> 'intent_id')::uuid,
      (v_existing.response ->> 'order_payment_id')::uuid,
      v_existing.response ->> 'status',
      true;
    RETURN;
  END IF;
  v_payment_type := CASE v_intent.payment_purpose
    WHEN 'advance' THEN 'advance'
    WHEN 'final_payment' THEN 'balance'
    ELSE 'balance'
  END;
  PERFORM pg_advisory_xact_lock(hashtextextended('payment-gateway-settle:' || p_intent_id::text, 0));
  INSERT INTO public.order_payment_authority_scopes(backend_pid, transaction_id, operation, actor_id)
  VALUES (pg_backend_pid(), txid_current(), 'RECEIVE', v_intent.created_by)
  RETURNING scope_id INTO v_scope;
  INSERT INTO public.order_payments(
    order_id, company_id, payment_type, amount, reference_no, created_by, status,
    proforma_invoice_id, commercial_version_id, source_channel, source_reference, currency,
    payment_mode, payer_reference, proof_evidence_reference, proof_received_at, proof_received_by,
    correlation_id, idempotency_key
  ) VALUES (
    v_intent.order_id, v_intent.company_id, v_payment_type, v_intent.canonical_amount,
    coalesce(nullif(btrim(v_event.provider_payment_id), ''), 'gateway:' || v_event.provider_event_id),
    v_intent.created_by, 'uploaded', v_intent.proforma_invoice_id, v_intent.commercial_version_id,
    'PAYMENT_GATEWAY', 'gateway-intent:' || v_intent.id::text, v_intent.currency, v_intent.provider_code,
    NULL, 'gateway-event:' || v_event.id::text, statement_timestamp(), v_intent.created_by,
    btrim(p_correlation_id), btrim(p_idempotency_key) || ':payment'
  ) RETURNING * INTO v_payment;
  UPDATE public.order_payment_authority_scopes SET payment_id = v_payment.id WHERE scope_id = v_scope;
  INSERT INTO public.order_payment_authority_audit(
    payment_id, order_id, proforma_invoice_id, commercial_version_id, action,
    prior_status, new_status, submitted_amount, currency, actor_id, actor_role,
    source_channel, source_reference, correlation_id, idempotency_key, metadata
  ) VALUES (
    v_payment.id, v_intent.order_id, v_intent.proforma_invoice_id, v_intent.commercial_version_id,
    'RECEIVED', NULL, 'uploaded', v_payment.amount, v_payment.currency, v_intent.created_by,
    v_intent.created_role, 'PAYMENT_GATEWAY', 'gateway-intent:' || v_intent.id::text,
    btrim(p_correlation_id), btrim(p_idempotency_key) || ':payment',
    jsonb_build_object('gateway_intent_id', v_intent.id, 'gateway_event_id', v_event.id,
      'provider_code', v_intent.provider_code, 'verification_required', true)
  );
  DELETE FROM public.order_payment_authority_scopes WHERE scope_id = v_scope;
  UPDATE public.payment_gateway_payable_intents
     SET status = 'success', order_payment_id = v_payment.id,
         provider_payment_id = coalesce(nullif(btrim(v_event.provider_payment_id), ''), provider_payment_id)
   WHERE id = p_intent_id;
  v_response := jsonb_build_object('intent_id', p_intent_id, 'order_payment_id', v_payment.id, 'status', 'success');
  INSERT INTO public.payment_gateway_idempotency(idempotency_key, operation, request_fingerprint, intent_id, provider_event_id, response)
  VALUES (btrim(p_idempotency_key), 'SETTLE', v_fingerprint, p_intent_id, p_provider_event_id, v_response);
  RETURN QUERY SELECT p_intent_id, v_payment.id, 'success'::text, false;
END;
$$;
REVOKE ALL ON FUNCTION public.settle_payment_gateway_intent_v1(uuid,uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_payment_gateway_intent_v1(uuid,uuid,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.get_payment_gateway_finance_facts_v1(p_intent_id uuid DEFAULT NULL, p_order_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'PAYMENT_GATEWAY_FINANCE_FACTS_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'intents', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'intent_id', i.id, 'order_id', i.order_id, 'company_id', i.company_id,
        'payment_purpose', i.payment_purpose, 'provider_code', i.provider_code,
        'canonical_amount', i.canonical_amount, 'status', i.status,
        'order_payment_id', i.order_payment_id, 'provider_payment_id', i.provider_payment_id,
        'created_at', i.created_at, 'expires_at', i.expires_at
      ) ORDER BY i.created_at DESC)
      FROM public.payment_gateway_payable_intents i
     WHERE (p_intent_id IS NULL OR i.id = p_intent_id)
       AND (p_order_id IS NULL OR i.order_id = p_order_id)
    ), '[]'::jsonb),
    'facts_as_of', statement_timestamp(),
    'gateway_facts_only', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_payment_gateway_finance_facts_v1(uuid,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_payment_gateway_finance_facts_v1(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_finance_dispatch_clearance_facts_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_clear public.finance_dispatch_clearance_authority_v1%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_settlement jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_FACTS_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_clear FROM public.finance_dispatch_clearance_authority_v1 WHERE order_id = p_order_id;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id = p_order_id AND status = 'ISSUED'
   ORDER BY created_at DESC LIMIT 1;
  IF v_invoice.id IS NOT NULL THEN
    v_settlement := public.get_final_settlement_facts_v1(v_invoice.id);
  END IF;
  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'dispatch_clearance', CASE WHEN v_clear.order_id IS NULL THEN NULL ELSE to_jsonb(v_clear) END,
    'final_invoice_id', v_invoice.id,
    'settlement_facts', v_settlement,
    'blocking_finance_hold', EXISTS (
      SELECT 1 FROM public.finance_control_authority_v1 f
      JOIN public.orders o ON o.id = p_order_id
       WHERE f.active_blocking_hold
         AND (
           (f.scope = 'DISPATCH' AND (f.order_id IS NULL OR f.order_id = p_order_id))
           OR (f.scope = 'ORDER' AND f.order_id = p_order_id)
           OR (f.scope = 'COMPANY' AND f.company_id = o.company_id)
         )
    ),
    'facts_as_of', statement_timestamp(),
    'dispatch_clearance_facts_only', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_finance_dispatch_clearance_facts_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_finance_dispatch_clearance_facts_v1(uuid) TO authenticated;

COMMENT ON TABLE public.payment_gateway_payable_intents IS 'A1 canonical payable intents. Amounts are server-derived; Edge/provider adapters bind webhooks here.';
COMMENT ON TABLE public.payment_gateway_provider_events IS 'A1 immutable provider webhook/event evidence. Signature must be validated before insert.';
COMMENT ON FUNCTION public.settle_payment_gateway_intent_v1(uuid,uuid,text,text) IS 'Maps verified gateway success into canonical order_payments as uploaded proof; Finance verify remains separate.';
