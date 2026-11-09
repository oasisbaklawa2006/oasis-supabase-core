-- Finance two-step reversal authority (additive, forward-only; ASM CP17 Task 1).
-- Preserves the stronger control Central expects: request -> independent second-person approval -> completion,
-- instead of mapping it onto the immediate reverse_finance_control_v1 (left untouched; nothing is removed).
--   * request_finance_reversal_v1   : Finance + AAL2 initiator; immutable reason, target event and financial snapshot.
--   * decide_finance_reversal_v1    : a DIFFERENT Finance + AAL2 actor approves or rejects (maker-checker).
--   * complete_finance_reversal_v1  : Finance + AAL2; requires an APPROVED decision and an unchanged financial
--                                     snapshot; writes the same REVERSAL event the existing neutralizer logic reads,
--                                     so hold/release/balance integrity needs no change.
-- All three are idempotent (finance_control_idempotency, actor + fingerprint conflict) and serialised per target event.
-- Only new control_kind values are added to the CHECK constraint (superset); existing rows are unaffected.
-- rollback-plan: drop the three functions and uq_finance_reversal_approval_once; restore the previous CHECK
-- (HOLD, RELEASE, REVERSAL, SECOND_APPROVAL) only if no REVERSAL_REQUEST/REVERSAL_APPROVAL rows exist. The
-- append-only events written by these functions are retained as audit evidence.

-- Replace only the named control-kind constraint. Do not drop other unrelated
-- CHECK constraints simply because their definitions reference control_kind.
ALTER TABLE public.finance_control_events
  DROP CONSTRAINT finance_control_events_control_kind_check;
ALTER TABLE public.finance_control_events
  ADD CONSTRAINT finance_control_events_control_kind_check
  CHECK (control_kind IN ('HOLD','RELEASE','REVERSAL','SECOND_APPROVAL','REVERSAL_REQUEST','REVERSAL_APPROVAL'));

CREATE UNIQUE INDEX IF NOT EXISTS uq_finance_reversal_approval_once
  ON public.finance_control_events(prior_event_id) WHERE control_kind = 'REVERSAL_APPROVAL';
-- Both old immediate and new two-step reversal writers must share this
-- database-level invariant, independent of their different advisory locks.
CREATE UNIQUE INDEX IF NOT EXISTS uq_finance_reversal_target_once
  ON public.finance_control_events(prior_event_id)
  WHERE control_kind = 'REVERSAL' AND decision = 'REVERSED';

CREATE OR REPLACE FUNCTION public.finance_reversal_snapshot_is_current_v1(p_request_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT (r.facts_snapshot->'order_sales_order_value') IS NOT DISTINCT FROM coalesce(to_jsonb(o.sales_order_value), 'null'::jsonb)
     AND (r.facts_snapshot->'order_advance_paid') IS NOT DISTINCT FROM coalesce(to_jsonb(o.advance_paid), 'null'::jsonb)
     AND (r.facts_snapshot->'order_payment_status') IS NOT DISTINCT FROM coalesce(to_jsonb(o.payment_status), 'null'::jsonb)
    FROM public.finance_control_events r
    LEFT JOIN public.orders o ON o.id = r.order_id
   WHERE r.id = p_request_event_id;
$$;
REVOKE ALL ON FUNCTION public.finance_reversal_snapshot_is_current_v1(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.request_finance_reversal_v1(
  p_event_id uuid,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(request_event_id uuid, decision text, already_requested boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_target public.finance_control_events%rowtype;
  v_order public.orders%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
  v_superseded_requests jsonb := '[]'::jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF p_event_id IS NULL OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('finance-reversal:' || p_event_id::text, 0));
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'operation', 'REQUEST_REVERSAL', 'event_id', p_event_id, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.operation IS DISTINCT FROM 'REQUEST_REVERSAL'
       OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'request_event_id')::uuid, 'PENDING'::text, true;
    RETURN;
  END IF;

  SELECT * INTO v_target FROM public.finance_control_events WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_CONTROL_EVENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF NOT ((v_target.control_kind = 'HOLD' AND v_target.decision = 'APPLIED')
       OR (v_target.control_kind = 'RELEASE' AND v_target.decision = 'RELEASED')) THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_TARGET_NOT_REVERSIBLE' USING ERRCODE = '55000';
  END IF;
  -- Match dispatch's canonical lock ordering (eligibility order, eligibility
  -- company, then order row) before ANY stale-approval/open-request checks.
  -- Keep the row locked through supersession aggregation and snapshot insert.
  IF v_target.scope IN ('ORDER','DISPATCH','COMPANY') THEN
    IF v_target.order_id IS NOT NULL THEN
      PERFORM public.lock_finance_dispatch_eligibility_v1(v_target.order_id);
    END IF;
    PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_target.company_id);
  END IF;
  IF v_target.order_id IS NOT NULL THEN
    PERFORM 1 FROM public.orders WHERE id = v_target.order_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_ORDER_NOT_FOUND' USING ERRCODE = '55000';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.finance_control_events c
              WHERE c.control_kind = 'REVERSAL' AND c.decision = 'REVERSED' AND c.prior_event_id = p_event_id) THEN
    RAISE EXCEPTION 'FINANCE_CONTROL_ALREADY_REVERSED' USING ERRCODE = '55000';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events r
     WHERE r.control_kind = 'REVERSAL_REQUEST' AND r.prior_event_id = p_event_id
       AND NOT EXISTS (SELECT 1 FROM public.finance_control_events a
                        WHERE a.control_kind = 'REVERSAL_APPROVAL' AND a.prior_event_id = r.id AND a.decision = 'REJECTED')
       AND NOT EXISTS (
         SELECT 1 FROM public.finance_control_events newer
          WHERE newer.control_kind = 'REVERSAL_REQUEST' AND newer.prior_event_id = p_event_id
            AND coalesce(newer.facts_snapshot->'supersedes_request_event_ids', '[]'::jsonb) ? r.id::text
       )
       AND NOT (EXISTS (SELECT 1 FROM public.finance_control_events a
                         WHERE a.control_kind = 'REVERSAL_APPROVAL' AND a.prior_event_id = r.id AND a.decision = 'APPROVED')
                AND NOT public.finance_reversal_snapshot_is_current_v1(r.id))
  ) THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_REQUEST_ALREADY_OPEN' USING ERRCODE = '55000';
  END IF;

  -- Every approved stale predecessor becomes irrevocably superseded in the
  -- new immutable event, even if the order later returns to its old values.
  SELECT coalesce(jsonb_agg(r.id::text), '[]'::jsonb) INTO v_superseded_requests
    FROM public.finance_control_events r
   WHERE r.control_kind = 'REVERSAL_REQUEST' AND r.prior_event_id = p_event_id
     AND EXISTS (SELECT 1 FROM public.finance_control_events a
                  WHERE a.control_kind = 'REVERSAL_APPROVAL' AND a.prior_event_id = r.id
                    AND a.decision = 'APPROVED')
     AND public.finance_reversal_snapshot_is_current_v1(r.id) IS FALSE;

  IF v_target.order_id IS NOT NULL THEN
    SELECT * INTO v_order FROM public.orders WHERE id = v_target.order_id;
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key, facts_snapshot
  ) VALUES (
    v_target.company_id, v_target.order_id, v_target.final_invoice_id, 'REVERSAL_REQUEST', v_target.scope, false,
    v_target.amount, p_event_id, 'PENDING', btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object(
      'target_event_id', v_target.id, 'supersedes_request_event_ids', v_superseded_requests,
      'target_kind', v_target.control_kind, 'target_decision', v_target.decision,
      'target_scope', v_target.scope, 'target_amount', v_target.amount, 'company_id', v_target.company_id,
      'order_id', v_target.order_id, 'final_invoice_id', v_target.final_invoice_id,
      'order_sales_order_value', v_order.sales_order_value, 'order_advance_paid', v_order.advance_paid,
      'order_payment_status', v_order.payment_status
    )
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('request_event_id', v_event.id, 'decision', 'PENDING');
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'REQUEST_REVERSAL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, 'PENDING'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_finance_reversal_v1(
  p_request_event_id uuid,
  p_approve boolean,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(approval_event_id uuid, decision text, already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_request public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_decision text := CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF p_request_event_id IS NULL OR p_approve IS NULL OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_request FROM public.finance_control_events WHERE id = p_request_event_id;
  IF NOT FOUND OR v_request.control_kind <> 'REVERSAL_REQUEST' THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('finance-reversal:' || v_request.prior_event_id::text, 0));
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'operation', 'DECIDE_REVERSAL', 'request_event_id', p_request_event_id, 'approve', p_approve, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.operation IS DISTINCT FROM 'DECIDE_REVERSAL'
       OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'approval_event_id')::uuid, v_existing.response->>'decision', true;
    RETURN;
  END IF;
  IF v_request.actor_id = v_actor THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_MAKER_CHECKER' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.finance_control_events a
              WHERE a.control_kind = 'REVERSAL_APPROVAL' AND a.prior_event_id = p_request_event_id) THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_ALREADY_DECIDED' USING ERRCODE = '55000';
  END IF;
  -- Same convention as SECOND_APPROVAL: actor_* stays the maker, approver_id is the checker.
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, approver_id, correlation_id, idempotency_key, facts_snapshot
  ) VALUES (
    v_request.company_id, v_request.order_id, v_request.final_invoice_id, 'REVERSAL_APPROVAL', v_request.scope, false,
    v_request.amount, p_request_event_id, v_decision, btrim(p_reason), btrim(p_evidence_reference),
    v_request.actor_id, v_request.actor_role, v_actor, btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('request_event_id', p_request_event_id, 'target_event_id', v_request.prior_event_id,
                       'approver_role', v_role)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('approval_event_id', v_event.id, 'decision', v_decision);
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'DECIDE_REVERSAL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, v_decision, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_finance_reversal_v1(
  p_request_event_id uuid,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, already_reversed boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_request public.finance_control_events%rowtype;
  v_approval public.finance_control_events%rowtype;
  v_target public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF p_request_event_id IS NULL OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_request FROM public.finance_control_events WHERE id = p_request_event_id;
  IF NOT FOUND OR v_request.control_kind <> 'REVERSAL_REQUEST' THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('finance-reversal:' || v_request.prior_event_id::text, 0));
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'operation', 'COMPLETE_REVERSAL', 'request_event_id', p_request_event_id, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.operation IS DISTINCT FROM 'COMPLETE_REVERSAL'
       OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, 'REVERSED'::text, true;
    RETURN;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events newer
     WHERE newer.control_kind = 'REVERSAL_REQUEST' AND newer.prior_event_id = v_request.prior_event_id
       AND coalesce(newer.facts_snapshot->'supersedes_request_event_ids', '[]'::jsonb) ? v_request.id::text
  ) THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_REQUEST_SUPERSEDED' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_approval FROM public.finance_control_events
   WHERE control_kind = 'REVERSAL_APPROVAL' AND prior_event_id = p_request_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_REVERSAL_NOT_APPROVED' USING ERRCODE = '55000'; END IF;
  IF v_approval.decision <> 'APPROVED' THEN RAISE EXCEPTION 'FINANCE_REVERSAL_REJECTED' USING ERRCODE = '55000'; END IF;
  IF v_approval.approver_id IS NULL OR v_approval.approver_id = v_request.actor_id THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_MAKER_CHECKER' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.finance_control_events c
              WHERE c.control_kind = 'REVERSAL' AND c.decision = 'REVERSED' AND c.prior_event_id = v_request.prior_event_id) THEN
    RAISE EXCEPTION 'FINANCE_CONTROL_ALREADY_REVERSED' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_target FROM public.finance_control_events WHERE id = v_request.prior_event_id;
  -- Match dispatch-finalization lock order: take both Finance eligibility
  -- locks before the order row lock. Holding the row lock through snapshot
  -- comparison and INSERT closes the time-of-check/time-of-use race.
  IF v_target.scope IN ('ORDER','DISPATCH','COMPANY') THEN
    IF v_target.order_id IS NOT NULL THEN
      PERFORM public.lock_finance_dispatch_eligibility_v1(v_target.order_id);
    END IF;
    PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_target.company_id);
  END IF;
  IF v_target.order_id IS NOT NULL THEN
    PERFORM 1 FROM public.orders WHERE id = v_target.order_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_ORDER_NOT_FOUND' USING ERRCODE = '55000';
    END IF;
  END IF;
  -- Revalidate under shared locks: the old immediate RPC uses these same
  -- eligibility locks but not the new reversal-specific advisory lock.
  IF EXISTS (SELECT 1 FROM public.finance_control_events other
              WHERE other.control_kind = 'REVERSAL' AND other.decision = 'REVERSED'
                AND other.prior_event_id = v_request.prior_event_id) THEN
    RAISE EXCEPTION 'FINANCE_CONTROL_ALREADY_REVERSED' USING ERRCODE = '55000';
  END IF;
  -- Balance integrity: the financial position the approver saw must be the position being reversed.
  IF NOT public.finance_reversal_snapshot_is_current_v1(p_request_event_id) THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_SNAPSHOT_STALE: financial position changed since the request' USING ERRCODE = '40001';
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, approver_id, correlation_id, idempotency_key, facts_snapshot
  ) VALUES (
    v_target.company_id, v_target.order_id, v_target.final_invoice_id, 'REVERSAL', v_target.scope, false,
    v_target.amount, v_target.id, 'REVERSED', btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role,
    v_approval.approver_id, btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('reversed_event_id', v_target.id, 'reversed_kind', v_target.control_kind,
                       'request_event_id', v_request.id, 'approval_event_id', v_approval.id,
                       'requested_by', v_request.actor_id, 'approved_by', v_approval.approver_id,
                       'completed_by', v_actor)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', 'REVERSED');
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'COMPLETE_REVERSAL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, 'REVERSED'::text, false;
END;
$$;

REVOKE ALL ON FUNCTION public.request_finance_reversal_v1(uuid,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.request_finance_reversal_v1(uuid,text,text,text,text,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid) TO authenticated;
