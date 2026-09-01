-- APP-E2E Core authority: canonical company-wide SO and PI numbering.
--
-- This migration is intentionally forward-only. Existing orders.order_number and
-- existing PI identities are never rewritten. Future governed SO creation keeps
-- using orders.order_number as the single canonical SO identity, while PI issue
-- extends the existing sales_order_proforma_invoices authority.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE IF NOT EXISTS public.commercial_document_number_counters (
  document_kind text NOT NULL CHECK (document_kind IN ('SO','PI')),
  business_period text NOT NULL CHECK (business_period ~ '^[0-9]{4}/(0[1-9]|1[0-2])$'),
  last_value integer NOT NULL CHECK (last_value >= 0),
  updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  PRIMARY KEY (document_kind,business_period)
);
ALTER TABLE public.commercial_document_number_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commercial_document_number_counters FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE public.commercial_document_number_counters IS
  'Private allocation state for canonical company-wide monthly SO and PI numbering. It stores counters only; document identity remains on orders.order_number and sales_order_proforma_invoices.customer_visible_pi_number.';

CREATE OR REPLACE FUNCTION public.allocate_commercial_document_number_v1(p_document_kind text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $$
DECLARE
  v_kind text:=upper(btrim(coalesce(p_document_kind,'')));
  v_business_period text:=to_char(statement_timestamp() AT TIME ZONE 'Asia/Kolkata','YYYY/MM');
  v_existing_max integer:=0;
  v_next integer;
  v_limit integer;
BEGIN
  IF v_kind NOT IN ('SO','PI') THEN
    RAISE EXCEPTION 'COMMERCIAL_DOCUMENT_KIND_INVALID' USING ERRCODE='22023';
  END IF;

  v_limit:=CASE v_kind WHEN 'SO' THEN 9999 ELSE 999 END;
  PERFORM pg_advisory_xact_lock(hashtextextended('commercial-document-number:'||v_kind||':'||v_business_period,0));

  IF v_kind='SO' THEN
    SELECT coalesce(max((regexp_match(o.order_number,'^SO'||v_business_period||'-([0-9]{4})$'))[1]::integer),0)
      INTO v_existing_max
      FROM public.orders o
     WHERE o.order_number ~ ('^SO'||v_business_period||'-[0-9]{4}$');
  ELSE
    SELECT coalesce(max((regexp_match(p.customer_visible_pi_number,'^PI'||v_business_period||'-([0-9]{3})$'))[1]::integer),0)
      INTO v_existing_max
      FROM public.sales_order_proforma_invoices p
     WHERE p.customer_visible_pi_number ~ ('^PI'||v_business_period||'-[0-9]{3}$');
  END IF;

  INSERT INTO public.commercial_document_number_counters(document_kind,business_period,last_value)
  VALUES(v_kind,v_business_period,v_existing_max)
  ON CONFLICT(document_kind,business_period) DO UPDATE
    SET last_value=greatest(public.commercial_document_number_counters.last_value,EXCLUDED.last_value),
        updated_at=statement_timestamp();

  UPDATE public.commercial_document_number_counters
     SET last_value=last_value+1,
         updated_at=statement_timestamp()
   WHERE document_kind=v_kind
     AND business_period=v_business_period
     AND last_value<v_limit
  RETURNING last_value INTO v_next;

  IF v_next IS NULL THEN
    RAISE EXCEPTION '%_MONTHLY_SEQUENCE_EXHAUSTED: %',v_kind,v_business_period USING ERRCODE='54000';
  END IF;

  RETURN CASE v_kind
    WHEN 'SO' THEN 'SO'||v_business_period||'-'||lpad(v_next::text,4,'0')
    ELSE 'PI'||v_business_period||'-'||lpad(v_next::text,3,'0')
  END;
END;
$$;
REVOKE ALL ON FUNCTION public.allocate_commercial_document_number_v1(text)
  FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION public.allocate_commercial_document_number_v1(text) IS
  'Private transactional allocator. Uses Asia/Kolkata business month, one company-wide counter per document kind/month, advisory locking and fail-closed SO=9999 / PI=999 limits.';

-- Replace the legacy SO-YYYY-NNNNNN allocator in place. Controlled replay and
-- historical fixtures run as postgres and may preserve an explicit historical
-- number. Runtime browser/service-role raw inserts cannot create a Sales Order;
-- governed SECURITY DEFINER creation RPCs run as postgres and omit the number.
CREATE OR REPLACE FUNCTION public.assign_order_number_on_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path=pg_catalog,public
AS $$
BEGIN
  IF NEW.order_number IS NOT NULL AND btrim(NEW.order_number)<>'' THEN
    IF current_user<>'postgres' THEN
      RAISE EXCEPTION 'SO_NUMBER_SERVER_ASSIGNED' USING ERRCODE='42501';
    END IF;
    RETURN NEW;
  END IF;

  IF current_user<>'postgres' THEN
    RAISE EXCEPTION 'SALES_ORDER_CREATION_RPC_REQUIRED' USING ERRCODE='42501';
  END IF;

  NEW.order_number:=public.allocate_commercial_document_number_v1('SO');
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.assign_order_number_on_insert() FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION public.assign_order_number_on_insert() IS
  'Canonical SO assignment trigger. Future governed order creation receives SOYYYY/MM-NNNN in Asia/Kolkata; explicit historical values are preserved only in controlled postgres replay/migration context.';

CREATE OR REPLACE FUNCTION public.prevent_sales_order_number_mutation_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path=pg_catalog,public
AS $$
BEGIN
  IF OLD.order_number IS DISTINCT FROM NEW.order_number THEN
    RAISE EXCEPTION 'SALES_ORDER_NUMBER_IMMUTABLE' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_orders_order_number_immutable ON public.orders;
CREATE TRIGGER trg_orders_order_number_immutable
  BEFORE UPDATE OF order_number ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_number_mutation_v1();
REVOKE ALL ON FUNCTION public.prevent_sales_order_number_mutation_v1() FROM PUBLIC,anon,authenticated,service_role;

-- PF-5 deliberately required customer_visible_pi_number IS NULL. Supersede that
-- fail-closed placeholder without changing any historical PI row.
ALTER TABLE public.sales_order_proforma_invoices
  DROP CONSTRAINT IF EXISTS sales_order_proforma_invoices_customer_visible_pi_number_check;
ALTER TABLE public.sales_order_proforma_invoices
  ADD CONSTRAINT sales_order_proforma_invoices_customer_visible_pi_number_check
  CHECK (
    (status IN ('DRAFT','READY_FOR_ISSUE') AND customer_visible_pi_number IS NULL)
    OR (
      status='ISSUED'
      AND customer_visible_pi_number IS NOT NULL
      AND customer_visible_pi_number ~ '^PI[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{3}$'
    )
    OR (
      status IN ('CANCELLED','SUPERSEDED')
      AND (
        customer_visible_pi_number IS NULL
        OR customer_visible_pi_number ~ '^PI[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{3}$'
      )
    )
  ) NOT VALID;
CREATE UNIQUE INDEX IF NOT EXISTS uq_sales_order_pi_customer_visible_number
  ON public.sales_order_proforma_invoices(customer_visible_pi_number)
  WHERE customer_visible_pi_number IS NOT NULL;

CREATE OR REPLACE FUNCTION public.prevent_sales_order_proforma_invoice_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_IMMUTABLE' USING ERRCODE='P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.sales_order_proforma_invoice_mutation_scopes s
     WHERE s.backend_pid=pg_backend_pid()
       AND s.transaction_id=txid_current()
       AND s.pi_id=OLD.id
  ) THEN
    RAISE EXCEPTION 'DIRECT_SALES_ORDER_PI_MUTATION_FORBIDDEN' USING ERRCODE='42501';
  END IF;
  IF OLD.id IS DISTINCT FROM NEW.id
     OR OLD.order_id IS DISTINCT FROM NEW.order_id
     OR OLD.commercial_version_id IS DISTINCT FROM NEW.commercial_version_id
     OR OLD.commercial_version_number IS DISTINCT FROM NEW.commercial_version_number
     OR OLD.frozen_commercial_snapshot IS DISTINCT FROM NEW.frozen_commercial_snapshot
     OR OLD.frozen_snapshot_fingerprint IS DISTINCT FROM NEW.frozen_snapshot_fingerprint
     OR OLD.reason IS DISTINCT FROM NEW.reason
     OR OLD.source IS DISTINCT FROM NEW.source
     OR OLD.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR OLD.idempotency_key IS DISTINCT FROM NEW.idempotency_key THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_FROZEN_FIELDS_IMMUTABLE' USING ERRCODE='P0001';
  END IF;

  IF OLD.customer_visible_pi_number IS DISTINCT FROM NEW.customer_visible_pi_number
     AND NOT (
       OLD.customer_visible_pi_number IS NULL
       AND NEW.customer_visible_pi_number IS NOT NULL
       AND OLD.status='READY_FOR_ISSUE'
       AND NEW.status='ISSUED'
     ) THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_NUMBER_IMMUTABLE' USING ERRCODE='55000';
  END IF;

  IF OLD.status='ISSUED' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'ISSUED_SALES_ORDER_PI_IMMUTABLE' USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$$;

-- Change only the response shape of the existing canonical issue RPC by adding
-- pi_number. The input signature and authority name remain unchanged.
DROP FUNCTION IF EXISTS public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid);
CREATE FUNCTION public.issue_sales_order_proforma_invoice_v1(
  p_pi_id uuid,
  p_reason text,
  p_source text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(
  pi_id uuid,
  status text,
  customer_visible_pi_number text,
  already_issued boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
#variable_conflict use_column
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_order public.orders%rowtype;
  v_existing public.sales_order_proforma_invoice_idempotency%rowtype;
  v_fingerprint text;
  v_response jsonb;
  v_pi_number text;
BEGIN
  PERFORM public.assert_sales_order_pi_actor_v1(v_actor,true);
  IF p_pi_id IS NULL OR nullif(btrim(p_reason),'') IS NULL OR nullif(btrim(p_source),'') IS NULL
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  v_fingerprint:=md5(concat_ws('|','ISSUE',p_pi_id::text,btrim(p_reason),btrim(p_source),btrim(p_correlation_id)));
  PERFORM pg_advisory_xact_lock(hashtextextended('sales-order-pi-issue:'||p_pi_id::text,0));

  SELECT * INTO v_existing
  FROM public.sales_order_proforma_invoice_idempotency
  WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'SALES_ORDER_PI_IDEMPOTENCY_ACTOR_CONFLICT' USING ERRCODE='42501';
    END IF;
    IF v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'SALES_ORDER_PI_IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT
      v_existing.pi_id,
      (v_existing.response->>'status'),
      (v_existing.response->>'customer_visible_pi_number'),
      true;
    RETURN;
  END IF;

  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices WHERE id=p_pi_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_PI_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  IF v_pi.status='ISSUED' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_ALREADY_ISSUED' USING ERRCODE='55000';
  END IF;
  IF v_pi.status<>'READY_FOR_ISSUE' THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_NOT_READY' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id=v_pi.order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  IF lower(coalesce(v_order.status,'')) IN ('cancelled','canceled') THEN
    RAISE EXCEPTION 'CANCELLED_ORDER_PI_FORBIDDEN' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE id=v_pi.commercial_version_id AND order_id=v_pi.order_id FOR SHARE;
  IF NOT FOUND OR v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'STALE_SALES_ORDER_VERSION' USING ERRCODE='40001';
  END IF;
  IF v_pi.commercial_version_number IS DISTINCT FROM v_version.version_number
     OR v_pi.frozen_snapshot_fingerprint IS DISTINCT FROM v_version.snapshot_fingerprint
     OR md5(v_version.commercial_snapshot::text) IS DISTINCT FROM v_version.snapshot_fingerprint
     OR v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
     OR jsonb_typeof(v_version.commercial_snapshot->'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_version.commercial_snapshot->'lines')=0 THEN
    RAISE EXCEPTION 'SALES_ORDER_PI_COMMERCIAL_TRUTH_INCONSISTENT' USING ERRCODE='P0001';
  END IF;

  v_pi_number:=public.allocate_commercial_document_number_v1('PI');

  INSERT INTO public.sales_order_proforma_invoice_mutation_scopes(backend_pid,transaction_id,pi_id)
  VALUES(pg_backend_pid(),txid_current(),p_pi_id);
  UPDATE public.sales_order_proforma_invoices
     SET status='ISSUED',
         customer_visible_pi_number=v_pi_number,
         issued_by=v_actor,
         issued_at=statement_timestamp()
   WHERE id=p_pi_id;

  v_response:=jsonb_build_object(
    'pi_id',p_pi_id,
    'status','ISSUED',
    'customer_visible_pi_number',v_pi_number
  );
  INSERT INTO public.sales_order_proforma_invoice_idempotency(
    idempotency_key,operation,request_fingerprint,pi_id,response,actor_id
  ) VALUES(
    btrim(p_idempotency_key),'ISSUE',v_fingerprint,p_pi_id,v_response,v_actor
  );
  INSERT INTO public.sales_order_proforma_invoice_audit(
    pi_id,action,old_status,new_status,actor_id,reason,source,correlation_id,idempotency_key,metadata
  ) VALUES(
    p_pi_id,'ISSUED','READY_FOR_ISSUE','ISSUED',v_actor,btrim(p_reason),btrim(p_source),
    btrim(p_correlation_id),btrim(p_idempotency_key),
    jsonb_build_object(
      'commercial_version_id',v_pi.commercial_version_id,
      'commercial_version_number',v_pi.commercial_version_number,
      'customer_visible_pi_number',v_pi_number
    )
  );
  DELETE FROM public.sales_order_proforma_invoice_mutation_scopes
   WHERE backend_pid=pg_backend_pid() AND transaction_id=txid_current() AND pi_id=p_pi_id;

  RETURN QUERY SELECT p_pi_id,'ISSUED'::text,v_pi_number,false;
END;
$$;
REVOKE ALL ON FUNCTION public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)
  TO authenticated;
COMMENT ON FUNCTION public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid) IS
  'Canonical Finance PI issuance. Atomically assigns PIYYYY/MM-NNN in Asia/Kolkata on ISSUE, persists the number in immutable PI truth, and returns the same number on exact idempotent replay.';
