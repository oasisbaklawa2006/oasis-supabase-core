-- PF-6A: canonical payment evidence and Finance-verification authority.
--
-- order_payments remains the single canonical payment projection.  The
-- supporting tables below are only append-only audit, idempotency, and
-- transaction-scoped mutation controls; they are not a second ledger.

ALTER TABLE public.order_payments
  ADD COLUMN IF NOT EXISTS proforma_invoice_id uuid
    REFERENCES public.sales_order_proforma_invoices(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS commercial_version_id uuid
    REFERENCES public.sales_order_commercial_versions(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS source_channel text,
  ADD COLUMN IF NOT EXISTS source_reference text,
  ADD COLUMN IF NOT EXISTS currency text,
  ADD COLUMN IF NOT EXISTS payment_mode text,
  ADD COLUMN IF NOT EXISTS payer_reference text,
  ADD COLUMN IF NOT EXISTS proof_evidence_reference text,
  ADD COLUMN IF NOT EXISTS proof_received_at timestamptz,
  ADD COLUMN IF NOT EXISTS proof_received_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS verified_amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS verified_reference text,
  ADD COLUMN IF NOT EXISTS verification_evidence_reference text,
  ADD COLUMN IF NOT EXISTS rejected_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS rejected_at timestamptz,
  ADD COLUMN IF NOT EXISTS reversal_status text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS reversed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reversed_at timestamptz,
  ADD COLUMN IF NOT EXISTS reversal_reason text,
  ADD COLUMN IF NOT EXISTS correlation_id text,
  ADD COLUMN IF NOT EXISTS idempotency_key text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'order_payments_authority_binding_shape'
       AND conrelid = 'public.order_payments'::regclass
  ) THEN
    ALTER TABLE public.order_payments
      ADD CONSTRAINT order_payments_authority_binding_shape CHECK (
        (proforma_invoice_id IS NULL AND commercial_version_id IS NULL)
        OR (proforma_invoice_id IS NOT NULL AND commercial_version_id IS NOT NULL)
      );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'order_payments_reversal_status_check'
       AND conrelid = 'public.order_payments'::regclass
  ) THEN
    ALTER TABLE public.order_payments
      ADD CONSTRAINT order_payments_reversal_status_check
      CHECK (reversal_status IS NULL OR reversal_status IN ('none', 'pending', 'reversed'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'order_payments_governed_shape_check'
       AND conrelid = 'public.order_payments'::regclass
  ) THEN
    ALTER TABLE public.order_payments
      ADD CONSTRAINT order_payments_governed_shape_check CHECK (
        idempotency_key IS NULL
        OR (
          proforma_invoice_id IS NOT NULL
          AND commercial_version_id IS NOT NULL
          AND source_channel IS NOT NULL
          AND source_reference IS NOT NULL
          AND currency IS NOT NULL
          AND proof_evidence_reference IS NOT NULL
          AND proof_received_at IS NOT NULL
          AND (
            (status = 'uploaded'
             AND verified_amount IS NULL AND verified_by IS NULL AND verified_at IS NULL
             AND verification_evidence_reference IS NULL
             AND rejected_by IS NULL AND rejected_at IS NULL)
            OR
            (status = 'verified'
             AND verified_amount IS NOT NULL AND verified_amount > 0
             AND verified_by IS NOT NULL AND verified_at IS NOT NULL
             AND verification_evidence_reference IS NOT NULL
             AND rejected_by IS NULL AND rejected_at IS NULL
             AND rejection_reason IS NULL)
            OR
            (status = 'rejected'
             AND rejected_by IS NOT NULL AND rejected_at IS NOT NULL
             AND rejection_reason IS NOT NULL AND length(btrim(rejection_reason)) > 0
             AND verified_amount IS NULL AND verified_by IS NULL AND verified_at IS NULL
             AND verification_evidence_reference IS NULL)
          )
        )
      );
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.order_payment_authority_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('RECEIVE', 'VERIFY', 'REJECT')),
  payment_id uuid NOT NULL REFERENCES public.order_payments(id) ON DELETE RESTRICT,
  request_fingerprint text NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE IF NOT EXISTS public.order_payment_authority_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL REFERENCES public.order_payments(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  proforma_invoice_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id) ON DELETE RESTRICT,
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id) ON DELETE RESTRICT,
  action text NOT NULL CHECK (action IN ('RECEIVED', 'VERIFIED', 'REJECTED', 'REVERSED')),
  prior_status text,
  new_status text NOT NULL,
  submitted_amount numeric(14,2),
  verified_amount numeric(14,2),
  currency text,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  actor_role text NOT NULL,
  reason text,
  source_channel text NOT NULL,
  source_reference text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE INDEX IF NOT EXISTS order_payment_authority_audit_payment_idx
  ON public.order_payment_authority_audit (payment_id, created_at, id);
CREATE INDEX IF NOT EXISTS order_payment_authority_audit_pi_idx
  ON public.order_payment_authority_audit (proforma_invoice_id, created_at, id);
CREATE INDEX IF NOT EXISTS order_payments_authority_pi_idx
  ON public.order_payments (proforma_invoice_id, status, created_at, id);
CREATE INDEX IF NOT EXISTS order_payments_authority_reference_lookup_idx
  ON public.order_payments (lower(btrim(reference_no)))
  WHERE reference_no IS NOT NULL AND coalesce(status, '') <> 'rejected';
CREATE INDEX IF NOT EXISTS order_payments_authority_proof_lookup_idx
  ON public.order_payments (lower(btrim(proof_evidence_reference)))
  WHERE proof_evidence_reference IS NOT NULL AND coalesce(status, '') <> 'rejected';

CREATE TABLE IF NOT EXISTS public.order_payment_authority_scopes (
  scope_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  backend_pid bigint NOT NULL,
  transaction_id bigint NOT NULL,
  operation text NOT NULL CHECK (operation IN ('RECEIVE', 'VERIFY', 'REJECT')),
  payment_id uuid REFERENCES public.order_payments(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

ALTER TABLE public.order_payment_authority_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_payment_authority_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_payment_authority_scopes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.order_payment_authority_idempotency,
  public.order_payment_authority_audit,
  public.order_payment_authority_scopes
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.order_payment_authority_audit TO authenticated, service_role;
DROP POLICY IF EXISTS order_payment_authority_audit_read ON public.order_payment_authority_audit;
CREATE POLICY order_payment_authority_audit_read
  ON public.order_payment_authority_audit
  FOR SELECT TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.orders o
       WHERE o.id = order_payment_authority_audit.order_id
         AND o.company_id = public.auth_buyer_company_id()
    )
  );

-- PF-6A governed payment writes occur only inside the RPCs below. Preserve
-- only the pre-existing credit-rescue compatibility path: a NULL idempotency
-- key is acceptable solely for rescue uploads and the established staff-only
-- uploaded->verified rescue transition. Ordinary payment evidence cannot use
-- missing fields as an authority bypass; service_role and anonymous/public
-- direct mutation remain closed.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.order_payments FROM PUBLIC, anon, service_role;
GRANT SELECT ON TABLE public.order_payments TO authenticated, service_role;

DROP POLICY IF EXISTS "Admins manage payments" ON public.order_payments;
DROP POLICY IF EXISTS "Staff manage order payments" ON public.order_payments;
DROP POLICY IF EXISTS "Buyers insert own company payments" ON public.order_payments;

CREATE POLICY "Admins manage payments"
  ON public.order_payments
  FOR SELECT TO authenticated
  USING (public.get_user_role(auth.uid()) = ANY (ARRAY['admin', 'super_admin']));

CREATE POLICY "Staff manage order payments"
  ON public.order_payments
  FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()) OR public.get_user_role(auth.uid()) = ANY (ARRAY['admin', 'super_admin']));

CREATE POLICY "Buyers insert own company payments"
  ON public.order_payments
  FOR INSERT TO authenticated
  WITH CHECK (
    payment_type = 'rescue'
    AND idempotency_key IS NULL
    AND status = 'uploaded'
    AND verified_by IS NULL
    AND verified_at IS NULL
    AND verified_amount IS NULL
    AND verification_evidence_reference IS NULL
    AND rejected_by IS NULL
    AND rejected_at IS NULL
    AND rejection_reason IS NULL
    AND NOT (created_by IS DISTINCT FROM auth.uid())
    AND NOT (company_id IS DISTINCT FROM public.auth_buyer_company_id())
    AND EXISTS (
      SELECT 1 FROM public.orders o
       WHERE o.id = order_payments.order_id
         AND o.company_id = public.auth_buyer_company_id()
    )
  );

CREATE POLICY "Staff insert legacy credit rescue payments"
  ON public.order_payments
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_internal_staff(auth.uid())
    AND payment_type = 'rescue'
    AND idempotency_key IS NULL
    AND status = 'uploaded'
  );

CREATE POLICY "Staff update legacy credit rescue payments"
  ON public.order_payments
  FOR UPDATE TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    AND payment_type = 'rescue'
    AND idempotency_key IS NULL
  )
  WITH CHECK (
    public.is_internal_staff(auth.uid())
    AND payment_type = 'rescue'
    AND idempotency_key IS NULL
    AND status IN ('uploaded', 'verified')
  );

CREATE POLICY "Staff delete legacy credit rescue payments"
  ON public.order_payments
  FOR DELETE TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    AND payment_type = 'rescue'
    AND idempotency_key IS NULL
  );

CREATE OR REPLACE FUNCTION public.guard_order_payment_authority_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  -- Migrations and maintenance run without a user identity. Every governed
  -- (idempotency-keyed) mutation must pass through a scope.
  IF auth.uid() IS NULL
     AND pg_catalog.pg_has_role(
       current_user,
       (SELECT pg_catalog.pg_get_userbyid(c.relowner)
          FROM pg_catalog.pg_class c
         WHERE c.oid = 'public.order_payments'::regclass),
       'USAGE') THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'INSERT'
     AND NEW.idempotency_key IS NULL
     AND NEW.payment_type = 'rescue'
     AND NEW.status = 'uploaded' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.idempotency_key IS NULL AND NEW.idempotency_key IS NULL
     AND OLD.payment_type = 'rescue' AND NEW.payment_type = 'rescue'
     AND OLD.status = 'uploaded' AND NEW.status IN ('uploaded', 'verified')
     AND public.is_internal_staff(auth.uid()) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE'
     AND OLD.idempotency_key IS NULL
     AND OLD.payment_type = 'rescue'
     AND public.is_internal_staff(auth.uid()) THEN
    RETURN OLD;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.order_payment_authority_scopes s
     WHERE s.backend_pid = pg_backend_pid()
       AND s.transaction_id = txid_current()
       AND (s.payment_id IS NULL OR s.payment_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END)
  ) THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_order_payment_authority_mutation ON public.order_payments;
CREATE TRIGGER trg_guard_order_payment_authority_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.order_payments
  FOR EACH ROW EXECUTE FUNCTION public.guard_order_payment_authority_mutation();

CREATE OR REPLACE FUNCTION public.guard_order_payment_authority_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, auth
AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_AUDIT_IMMUTABLE' USING ERRCODE = '55000';
  END IF;
  IF auth.uid() IS NULL
     AND pg_catalog.pg_has_role(
       current_user,
       (SELECT pg_catalog.pg_get_userbyid(c.relowner)
          FROM pg_catalog.pg_class c
         WHERE c.oid = 'public.order_payment_authority_audit'::regclass),
       'USAGE') THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.order_payment_authority_scopes s
     WHERE s.backend_pid = pg_backend_pid()
       AND s.transaction_id = txid_current()
       AND (s.payment_id IS NULL OR s.payment_id = NEW.payment_id)
       AND s.actor_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_AUDIT_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_order_payment_authority_audit_mutation
  ON public.order_payment_authority_audit;
CREATE TRIGGER trg_guard_order_payment_authority_audit_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.order_payment_authority_audit
  FOR EACH ROW EXECUTE FUNCTION public.guard_order_payment_authority_audit_mutation();

CREATE OR REPLACE FUNCTION public.assert_order_payment_binding_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid
) RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_order public.orders%rowtype;
BEGIN
  SELECT * INTO v_pi
    FROM public.sales_order_proforma_invoices
   WHERE id = p_pi_id AND order_id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_PI_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  IF v_pi.status NOT IN ('READY_FOR_ISSUE', 'ISSUED') THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_PI_NOT_PAYABLE' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_version
    FROM public.sales_order_commercial_versions
   WHERE id = p_commercial_version_id AND order_id = p_order_id;
  IF NOT FOUND OR v_pi.commercial_version_id IS DISTINCT FROM v_version.id
     OR v_pi.commercial_version_number IS DISTINCT FROM v_version.version_number
     OR v_pi.frozen_snapshot_fingerprint IS DISTINCT FROM v_version.snapshot_fingerprint
     OR v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
     OR md5(v_version.commercial_snapshot::text) IS DISTINCT FROM v_version.snapshot_fingerprint
     OR v_version.commercial_snapshot ->> 'order_id' IS DISTINCT FROM p_order_id::text
     OR jsonb_typeof(v_version.commercial_snapshot -> 'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_version.commercial_snapshot -> 'lines') = 0 THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_COMMERCIAL_VERSION_MISMATCH' USING ERRCODE = '40001';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_ORDER_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_order_payment_proof_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_payment_type text,
  p_submitted_amount numeric,
  p_currency text,
  p_payment_mode text,
  p_external_reference text,
  p_payer_reference text,
  p_proof_evidence_reference text,
  p_source_channel text,
  p_source_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(payment_id uuid, status text, already_recorded boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_order public.orders%rowtype;
  v_payment public.order_payments%rowtype;
  v_existing public.order_payment_authority_idempotency%rowtype;
  v_fingerprint text;
  v_ref text := nullif(btrim(p_external_reference), '');
  v_proof_ref text := nullif(btrim(p_proof_evidence_reference), '');
  v_source text := upper(nullif(btrim(p_source_channel), ''));
  v_currency text := upper(nullif(btrim(p_currency), ''));
  v_scope uuid;
  v_prior uuid;
  v_prior_rejected uuid;
  v_prior_proof uuid;
  v_response jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_ACTOR_MISMATCH' USING ERRCODE = '42501';
  END IF;
  IF p_order_id IS NULL OR p_pi_id IS NULL OR p_commercial_version_id IS NULL
     OR p_submitted_amount IS NULL OR p_submitted_amount <= 0
     OR p_payment_type NOT IN ('advance', 'balance', 'adjustment')
     OR v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$'
     OR nullif(btrim(p_proof_evidence_reference), '') IS NULL
     OR v_source IS NULL OR nullif(btrim(p_source_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_PROOF_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM public.assert_order_payment_binding_v1(p_order_id, p_pi_id, p_commercial_version_id);
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT public.is_internal_staff(v_actor)
     AND v_order.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_COMPANY_MISMATCH' USING ERRCODE = '42501';
  END IF;

  v_fingerprint := encode(extensions.digest(
    jsonb_build_object('operation', 'RECEIVE', 'order_id', p_order_id,
      'pi_id', p_pi_id, 'commercial_version_id', p_commercial_version_id,
      'payment_type', p_payment_type, 'submitted_amount', p_submitted_amount,
      'currency', v_currency, 'payment_mode', p_payment_mode,
      'external_reference', v_ref, 'payer_reference', p_payer_reference,
      'proof_evidence_reference', p_proof_evidence_reference,
      'source_channel', v_source, 'source_reference', p_source_reference,
      'correlation_id', p_correlation_id)::text, 'sha256'), 'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended('order-payment:' || p_order_id::text, 0));
  IF v_ref IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('order-payment-reference:' || lower(v_ref), 0));
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('order-payment-proof:' || lower(v_proof_ref), 0));

  SELECT * INTO v_existing FROM public.order_payment_authority_idempotency
   WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_IDEMPOTENCY_ACTOR_CONFLICT' USING ERRCODE = '42501';
    END IF;
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.payment_id,
      (v_existing.response ->> 'status')::text, true;
    RETURN;
  END IF;

  IF v_ref IS NOT NULL THEN
    SELECT p.id INTO v_prior FROM public.order_payments p
     WHERE lower(btrim(p.reference_no)) = lower(v_ref)
       AND coalesce(p.status, '') <> 'rejected'
     ORDER BY p.created_at, p.id LIMIT 1;
    IF v_prior IS NOT NULL THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_REFERENCE_CONFLICT' USING ERRCODE = '23505';
    END IF;
    SELECT p.id INTO v_prior_rejected FROM public.order_payments p
     WHERE lower(btrim(p.reference_no)) = lower(v_ref)
       AND p.status = 'rejected'
     ORDER BY p.created_at, p.id LIMIT 1;
  END IF;
  SELECT p.id INTO v_prior_proof FROM public.order_payments p
   WHERE lower(btrim(p.proof_evidence_reference)) = lower(v_proof_ref)
     AND coalesce(p.status, '') <> 'rejected'
   ORDER BY p.created_at, p.id LIMIT 1;
  IF v_prior_proof IS NOT NULL THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_PROOF_CONFLICT' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.order_payment_authority_scopes(
    backend_pid, transaction_id, operation, actor_id
  ) VALUES (pg_backend_pid(), txid_current(), 'RECEIVE', v_actor)
  RETURNING scope_id INTO v_scope;

  INSERT INTO public.order_payments(
    order_id, company_id, payment_type, amount, reference_no, created_by,
    status, proforma_invoice_id, commercial_version_id, source_channel,
    source_reference, currency, payment_mode, payer_reference,
    proof_evidence_reference, proof_received_at, proof_received_by,
    correlation_id, idempotency_key
  ) VALUES (
    p_order_id, v_order.company_id, p_payment_type, round(p_submitted_amount, 2),
    v_ref, v_actor, 'uploaded', p_pi_id, p_commercial_version_id, v_source,
    btrim(p_source_reference), v_currency, nullif(btrim(p_payment_mode), ''),
    nullif(btrim(p_payer_reference), ''), btrim(p_proof_evidence_reference),
    statement_timestamp(), v_actor, btrim(p_correlation_id), btrim(p_idempotency_key)
  ) RETURNING * INTO v_payment;
  UPDATE public.order_payment_authority_scopes SET payment_id = v_payment.id WHERE scope_id = v_scope;

  INSERT INTO public.order_payment_authority_audit(
    payment_id, order_id, proforma_invoice_id, commercial_version_id, action,
    prior_status, new_status, submitted_amount, currency, actor_id, actor_role,
    source_channel, source_reference, correlation_id, idempotency_key, metadata
  ) VALUES (
    v_payment.id, p_order_id, p_pi_id, p_commercial_version_id, 'RECEIVED',
    NULL, 'uploaded', v_payment.amount, v_currency, v_actor,
    coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN'), v_source, btrim(p_source_reference),
    btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('payment_type', p_payment_type, 'payment_mode', p_payment_mode,
      'external_reference', v_ref, 'prior_rejected_payment_id', v_prior_rejected)
  );
  v_response := jsonb_build_object('payment_id', v_payment.id, 'status', 'uploaded');
  INSERT INTO public.order_payment_authority_idempotency(
    idempotency_key, operation, payment_id, request_fingerprint, actor_id, response
  ) VALUES (btrim(p_idempotency_key), 'RECEIVE', v_payment.id, v_fingerprint, v_actor, v_response);
  DELETE FROM public.order_payment_authority_scopes WHERE scope_id = v_scope;
  RETURN QUERY SELECT v_payment.id, 'uploaded'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_order_payment_v1(
  p_payment_id uuid,
  p_verified_amount numeric,
  p_verified_reference text,
  p_verification_evidence_reference text,
  p_reason text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(payment_id uuid, status text, already_verified boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_payment public.order_payments%rowtype;
  v_existing public.order_payment_authority_idempotency%rowtype;
  v_fingerprint text;
  v_verified_ref text;
  v_scope uuid;
  v_response jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid()
     OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_FINANCE_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_order_transition_role('finance_review');
  IF NOT public.has_step_up_auth() THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_AAL2_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_payment_id IS NULL OR p_verified_amount IS NULL OR p_verified_amount <= 0
     OR nullif(btrim(p_verification_evidence_reference), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_VERIFICATION_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('order-payment-verify:' || p_payment_id::text, 0));
  SELECT * INTO v_payment FROM public.order_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.assert_order_payment_binding_v1(v_payment.order_id, v_payment.proforma_invoice_id, v_payment.commercial_version_id);
  v_fingerprint := encode(extensions.digest(
    jsonb_build_object('operation', 'VERIFY', 'payment_id', p_payment_id,
      'verified_amount', p_verified_amount, 'verified_reference', p_verified_reference,
      'verification_evidence_reference', p_verification_evidence_reference,
      'reason', p_reason, 'correlation_id', p_correlation_id)::text,
    'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.order_payment_authority_idempotency
   WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_IDEMPOTENCY_ACTOR_CONFLICT' USING ERRCODE = '42501';
    END IF;
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.payment_id, (v_existing.response ->> 'status')::text, true;
    RETURN;
  END IF;
  IF v_payment.status <> 'uploaded' THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_NOT_PENDING_VERIFICATION' USING ERRCODE = '55000';
  END IF;
  v_verified_ref := nullif(btrim(p_verified_reference), '');
  IF v_verified_ref IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('order-payment-verified-reference:' || lower(v_verified_ref), 0));
    IF EXISTS (
      SELECT 1 FROM public.order_payments p
       WHERE p.id <> p_payment_id AND p.status = 'verified'
         AND lower(btrim(coalesce(p.verified_reference, p.reference_no))) = lower(v_verified_ref)
    ) THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_VERIFIED_REFERENCE_CONFLICT' USING ERRCODE = '23505';
    END IF;
  END IF;
  INSERT INTO public.order_payment_authority_scopes(
    backend_pid, transaction_id, operation, payment_id, actor_id
  ) VALUES (pg_backend_pid(), txid_current(), 'VERIFY', p_payment_id, v_actor)
  RETURNING scope_id INTO v_scope;
  UPDATE public.order_payments SET
    status = 'verified', verified_amount = round(p_verified_amount, 2),
    verified_reference = v_verified_ref,
    verification_evidence_reference = btrim(p_verification_evidence_reference),
    verified_by = v_actor, verified_at = statement_timestamp(),
    rejection_reason = null, rejected_by = null, rejected_at = null
   WHERE id = p_payment_id;
  INSERT INTO public.order_payment_authority_audit(
    payment_id, order_id, proforma_invoice_id, commercial_version_id, action,
    prior_status, new_status, submitted_amount, verified_amount, currency,
    actor_id, actor_role, reason, source_channel, source_reference,
    correlation_id, idempotency_key, metadata
  ) VALUES (
    p_payment_id, v_payment.order_id, v_payment.proforma_invoice_id,
    v_payment.commercial_version_id, 'VERIFIED', 'uploaded', 'verified',
    v_payment.amount, round(p_verified_amount, 2), v_payment.currency, v_actor,
    coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN'), nullif(btrim(p_reason), ''),
    v_payment.source_channel, v_payment.source_reference, btrim(p_correlation_id),
    btrim(p_idempotency_key), jsonb_build_object('verified_reference', p_verified_reference,
      'payment_release_mutated', false)
  );
  v_response := jsonb_build_object('payment_id', p_payment_id, 'status', 'verified',
    'verified_amount', round(p_verified_amount, 2));
  INSERT INTO public.order_payment_authority_idempotency(
    idempotency_key, operation, payment_id, request_fingerprint, actor_id, response
  ) VALUES (btrim(p_idempotency_key), 'VERIFY', p_payment_id, v_fingerprint, v_actor, v_response);
  DELETE FROM public.order_payment_authority_scopes WHERE scope_id = v_scope;
  RETURN QUERY SELECT p_payment_id, 'verified'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_order_payment_v1(
  p_payment_id uuid,
  p_reason text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(payment_id uuid, status text, already_rejected boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_payment public.order_payments%rowtype;
  v_existing public.order_payment_authority_idempotency%rowtype;
  v_fingerprint text;
  v_scope uuid;
  v_response jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid()
     OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_FINANCE_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_order_transition_role('finance_review');
  IF NOT public.has_step_up_auth() THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_AAL2_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_payment_id IS NULL OR length(btrim(coalesce(p_reason, ''))) < 5
     OR nullif(btrim(p_correlation_id), '') IS NULL
     OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_REJECTION_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('order-payment-reject:' || p_payment_id::text, 0));
  SELECT * INTO v_payment FROM public.order_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_PAYMENT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  PERFORM public.assert_order_payment_binding_v1(v_payment.order_id, v_payment.proforma_invoice_id, v_payment.commercial_version_id);
  v_fingerprint := encode(extensions.digest(
    jsonb_build_object('operation', 'REJECT', 'payment_id', p_payment_id,
      'reason', btrim(p_reason), 'correlation_id', p_correlation_id)::text,
    'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.order_payment_authority_idempotency
   WHERE idempotency_key = btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_IDEMPOTENCY_ACTOR_CONFLICT' USING ERRCODE = '42501';
    END IF;
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'ORDER_PAYMENT_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.payment_id, (v_existing.response ->> 'status')::text, true;
    RETURN;
  END IF;
  IF v_payment.status <> 'uploaded' THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_NOT_PENDING_REVIEW' USING ERRCODE = '55000';
  END IF;
  INSERT INTO public.order_payment_authority_scopes(
    backend_pid, transaction_id, operation, payment_id, actor_id
  ) VALUES (pg_backend_pid(), txid_current(), 'REJECT', p_payment_id, v_actor)
  RETURNING scope_id INTO v_scope;
  UPDATE public.order_payments SET
    status = 'rejected', rejection_reason = btrim(p_reason),
    rejected_by = v_actor, rejected_at = statement_timestamp(),
    verified_amount = null, verified_reference = null,
    verification_evidence_reference = null, verified_by = null, verified_at = null
   WHERE id = p_payment_id;
  INSERT INTO public.order_payment_authority_audit(
    payment_id, order_id, proforma_invoice_id, commercial_version_id, action,
    prior_status, new_status, submitted_amount, currency, actor_id, actor_role,
    reason, source_channel, source_reference, correlation_id, idempotency_key
  ) VALUES (
    p_payment_id, v_payment.order_id, v_payment.proforma_invoice_id,
    v_payment.commercial_version_id, 'REJECTED', 'uploaded', 'rejected',
    v_payment.amount, v_payment.currency, v_actor, coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN'),
    btrim(p_reason), v_payment.source_channel, v_payment.source_reference,
    btrim(p_correlation_id), btrim(p_idempotency_key)
  );
  v_response := jsonb_build_object('payment_id', p_payment_id, 'status', 'rejected');
  INSERT INTO public.order_payment_authority_idempotency(
    idempotency_key, operation, payment_id, request_fingerprint, actor_id, response
  ) VALUES (btrim(p_idempotency_key), 'REJECT', p_payment_id, v_fingerprint, v_actor, v_response);
  DELETE FROM public.order_payment_authority_scopes WHERE scope_id = v_scope;
  RETURN QUERY SELECT p_payment_id, 'rejected'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_whatsapp_payment_proof_in_canonical_ledger_v1(
  p_payment_proof_id uuid,
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_payment_type text,
  p_currency text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(payment_id uuid, status text, already_recorded boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_claimed_amount numeric;
  v_claimed_reference text;
  v_promoted_order_id uuid;
  v_case_id uuid;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid()
     OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_WHATSAPP_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  SELECT pp.case_id, pp.claimed_amount, pp.claimed_reference, d.promoted_order_id
    INTO v_case_id, v_claimed_amount, v_claimed_reference, v_promoted_order_id
    FROM public.whatsapp_case_payment_proofs pp
    JOIN public.whatsapp_communication_cases c ON c.id = pp.case_id
    LEFT JOIN public.sales_order_drafts d ON d.id = c.sales_order_draft_id
   WHERE pp.id = p_payment_proof_id;
  IF NOT FOUND OR v_promoted_order_id IS DISTINCT FROM p_order_id THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_WHATSAPP_ORDER_MISMATCH' USING ERRCODE = '40001';
  END IF;
  IF v_claimed_amount IS NULL OR v_claimed_amount <= 0 THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_WHATSAPP_AMOUNT_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  -- This bridge records WhatsApp evidence as uploaded only.  A prior
  -- WhatsApp VERIFIED decision never impersonates canonical Finance
  -- verification; verify_order_payment_v1 remains the sole verifier.
  RETURN QUERY
    SELECT * FROM public.record_order_payment_proof_v1(
      p_order_id, p_pi_id, p_commercial_version_id, p_payment_type,
      v_claimed_amount, p_currency, NULL, v_claimed_reference, NULL,
      'whatsapp-case-payment-proof:' || p_payment_proof_id::text,
      'WHATSAPP', 'whatsapp-case-payment-proof:' || p_payment_proof_id::text,
      p_correlation_id, p_idempotency_key, v_actor
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_order_payment_facts_v1(p_pi_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_order public.orders%rowtype;
  v_verified numeric;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'ORDER_PAYMENT_AUTHENTICATION_REQUIRED' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id = p_pi_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_PAYMENT_PI_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = v_pi.order_id;
  IF NOT public.is_internal_staff(auth.uid())
     AND v_order.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'ORDER_PAYMENT_COMPANY_MISMATCH' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_order_payment_binding_v1(v_pi.order_id, v_pi.id, v_pi.commercial_version_id);
  SELECT coalesce(sum(verified_amount), 0) INTO v_verified
    FROM public.order_payments
   WHERE proforma_invoice_id = v_pi.id AND status = 'verified';
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'payment_id', p.id, 'status', p.status, 'payment_type', p.payment_type,
    'submitted_amount', p.amount, 'verified_amount', p.verified_amount,
    'currency', p.currency, 'payment_mode', p.payment_mode,
    'external_reference', p.reference_no, 'source_channel', p.source_channel,
    'source_reference', p.source_reference, 'proof_received_at', p.proof_received_at,
    'verified_at', p.verified_at, 'rejected_at', p.rejected_at
  ) ORDER BY p.created_at, p.id), '[]'::jsonb) INTO v_rows
    FROM public.order_payments p WHERE p.proforma_invoice_id = v_pi.id;
  RETURN jsonb_build_object(
    'pi_id', v_pi.id,
    'order_id', v_pi.order_id,
    'commercial_version_id', v_pi.commercial_version_id,
    'commercial_version_number', v_pi.commercial_version_number,
    'commercial_value', (v_pi.frozen_commercial_snapshot ->> 'sales_order_value')::numeric,
    'verified_total', v_verified,
    'remaining_commercial_amount', greatest(0,
      coalesce((v_pi.frozen_commercial_snapshot ->> 'sales_order_value')::numeric, 0) - v_verified),
    'payments', v_rows,
    'payment_facts_only', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.guard_order_payment_authority_mutation() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.guard_order_payment_authority_audit_mutation() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.assert_order_payment_binding_v1(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_order_payment_proof_v1(uuid, uuid, uuid, text, numeric, text, text, text, text, text, text, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.verify_order_payment_v1(uuid, numeric, text, text, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.reject_order_payment_v1(uuid, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.record_whatsapp_payment_proof_in_canonical_ledger_v1(uuid, uuid, uuid, uuid, text, text, text, text, uuid) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.get_order_payment_facts_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_order_payment_proof_v1(uuid, uuid, uuid, text, numeric, text, text, text, text, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_order_payment_v1(uuid, numeric, text, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_order_payment_v1(uuid, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_whatsapp_payment_proof_in_canonical_ledger_v1(uuid, uuid, uuid, uuid, text, text, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_payment_facts_v1(uuid) TO authenticated, service_role;

COMMENT ON TABLE public.order_payment_authority_idempotency IS
  'PF-6A idempotency receipts for canonical payment proof/Finance decisions; not a payment ledger.';
COMMENT ON TABLE public.order_payment_authority_audit IS
  'PF-6A append-only payment evidence and Finance decision history.';
COMMENT ON FUNCTION public.get_order_payment_facts_v1(uuid) IS
  'Factual payment projection only; never Finance Clearance or Operations Release.';
