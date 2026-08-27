-- Pre-Factory PF-5: Core-owned internal Proforma Invoice authority.
-- Customer-visible numbering is deliberately unassigned until a separate
-- owner-approved numbering policy exists. The legacy ols_finance_pi trace
-- authority remains separate and is not repurposed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.sales_order_proforma_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id),
  commercial_version_number integer NOT NULL CHECK (commercial_version_number > 0),
  frozen_commercial_snapshot jsonb NOT NULL,
  frozen_snapshot_fingerprint text NOT NULL,
  status text NOT NULL DEFAULT 'READY_FOR_ISSUE'
    CHECK (status IN ('DRAFT', 'READY_FOR_ISSUE', 'ISSUED', 'CANCELLED', 'SUPERSEDED')),
  customer_visible_pi_number text NULL,
  reason text NOT NULL,
  source text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  issued_by uuid REFERENCES auth.users(id),
  issued_at timestamptz,
  cancelled_by uuid REFERENCES auth.users(id),
  cancelled_at timestamptz,
  cancellation_reason text,
  superseded_by_id uuid REFERENCES public.sales_order_proforma_invoices(id),
  UNIQUE (order_id, commercial_version_id),
  UNIQUE (idempotency_key),
  CHECK (customer_visible_pi_number IS NULL),
  CHECK ((status = 'ISSUED') = (issued_at IS NOT NULL AND issued_by IS NOT NULL)),
  CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL AND cancellation_reason IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS public.sales_order_proforma_invoice_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('CREATE', 'ISSUE', 'CANCEL')),
  request_fingerprint text NOT NULL,
  pi_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id),
  response jsonb NOT NULL,
  actor_id uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE IF NOT EXISTS public.sales_order_proforma_invoice_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pi_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id),
  action text NOT NULL CHECK (action IN ('CREATED', 'ISSUED', 'CANCELLED', 'SUPERSEDED')),
  old_status text,
  new_status text NOT NULL,
  actor_id uuid REFERENCES auth.users(id),
  reason text NOT NULL,
  source text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (pi_id, action, idempotency_key)
);

CREATE TABLE IF NOT EXISTS public.sales_order_proforma_invoice_mutation_scopes (
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  pi_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id),
  PRIMARY KEY (backend_pid, transaction_id, pi_id)
);

ALTER TABLE public.sales_order_proforma_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_proforma_invoice_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_proforma_invoice_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_proforma_invoice_mutation_scopes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.sales_order_proforma_invoices FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sales_order_proforma_invoice_idempotency FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.sales_order_proforma_invoice_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sales_order_proforma_invoice_mutation_scopes FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.sales_order_proforma_invoices TO authenticated, service_role;
GRANT SELECT ON TABLE public.sales_order_proforma_invoice_audit TO authenticated, service_role;

DROP POLICY IF EXISTS sales_order_proforma_invoices_internal_read
  ON public.sales_order_proforma_invoices;
CREATE POLICY sales_order_proforma_invoices_internal_read
  ON public.sales_order_proforma_invoices FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS sales_order_proforma_invoice_audit_internal_read
  ON public.sales_order_proforma_invoice_audit;
CREATE POLICY sales_order_proforma_invoice_audit_internal_read
  ON public.sales_order_proforma_invoice_audit FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_sales_order_proforma_invoice_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_IMMUTABLE' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.sales_order_proforma_invoice_mutation_scopes s
     WHERE s.backend_pid = pg_backend_pid()
       AND s.transaction_id = txid_current()
       AND s.pi_id = old.id
  ) THEN
    RAISE EXCEPTION 'DIRECT_SALES_ORDER_PI_MUTATION_FORBIDDEN' USING ERRCODE = '42501';
  END IF;
  IF old.id IS DISTINCT FROM new.id
     OR old.order_id IS DISTINCT FROM new.order_id
     OR old.commercial_version_id IS DISTINCT FROM new.commercial_version_id
     OR old.commercial_version_number IS DISTINCT FROM new.commercial_version_number
     OR old.frozen_commercial_snapshot IS DISTINCT FROM new.frozen_commercial_snapshot
     OR old.frozen_snapshot_fingerprint IS DISTINCT FROM new.frozen_snapshot_fingerprint
     OR old.reason IS DISTINCT FROM new.reason
     OR old.source IS DISTINCT FROM new.source
     OR old.correlation_id IS DISTINCT FROM new.correlation_id
     OR old.idempotency_key IS DISTINCT FROM new.idempotency_key
     OR new.customer_visible_pi_number IS NOT NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_FROZEN_FIELDS_IMMUTABLE' USING ERRCODE = 'P0001';
  END IF;
  IF old.status = 'ISSUED' AND new.status IS DISTINCT FROM old.status THEN
    RAISE EXCEPTION 'ISSUED_SALES_ORDER_PI_IMMUTABLE' USING ERRCODE = 'P0001';
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_order_proforma_invoice_immutable
  ON public.sales_order_proforma_invoices;
CREATE TRIGGER trg_sales_order_proforma_invoice_immutable
  BEFORE UPDATE OR DELETE ON public.sales_order_proforma_invoices
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_proforma_invoice_mutation();
REVOKE ALL ON FUNCTION public.prevent_sales_order_proforma_invoice_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_sales_order_proforma_invoice_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'SALES_ORDER_PI_AUDIT_IMMUTABLE' USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_order_proforma_invoice_audit_immutable
  ON public.sales_order_proforma_invoice_audit;
CREATE TRIGGER trg_sales_order_proforma_invoice_audit_immutable
  BEFORE UPDATE OR DELETE ON public.sales_order_proforma_invoice_audit
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_proforma_invoice_audit_mutation();
REVOKE ALL ON FUNCTION public.prevent_sales_order_proforma_invoice_audit_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_sales_order_pi_frozen_order_item_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_order_id uuid;
BEGIN
  v_order_id := CASE WHEN TG_OP = 'DELETE' THEN old.order_id ELSE new.order_id END;
  IF EXISTS (
    SELECT 1 FROM public.sales_order_proforma_invoices p
     WHERE p.order_id = v_order_id AND p.status = 'ISSUED'
  ) THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_FROZEN' USING ERRCODE = '55000';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN old ELSE new END;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_order_pi_frozen_order_item_mutation ON public.order_items;
CREATE TRIGGER trg_sales_order_pi_frozen_order_item_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_pi_frozen_order_item_mutation();
REVOKE ALL ON FUNCTION public.prevent_sales_order_pi_frozen_order_item_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assert_sales_order_pi_actor_v1(p_actor_id uuid, p_require_step_up boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_role text;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF auth.role() <> 'service_role' AND (auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_actor_id) THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_ACTOR_MISMATCH' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_internal_staff(p_actor_id) THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_INTERNAL_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  v_role := upper(public.get_user_role(p_actor_id));
  IF p_require_step_up AND coalesce(v_role, '') <> ALL (ARRAY['FINANCE_HEAD', 'FINANCE_EXEC', 'ADMIN', 'SUPER_ADMIN', 'OWNER']) THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_FINANCE_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;
  IF p_require_step_up AND NOT public.has_step_up_auth() THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_AAL2_REQUIRED' USING ERRCODE = '42501';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.assert_sales_order_pi_actor_v1(uuid, boolean) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_sales_order_proforma_invoice_v1(
  p_order_id uuid,
  p_commercial_version_id uuid,
  p_reason text,
  p_source text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(pi_id uuid, status text, already_exists boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
#variable_conflict use_column
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_order public.orders%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_existing public.sales_order_proforma_invoice_idempotency%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  PERFORM public.assert_sales_order_pi_actor_v1(v_actor, false);
  IF p_order_id IS NULL OR p_commercial_version_id IS NULL
     OR nullif(btrim(p_reason), '') IS NULL OR nullif(btrim(p_source), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := md5(concat_ws('|', 'CREATE', p_order_id::text, p_commercial_version_id::text,
    btrim(p_reason), btrim(p_source), btrim(p_correlation_id)));
  PERFORM pg_advisory_xact_lock(hashtextextended('sales-order-pi:' || p_order_id::text, 0));
  SELECT * INTO v_existing FROM public.sales_order_proforma_invoice_idempotency
   WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'SALES_ORDER_PI_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.pi_id, (v_existing.response ->> 'status'), true;
    RETURN;
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF lower(coalesce(v_order.status, '')) IN ('cancelled', 'canceled') THEN
    RAISE EXCEPTION 'CANCELLED_ORDER_PI_FORBIDDEN' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE id = p_commercial_version_id AND order_id = p_order_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_COMMERCIAL_VERSION_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'STALE_SALES_ORDER_VERSION' USING ERRCODE = '40001';
  END IF;
  IF md5(v_version.commercial_snapshot::text) IS DISTINCT FROM v_version.snapshot_fingerprint
     OR jsonb_typeof(v_version.commercial_snapshot -> 'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_version.commercial_snapshot -> 'lines') = 0
     OR v_version.sales_order_value IS NULL OR v_version.advance_required IS NULL
     OR v_version.commercial_snapshot ->> 'order_id' IS DISTINCT FROM p_order_id::text THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_COMMERCIAL_TRUTH_INCOMPLETE' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices
   WHERE order_id = p_order_id AND commercial_version_id = p_commercial_version_id;
  IF FOUND THEN
    v_response := jsonb_build_object('pi_id', v_pi.id, 'status', v_pi.status);
    INSERT INTO public.sales_order_proforma_invoice_idempotency(idempotency_key, operation, request_fingerprint, pi_id, response, actor_id)
    VALUES (btrim(p_idempotency_key), 'CREATE', v_fingerprint, v_pi.id, v_response, v_actor);
    RETURN QUERY SELECT v_pi.id, v_pi.status, true;
    RETURN;
  END IF;
  INSERT INTO public.sales_order_proforma_invoices(
    order_id, commercial_version_id, commercial_version_number, frozen_commercial_snapshot,
    frozen_snapshot_fingerprint, status, reason, source, correlation_id, idempotency_key, created_by
  ) VALUES (
    p_order_id, p_commercial_version_id, v_version.version_number, v_version.commercial_snapshot,
    v_version.snapshot_fingerprint, 'READY_FOR_ISSUE', btrim(p_reason), btrim(p_source),
    btrim(p_correlation_id), btrim(p_idempotency_key), v_actor
  ) RETURNING * INTO v_pi;
  v_response := jsonb_build_object('pi_id', v_pi.id, 'status', v_pi.status);
  INSERT INTO public.sales_order_proforma_invoice_idempotency(idempotency_key, operation, request_fingerprint, pi_id, response, actor_id)
  VALUES (btrim(p_idempotency_key), 'CREATE', v_fingerprint, v_pi.id, v_response, v_actor);
  INSERT INTO public.sales_order_proforma_invoice_audit(
    pi_id, action, old_status, new_status, actor_id, reason, source, correlation_id, idempotency_key, metadata
  ) VALUES (v_pi.id, 'CREATED', NULL, v_pi.status, v_actor, btrim(p_reason), btrim(p_source), btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('commercial_version_id', p_commercial_version_id, 'commercial_version_number', v_version.version_number));
  RETURN QUERY SELECT v_pi.id, v_pi.status, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.issue_sales_order_proforma_invoice_v1(
  p_pi_id uuid,
  p_reason text,
  p_source text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(pi_id uuid, status text, already_issued boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
#variable_conflict use_column
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_order public.orders%rowtype;
  v_existing public.sales_order_proforma_invoice_idempotency%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  PERFORM public.assert_sales_order_pi_actor_v1(v_actor, true);
  IF p_pi_id IS NULL OR nullif(btrim(p_reason), '') IS NULL OR nullif(btrim(p_source), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := md5(concat_ws('|', 'ISSUE', p_pi_id::text, btrim(p_reason), btrim(p_source), btrim(p_correlation_id)));
  PERFORM pg_advisory_xact_lock(hashtextextended('sales-order-pi-issue:' || p_pi_id::text, 0));
  SELECT * INTO v_existing FROM public.sales_order_proforma_invoice_idempotency
   WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'SALES_ORDER_PI_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.pi_id, (v_existing.response ->> 'status'), true;
    RETURN;
  END IF;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id = p_pi_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_PI_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_pi.status = 'ISSUED' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_ALREADY_ISSUED' USING ERRCODE = '55000';
  END IF;
  IF v_pi.status <> 'READY_FOR_ISSUE' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_NOT_READY' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = v_pi.order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF lower(coalesce(v_order.status, '')) IN ('cancelled', 'canceled') THEN
    RAISE EXCEPTION 'CANCELLED_ORDER_PI_FORBIDDEN' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE id = v_pi.commercial_version_id AND order_id = v_pi.order_id FOR SHARE;
  IF NOT FOUND OR v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'STALE_SALES_ORDER_VERSION' USING ERRCODE = '40001';
  END IF;
  IF v_pi.commercial_version_number IS DISTINCT FROM v_version.version_number
     OR v_pi.frozen_snapshot_fingerprint IS DISTINCT FROM v_version.snapshot_fingerprint
     OR md5(v_version.commercial_snapshot::text) IS DISTINCT FROM v_version.snapshot_fingerprint
     OR v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
     OR jsonb_typeof(v_version.commercial_snapshot -> 'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_version.commercial_snapshot -> 'lines') = 0 THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_COMMERCIAL_TRUTH_INCONSISTENT' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO public.sales_order_proforma_invoice_mutation_scopes(backend_pid, transaction_id, pi_id)
  VALUES (pg_backend_pid(), txid_current(), p_pi_id);
  UPDATE public.sales_order_proforma_invoices
     SET status = 'ISSUED', issued_by = v_actor, issued_at = statement_timestamp()
   WHERE id = p_pi_id;
  v_response := jsonb_build_object('pi_id', p_pi_id, 'status', 'ISSUED');
  INSERT INTO public.sales_order_proforma_invoice_idempotency(idempotency_key, operation, request_fingerprint, pi_id, response, actor_id)
  VALUES (btrim(p_idempotency_key), 'ISSUE', v_fingerprint, p_pi_id, v_response, v_actor);
  INSERT INTO public.sales_order_proforma_invoice_audit(
    pi_id, action, old_status, new_status, actor_id, reason, source, correlation_id, idempotency_key, metadata
  ) VALUES (p_pi_id, 'ISSUED', 'READY_FOR_ISSUE', 'ISSUED', v_actor, btrim(p_reason), btrim(p_source), btrim(p_correlation_id), btrim(p_idempotency_key),
    jsonb_build_object('commercial_version_id', v_pi.commercial_version_id, 'commercial_version_number', v_pi.commercial_version_number));
  DELETE FROM public.sales_order_proforma_invoice_mutation_scopes
   WHERE backend_pid = pg_backend_pid() AND transaction_id = txid_current() AND pi_id = p_pi_id;
  RETURN QUERY SELECT p_pi_id, 'ISSUED'::text, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_sales_order_proforma_invoice_v1(
  p_pi_id uuid,
  p_reason text,
  p_source text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(pi_id uuid, status text, already_cancelled boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
#variable_conflict use_column
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_existing public.sales_order_proforma_invoice_idempotency%rowtype;
  v_fingerprint text;
  v_response jsonb;
BEGIN
  PERFORM public.assert_sales_order_pi_actor_v1(v_actor, true);
  IF p_pi_id IS NULL OR nullif(btrim(p_reason), '') IS NULL OR nullif(btrim(p_source), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL OR nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_EVIDENCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  v_fingerprint := md5(concat_ws('|', 'CANCEL', p_pi_id::text, btrim(p_reason), btrim(p_source), btrim(p_correlation_id)));
  PERFORM pg_advisory_xact_lock(hashtextextended('sales-order-pi-cancel:' || p_pi_id::text, 0));
  SELECT * INTO v_existing FROM public.sales_order_proforma_invoice_idempotency
   WHERE idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'SALES_ORDER_PI_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = '23505';
    END IF;
    RETURN QUERY SELECT v_existing.pi_id, (v_existing.response ->> 'status'), true;
    RETURN;
  END IF;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id = p_pi_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_PI_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_pi.status = 'ISSUED' THEN
    RAISE EXCEPTION 'ISSUED_SALES_ORDER_PI_REVERSAL_REQUIRED' USING ERRCODE = '55000';
  END IF;
  IF v_pi.status <> 'READY_FOR_ISSUE' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_NOT_CANCELLABLE' USING ERRCODE = '55000';
  END IF;
  INSERT INTO public.sales_order_proforma_invoice_mutation_scopes(backend_pid, transaction_id, pi_id)
  VALUES (pg_backend_pid(), txid_current(), p_pi_id);
  UPDATE public.sales_order_proforma_invoices
     SET status = 'CANCELLED', cancelled_by = v_actor, cancelled_at = statement_timestamp(), cancellation_reason = btrim(p_reason)
   WHERE id = p_pi_id;
  v_response := jsonb_build_object('pi_id', p_pi_id, 'status', 'CANCELLED');
  INSERT INTO public.sales_order_proforma_invoice_idempotency(idempotency_key, operation, request_fingerprint, pi_id, response, actor_id)
  VALUES (btrim(p_idempotency_key), 'CANCEL', v_fingerprint, p_pi_id, v_response, v_actor);
  INSERT INTO public.sales_order_proforma_invoice_audit(
    pi_id, action, old_status, new_status, actor_id, reason, source, correlation_id, idempotency_key
  ) VALUES (p_pi_id, 'CANCELLED', 'READY_FOR_ISSUE', 'CANCELLED', v_actor, btrim(p_reason), btrim(p_source), btrim(p_correlation_id), btrim(p_idempotency_key));
  DELETE FROM public.sales_order_proforma_invoice_mutation_scopes
   WHERE backend_pid = pg_backend_pid() AND transaction_id = txid_current() AND pi_id = p_pi_id;
  RETURN QUERY SELECT p_pi_id, 'CANCELLED'::text, false;
END;
$$;

REVOKE ALL ON FUNCTION public.create_sales_order_proforma_invoice_v1(uuid, uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.issue_sales_order_proforma_invoice_v1(uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_sales_order_proforma_invoice_v1(uuid, text, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sales_order_proforma_invoice_v1(uuid, uuid, text, text, text, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.issue_sales_order_proforma_invoice_v1(uuid, text, text, text, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_sales_order_proforma_invoice_v1(uuid, text, text, text, text, uuid) TO authenticated, service_role;

CREATE OR REPLACE VIEW public.sales_order_proforma_invoice_authority_v1
WITH (security_invoker = true)
AS
SELECT id, order_id, commercial_version_id, commercial_version_number,
       frozen_commercial_snapshot, frozen_snapshot_fingerprint, status,
       customer_visible_pi_number, reason, source, correlation_id,
       created_by, created_at, issued_by, issued_at, cancelled_by,
       cancelled_at, cancellation_reason, superseded_by_id
  FROM public.sales_order_proforma_invoices;

REVOKE ALL ON public.sales_order_proforma_invoice_authority_v1 FROM PUBLIC, anon;
GRANT SELECT ON public.sales_order_proforma_invoice_authority_v1 TO authenticated, service_role;

COMMENT ON TABLE public.sales_order_proforma_invoices IS
  'Core-owned internal PI authority. Frozen commercial truth is copied from one immutable SO commercial version; customer-visible numbering remains unassigned.';
COMMENT ON VIEW public.sales_order_proforma_invoice_authority_v1 IS
  'Stable Central read contract. Central may read/render but cannot author PI truth.';
