-- PF-6C hardening: decision retries must replay the recorded decision before
-- re-evaluating mutable funding/state facts. Request fingerprints therefore bind
-- only caller-supplied decision inputs; the immutable facts snapshot is stored on
-- the resulting clearance event, not used as retry identity.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

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

  v_operation := CASE v_decision
    WHEN 'GRANTED' THEN 'GRANT_OPERATIONS'
    WHEN 'DENIED' THEN 'DENY_OPERATIONS'
    ELSE 'REVOKE_OPERATIONS'
  END;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'operation',v_operation,
    'order_id',p_order_id,
    'pi_id',p_pi_id,
    'commercial_version_id',p_commercial_version_id,
    'reason',btrim(p_reason),
    'evidence_reference',btrim(p_evidence_reference),
    'source_channel',upper(btrim(p_source_channel)),
    'source_reference',coalesce(nullif(btrim(p_source_reference),''),''),
    'correlation_id',btrim(p_correlation_id)
  )::text,'sha256'),'hex');

  PERFORM pg_advisory_xact_lock(hashtextextended('finance-operations-clearance:' || p_order_id::text, 0));

  -- Retry replay must happen before any mutable funding or latest-state check.
  SELECT * INTO v_existing FROM public.finance_clearance_idempotency
   WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_CLEARANCE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.clearance_event_id,
      (v_existing.response->>'decision')::text, true;
    RETURN;
  END IF;

  v_facts := public.get_finance_operations_clearance_facts_v1(
    p_order_id, p_pi_id, p_commercial_version_id
  );
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.company_id::text IS DISTINCT FROM (v_facts ->> 'company_id') THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_COMPANY_BINDING_MISMATCH' USING ERRCODE = '40001';
  END IF;

  SELECT * INTO v_latest FROM public.finance_clearance_events e
   WHERE e.order_id=p_order_id AND e.clearance_type='OPERATIONS'
   ORDER BY e.created_at DESC, e.id DESC LIMIT 1;

  IF v_decision = 'GRANTED'
     AND coalesce((v_facts ->> 'eligible_for_operations_clearance')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_NOT_FUNDED' USING ERRCODE = '55000';
  END IF;
  IF v_decision = 'REVOKED'
     AND (v_latest.id IS NULL OR v_latest.decision <> 'GRANTED') THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_NOT_ACTIVE' USING ERRCODE = '55000';
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
    'clearance_event_id',v_event.id,
    'decision',v_event.decision,
    'clearance_type','OPERATIONS',
    'order_id',p_order_id,
    'operations_release_mutated',false,
    'dispatch_release_mutated',false
  );
  INSERT INTO public.finance_clearance_idempotency(
    idempotency_key,operation,request_fingerprint,clearance_event_id,actor_id,response
  ) VALUES (
    btrim(p_idempotency_key),v_operation,v_fingerprint,v_event.id,v_actor,v_response
  );

  RETURN QUERY SELECT v_event.id,v_event.decision,false;
END;
$$;

REVOKE ALL ON FUNCTION public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)
  TO authenticated;

COMMENT ON FUNCTION public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid) IS
  'PF-6C Finance Operations Clearance decision. Actor-bound idempotent retries replay before mutable funding/state validation; recorded events retain the exact facts snapshot used for the original decision.';
