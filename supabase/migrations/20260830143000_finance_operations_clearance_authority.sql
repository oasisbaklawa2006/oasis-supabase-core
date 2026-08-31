-- PF-6C: canonical Finance Operations Clearance authority.
--
-- Payment verification, wallet/credit facts, and Finance clearance are distinct
-- authorities.  This migration creates an append-only Finance decision record;
-- it does not mutate order status, manufacturing state, dispatch state, DPL,
-- invoice, carton, or gate truth.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.finance_clearance_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  proforma_invoice_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id),
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id),
  clearance_type text NOT NULL CHECK (clearance_type IN ('OPERATIONS')),
  decision text NOT NULL CHECK (decision IN ('GRANTED','DENIED','REVOKED')),
  commercial_value numeric NOT NULL CHECK (commercial_value >= 0),
  required_advance numeric NOT NULL CHECK (required_advance >= 0),
  verified_payment_amount numeric NOT NULL CHECK (verified_payment_amount >= 0),
  wallet_applied_amount numeric NOT NULL CHECK (wallet_applied_amount >= 0),
  approved_credit_amount numeric NOT NULL CHECK (approved_credit_amount >= 0),
  covered_amount numeric NOT NULL CHECK (covered_amount >= 0),
  reason text NOT NULL,
  evidence_reference text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  source_channel text NOT NULL,
  source_reference text,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  facts_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS finance_clearance_events_order_idx
  ON public.finance_clearance_events(order_id, clearance_type, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS finance_clearance_events_pi_idx
  ON public.finance_clearance_events(proforma_invoice_id, commercial_version_id, created_at DESC);

ALTER TABLE public.finance_clearance_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.finance_clearance_events FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.finance_clearance_events TO authenticated, service_role;
DROP POLICY IF EXISTS finance_clearance_internal_read ON public.finance_clearance_events;
CREATE POLICY finance_clearance_internal_read
  ON public.finance_clearance_events FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE TABLE IF NOT EXISTS public.finance_clearance_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('GRANT_OPERATIONS','DENY_OPERATIONS','REVOKE_OPERATIONS')),
  request_fingerprint text NOT NULL,
  clearance_event_id uuid NOT NULL REFERENCES public.finance_clearance_events(id),
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.finance_clearance_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.finance_clearance_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_finance_clearance_event_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'FINANCE_CLEARANCE_EVENTS_APPEND_ONLY' USING ERRCODE = '42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_finance_clearance_events_immutable ON public.finance_clearance_events;
CREATE TRIGGER trg_finance_clearance_events_immutable
  BEFORE UPDATE OR DELETE ON public.finance_clearance_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_finance_clearance_event_mutation();
REVOKE ALL ON FUNCTION public.prevent_finance_clearance_event_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assert_finance_clearance_actor_v1(p_actor_id uuid DEFAULT auth.uid())
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid := coalesce(p_actor_id, auth.uid()); v_role text;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_order_transition_role('finance_review');
  IF NOT public.has_step_up_auth() THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_AAL2_REQUIRED' USING ERRCODE = '42501';
  END IF;
  v_role := coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN');
  RETURN v_role;
END;
$$;
REVOKE ALL ON FUNCTION public.assert_finance_clearance_actor_v1(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_finance_operations_clearance_facts_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_payment jsonb;
  v_value numeric;
  v_required numeric;
  v_verified numeric;
  v_wallet_applied numeric;
  v_credit numeric;
  v_covered numeric;
  v_latest_decision text;
  v_latest_event uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_FACTS_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_order_payment_binding_v1(p_order_id, p_pi_id, p_commercial_version_id);
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices
   WHERE id = p_pi_id AND order_id = p_order_id AND commercial_version_id = p_commercial_version_id;
  IF NOT FOUND OR v_order.company_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_BINDING_INCOMPLETE' USING ERRCODE = '40001';
  END IF;

  v_value := (v_pi.frozen_commercial_snapshot ->> 'sales_order_value')::numeric;
  IF v_value IS NULL OR v_value < 0
     OR md5(v_pi.frozen_commercial_snapshot::text) IS DISTINCT FROM v_pi.frozen_snapshot_fingerprint THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_COMMERCIAL_TRUTH_INCOMPLETE' USING ERRCODE = '40001';
  END IF;

  -- Canonical business policy: 30% of frozen SO value, rounded to nearest INR 500.
  v_required := greatest(0, round((v_value * 0.30) / 500) * 500);
  v_payment := public.get_order_payment_facts_v1(p_pi_id);
  v_verified := coalesce((v_payment ->> 'verified_total')::numeric, 0);

  -- Wallet contributes only when a governed debit has actually been applied to
  -- this exact SO/PI/commercial version. Mere available wallet balance is not clearance.
  SELECT coalesce(sum(w.amount), 0) INTO v_wallet_applied
    FROM public.wallet_transactions w
   WHERE w.order_id = p_order_id
     AND w.proforma_invoice_id = p_pi_id
     AND w.commercial_version_id = p_commercial_version_id
     AND w.direction = 'debit';

  -- Only approved, unexpired credit bound to this exact commercial obligation counts.
  SELECT coalesce(sum(c.requested_amount), 0) INTO v_credit
    FROM public.credit_requests c
   WHERE c.order_id = p_order_id
     AND c.proforma_invoice_id = p_pi_id
     AND c.commercial_version_id = p_commercial_version_id
     AND c.status = 'approved'
     AND (c.expires_at IS NULL OR c.expires_at > statement_timestamp());

  v_covered := v_verified + v_wallet_applied + v_credit;

  SELECT e.id, e.decision INTO v_latest_event, v_latest_decision
    FROM public.finance_clearance_events e
   WHERE e.order_id = p_order_id AND e.clearance_type = 'OPERATIONS'
   ORDER BY e.created_at DESC, e.id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'company_id', v_order.company_id,
    'pi_id', p_pi_id,
    'commercial_version_id', p_commercial_version_id,
    'commercial_value', v_value,
    'advance_policy_percent', 30,
    'advance_rounding_increment', 500,
    'required_advance', v_required,
    'verified_payment_amount', v_verified,
    'wallet_applied_amount', v_wallet_applied,
    'approved_credit_amount', v_credit,
    'covered_amount', v_covered,
    'eligible_for_operations_clearance', (v_covered >= v_required),
    'latest_clearance_event_id', v_latest_event,
    'latest_clearance_decision', v_latest_decision,
    'payment_facts', v_payment,
    'facts_as_of', statement_timestamp(),
    'payment_verified_is_not_clearance', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.decide_finance_operations_clearance_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_decision text,
  p_reason text,
  p_evidence_reference text,
  p_source_channel text,
  p_source_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(clearance_event_id uuid, decision text, already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_decision text := upper(nullif(btrim(p_decision), ''));
  v_facts jsonb;
  v_order public.orders%rowtype;
  v_existing public.finance_clearance_idempotency%rowtype;
  v_fingerprint text;
  v_latest public.finance_clearance_events%rowtype;
  v_event public.finance_clearance_events%rowtype;
  v_operation text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF v_decision NOT IN ('GRANTED','DENIED','REVOKED')
     OR length(btrim(coalesce(p_reason,''))) < 5
     OR nullif(btrim(p_evidence_reference),'') IS NULL
     OR nullif(btrim(p_source_channel),'') IS NULL
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_DECISION_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('finance-operations-clearance:' || p_order_id::text, 0));
  v_facts := public.get_finance_operations_clearance_facts_v1(p_order_id, p_pi_id, p_commercial_version_id);
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.company_id::text IS DISTINCT FROM (v_facts ->> 'company_id') THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_COMPANY_BINDING_MISMATCH' USING ERRCODE = '40001';
  END IF;

  SELECT * INTO v_latest FROM public.finance_clearance_events e
   WHERE e.order_id=p_order_id AND e.clearance_type='OPERATIONS'
   ORDER BY e.created_at DESC, e.id DESC LIMIT 1;

  IF v_decision = 'GRANTED' AND coalesce((v_facts ->> 'eligible_for_operations_clearance')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_NOT_FUNDED' USING ERRCODE = '55000';
  END IF;
  IF v_decision = 'REVOKED' AND (NOT FOUND OR v_latest.decision <> 'GRANTED') THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_NOT_ACTIVE' USING ERRCODE = '55000';
  END IF;

  v_operation := CASE v_decision WHEN 'GRANTED' THEN 'GRANT_OPERATIONS' WHEN 'DENIED' THEN 'DENY_OPERATIONS' ELSE 'REVOKE_OPERATIONS' END;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'operation',v_operation,'order_id',p_order_id,'pi_id',p_pi_id,
    'commercial_version_id',p_commercial_version_id,'reason',btrim(p_reason),
    'evidence_reference',btrim(p_evidence_reference),'source_channel',upper(btrim(p_source_channel)),
    'source_reference',coalesce(nullif(btrim(p_source_reference),''),''),
    'correlation_id',btrim(p_correlation_id),'facts',v_facts - 'facts_as_of'
  )::text,'sha256'),'hex');

  SELECT * INTO v_existing FROM public.finance_clearance_idempotency
   WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_CLEARANCE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.clearance_event_id, (v_existing.response->>'decision')::text, true;
    RETURN;
  END IF;

  INSERT INTO public.finance_clearance_events(
    order_id,company_id,proforma_invoice_id,commercial_version_id,clearance_type,decision,
    commercial_value,required_advance,verified_payment_amount,wallet_applied_amount,
    approved_credit_amount,covered_amount,reason,evidence_reference,actor_id,actor_role,
    source_channel,source_reference,correlation_id,idempotency_key,facts_snapshot
  ) VALUES (
    p_order_id,v_order.company_id,p_pi_id,p_commercial_version_id,'OPERATIONS',v_decision,
    (v_facts->>'commercial_value')::numeric,(v_facts->>'required_advance')::numeric,
    (v_facts->>'verified_payment_amount')::numeric,(v_facts->>'wallet_applied_amount')::numeric,
    (v_facts->>'approved_credit_amount')::numeric,(v_facts->>'covered_amount')::numeric,
    btrim(p_reason),btrim(p_evidence_reference),v_actor,v_role,upper(btrim(p_source_channel)),
    nullif(btrim(p_source_reference),''),btrim(p_correlation_id),btrim(p_idempotency_key),v_facts
  ) RETURNING * INTO v_event;

  v_response := jsonb_build_object(
    'clearance_event_id',v_event.id,'decision',v_event.decision,'clearance_type','OPERATIONS',
    'order_id',p_order_id,'operations_release_mutated',false,'dispatch_release_mutated',false
  );
  INSERT INTO public.finance_clearance_idempotency(idempotency_key,operation,request_fingerprint,clearance_event_id,actor_id,response)
  VALUES (btrim(p_idempotency_key),v_operation,v_fingerprint,v_event.id,v_actor,v_response);

  RETURN QUERY SELECT v_event.id,v_event.decision,false;
END;
$$;
REVOKE ALL ON FUNCTION public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE VIEW public.finance_operations_clearance_authority_v1
WITH (security_invoker = true) AS
SELECT DISTINCT ON (e.order_id)
  e.order_id,
  e.company_id,
  e.proforma_invoice_id,
  e.commercial_version_id,
  e.id AS clearance_event_id,
  e.decision,
  (e.decision = 'GRANTED') AS operations_cleared,
  e.required_advance,
  e.covered_amount,
  e.actor_id,
  e.actor_role,
  e.created_at
FROM public.finance_clearance_events e
WHERE e.clearance_type='OPERATIONS'
ORDER BY e.order_id,e.created_at DESC,e.id DESC;
REVOKE ALL ON public.finance_operations_clearance_authority_v1 FROM PUBLIC, anon;
GRANT SELECT ON public.finance_operations_clearance_authority_v1 TO authenticated, service_role;

COMMENT ON TABLE public.finance_clearance_events IS 'PF-6C append-only Finance clearance decisions. Payment verification is evidence only and never implies clearance.';
COMMENT ON FUNCTION public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid) IS 'PF-6C facts for Finance Operations Clearance using frozen PI, verified payments, applied wallet debits and approved bound credit.';
COMMENT ON FUNCTION public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid) IS 'PF-6C Finance+AAL2 decision authority for Operations Clearance. Does not mutate operational or dispatch state.';
