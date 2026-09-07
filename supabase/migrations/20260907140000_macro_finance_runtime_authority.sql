-- MACRO-FINANCE: governed Finance-control runtime authority for Central Point77–81.
-- Reuses canonical invoice/payment/adjustment/clearance truth; no shadow ledgers.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- Ageing bucket helper (shared by AR and portfolio facts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finance_ageing_bucket_v1(p_age_days integer)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN coalesce(p_age_days, 0) <= 0 THEN 'CURRENT'
    WHEN p_age_days BETWEEN 1 AND 30 THEN '1-30'
    WHEN p_age_days BETWEEN 31 AND 60 THEN '31-60'
    WHEN p_age_days BETWEEN 61 AND 90 THEN '61-90'
    ELSE '90+'
  END;
$$;
REVOKE ALL ON FUNCTION public.finance_ageing_bucket_v1(integer) FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- Ledger disputes: append-only events + governed raise/transition RPCs
-- ---------------------------------------------------------------------------
ALTER TABLE public.ledger_disputes
  ADD COLUMN IF NOT EXISTS correlation_id text,
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS evidence_references jsonb,
  ADD COLUMN IF NOT EXISTS raised_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS raised_role text;

CREATE UNIQUE INDEX IF NOT EXISTS ledger_disputes_idempotency_key_uq
  ON public.ledger_disputes (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

ALTER TABLE public.ledger_disputes
  DROP CONSTRAINT IF EXISTS ledger_disputes_status_check;
ALTER TABLE public.ledger_disputes
  ADD CONSTRAINT ledger_disputes_status_check
  CHECK (status IN ('open','investigating','resolved','rejected','closed'));

CREATE TABLE IF NOT EXISTS public.ledger_dispute_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES public.ledger_disputes(id),
  status text NOT NULL CHECK (status IN ('OPEN','INVESTIGATING','RESOLVED','REJECTED','CLOSED')),
  notes text NOT NULL,
  evidence_references jsonb,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX IF NOT EXISTS ledger_dispute_events_dispute_idx
  ON public.ledger_dispute_events(dispute_id, created_at DESC, id DESC);

ALTER TABLE public.ledger_dispute_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ledger_dispute_events FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.ledger_dispute_events TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.ledger_dispute_mutation_scopes (
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  dispute_id uuid NOT NULL,
  PRIMARY KEY (backend_pid, transaction_id, dispute_id)
);
ALTER TABLE public.ledger_dispute_mutation_scopes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ledger_dispute_mutation_scopes FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_ledger_dispute_direct_write()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_APPEND_ONLY' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'INSERT' AND NOT EXISTS (
    SELECT 1 FROM public.ledger_dispute_mutation_scopes s
     WHERE s.backend_pid = pg_backend_pid()
       AND s.transaction_id = txid_current()
       AND s.dispute_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_GOVERNED_WRITE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_ledger_disputes_governed_write ON public.ledger_disputes;
CREATE TRIGGER trg_ledger_disputes_governed_write
  BEFORE INSERT OR UPDATE OR DELETE ON public.ledger_disputes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_dispute_direct_write();
REVOKE ALL ON FUNCTION public.prevent_ledger_dispute_direct_write() FROM PUBLIC, anon, authenticated, service_role;

DROP POLICY IF EXISTS "Buyers raise own company disputes" ON public.ledger_disputes;
DROP POLICY IF EXISTS "Staff full access ledger_disputes" ON public.ledger_disputes;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.ledger_disputes FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.ledger_dispute_authority_v1
WITH (security_invoker=true) AS
SELECT
  d.id dispute_id,
  d.ledger_id,
  d.company_id,
  d.raised_via,
  d.description,
  coalesce(e.status, upper(d.status)) current_status,
  d.correlation_id,
  d.idempotency_key,
  d.evidence_references,
  d.raised_by,
  d.raised_role,
  d.created_at,
  e.id latest_event_id,
  e.created_at latest_event_at
FROM public.ledger_disputes d
LEFT JOIN LATERAL (
  SELECT ev.*
    FROM public.ledger_dispute_events ev
   WHERE ev.dispute_id = d.id
   ORDER BY ev.created_at DESC, ev.id DESC
   LIMIT 1
) e ON true;
REVOKE ALL ON public.ledger_dispute_authority_v1 FROM PUBLIC, anon;
GRANT SELECT ON public.ledger_dispute_authority_v1 TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.raise_ledger_dispute_v1(
  p_ledger_id uuid,
  p_description text,
  p_evidence_references jsonb,
  p_raised_via text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(dispute_id uuid, current_status text, already_raised boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_ledger public.bi_monthly_ledgers%rowtype;
  v_internal boolean;
  v_existing public.ledger_disputes%rowtype;
  v_dispute public.ledger_disputes%rowtype;
  v_via text := lower(btrim(coalesce(p_raised_via, 'whatsapp')));
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_ledger FROM public.bi_monthly_ledgers WHERE id = p_ledger_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEDGER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  v_internal := public.is_internal_staff(v_actor);
  IF NOT v_internal AND v_ledger.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_COMPANY_SCOPE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  v_role := coalesce(public.get_user_role(v_actor), CASE WHEN v_internal THEN 'unknown' ELSE 'b2b_buyer' END);
  IF length(btrim(coalesce(p_description, ''))) < 5
     OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references) = 0
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL
     OR v_via NOT IN ('whatsapp','portal','finance','system') THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_existing FROM public.ledger_disputes WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.ledger_id IS DISTINCT FROM p_ledger_id
       OR v_existing.company_id IS DISTINCT FROM v_ledger.company_id
       OR v_existing.raised_by IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'LEDGER_DISPUTE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.id, 'OPEN'::text, true;
    RETURN;
  END IF;
  v_dispute.id := gen_random_uuid();
  INSERT INTO public.ledger_dispute_mutation_scopes(backend_pid, transaction_id, dispute_id)
  VALUES (pg_backend_pid(), txid_current(), v_dispute.id);
  INSERT INTO public.ledger_disputes(
    id, ledger_id, company_id, raised_via, description, status,
    correlation_id, idempotency_key, evidence_references, raised_by, raised_role
  ) VALUES (
    v_dispute.id, p_ledger_id, v_ledger.company_id, v_via, btrim(p_description), 'open',
    btrim(p_correlation_id), btrim(p_idempotency_key), p_evidence_references, v_actor, v_role
  ) RETURNING * INTO v_dispute;
  DELETE FROM public.ledger_dispute_mutation_scopes s
   WHERE s.backend_pid = pg_backend_pid()
     AND s.transaction_id = txid_current()
     AND s.dispute_id = v_dispute.id;
  INSERT INTO public.ledger_dispute_events(
    dispute_id, status, notes, evidence_references, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    v_dispute.id, 'OPEN', btrim(p_description), p_evidence_references, v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key) || ':open'
  );
  RETURN QUERY SELECT v_dispute.id, 'OPEN'::text, false;
END;
$$;
REVOKE ALL ON FUNCTION public.raise_ledger_dispute_v1(uuid,text,jsonb,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.raise_ledger_dispute_v1(uuid,text,jsonb,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.transition_ledger_dispute_v1(
  p_dispute_id uuid,
  p_transition text,
  p_notes text,
  p_evidence_references jsonb,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(dispute_id uuid, current_status text, already_transitioned boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_dispute public.ledger_disputes%rowtype;
  v_current text;
  v_target text := upper(btrim(coalesce(p_transition, '')));
  v_existing public.ledger_dispute_events%rowtype;
  v_internal boolean;
  v_terminal boolean;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_dispute FROM public.ledger_disputes WHERE id = p_dispute_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEDGER_DISPUTE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  v_internal := public.is_internal_staff(v_actor);
  IF NOT v_internal AND v_dispute.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_COMPANY_SCOPE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(e.status, upper(v_dispute.status)) INTO v_current
    FROM public.ledger_dispute_events e
   WHERE e.dispute_id = p_dispute_id
   ORDER BY e.created_at DESC, e.id DESC
   LIMIT 1;
  v_current := coalesce(v_current, upper(v_dispute.status));
  v_terminal := v_current IN ('RESOLVED','REJECTED','CLOSED');
  IF v_target NOT IN ('INVESTIGATING','RESOLVED','REJECTED','CLOSED')
     OR length(btrim(coalesce(p_notes, ''))) < 5
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_TRANSITION_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_target IN ('RESOLVED','REJECTED','CLOSED') THEN
    v_role := public.assert_finance_clearance_actor_v1(v_actor);
  ELSE
    IF NOT v_internal THEN RAISE EXCEPTION 'LEDGER_DISPUTE_INTERNAL_ONLY' USING ERRCODE = '42501'; END IF;
    v_role := coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN');
  END IF;
  SELECT * INTO v_existing FROM public.ledger_dispute_events WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.dispute_id IS DISTINCT FROM p_dispute_id OR v_existing.status IS DISTINCT FROM v_target THEN
      RAISE EXCEPTION 'LEDGER_DISPUTE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT p_dispute_id, v_target, true;
    RETURN;
  END IF;
  IF v_terminal THEN RAISE EXCEPTION 'LEDGER_DISPUTE_TERMINAL_STATE' USING ERRCODE = '55000'; END IF;
  IF v_target = 'INVESTIGATING' AND v_current NOT IN ('OPEN') THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_INVALID_TRANSITION' USING ERRCODE = '55000';
  END IF;
  IF v_target IN ('RESOLVED','REJECTED','CLOSED') AND v_current NOT IN ('OPEN','INVESTIGATING') THEN
    RAISE EXCEPTION 'LEDGER_DISPUTE_INVALID_TRANSITION' USING ERRCODE = '55000';
  END IF;
  INSERT INTO public.ledger_dispute_events(
    dispute_id, status, notes, evidence_references, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    p_dispute_id, v_target, btrim(p_notes), p_evidence_references, v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key)
  );
  RETURN QUERY SELECT p_dispute_id, v_target, false;
END;
$$;
REVOKE ALL ON FUNCTION public.transition_ledger_dispute_v1(uuid,text,text,jsonb,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.transition_ledger_dispute_v1(uuid,text,text,jsonb,text,text,uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Finance control events: holds, releases, reversals, second approval
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.finance_control_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  order_id uuid REFERENCES public.orders(id),
  final_invoice_id uuid REFERENCES public.final_invoices(id),
  control_kind text NOT NULL CHECK (control_kind IN ('HOLD','RELEASE','REVERSAL','SECOND_APPROVAL')),
  scope text NOT NULL CHECK (scope IN ('COMPANY','ORDER','INVOICE','DISPATCH')),
  blocking boolean NOT NULL DEFAULT false,
  amount numeric CHECK (amount IS NULL OR amount >= 0),
  prior_event_id uuid REFERENCES public.finance_control_events(id),
  decision text NOT NULL CHECK (decision IN ('APPLIED','RELEASED','REVERSED','APPROVED','REJECTED','PENDING')),
  reason text NOT NULL,
  evidence_reference text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  actor_role text NOT NULL,
  approver_id uuid REFERENCES auth.users(id),
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  facts_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX IF NOT EXISTS finance_control_events_company_idx
  ON public.finance_control_events(company_id, scope, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS finance_control_events_order_idx
  ON public.finance_control_events(order_id, scope, created_at DESC, id DESC)
  WHERE order_id IS NOT NULL;

ALTER TABLE public.finance_control_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.finance_control_events FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.finance_control_events TO authenticated, service_role;
CREATE POLICY finance_control_events_internal_read ON public.finance_control_events
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));

CREATE TABLE IF NOT EXISTS public.finance_control_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL,
  request_fingerprint text NOT NULL,
  control_event_id uuid NOT NULL REFERENCES public.finance_control_events(id),
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.finance_control_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.finance_control_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_finance_control_event_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'FINANCE_CONTROL_EVENTS_APPEND_ONLY' USING ERRCODE = '42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_finance_control_events_immutable ON public.finance_control_events;
CREATE TRIGGER trg_finance_control_events_immutable
  BEFORE UPDATE OR DELETE ON public.finance_control_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_finance_control_event_mutation();
REVOKE ALL ON FUNCTION public.prevent_finance_control_event_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.finance_control_authority_v1
WITH (security_invoker=true) AS
SELECT
  h.id control_event_id,
  h.company_id,
  h.order_id,
  h.final_invoice_id,
  h.control_kind,
  h.scope,
  h.blocking,
  h.amount,
  h.decision,
  h.prior_event_id,
  h.reason,
  h.evidence_reference,
  h.actor_id,
  h.actor_role,
  h.approver_id,
  h.correlation_id,
  h.created_at,
  true active_blocking_hold
FROM public.finance_control_events h
WHERE h.control_kind = 'HOLD'
  AND h.decision = 'APPLIED'
  AND h.blocking
  AND NOT EXISTS (
    SELECT 1 FROM public.finance_control_events r
     WHERE r.prior_event_id = h.id AND r.control_kind = 'RELEASE' AND r.decision = 'RELEASED'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.finance_control_events rev
     WHERE rev.prior_event_id = h.id AND rev.control_kind = 'REVERSAL' AND rev.decision = 'REVERSED'
  );
REVOKE ALL ON public.finance_control_authority_v1 FROM PUBLIC, anon;
GRANT SELECT ON public.finance_control_authority_v1 TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assert_no_blocking_finance_hold_v1(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%rowtype;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN; END IF;
  IF EXISTS (
    SELECT 1
      FROM public.finance_control_events h
     WHERE h.control_kind = 'HOLD'
       AND h.decision = 'APPLIED'
       AND h.blocking
       AND NOT EXISTS (
         SELECT 1 FROM public.finance_control_events r
          WHERE r.prior_event_id = h.id AND r.control_kind = 'RELEASE' AND r.decision = 'RELEASED'
       )
       AND NOT EXISTS (
         SELECT 1 FROM public.finance_control_events rev
          WHERE rev.prior_event_id = h.id AND rev.control_kind = 'REVERSAL' AND rev.decision = 'REVERSED'
       )
       AND (
         (h.scope = 'DISPATCH' AND (h.order_id IS NULL OR h.order_id = p_order_id))
         OR (h.scope = 'ORDER' AND h.order_id = p_order_id)
         OR (h.scope = 'COMPANY' AND h.company_id = v_order.company_id)
       )
  ) THEN
    RAISE EXCEPTION 'FINANCE_BLOCKING_HOLD_ACTIVE' USING ERRCODE = '55000';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.assert_no_blocking_finance_hold_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_no_blocking_finance_hold_v1(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.apply_finance_hold_v1(
  p_company_id uuid,
  p_order_id uuid,
  p_final_invoice_id uuid,
  p_scope text,
  p_amount numeric,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, requires_second_approval boolean, already_applied boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_scope text := upper(btrim(coalesce(p_scope, '')));
  v_threshold numeric := 100000;
  v_requires_second boolean := false;
  v_blocking boolean := false;
  v_decision text := 'APPLIED';
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF v_scope NOT IN ('COMPANY','ORDER','INVOICE','DISPATCH')
     OR p_amount IS NULL OR p_amount < 0
     OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_HOLD_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_scope IN ('ORDER','DISPATCH') AND p_order_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_HOLD_ORDER_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_scope = 'INVOICE' AND p_final_invoice_id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_HOLD_INVOICE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount >= v_threshold THEN
    v_requires_second := true;
    v_blocking := false;
    v_decision := 'PENDING';
  ELSE
    v_blocking := true;
    v_decision := 'APPLIED';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'company_id', p_company_id, 'order_id', p_order_id, 'final_invoice_id', p_final_invoice_id,
    'scope', v_scope, 'amount', p_amount, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_HOLD_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT
      (v_existing.response->>'control_event_id')::uuid,
      v_existing.response->>'decision',
      coalesce((v_existing.response->>'requires_second_approval')::boolean, false),
      true;
    RETURN;
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    p_company_id, p_order_id, p_final_invoice_id, 'HOLD', v_scope, v_blocking, p_amount, v_decision,
    btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object(
    'control_event_id', v_event.id, 'decision', v_event.decision,
    'requires_second_approval', v_requires_second, 'blocking', v_blocking
  );
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'APPLY_HOLD', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, v_event.decision, v_requires_second, false;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_finance_hold_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.apply_finance_hold_v1(uuid,uuid,uuid,text,numeric,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.release_finance_hold_v1(
  p_hold_event_id uuid,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, already_released boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_hold public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_RELEASE_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_hold FROM public.finance_control_events WHERE id = p_hold_event_id;
  IF NOT FOUND OR v_hold.control_kind <> 'HOLD' THEN
    RAISE EXCEPTION 'FINANCE_HOLD_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_hold.decision = 'PENDING' THEN
    RAISE EXCEPTION 'FINANCE_HOLD_PENDING_APPROVAL' USING ERRCODE = '55000';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events r
     WHERE r.prior_event_id = p_hold_event_id AND r.control_kind = 'RELEASE' AND r.decision = 'RELEASED'
  ) THEN
    RAISE EXCEPTION 'FINANCE_HOLD_ALREADY_RELEASED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'hold_event_id', p_hold_event_id, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_RELEASE_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, 'RELEASED'::text, true;
    RETURN;
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key
  ) VALUES (
    v_hold.company_id, v_hold.order_id, v_hold.final_invoice_id, 'RELEASE', v_hold.scope, false, v_hold.amount,
    p_hold_event_id, 'RELEASED', btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', 'RELEASED');
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'RELEASE_HOLD', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, 'RELEASED'::text, false;
END;
$$;
REVOKE ALL ON FUNCTION public.release_finance_hold_v1(uuid,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.release_finance_hold_v1(uuid,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.reverse_finance_control_v1(
  p_event_id uuid,
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
  v_source public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_REVERSAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_source FROM public.finance_control_events WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_CONTROL_EVENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events r
     WHERE r.prior_event_id = p_event_id AND r.control_kind = 'REVERSAL' AND r.decision = 'REVERSED'
  ) THEN
    RAISE EXCEPTION 'FINANCE_CONTROL_ALREADY_REVERSED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'event_id', p_event_id, 'reason', btrim(p_reason),
    'evidence_reference', btrim(p_evidence_reference), 'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_REVERSAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, 'REVERSED'::text, true;
    RETURN;
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, correlation_id, idempotency_key, facts_snapshot
  ) VALUES (
    v_source.company_id, v_source.order_id, v_source.final_invoice_id, 'REVERSAL', v_source.scope, false,
    v_source.amount, p_event_id, 'REVERSED', btrim(p_reason), btrim(p_evidence_reference), v_actor, v_role,
    btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('reversed_event_id', p_event_id, 'reversed_kind', v_source.control_kind)
  ) RETURNING * INTO v_event;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', 'REVERSED');
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'REVERSE_CONTROL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, 'REVERSED'::text, false;
END;
$$;
REVOKE ALL ON FUNCTION public.reverse_finance_control_v1(uuid,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.reverse_finance_control_v1(uuid,text,text,text,text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.decide_finance_second_approval_v1(
  p_pending_hold_event_id uuid,
  p_approve boolean,
  p_reason text,
  p_evidence_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(control_event_id uuid, decision text, already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_hold public.finance_control_events%rowtype;
  v_existing public.finance_control_idempotency%rowtype;
  v_event public.finance_control_events%rowtype;
  v_decision text := CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_hold FROM public.finance_control_events WHERE id = p_pending_hold_event_id FOR UPDATE;
  IF NOT FOUND OR v_hold.control_kind <> 'HOLD' OR v_hold.decision <> 'PENDING' THEN
    RAISE EXCEPTION 'FINANCE_HOLD_NOT_PENDING' USING ERRCODE = '55000';
  END IF;
  IF v_hold.actor_id = v_actor THEN
    RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_MAKER_CHECKER' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_control_events s
     WHERE s.prior_event_id = p_pending_hold_event_id AND s.control_kind = 'SECOND_APPROVAL'
  ) THEN
    RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_ALREADY_DECIDED' USING ERRCODE = '55000';
  END IF;
  v_fingerprint := encode(extensions.digest(jsonb_build_object(
    'pending_hold_event_id', p_pending_hold_event_id, 'approve', p_approve,
    'reason', btrim(p_reason), 'evidence_reference', btrim(p_evidence_reference),
    'correlation_id', btrim(p_correlation_id)
  )::text, 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.finance_control_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_SECOND_APPROVAL_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'control_event_id')::uuid, v_existing.response->>'decision', true;
    RETURN;
  END IF;
  INSERT INTO public.finance_control_events(
    company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
    reason, evidence_reference, actor_id, actor_role, approver_id, correlation_id, idempotency_key
  ) VALUES (
    v_hold.company_id, v_hold.order_id, v_hold.final_invoice_id, 'SECOND_APPROVAL', v_hold.scope,
    p_approve, v_hold.amount, p_pending_hold_event_id, v_decision, btrim(p_reason), btrim(p_evidence_reference),
    v_hold.actor_id, v_hold.actor_role, v_actor, btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_event;
  IF p_approve THEN
    INSERT INTO public.finance_control_events(
      company_id, order_id, final_invoice_id, control_kind, scope, blocking, amount, prior_event_id, decision,
      reason, evidence_reference, actor_id, actor_role, approver_id, correlation_id, idempotency_key
    ) VALUES (
      v_hold.company_id, v_hold.order_id, v_hold.final_invoice_id, 'HOLD', v_hold.scope, true, v_hold.amount,
      p_pending_hold_event_id, 'APPLIED', btrim(p_reason), btrim(p_evidence_reference), v_hold.actor_id,
      v_hold.actor_role, v_actor, btrim(p_correlation_id), btrim(p_idempotency_key) || ':applied'
    );
  END IF;
  v_response := jsonb_build_object('control_event_id', v_event.id, 'decision', v_decision);
  INSERT INTO public.finance_control_idempotency(idempotency_key, operation, request_fingerprint, control_event_id, actor_id, response)
  VALUES (btrim(p_idempotency_key), 'SECOND_APPROVAL', v_fingerprint, v_event.id, v_actor, v_response);
  RETURN QUERY SELECT v_event.id, v_decision, false;
END;
$$;
REVOKE ALL ON FUNCTION public.decide_finance_second_approval_v1(uuid,boolean,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.decide_finance_second_approval_v1(uuid,boolean,text,text,text,text,uuid) TO authenticated;

-- Integrate blocking holds with dispatch clearance guard
CREATE OR REPLACE FUNCTION public.assert_active_dispatch_clearance_v1(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v public.finance_dispatch_clearance_authority_v1%rowtype;
BEGIN
  PERFORM public.assert_no_blocking_finance_hold_v1(p_order_id);
  SELECT * INTO v FROM public.finance_dispatch_clearance_authority_v1 WHERE order_id = p_order_id;
  IF NOT FOUND OR NOT coalesce(v.dispatch_cleared, false) THEN
    RAISE EXCEPTION 'FINANCE_DISPATCH_CLEARANCE_REQUIRED' USING ERRCODE = '55000';
  END IF;
  RETURN v.clearance_event_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Non-complaint finance adjustments via canonical commercial_adjustments
-- ---------------------------------------------------------------------------
ALTER TABLE public.commercial_adjustments
  ADD COLUMN IF NOT EXISTS adjustment_source text NOT NULL DEFAULT 'COMPLAINT_REMEDY';

ALTER TABLE public.commercial_adjustments
  ALTER COLUMN complaint_id DROP NOT NULL;

ALTER TABLE public.commercial_adjustments
  DROP CONSTRAINT IF EXISTS commercial_adjustments_source_check;
ALTER TABLE public.commercial_adjustments
  ADD CONSTRAINT commercial_adjustments_source_check
  CHECK (
    (adjustment_source = 'COMPLAINT_REMEDY' AND complaint_id IS NOT NULL)
    OR (adjustment_source = 'FINANCE_DIRECT' AND complaint_id IS NULL)
  );

CREATE OR REPLACE FUNCTION public.apply_finance_adjustment_v1(
  p_final_invoice_id uuid,
  p_adjustment_type text,
  p_amount numeric,
  p_document_number text,
  p_document_reference text,
  p_payment_reference text,
  p_decision_reason text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(adjustment_id uuid, wallet_entry_id uuid, already_applied boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_invoice public.final_invoices%rowtype;
  v_type text := upper(btrim(coalesce(p_adjustment_type, '')));
  v_existing public.commercial_adjustments%rowtype;
  v_wallet uuid;
  v_wallet_balance numeric;
  v_wallet_dup boolean;
BEGIN
  v_role := public.assert_finance_clearance_actor_v1(v_actor);
  IF v_type NOT IN ('CREDIT_NOTE','DEBIT_NOTE','REFUND_TO_BANK','REFUND_TO_WALLET','PARTIAL_WRITE_OFF','CUSTOMER_DEBIT')
     OR p_amount IS NULL OR p_amount < 0
     OR length(btrim(coalesce(p_decision_reason, ''))) < 5
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_ADJUSTMENT_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_type IN ('CREDIT_NOTE','DEBIT_NOTE')
     AND (p_amount <= 0 OR nullif(btrim(p_document_number), '') IS NULL OR nullif(btrim(p_document_reference), '') IS NULL) THEN
    RAISE EXCEPTION 'TAX_ADJUSTMENT_DOCUMENT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_type = 'REFUND_TO_BANK' AND (p_amount <= 0 OR nullif(btrim(p_payment_reference), '') IS NULL) THEN
    RAISE EXCEPTION 'BANK_REFUND_REFERENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_type = 'REFUND_TO_WALLET' AND p_amount <= 0 THEN
    RAISE EXCEPTION 'WALLET_REFUND_AMOUNT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_invoice FROM public.final_invoices WHERE id = p_final_invoice_id AND status = 'ISSUED';
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_existing FROM public.commercial_adjustments WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.final_invoice_id IS DISTINCT FROM p_final_invoice_id
       OR v_existing.adjustment_type IS DISTINCT FROM v_type
       OR v_existing.amount IS DISTINCT FROM p_amount THEN
      RAISE EXCEPTION 'FINANCE_ADJUSTMENT_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.wallet_entry_id, true;
    RETURN;
  END IF;
  IF v_type = 'REFUND_TO_WALLET' THEN
    SELECT r.entry_id, r.balance, r.already_applied
      INTO v_wallet, v_wallet_balance, v_wallet_dup
      FROM public.record_wallet_entry_v1(
        v_invoice.company_id, 'credit', p_amount, 'INR', v_invoice.order_id, v_invoice.proforma_invoice_id,
        v_invoice.commercial_version_id, 'FINANCE_ADJUSTMENT', p_final_invoice_id::text, btrim(p_decision_reason),
        btrim(p_correlation_id), btrim(p_idempotency_key) || ':wallet', v_actor
      ) r;
  END IF;
  INSERT INTO public.commercial_adjustments(
    complaint_id, order_id, final_invoice_id, adjustment_type, amount, document_number, document_reference,
    payment_reference, wallet_entry_id, decision_reason, actor_id, actor_role, correlation_id, idempotency_key,
    adjustment_source
  ) VALUES (
    NULL, v_invoice.order_id, v_invoice.id, v_type, p_amount, nullif(btrim(p_document_number), ''),
    nullif(btrim(p_document_reference), ''), nullif(btrim(p_payment_reference), ''), v_wallet,
    btrim(p_decision_reason), v_actor, v_role, btrim(p_correlation_id), btrim(p_idempotency_key), 'FINANCE_DIRECT'
  ) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id, v_existing.wallet_entry_id, false;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.apply_finance_adjustment_v1(uuid,text,numeric,text,text,text,text,text,text,uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Company AR ageing facts (derived; no balance table)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_company_ar_ageing_facts_v1(p_company_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_company public.companies%rowtype;
  v_lines jsonb := '[]'::jsonb;
  v_line record;
  v_settlement jsonb;
  v_settled numeric;
  v_credit_notes numeric;
  v_debit_notes numeric;
  v_refunds numeric;
  v_open numeric;
  v_due date;
  v_age integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AR_AGEING_AUTH_REQUIRED' USING ERRCODE = '42501'; END IF;
  IF NOT public.is_internal_staff(auth.uid()) AND p_company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'AR_AGEING_COMPANY_SCOPE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_company FROM public.companies WHERE id = p_company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'AR_AGEING_COMPANY_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  FOR v_line IN
    SELECT fi.*
      FROM public.final_invoices fi
     WHERE fi.company_id = p_company_id
       AND fi.status = 'ISSUED'
     ORDER BY fi.invoice_date DESC, fi.created_at DESC
  LOOP
    v_settlement := public.get_final_settlement_facts_v1(v_line.id);
    v_settled := coalesce((v_settlement->>'verified_payment_total')::numeric, 0)
      + coalesce((v_settlement->>'wallet_applied_total')::numeric, 0)
      + coalesce((v_settlement->>'approved_credit_total')::numeric, 0);
    SELECT
      coalesce(sum(CASE WHEN a.adjustment_type = 'CREDIT_NOTE' THEN a.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN a.adjustment_type = 'DEBIT_NOTE' THEN a.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN a.adjustment_type IN ('REFUND_TO_BANK','REFUND_TO_WALLET') THEN a.amount ELSE 0 END), 0)
      INTO v_credit_notes, v_debit_notes, v_refunds
      FROM public.commercial_adjustments a
     WHERE a.final_invoice_id = v_line.id;
    v_open := greatest(0, round(v_line.gross_total - v_settled - v_credit_notes + v_debit_notes - v_refunds, 2));
    v_due := CASE WHEN v_company.payment_terms = 'credit' THEN v_line.invoice_date + 30 ELSE v_line.invoice_date END;
    v_age := current_date - v_due;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'final_invoice_id', v_line.id,
      'order_id', v_line.order_id,
      'document_reference', v_line.invoice_number,
      'invoice_date', v_line.invoice_date,
      'due_date', v_due,
      'currency', v_line.currency,
      'original_amount', v_line.gross_total,
      'settled_amount', v_settled,
      'credit_note_amount', v_credit_notes,
      'debit_note_amount', v_debit_notes,
      'refund_amount', v_refunds,
      'open_amount', v_open,
      'age_days', v_age,
      'ageing_bucket', public.finance_ageing_bucket_v1(v_age),
      'dispute_state', CASE
        WHEN EXISTS (
          SELECT 1 FROM public.commercial_complaints c
           WHERE c.order_id = v_line.order_id
             AND NOT EXISTS (SELECT 1 FROM public.commercial_adjustments ca WHERE ca.complaint_id = c.id)
        ) THEN 'COMPLAINT_OPEN'
        WHEN EXISTS (
          SELECT 1 FROM public.ledger_dispute_authority_v1 ld
           WHERE ld.company_id = p_company_id
             AND ld.current_status IN ('OPEN','INVESTIGATING')
        ) THEN 'LEDGER_DISPUTE_OPEN'
        ELSE 'NONE'
      END,
      'hold_state', CASE
        WHEN EXISTS (
          SELECT 1 FROM public.finance_control_authority_v1 f
           WHERE f.active_blocking_hold
             AND f.company_id = p_company_id
             AND (f.order_id IS NULL OR f.order_id = v_line.order_id OR f.final_invoice_id = v_line.id)
        ) THEN 'BLOCKING_HOLD'
        ELSE 'NONE'
      END
    ));
  END LOOP;
  RETURN jsonb_build_object(
    'company_id', p_company_id,
    'payment_terms', v_company.payment_terms,
    'lines', v_lines,
    'facts_as_of', statement_timestamp(),
    'ar_ageing_facts_only', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_company_ar_ageing_facts_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_company_ar_ageing_facts_v1(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Portfolio exposure facts (reuses credit exposure semantics)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_portfolio_exposure_facts_v1(p_company_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_company_ids uuid[];
  v_company_id uuid;
  v_ar jsonb;
  v_line jsonb;
  v_total_receivable numeric := 0;
  v_current numeric := 0;
  v_overdue numeric := 0;
  v_disputed numeric := 0;
  v_held numeric := 0;
  v_wallet numeric := 0;
  v_short_credit numeric := 0;
  v_long_credit numeric := 0;
  v_total_short_credit numeric := 0;
  v_total_long_credit numeric := 0;
  v_drilldown jsonb := '[]'::jsonb;
  v_buckets jsonb := jsonb_build_object('CURRENT',0,'1-30',0,'31-60',0,'61-90',0,'90+',0);
  v_open numeric;
  v_company_open numeric;
  v_company_disputed numeric;
  v_company_held numeric;
  v_company_overdue numeric;
  v_bucket text;
  v_high_risk boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'PORTFOLIO_EXPOSURE_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;
  IF p_company_id IS NULL THEN
    SELECT array_agg(c.id ORDER BY c.business_name) INTO v_company_ids FROM public.companies c WHERE NOT coalesce(c.is_frozen, false);
  ELSE
    v_company_ids := ARRAY[p_company_id];
  END IF;
  FOREACH v_company_id IN ARRAY coalesce(v_company_ids, ARRAY[]::uuid[]) LOOP
    v_ar := public.get_company_ar_ageing_facts_v1(v_company_id);
    v_wallet := v_wallet + coalesce(public.get_wallet_balance_v1(v_company_id), 0);
    SELECT coalesce(sum(requested_amount), 0) INTO v_short_credit
      FROM public.credit_requests
     WHERE company_id = v_company_id AND credit_type = 'short_term_so' AND status = 'approved'
       AND (expires_at IS NULL OR expires_at > statement_timestamp());
    SELECT coalesce(sum(requested_amount), 0) INTO v_long_credit
      FROM public.credit_requests
     WHERE company_id = v_company_id AND credit_type = 'long_term_limit' AND status = 'approved'
       AND (expires_at IS NULL OR expires_at > statement_timestamp());
    v_total_short_credit := v_total_short_credit + v_short_credit;
    v_total_long_credit := v_total_long_credit + v_long_credit;
    v_company_open := 0;
    v_company_disputed := 0;
    v_company_held := 0;
    v_company_overdue := 0;
    FOR v_line IN SELECT value FROM jsonb_array_elements(coalesce(v_ar->'lines', '[]'::jsonb)) LOOP
      v_open := coalesce((v_line->>'open_amount')::numeric, 0);
      v_company_open := v_company_open + v_open;
      v_total_receivable := v_total_receivable + v_open;
      v_bucket := coalesce(v_line->>'ageing_bucket', 'CURRENT');
      v_buckets := jsonb_set(v_buckets, ARRAY[v_bucket], to_jsonb(coalesce((v_buckets->>v_bucket)::numeric, 0) + v_open));
      IF v_bucket = 'CURRENT' THEN v_current := v_current + v_open; ELSE v_overdue := v_overdue + v_open; v_company_overdue := v_company_overdue + v_open; END IF;
      IF coalesce(v_line->>'dispute_state', 'NONE') <> 'NONE' THEN v_disputed := v_disputed + v_open; v_company_disputed := v_company_disputed + v_open; END IF;
      IF coalesce(v_line->>'hold_state', 'NONE') = 'BLOCKING_HOLD' THEN v_held := v_held + v_open; v_company_held := v_company_held + v_open; END IF;
    END LOOP;
    v_high_risk := v_company_overdue > 0 OR v_company_disputed > 0 OR v_company_held > 0;
    v_drilldown := v_drilldown || jsonb_build_array(jsonb_build_object(
      'company_id', v_company_id,
      'total_receivable', v_company_open,
      'wallet_balance', public.get_wallet_balance_v1(v_company_id),
      'approved_short_term_credit', v_short_credit,
      'approved_long_term_credit', v_long_credit,
      'disputed_amount', v_company_disputed,
      'held_amount', v_company_held,
      'high_risk', v_high_risk,
      'overdue_amount', v_company_overdue
    ));
  END LOOP;
  RETURN jsonb_build_object(
    'company_filter', p_company_id,
    'total_receivable', v_total_receivable,
    'current_receivable', v_current,
    'overdue_receivable', v_overdue,
    'ageing_buckets', v_buckets,
    'approved_open_credit_exposure', v_total_short_credit + v_total_long_credit,
    'wallet_balance_total', v_wallet,
    'disputed_amount', v_disputed,
    'held_amount', v_held,
    'high_risk_present', v_overdue > 0 OR v_disputed > 0 OR v_held > 0,
    'company_drilldown', v_drilldown,
    'exposure_facts_only', true,
    'clearance_decision', null,
    'facts_as_of', statement_timestamp()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_portfolio_exposure_facts_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_portfolio_exposure_facts_v1(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Central read projection: ageing, exposure, disputes, holds, adjustments, approvals
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_finance_control_projection_v1(
  p_company_id uuid,
  p_order_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_adjustments jsonb;
  v_pending_approvals jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'FINANCE_CONTROL_PROJECTION_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'adjustment_id', a.id,
    'order_id', a.order_id,
    'final_invoice_id', a.final_invoice_id,
    'adjustment_type', a.adjustment_type,
    'amount', a.amount,
    'adjustment_source', a.adjustment_source,
    'created_at', a.created_at
  ) ORDER BY a.created_at DESC), '[]'::jsonb)
    INTO v_adjustments
    FROM public.commercial_adjustments a
    JOIN public.final_invoices fi ON fi.id = a.final_invoice_id
   WHERE fi.company_id = p_company_id
     AND (p_order_id IS NULL OR a.order_id = p_order_id);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'control_event_id', e.id,
    'company_id', e.company_id,
    'order_id', e.order_id,
    'scope', e.scope,
    'amount', e.amount,
    'reason', e.reason,
    'created_at', e.created_at
  ) ORDER BY e.created_at DESC), '[]'::jsonb)
    INTO v_pending_approvals
    FROM public.finance_control_events e
   WHERE e.company_id = p_company_id
     AND e.control_kind = 'HOLD'
     AND e.decision = 'PENDING'
     AND (p_order_id IS NULL OR e.order_id IS NULL OR e.order_id = p_order_id);
  RETURN jsonb_build_object(
    'company_id', p_company_id,
    'order_filter', p_order_id,
    'ar_ageing', public.get_company_ar_ageing_facts_v1(p_company_id),
    'portfolio_exposure', public.get_portfolio_exposure_facts_v1(p_company_id),
    'ledger_disputes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'dispute_id', ld.dispute_id,
        'ledger_id', ld.ledger_id,
        'current_status', ld.current_status,
        'description', ld.description,
        'latest_event_at', ld.latest_event_at
      ) ORDER BY ld.latest_event_at DESC NULLS LAST)
        FROM public.ledger_dispute_authority_v1 ld
       WHERE ld.company_id = p_company_id
         AND ld.current_status IN ('OPEN','INVESTIGATING')
    ), '[]'::jsonb),
    'active_holds', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'control_event_id', f.control_event_id,
        'order_id', f.order_id,
        'scope', f.scope,
        'amount', f.amount,
        'reason', f.reason,
        'created_at', f.created_at
      ) ORDER BY f.created_at DESC)
        FROM public.finance_control_authority_v1 f
       WHERE f.company_id = p_company_id
         AND f.active_blocking_hold
         AND (p_order_id IS NULL OR f.order_id IS NULL OR f.order_id = p_order_id)
    ), '[]'::jsonb),
    'adjustments', v_adjustments,
    'second_approval_queue', v_pending_approvals,
    'facts_as_of', statement_timestamp(),
    'projection_read_only', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_finance_control_projection_v1(uuid,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_finance_control_projection_v1(uuid,uuid) TO authenticated;

COMMENT ON FUNCTION public.get_company_ar_ageing_facts_v1(uuid) IS 'Governed AR ageing facts derived from final invoices, settlement facts and commercial adjustments. No balance table.';
COMMENT ON FUNCTION public.get_portfolio_exposure_facts_v1(uuid) IS 'Portfolio receivable/exposure aggregation reusing credit-exposure semantics; facts-only, not clearance.';
COMMENT ON FUNCTION public.get_finance_control_projection_v1(uuid,uuid) IS 'Bounded Central read model for ageing, exposure, disputes, holds, adjustments and second-approval queue.';
