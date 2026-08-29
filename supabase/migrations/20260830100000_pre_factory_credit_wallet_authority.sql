-- Pre-Factory PF-6B: canonical wallet, credit and credit-exposure authority.
--
-- This migration extends the legacy wallet/credit tables in place.  It does
-- not create a second wallet truth, does not introduce a credit policy matrix,
-- and deliberately does not grant any Operations/Manufacturing release
-- authority.  Historical rows are retained and labelled as historical
-- evidence; new governed facts enter only through the RPCs below.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ---------------------------------------------------------------------------
-- Wallet ledger: extend the existing table rather than creating a parallel
-- balance store.  Existing rows are reconciled deterministically before the
-- append-only guard is installed.
-- ---------------------------------------------------------------------------
ALTER TABLE public.wallet_transactions
  ADD COLUMN IF NOT EXISTS direction text,
  ADD COLUMN IF NOT EXISTS entry_type text,
  ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'INR',
  ADD COLUMN IF NOT EXISTS order_id uuid REFERENCES public.orders(id),
  ADD COLUMN IF NOT EXISTS proforma_invoice_id uuid REFERENCES public.sales_order_proforma_invoices(id),
  ADD COLUMN IF NOT EXISTS commercial_version_id uuid REFERENCES public.sales_order_commercial_versions(id),
  ADD COLUMN IF NOT EXISTS source_channel text,
  ADD COLUMN IF NOT EXISTS source_reference text,
  ADD COLUMN IF NOT EXISTS reason text,
  ADD COLUMN IF NOT EXISTS actor_id uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS actor_role text,
  ADD COLUMN IF NOT EXISTS correlation_id text,
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS reversal_of_id uuid REFERENCES public.wallet_transactions(id);

UPDATE public.wallet_transactions
   SET direction = CASE lower(type)
                     WHEN 'credit' THEN 'credit'
                     WHEN 'debit' THEN 'debit'
                     WHEN 'withdrawal' THEN 'debit'
                   END,
       entry_type = coalesce(nullif(entry_type, ''), type),
       source_channel = coalesce(nullif(source_channel, ''), 'LEGACY_ERP'),
       source_reference = coalesce(source_reference, reference),
       reason = coalesce(reason, 'Historical wallet ledger reconciliation'),
       idempotency_key = coalesce(idempotency_key, 'legacy-wallet:' || id::text)
 WHERE direction IS NULL;

ALTER TABLE public.wallet_transactions
  DROP CONSTRAINT IF EXISTS wallet_transactions_amount_positive,
  DROP CONSTRAINT IF EXISTS wallet_transactions_direction_check,
  DROP CONSTRAINT IF EXISTS wallet_transactions_currency_check;
ALTER TABLE public.wallet_transactions
  ADD CONSTRAINT wallet_transactions_amount_positive CHECK (amount > 0) NOT VALID,
  ADD CONSTRAINT wallet_transactions_direction_check CHECK (direction IS NULL OR direction IN ('credit', 'debit')) NOT VALID,
  ADD CONSTRAINT wallet_transactions_currency_check CHECK (currency ~ '^[A-Z]{3}$') NOT VALID;

CREATE UNIQUE INDEX IF NOT EXISTS wallet_transactions_idempotency_key_uq
  ON public.wallet_transactions (idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS wallet_transactions_company_created_idx
  ON public.wallet_transactions (company_id, created_at, id);

CREATE TABLE IF NOT EXISTS public.wallet_opening_balance_evidence (
  company_id uuid PRIMARY KEY REFERENCES public.companies(id),
  opening_balance numeric,
  opening_balance_known boolean NOT NULL,
  source text NOT NULL,
  reconciliation_key text NOT NULL UNIQUE,
  captured_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  captured_by uuid REFERENCES auth.users(id),
  notes text
);

ALTER TABLE public.wallet_opening_balance_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.wallet_opening_balance_evidence FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.wallet_opening_balance_evidence TO authenticated, service_role;
INSERT INTO public.wallet_opening_balance_evidence(
  company_id, opening_balance, opening_balance_known, source, reconciliation_key, notes
)
SELECT c.id, c.wallet_balance, c.wallet_balance IS NOT NULL, 'LEGACY_OPENING_BALANCE',
       'legacy-wallet-opening:' || c.id::text,
       'Deterministic PF-6B opening evidence; no historical row was rewritten.'
  FROM public.companies c
ON CONFLICT (company_id) DO NOTHING;

DROP POLICY IF EXISTS wallet_opening_balance_internal_read ON public.wallet_opening_balance_evidence;
CREATE POLICY wallet_opening_balance_internal_read
  ON public.wallet_opening_balance_evidence FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.capture_wallet_opening_balance_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.wallet_opening_balance_evidence(
    company_id, opening_balance, opening_balance_known, source, reconciliation_key, notes
  ) VALUES (
    new.id, new.wallet_balance, new.wallet_balance IS NOT NULL,
    'COMPANY_CREATION_OPENING_BALANCE', 'company-opening:' || new.id::text,
    'Opening evidence captured at company creation; canonical ledger entries are applied after this point.'
  ) ON CONFLICT (company_id) DO NOTHING;
  RETURN new;
END;
$$;
DROP TRIGGER IF EXISTS trg_company_wallet_opening_evidence ON public.companies;
CREATE TRIGGER trg_company_wallet_opening_evidence
  AFTER INSERT ON public.companies
  FOR EACH ROW EXECUTE FUNCTION public.capture_wallet_opening_balance_v1();
REVOKE ALL ON FUNCTION public.capture_wallet_opening_balance_v1() FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.wallet_authority_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('CREDIT', 'DEBIT')),
  request_fingerprint text NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id),
  entry_id uuid NOT NULL REFERENCES public.wallet_transactions(id),
  response jsonb NOT NULL,
  actor_id uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

ALTER TABLE public.wallet_authority_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.wallet_authority_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.wallet_mutation_scopes (
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  entry_id uuid NOT NULL REFERENCES public.wallet_transactions(id),
  PRIMARY KEY (backend_pid, transaction_id, entry_id)
);
ALTER TABLE public.wallet_mutation_scopes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.wallet_mutation_scopes FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_wallet_transaction_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'WALLET_LEDGER_APPEND_ONLY' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.wallet_mutation_scopes s
     WHERE s.backend_pid = pg_backend_pid()
       AND s.transaction_id = txid_current()
       AND s.entry_id = old.id
  ) THEN
    RAISE EXCEPTION 'DIRECT_WALLET_LEDGER_MUTATION_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF old.id IS DISTINCT FROM new.id
     OR old.company_id IS DISTINCT FROM new.company_id
     OR old.amount IS DISTINCT FROM new.amount
     OR old.direction IS DISTINCT FROM new.direction
     OR old.currency IS DISTINCT FROM new.currency
     OR old.order_id IS DISTINCT FROM new.order_id
     OR old.proforma_invoice_id IS DISTINCT FROM new.proforma_invoice_id
     OR old.commercial_version_id IS DISTINCT FROM new.commercial_version_id
     OR old.source_channel IS DISTINCT FROM new.source_channel
     OR old.source_reference IS DISTINCT FROM new.source_reference
     OR old.reason IS DISTINCT FROM new.reason
     OR old.actor_id IS DISTINCT FROM new.actor_id
     OR old.actor_role IS DISTINCT FROM new.actor_role
     OR old.correlation_id IS DISTINCT FROM new.correlation_id
     OR old.idempotency_key IS DISTINCT FROM new.idempotency_key
     OR old.reversal_of_id IS DISTINCT FROM new.reversal_of_id THEN
    RAISE EXCEPTION 'WALLET_LEDGER_FACTS_IMMUTABLE' USING ERRCODE = '42501';
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_wallet_transaction_immutable ON public.wallet_transactions;
CREATE TRIGGER trg_wallet_transaction_immutable
  BEFORE UPDATE OR DELETE ON public.wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_wallet_transaction_mutation();
REVOKE ALL ON FUNCTION public.prevent_wallet_transaction_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.refresh_wallet_balance_projection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_opening public.wallet_opening_balance_evidence%rowtype; v_balance numeric;
BEGIN
  SELECT * INTO v_opening FROM public.wallet_opening_balance_evidence
   WHERE company_id = new.company_id FOR SHARE;
  IF NOT FOUND OR NOT v_opening.opening_balance_known THEN
    RAISE EXCEPTION 'WALLET_OPENING_BALANCE_UNRECONCILED' USING ERRCODE = '55000';
  END IF;
  PERFORM 1 FROM public.companies WHERE id = new.company_id FOR UPDATE;
  SELECT v_opening.opening_balance + coalesce(sum(CASE direction WHEN 'credit' THEN amount WHEN 'debit' THEN -amount ELSE 0 END), 0)
    INTO v_balance
    FROM public.wallet_transactions
   WHERE company_id = new.company_id AND source_channel IS DISTINCT FROM 'LEGACY_ERP';
  UPDATE public.companies SET wallet_balance = v_balance WHERE id = new.company_id;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_wallet_balance_projection ON public.wallet_transactions;
CREATE TRIGGER trg_wallet_balance_projection
  AFTER INSERT ON public.wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION public.refresh_wallet_balance_projection();
REVOKE ALL ON FUNCTION public.refresh_wallet_balance_projection() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Credit requests and append-only decision history.
-- ---------------------------------------------------------------------------
ALTER TABLE public.credit_requests
  ADD COLUMN IF NOT EXISTS order_id uuid REFERENCES public.orders(id),
  ADD COLUMN IF NOT EXISTS proforma_invoice_id uuid REFERENCES public.sales_order_proforma_invoices(id),
  ADD COLUMN IF NOT EXISTS commercial_version_id uuid REFERENCES public.sales_order_commercial_versions(id),
  ADD COLUMN IF NOT EXISTS source_channel text,
  ADD COLUMN IF NOT EXISTS source_reference text,
  ADD COLUMN IF NOT EXISTS actor_role text,
  ADD COLUMN IF NOT EXISTS correlation_id text,
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS decided_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS decided_role text,
  ADD COLUMN IF NOT EXISTS decided_at timestamptz,
  ADD COLUMN IF NOT EXISTS decision_reason text,
  ADD COLUMN IF NOT EXISTS decision_source text;

ALTER TABLE public.credit_requests
  DROP CONSTRAINT IF EXISTS credit_requests_requested_amount_positive;
ALTER TABLE public.credit_requests
  ADD CONSTRAINT credit_requests_requested_amount_positive CHECK (requested_amount > 0) NOT VALID;
CREATE UNIQUE INDEX IF NOT EXISTS credit_requests_idempotency_key_uq
  ON public.credit_requests (idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.credit_request_mutation_scopes (
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  request_id uuid NOT NULL REFERENCES public.credit_requests(id),
  PRIMARY KEY (backend_pid, transaction_id, request_id)
);
ALTER TABLE public.credit_request_mutation_scopes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.credit_request_mutation_scopes FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.credit_decision_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.credit_requests(id),
  old_status text,
  new_status text NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  credit_type text NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id),
  order_id uuid REFERENCES public.orders(id),
  proforma_invoice_id uuid REFERENCES public.sales_order_proforma_invoices(id),
  commercial_version_id uuid REFERENCES public.sales_order_commercial_versions(id),
  actor_id uuid REFERENCES auth.users(id),
  actor_role text NOT NULL,
  reason text NOT NULL,
  source_channel text NOT NULL,
  source_reference text,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (request_id, new_status, idempotency_key)
);
ALTER TABLE public.credit_decision_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.credit_decision_audit FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.credit_decision_audit TO authenticated, service_role;
DROP POLICY IF EXISTS credit_decision_audit_internal_read ON public.credit_decision_audit;
CREATE POLICY credit_decision_audit_internal_read
  ON public.credit_decision_audit FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_credit_request_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'CREDIT_REQUEST_APPEND_ONLY' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.credit_request_mutation_scopes s
     WHERE s.backend_pid = pg_backend_pid()
       AND s.transaction_id = txid_current()
       AND s.request_id = old.id
  ) THEN
    RAISE EXCEPTION 'DIRECT_CREDIT_REQUEST_MUTATION_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF old.id IS DISTINCT FROM new.id OR old.company_id IS DISTINCT FROM new.company_id
     OR old.requested_by IS DISTINCT FROM new.requested_by
     OR old.requested_amount IS DISTINCT FROM new.requested_amount
     OR old.credit_type IS DISTINCT FROM new.credit_type
     OR old.order_id IS DISTINCT FROM new.order_id
     OR old.proforma_invoice_id IS DISTINCT FROM new.proforma_invoice_id
     OR old.commercial_version_id IS DISTINCT FROM new.commercial_version_id
     OR old.source_channel IS DISTINCT FROM new.source_channel
     OR old.source_reference IS DISTINCT FROM new.source_reference
     OR old.actor_role IS DISTINCT FROM new.actor_role
     OR old.correlation_id IS DISTINCT FROM new.correlation_id
     OR old.idempotency_key IS DISTINCT FROM new.idempotency_key THEN
    RAISE EXCEPTION 'CREDIT_REQUEST_FACTS_IMMUTABLE' USING ERRCODE = '42501';
  END IF;
  RETURN new;
END;
$$;
DROP TRIGGER IF EXISTS trg_credit_request_immutable ON public.credit_requests;
CREATE TRIGGER trg_credit_request_immutable
  BEFORE UPDATE OR DELETE ON public.credit_requests
  FOR EACH ROW EXECUTE FUNCTION public.prevent_credit_request_mutation();
REVOKE ALL ON FUNCTION public.prevent_credit_request_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.credit_authority_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('REQUEST', 'APPROVE', 'REJECT')),
  request_fingerprint text NOT NULL,
  request_id uuid NOT NULL REFERENCES public.credit_requests(id),
  response jsonb NOT NULL,
  actor_id uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.credit_authority_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.credit_authority_idempotency FROM PUBLIC, anon, authenticated, service_role;

-- Replace legacy broad table policies.  All writes are through the governed
-- RPCs; internal staff can read the decision facts and audit only.
DROP POLICY IF EXISTS "Admins manage credit_requests" ON public.credit_requests;
DROP POLICY IF EXISTS "Authenticated can insert credit_requests" ON public.credit_requests;
DROP POLICY IF EXISTS "Authenticated can read credit_requests" ON public.credit_requests;
ALTER TABLE public.credit_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.credit_requests FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.credit_requests TO authenticated, service_role;
CREATE POLICY credit_requests_internal_read ON public.credit_requests FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS "Companies view own rescue events" ON public.credit_rescue_events;
DROP POLICY IF EXISTS "Staff full access to rescue events" ON public.credit_rescue_events;
ALTER TABLE public.credit_rescue_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.credit_rescue_events FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.credit_rescue_events TO authenticated, service_role;
CREATE POLICY credit_rescue_events_internal_read ON public.credit_rescue_events FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS "Users can view their wallet" ON public.wallet_transactions;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.wallet_transactions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.wallet_transactions TO authenticated, service_role;
CREATE POLICY wallet_transactions_authorized_read ON public.wallet_transactions FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()) OR company_id = public.auth_buyer_company_id());

-- ---------------------------------------------------------------------------
-- Shared helpers and governed wallet RPCs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_wallet_balance_v1(p_company_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_opening public.wallet_opening_balance_evidence%rowtype; v_balance numeric;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'WALLET_AUTHENTICATION_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF auth.role() <> 'service_role'
     AND NOT public.is_internal_staff(auth.uid())
     AND p_company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'WALLET_COMPANY_SCOPE_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_opening FROM public.wallet_opening_balance_evidence WHERE company_id = p_company_id;
  IF NOT FOUND OR NOT v_opening.opening_balance_known THEN
    RAISE EXCEPTION 'WALLET_OPENING_BALANCE_UNRECONCILED' USING ERRCODE = '55000';
  END IF;
  SELECT v_opening.opening_balance + coalesce(sum(CASE direction WHEN 'credit' THEN amount WHEN 'debit' THEN -amount ELSE 0 END), 0)
    INTO v_balance FROM public.wallet_transactions
   WHERE company_id = p_company_id AND source_channel IS DISTINCT FROM 'LEGACY_ERP';
  RETURN v_balance;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_credit_actor_v1(p_actor_id uuid, p_kind text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_role text;
BEGIN
  IF p_actor_id IS NULL OR auth.uid() IS DISTINCT FROM p_actor_id OR NOT public.is_internal_staff(p_actor_id) THEN
    RAISE EXCEPTION 'CREDIT_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  v_role := upper(public.get_user_role(p_actor_id));
  IF p_kind = 'SHORT_TERM' AND v_role <> ALL (ARRAY['FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER']) THEN
    RAISE EXCEPTION 'CREDIT_FINANCE_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_kind = 'LONG_TERM' AND v_role <> ALL (ARRAY['OWNER','ADMIN','SUPER_ADMIN']) THEN
    RAISE EXCEPTION 'CREDIT_MANAGEMENT_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_step_up_auth() THEN
    RAISE EXCEPTION 'CREDIT_AAL2_REQUIRED' USING ERRCODE = '42501';
  END IF;
  RETURN v_role;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_wallet_entry_v1(
  p_company_id uuid, p_direction text, p_amount numeric, p_currency text,
  p_order_id uuid, p_proforma_invoice_id uuid, p_commercial_version_id uuid,
  p_source_channel text, p_source_reference text, p_reason text,
  p_correlation_id text, p_idempotency_key text, p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(entry_id uuid, balance numeric, already_applied boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid := coalesce(p_actor_id, auth.uid()); v_role text; v_fingerprint text;
  v_existing public.wallet_authority_idempotency%rowtype; v_entry public.wallet_transactions%rowtype; v_source_entry public.wallet_transactions%rowtype;
  v_balance numeric; v_order public.orders%rowtype; v_pi public.sales_order_proforma_invoices%rowtype;
BEGIN
  v_role := public.assert_credit_actor_v1(v_actor, 'SHORT_TERM');
  IF p_company_id IS NULL OR p_direction NOT IN ('credit','debit') OR p_amount IS NULL OR p_amount <= 0
     OR p_currency IS NULL OR upper(btrim(p_currency)) !~ '^[A-Z]{3}$'
     OR nullif(btrim(p_reason), '') IS NULL OR nullif(btrim(p_source_channel), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'WALLET_ENTRY_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := md5(concat_ws('|','WALLET',p_company_id,p_direction,p_amount,upper(btrim(p_currency)),p_order_id,p_proforma_invoice_id,p_commercial_version_id,btrim(p_source_channel),coalesce(p_source_reference,''),btrim(p_reason),btrim(p_correlation_id)));
  PERFORM pg_advisory_xact_lock(hashtextextended('wallet-company:' || p_company_id::text, 0));
  SELECT * INTO v_existing FROM public.wallet_authority_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'WALLET_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.entry_id, (v_existing.response->>'balance')::numeric, true; RETURN;
  END IF;
  PERFORM 1 FROM public.companies WHERE id = p_company_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMPANY_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF nullif(btrim(p_source_reference), '') IS NOT NULL THEN
    SELECT * INTO v_source_entry FROM public.wallet_transactions
     WHERE company_id = p_company_id AND direction = p_direction
       AND source_channel = btrim(p_source_channel)
       AND source_reference = btrim(p_source_reference)
     ORDER BY created_at, id LIMIT 1;
    IF FOUND THEN
      IF v_source_entry.actor_id IS DISTINCT FROM v_actor OR v_source_entry.amount IS DISTINCT FROM p_amount
         OR v_source_entry.order_id IS DISTINCT FROM p_order_id OR v_source_entry.proforma_invoice_id IS DISTINCT FROM p_proforma_invoice_id
         OR v_source_entry.commercial_version_id IS DISTINCT FROM p_commercial_version_id THEN
        RAISE EXCEPTION 'WALLET_SOURCE_DUPLICATE_CONFLICT' USING ERRCODE = '23505';
      END IF;
      v_balance := public.get_wallet_balance_v1(p_company_id);
      INSERT INTO public.wallet_authority_idempotency(idempotency_key,operation,request_fingerprint,company_id,entry_id,response,actor_id)
      VALUES (btrim(p_idempotency_key),upper(p_direction),v_fingerprint,p_company_id,v_source_entry.id,jsonb_build_object('entry_id',v_source_entry.id,'balance',v_balance),v_actor);
      RETURN QUERY SELECT v_source_entry.id, v_balance, true; RETURN;
    END IF;
  END IF;
  IF p_order_id IS NOT NULL OR p_proforma_invoice_id IS NOT NULL OR p_commercial_version_id IS NOT NULL THEN
    IF p_order_id IS NULL OR p_proforma_invoice_id IS NULL OR p_commercial_version_id IS NULL THEN
      RAISE EXCEPTION 'WALLET_COMMERCIAL_BINDING_INCOMPLETE' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id = p_proforma_invoice_id AND order_id = p_order_id FOR SHARE;
    IF NOT FOUND OR v_pi.commercial_version_id IS DISTINCT FROM p_commercial_version_id THEN
      RAISE EXCEPTION 'WALLET_COMMERCIAL_BINDING_MISMATCH' USING ERRCODE = '40001';
    END IF;
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id AND company_id = p_company_id FOR SHARE;
    IF NOT FOUND OR v_order.commercial_current_version IS DISTINCT FROM v_pi.commercial_version_number THEN
      RAISE EXCEPTION 'STALE_SALES_ORDER_VERSION' USING ERRCODE = '40001';
    END IF;
  END IF;
  v_balance := public.get_wallet_balance_v1(p_company_id);
  IF p_direction = 'debit' AND v_balance < p_amount THEN
    RAISE EXCEPTION 'WALLET_INSUFFICIENT_BALANCE' USING ERRCODE = '55000';
  END IF;
  INSERT INTO public.wallet_transactions(company_id,type,entry_type,amount,direction,currency,order_id,proforma_invoice_id,commercial_version_id,source_channel,source_reference,reason,actor_id,actor_role,correlation_id,idempotency_key)
  VALUES (p_company_id,p_direction,p_direction,p_amount,p_direction,upper(btrim(p_currency)),p_order_id,p_proforma_invoice_id,p_commercial_version_id,btrim(p_source_channel),nullif(btrim(p_source_reference),''),btrim(p_reason),v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key))
  RETURNING * INTO v_entry;
  v_balance := public.get_wallet_balance_v1(p_company_id);
  INSERT INTO public.wallet_authority_idempotency(idempotency_key,operation,request_fingerprint,company_id,entry_id,response,actor_id)
  VALUES (btrim(p_idempotency_key),upper(p_direction),v_fingerprint,p_company_id,v_entry.id,jsonb_build_object('entry_id',v_entry.id,'balance',v_balance),v_actor);
  RETURN QUERY SELECT v_entry.id, v_balance, false;
END;
$$;

REVOKE ALL ON FUNCTION public.get_wallet_balance_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wallet_balance_v1(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.assert_credit_actor_v1(uuid,text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.record_wallet_entry_v1(uuid,text,numeric,text,uuid,uuid,uuid,text,text,text,text,text,uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Credit request / decision RPCs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_credit_authority_v1(
  p_company_id uuid, p_order_id uuid, p_proforma_invoice_id uuid,
  p_commercial_version_id uuid, p_credit_type text, p_requested_amount numeric,
  p_source_channel text, p_source_reference text, p_reason text,
  p_correlation_id text, p_idempotency_key text, p_expires_at timestamptz DEFAULT NULL,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(request_id uuid, status text, already_requested boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid := coalesce(p_actor_id, auth.uid()); v_existing public.credit_authority_idempotency%rowtype;
  v_request public.credit_requests%rowtype; v_prior public.credit_requests%rowtype; v_fingerprint text; v_value numeric; v_paid numeric;
BEGIN
  IF v_actor IS NULL OR auth.uid() IS DISTINCT FROM v_actor OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'CREDIT_REQUEST_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_credit_type NOT IN ('short_term_so','long_term_limit') OR p_requested_amount IS NULL OR p_requested_amount <= 0
     OR p_company_id IS NULL OR p_order_id IS NULL OR p_proforma_invoice_id IS NULL OR p_commercial_version_id IS NULL
     OR nullif(btrim(p_source_channel), '') IS NULL OR nullif(btrim(p_reason), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'CREDIT_REQUEST_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := md5(concat_ws('|','REQUEST',p_company_id,p_order_id,p_proforma_invoice_id,p_commercial_version_id,p_credit_type,p_requested_amount,btrim(p_source_channel),coalesce(p_source_reference,''),btrim(p_reason),coalesce(p_expires_at::text,''),btrim(p_correlation_id)));
  PERFORM pg_advisory_xact_lock(hashtextextended('credit-company:' || p_company_id::text, 0));
  SELECT * INTO v_existing FROM public.credit_authority_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN RAISE EXCEPTION 'CREDIT_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505'; END IF;
    RETURN QUERY SELECT v_existing.request_id, (v_existing.response->>'status'), true; RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales_order_proforma_invoices p WHERE p.id = p_proforma_invoice_id AND p.order_id = p_order_id AND p.commercial_version_id = p_commercial_version_id AND p.status IN ('READY_FOR_ISSUE','ISSUED')) THEN
    RAISE EXCEPTION 'CREDIT_PI_BINDING_MISMATCH' USING ERRCODE = '40001';
  END IF;
  SELECT (p.frozen_commercial_snapshot->>'sales_order_value')::numeric INTO v_value
    FROM public.sales_order_proforma_invoices p
   WHERE p.id = p_proforma_invoice_id AND p.order_id = p_order_id AND p.commercial_version_id = p_commercial_version_id;
  IF v_value IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.orders o
     WHERE o.id = p_order_id AND o.company_id = p_company_id
       AND o.commercial_current_version = (SELECT version_number FROM public.sales_order_commercial_versions WHERE id = p_commercial_version_id AND order_id = p_order_id)
  ) THEN RAISE EXCEPTION 'CREDIT_COMMERCIAL_BINDING_MISMATCH' USING ERRCODE = '40001'; END IF;
  IF p_credit_type = 'short_term_so' THEN
    SELECT coalesce(sum(verified_amount),0) INTO v_paid FROM public.order_payments WHERE proforma_invoice_id = p_proforma_invoice_id AND status = 'verified';
    IF p_requested_amount > greatest(0, v_value - v_paid) THEN RAISE EXCEPTION 'CREDIT_REQUEST_EXCEEDS_REMAINING_SO_VALUE' USING ERRCODE = '22003'; END IF;
  END IF;
  IF nullif(btrim(p_source_reference), '') IS NOT NULL THEN
    SELECT * INTO v_prior FROM public.credit_requests
     WHERE company_id = p_company_id AND commercial_version_id = p_commercial_version_id
       AND credit_type = p_credit_type AND source_reference = btrim(p_source_reference)
       AND status IN ('pending','approved')
     ORDER BY created_at, id LIMIT 1;
    IF FOUND THEN
      IF v_prior.requested_amount IS DISTINCT FROM p_requested_amount OR v_prior.order_id IS DISTINCT FROM p_order_id
         OR v_prior.proforma_invoice_id IS DISTINCT FROM p_proforma_invoice_id THEN
        RAISE EXCEPTION 'CREDIT_SOURCE_DUPLICATE_CONFLICT' USING ERRCODE = '23505';
      END IF;
      INSERT INTO public.credit_authority_idempotency(idempotency_key,operation,request_fingerprint,request_id,response,actor_id)
      VALUES (btrim(p_idempotency_key),'REQUEST',v_fingerprint,v_prior.id,jsonb_build_object('request_id',v_prior.id,'status',v_prior.status),v_actor);
      RETURN QUERY SELECT v_prior.id, v_prior.status, true; RETURN;
    END IF;
  END IF;
  INSERT INTO public.credit_requests(company_id,requested_by,credit_type,requested_amount,status,notes,order_id,proforma_invoice_id,commercial_version_id,source_channel,source_reference,actor_role,correlation_id,idempotency_key,expires_at)
  VALUES (p_company_id,v_actor,p_credit_type,p_requested_amount,'pending',btrim(p_reason),p_order_id,p_proforma_invoice_id,p_commercial_version_id,btrim(p_source_channel),nullif(btrim(p_source_reference),''),upper(public.get_user_role(v_actor)),btrim(p_correlation_id),btrim(p_idempotency_key),p_expires_at)
  RETURNING * INTO v_request;
  INSERT INTO public.credit_authority_idempotency(idempotency_key,operation,request_fingerprint,request_id,response,actor_id)
  VALUES (btrim(p_idempotency_key),'REQUEST',v_fingerprint,v_request.id,jsonb_build_object('request_id',v_request.id,'status',v_request.status),v_actor);
  RETURN QUERY SELECT v_request.id, v_request.status, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_credit_request_v1(
  p_request_id uuid, p_approve boolean, p_reason text, p_source_channel text,
  p_correlation_id text, p_idempotency_key text, p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(request_id uuid, status text, already_decided boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_actor uuid := coalesce(p_actor_id, auth.uid()); v_request public.credit_requests%rowtype;
  v_existing public.credit_authority_idempotency%rowtype; v_role text; v_fingerprint text; v_status text; v_response jsonb;
BEGIN
  SELECT * INTO v_request FROM public.credit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_REQUEST_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('credit-decision:' || v_request.company_id::text, 0));
  v_role := public.assert_credit_actor_v1(v_actor, CASE WHEN v_request.credit_type = 'short_term_so' THEN 'SHORT_TERM' ELSE 'LONG_TERM' END);
  IF nullif(btrim(p_reason), '') IS NULL OR nullif(btrim(p_source_channel), '') IS NULL OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN RAISE EXCEPTION 'CREDIT_DECISION_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  v_fingerprint := md5(concat_ws('|',CASE WHEN p_approve THEN 'APPROVE' ELSE 'REJECT' END,p_request_id,btrim(p_reason),btrim(p_source_channel),btrim(p_correlation_id)));
  SELECT * INTO v_existing FROM public.credit_authority_idempotency WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN RAISE EXCEPTION 'CREDIT_IDEMPOTENCY_CONFLICT' USING ERRCODE = '23505'; END IF;
    RETURN QUERY SELECT v_existing.request_id, (v_existing.response->>'status'), true; RETURN;
  END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'CREDIT_REQUEST_NOT_PENDING' USING ERRCODE = '55000'; END IF;
  IF v_request.expires_at IS NOT NULL AND v_request.expires_at <= statement_timestamp() THEN RAISE EXCEPTION 'CREDIT_REQUEST_EXPIRED' USING ERRCODE = '55000'; END IF;
  IF p_approve AND EXISTS (SELECT 1 FROM public.credit_requests x WHERE x.id <> v_request.id AND x.company_id = v_request.company_id AND x.proforma_invoice_id = v_request.proforma_invoice_id AND x.commercial_version_id = v_request.commercial_version_id AND x.credit_type = v_request.credit_type AND x.status = 'approved') THEN
    RAISE EXCEPTION 'CREDIT_REQUEST_ALREADY_APPROVED' USING ERRCODE = '55000';
  END IF;
  v_status := CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  INSERT INTO public.credit_request_mutation_scopes(backend_pid,transaction_id,request_id) VALUES (pg_backend_pid(),txid_current(),p_request_id);
  UPDATE public.credit_requests SET status=v_status, decided_by=v_actor, decided_role=v_role, decided_at=statement_timestamp(), decision_reason=btrim(p_reason), decision_source=btrim(p_source_channel) WHERE id=p_request_id;
  INSERT INTO public.credit_decision_audit(request_id,old_status,new_status,amount,credit_type,company_id,order_id,proforma_invoice_id,commercial_version_id,actor_id,actor_role,reason,source_channel,source_reference,correlation_id,idempotency_key)
  VALUES (p_request_id,'pending',v_status,v_request.requested_amount,v_request.credit_type,v_request.company_id,v_request.order_id,v_request.proforma_invoice_id,v_request.commercial_version_id,v_actor,v_role,btrim(p_reason),btrim(p_source_channel),v_request.source_reference,btrim(p_correlation_id),btrim(p_idempotency_key));
  DELETE FROM public.credit_request_mutation_scopes WHERE backend_pid=pg_backend_pid() AND transaction_id=txid_current() AND request_id=p_request_id;
  v_response := jsonb_build_object('request_id',p_request_id,'status',v_status);
  INSERT INTO public.credit_authority_idempotency(idempotency_key,operation,request_fingerprint,request_id,response,actor_id) VALUES (btrim(p_idempotency_key),CASE WHEN p_approve THEN 'APPROVE' ELSE 'REJECT' END,v_fingerprint,p_request_id,v_response,v_actor);
  RETURN QUERY SELECT p_request_id,v_status,false;
END;
$$;

REVOKE ALL ON FUNCTION public.request_credit_authority_v1(uuid,uuid,uuid,uuid,text,numeric,text,text,text,text,text,timestamptz,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.request_credit_authority_v1(uuid,uuid,uuid,uuid,text,numeric,text,text,text,text,text,timestamptz,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_credit_request_v1(uuid,boolean,text,text,text,text,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.decide_credit_request_v1(uuid,boolean,text,text,text,text,uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Factual exposure only.  This function intentionally returns no clearance,
-- release, dispatch or manufacturing decision.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_credit_exposure_facts_v1(
  p_company_id uuid, p_pi_id uuid, p_commercial_version_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE v_pi public.sales_order_proforma_invoices%rowtype; v_order public.orders%rowtype;
  v_payment jsonb; v_wallet numeric; v_short numeric; v_long numeric; v_value numeric;
BEGIN
  IF auth.uid() IS NULL OR (NOT public.is_internal_staff(auth.uid()) AND p_company_id IS DISTINCT FROM public.auth_buyer_company_id()) THEN
    RAISE EXCEPTION 'CREDIT_EXPOSURE_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id=p_pi_id AND commercial_version_id=p_commercial_version_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_EXPOSURE_PI_REQUIRED' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=v_pi.order_id AND company_id=p_company_id;
  IF NOT FOUND OR v_order.commercial_current_version IS DISTINCT FROM v_pi.commercial_version_number THEN RAISE EXCEPTION 'CREDIT_EXPOSURE_BINDING_MISMATCH' USING ERRCODE = '40001'; END IF;
  v_value := (v_pi.frozen_commercial_snapshot->>'sales_order_value')::numeric;
  IF v_value IS NULL OR md5(v_pi.frozen_commercial_snapshot::text) IS DISTINCT FROM v_pi.frozen_snapshot_fingerprint THEN RAISE EXCEPTION 'CREDIT_EXPOSURE_COMMERCIAL_TRUTH_INCOMPLETE' USING ERRCODE = 'P0001'; END IF;
  v_payment := public.get_order_payment_facts_v1(p_pi_id);
  v_wallet := public.get_wallet_balance_v1(p_company_id);
  SELECT coalesce(sum(requested_amount),0) INTO v_short FROM public.credit_requests WHERE company_id=p_company_id AND credit_type='short_term_so' AND status='approved' AND (expires_at IS NULL OR expires_at > statement_timestamp());
  SELECT coalesce(sum(requested_amount),0) INTO v_long FROM public.credit_requests WHERE company_id=p_company_id AND credit_type='long_term_limit' AND status='approved' AND (expires_at IS NULL OR expires_at > statement_timestamp());
  RETURN jsonb_build_object(
    'company_id',p_company_id,'order_id',v_pi.order_id,'pi_id',p_pi_id,
    'commercial_version_id',p_commercial_version_id,'commercial_version_number',v_pi.commercial_version_number,
    'commercial_value',v_value,'verified_payment_total',coalesce((v_payment->>'verified_total')::numeric,0),
    'wallet_balance',v_wallet,'approved_short_term_credit',v_short,
    'approved_long_term_credit',v_long,'proven_obligation_total',v_short+v_long,
    'payment_facts',v_payment,'facts_as_of',statement_timestamp(),
    'exposure_facts_only',true,'clearance_decision',null
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_credit_exposure_facts_v1(uuid,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_credit_exposure_facts_v1(uuid,uuid,uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_credit_audit_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN RAISE EXCEPTION 'CREDIT_DECISION_AUDIT_IMMUTABLE' USING ERRCODE='42501'; END; $$;
DROP TRIGGER IF EXISTS trg_credit_decision_audit_immutable ON public.credit_decision_audit;
CREATE TRIGGER trg_credit_decision_audit_immutable BEFORE UPDATE OR DELETE ON public.credit_decision_audit FOR EACH ROW EXECUTE FUNCTION public.prevent_credit_audit_mutation();
REVOKE ALL ON FUNCTION public.prevent_credit_audit_mutation() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.wallet_transactions IS 'PF-6B canonical append-only wallet ledger. Legacy rows remain historical evidence; new writes use record_wallet_entry_v1().';
COMMENT ON TABLE public.credit_requests IS 'PF-6B governed credit requests bound to one exact SO/PI/commercial version; direct table writes are forbidden.';
COMMENT ON FUNCTION public.get_credit_exposure_facts_v1(uuid,uuid,uuid) IS 'Factual credit exposure components only. Never returns Finance Clearance or Operations/Manufacturing release.';
