-- FIN-PAY-PI: DPL-bound final-payment Proforma Invoice revision authority.
--
-- Extends the existing immutable sales_order_proforma_invoices lineage. The
-- original PI identity/number is never replaced or renumbered. Each final-
-- payment demand is an immutable revision under that PI, bound to the exact
-- Finance-received DPL and commercial version. Final invoice issuance fails
-- closed until the latest exact revision is fully covered by verified payment,
-- applied wallet debit, and active approved credit.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.sales_order_pi_final_payment_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  proforma_invoice_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id) ON DELETE RESTRICT,
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id) ON DELETE RESTRICT,
  finance_dpl_receipt_id uuid NOT NULL REFERENCES public.finance_dpl_receipts(id) ON DELETE RESTRICT,
  revision_number integer NOT NULL CHECK (revision_number > 0),
  supersedes_request_id uuid REFERENCES public.sales_order_pi_final_payment_requests(id) ON DELETE RESTRICT,
  customer_visible_pi_number text NOT NULL,
  dpl_fingerprint text NOT NULL CHECK (dpl_fingerprint ~ '^[0-9a-f]{64}$'),
  currency text NOT NULL DEFAULT 'INR' CHECK (currency ~ '^[A-Z]{3}$'),
  taxable_total numeric(14,2) NOT NULL CHECK (taxable_total >= 0),
  tax_total numeric(14,2) NOT NULL CHECK (tax_total >= 0),
  final_payable_total numeric(14,2) NOT NULL CHECK (final_payable_total >= 0),
  verified_payment_at_issue numeric(14,2) NOT NULL CHECK (verified_payment_at_issue >= 0),
  wallet_applied_at_issue numeric(14,2) NOT NULL CHECK (wallet_applied_at_issue >= 0),
  approved_credit_at_issue numeric(14,2) NOT NULL CHECK (approved_credit_at_issue >= 0),
  balance_due_at_issue numeric(14,2) NOT NULL CHECK (balance_due_at_issue >= 0),
  payment_action text NOT NULL CHECK (payment_action IN ('PAY_NOW','BANK_TRANSFER','CONTACT_FINANCE')),
  payment_link text,
  payment_instructions text NOT NULL,
  document_reference text NOT NULL,
  issue_status text NOT NULL DEFAULT 'ISSUED' CHECK (issue_status = 'ISSUED'),
  request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
  reason text NOT NULL,
  source_channel text NOT NULL,
  source_reference text,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  issued_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  issued_role text NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(order_id, revision_number),
  UNIQUE(proforma_invoice_id, finance_dpl_receipt_id, revision_number),
  CHECK ((payment_action <> 'PAY_NOW') OR (nullif(btrim(payment_link),'') IS NOT NULL AND payment_link ~ '^https://')),
  CHECK (nullif(btrim(customer_visible_pi_number),'') IS NOT NULL),
  CHECK (nullif(btrim(payment_instructions),'') IS NOT NULL),
  CHECK (nullif(btrim(document_reference),'') IS NOT NULL),
  CHECK (nullif(btrim(reason),'') IS NOT NULL),
  CHECK (nullif(btrim(source_channel),'') IS NOT NULL),
  CHECK (nullif(btrim(correlation_id),'') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS sales_order_pi_final_payment_requests_order_idx
  ON public.sales_order_pi_final_payment_requests(order_id, revision_number DESC);
CREATE INDEX IF NOT EXISTS sales_order_pi_final_payment_requests_pi_idx
  ON public.sales_order_pi_final_payment_requests(proforma_invoice_id, revision_number DESC);

CREATE TABLE IF NOT EXISTS public.sales_order_pi_final_payment_request_idempotency (
  idempotency_key text PRIMARY KEY,
  operation text NOT NULL CHECK (operation IN ('ISSUE','DELIVER')),
  request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
  final_payment_request_id uuid NOT NULL REFERENCES public.sales_order_pi_final_payment_requests(id) ON DELETE RESTRICT,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

CREATE TABLE IF NOT EXISTS public.sales_order_pi_final_payment_request_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  final_payment_request_id uuid NOT NULL REFERENCES public.sales_order_pi_final_payment_requests(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  proforma_invoice_id uuid NOT NULL REFERENCES public.sales_order_proforma_invoices(id) ON DELETE RESTRICT,
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id) ON DELETE RESTRICT,
  finance_dpl_receipt_id uuid NOT NULL REFERENCES public.finance_dpl_receipts(id) ON DELETE RESTRICT,
  action text NOT NULL CHECK (action IN ('ISSUED','REISSUED')),
  revision_number integer NOT NULL CHECK (revision_number > 0),
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  actor_role text NOT NULL,
  reason text NOT NULL,
  source_channel text NOT NULL,
  source_reference text,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE(final_payment_request_id, action)
);

CREATE TABLE IF NOT EXISTS public.sales_order_pi_final_payment_request_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  final_payment_request_id uuid NOT NULL REFERENCES public.sales_order_pi_final_payment_requests(id) ON DELETE RESTRICT,
  channel text NOT NULL CHECK (channel IN ('WHATSAPP','IN_APP','EMAIL','SMS','OTHER')),
  destination_reference text NOT NULL,
  provider_message_id text,
  delivery_status text NOT NULL CHECK (delivery_status IN ('QUEUED','SENT','DELIVERED','FAILED')),
  evidence_reference text NOT NULL,
  delivered_at timestamptz,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  actor_role text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  CHECK ((delivery_status = 'DELIVERED') = (delivered_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS sales_order_pi_final_payment_request_deliveries_request_idx
  ON public.sales_order_pi_final_payment_request_deliveries(final_payment_request_id, created_at DESC);

ALTER TABLE public.sales_order_pi_final_payment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_pi_final_payment_request_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_pi_final_payment_request_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_pi_final_payment_request_deliveries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.sales_order_pi_final_payment_requests,
  public.sales_order_pi_final_payment_request_idempotency,
  public.sales_order_pi_final_payment_request_audit,
  public.sales_order_pi_final_payment_request_deliveries
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE public.sales_order_pi_final_payment_requests TO authenticated, service_role;
GRANT SELECT ON TABLE public.sales_order_pi_final_payment_request_audit TO authenticated, service_role;
GRANT SELECT ON TABLE public.sales_order_pi_final_payment_request_deliveries TO authenticated, service_role;

DROP POLICY IF EXISTS sales_order_pi_final_payment_requests_read
  ON public.sales_order_pi_final_payment_requests;
CREATE POLICY sales_order_pi_final_payment_requests_read
  ON public.sales_order_pi_final_payment_requests FOR SELECT TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.orders o
       WHERE o.id = sales_order_pi_final_payment_requests.order_id
         AND o.company_id = public.auth_buyer_company_id()
    )
  );

DROP POLICY IF EXISTS sales_order_pi_final_payment_request_audit_read
  ON public.sales_order_pi_final_payment_request_audit;
CREATE POLICY sales_order_pi_final_payment_request_audit_read
  ON public.sales_order_pi_final_payment_request_audit FOR SELECT TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.orders o
       WHERE o.id = sales_order_pi_final_payment_request_audit.order_id
         AND o.company_id = public.auth_buyer_company_id()
    )
  );

DROP POLICY IF EXISTS sales_order_pi_final_payment_request_deliveries_read
  ON public.sales_order_pi_final_payment_request_deliveries;
CREATE POLICY sales_order_pi_final_payment_request_deliveries_read
  ON public.sales_order_pi_final_payment_request_deliveries FOR SELECT TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    OR EXISTS (
      SELECT 1
        FROM public.sales_order_pi_final_payment_requests r
        JOIN public.orders o ON o.id = r.order_id
       WHERE r.id = sales_order_pi_final_payment_request_deliveries.final_payment_request_id
         AND o.company_id = public.auth_buyer_company_id()
    )
  );

CREATE OR REPLACE FUNCTION public.prevent_sales_order_pi_final_payment_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'FINAL_PAYMENT_PI_REVISION_IMMUTABLE' USING ERRCODE='55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_order_pi_final_payment_requests_immutable
  ON public.sales_order_pi_final_payment_requests;
CREATE TRIGGER trg_sales_order_pi_final_payment_requests_immutable
  BEFORE UPDATE OR DELETE ON public.sales_order_pi_final_payment_requests
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_pi_final_payment_mutation();

DROP TRIGGER IF EXISTS trg_sales_order_pi_final_payment_request_audit_immutable
  ON public.sales_order_pi_final_payment_request_audit;
CREATE TRIGGER trg_sales_order_pi_final_payment_request_audit_immutable
  BEFORE UPDATE OR DELETE ON public.sales_order_pi_final_payment_request_audit
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_pi_final_payment_mutation();

DROP TRIGGER IF EXISTS trg_sales_order_pi_final_payment_request_deliveries_immutable
  ON public.sales_order_pi_final_payment_request_deliveries;
CREATE TRIGGER trg_sales_order_pi_final_payment_request_deliveries_immutable
  BEFORE UPDATE OR DELETE ON public.sales_order_pi_final_payment_request_deliveries
  FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_order_pi_final_payment_mutation();

REVOKE ALL ON FUNCTION public.prevent_sales_order_pi_final_payment_mutation()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.calculate_finance_dpl_commercial_totals_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_finance_dpl_receipt_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_dpl public.finance_dpl_receipts%rowtype;
  v_invalid integer;
  v_taxable numeric := 0;
  v_tax numeric := 0;
  v_gross numeric := 0;
BEGIN
  IF p_order_id IS NULL OR p_pi_id IS NULL OR p_commercial_version_id IS NULL OR p_finance_dpl_receipt_id IS NULL THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_BINDING_REQUIRED' USING ERRCODE='P0001';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  SELECT * INTO v_pi
    FROM public.sales_order_proforma_invoices
   WHERE id=p_pi_id AND order_id=p_order_id AND commercial_version_id=p_commercial_version_id;
  SELECT * INTO v_version
    FROM public.sales_order_commercial_versions
   WHERE id=p_commercial_version_id AND order_id=p_order_id;
  SELECT * INTO v_dpl
    FROM public.finance_dpl_receipts
   WHERE id=p_finance_dpl_receipt_id
     AND order_id=p_order_id
     AND commercial_version_id=p_commercial_version_id;

  IF v_order.id IS NULL OR v_order.company_id IS NULL OR v_pi.id IS NULL
     OR v_version.id IS NULL OR v_dpl.id IS NULL
     OR v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_BINDING_MISMATCH' USING ERRCODE='40001';
  END IF;

  IF v_pi.status <> 'ISSUED'
     OR nullif(btrim(v_pi.customer_visible_pi_number),'') IS NULL THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_MUST_BE_CUSTOMER_VISIBLE' USING ERRCODE='55000';
  END IF;

  IF v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
     OR v_pi.frozen_snapshot_fingerprint IS DISTINCT FROM v_version.snapshot_fingerprint
     OR md5(v_version.commercial_snapshot::text) IS DISTINCT FROM v_version.snapshot_fingerprint THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_STALE_COMMERCIAL_TRUTH' USING ERRCODE='40001';
  END IF;

  IF v_dpl.dpl_snapshot->>'order_id' IS DISTINCT FROM p_order_id::text
     OR v_dpl.dpl_snapshot->>'commercial_version_id' IS DISTINCT FROM p_commercial_version_id::text
     OR jsonb_typeof(v_dpl.dpl_snapshot->'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_dpl.dpl_snapshot->'lines') = 0
     OR encode(extensions.digest(v_dpl.dpl_snapshot::text,'sha256'),'hex') IS DISTINCT FROM v_dpl.dpl_fingerprint THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_DPL_TRUTH_INVALID' USING ERRCODE='40001';
  END IF;

  IF coalesce((v_version.commercial_snapshot->>'packing_charge')::numeric,0) <> 0
     OR coalesce((v_version.commercial_snapshot->>'other_approved_charges')::numeric,0) <> 0
     OR coalesce((v_version.commercial_snapshot->>'discount_total')::numeric,0) <> 0 THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_NON_LINE_CHARGE_TAX_AUTHORITY_REQUIRED' USING ERRCODE='55000';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM jsonb_to_recordset(v_dpl.dpl_snapshot->'lines')
    d(order_item_id uuid,product_id uuid,actual_dispatch_qty numeric,uom text)
  LEFT JOIN LATERAL (
    SELECT x.*
      FROM jsonb_to_recordset(v_version.commercial_snapshot->'lines')
        x(order_item_id uuid,product_id uuid,sku text,product_name text,quantity numeric,uom text,unit_price numeric,gst_rate numeric,tax_inclusive boolean)
     WHERE x.order_item_id=d.order_item_id AND x.product_id=d.product_id
     LIMIT 1
  ) c ON true
  WHERE c.order_item_id IS NULL
     OR d.actual_dispatch_qty IS NULL OR d.actual_dispatch_qty<=0
     OR d.actual_dispatch_qty>c.quantity
     OR c.unit_price IS NULL OR c.gst_rate IS NULL;
  IF v_invalid>0 THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_DPL_COMMERCIAL_LINE_MISMATCH' USING ERRCODE='40001';
  END IF;

  WITH priced AS (
    SELECT
      round(CASE WHEN coalesce(c.tax_inclusive,false) AND coalesce(c.gst_rate,0)>0
        THEN d.actual_dispatch_qty*c.unit_price/(1+c.gst_rate/100)
        ELSE d.actual_dispatch_qty*c.unit_price END,2) taxable_value,
      round(d.actual_dispatch_qty*c.unit_price*
        CASE WHEN coalesce(c.tax_inclusive,false) THEN 1 ELSE 1+coalesce(c.gst_rate,0)/100 END,2) line_total
    FROM jsonb_to_recordset(v_dpl.dpl_snapshot->'lines')
      d(order_item_id uuid,product_id uuid,actual_dispatch_qty numeric,uom text)
    JOIN LATERAL (
      SELECT x.*
        FROM jsonb_to_recordset(v_version.commercial_snapshot->'lines')
          x(order_item_id uuid,product_id uuid,sku text,product_name text,quantity numeric,uom text,unit_price numeric,gst_rate numeric,tax_inclusive boolean)
       WHERE x.order_item_id=d.order_item_id AND x.product_id=d.product_id
       LIMIT 1
    ) c ON true
  )
  SELECT
    coalesce(sum(taxable_value),0),
    coalesce(sum(line_total-taxable_value),0),
    coalesce(sum(line_total),0)
  INTO v_taxable,v_tax,v_gross
  FROM priced;

  RETURN jsonb_build_object(
    'order_id',p_order_id,
    'pi_id',p_pi_id,
    'commercial_version_id',p_commercial_version_id,
    'finance_dpl_receipt_id',p_finance_dpl_receipt_id,
    'customer_visible_pi_number',v_pi.customer_visible_pi_number,
    'dpl_fingerprint',v_dpl.dpl_fingerprint,
    'currency','INR',
    'taxable_total',round(v_taxable,2),
    'tax_total',round(v_tax,2),
    'final_payable_total',round(v_gross,2),
    'totals_authority','FINANCE_DPL_PLUS_FROZEN_COMMERCIAL_VERSION'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.calculate_finance_dpl_commercial_totals_v1(uuid,uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_sales_order_final_payment_coverage_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_final_payable_total numeric
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_payment jsonb;
  v_verified numeric := 0;
  v_wallet numeric := 0;
  v_credit numeric := 0;
  v_balance numeric := 0;
  v_excess numeric := 0;
BEGIN
  IF p_order_id IS NULL OR p_pi_id IS NULL OR p_commercial_version_id IS NULL
     OR p_final_payable_total IS NULL OR p_final_payable_total < 0 THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_COVERAGE_INPUT_INVALID' USING ERRCODE='P0001';
  END IF;

  PERFORM public.assert_order_payment_binding_v1(p_order_id,p_pi_id,p_commercial_version_id);

  v_payment:=public.get_order_payment_facts_v1(p_pi_id);
  v_verified:=coalesce((v_payment->>'verified_total')::numeric,0);

  SELECT coalesce(sum(amount),0) INTO v_wallet
    FROM public.wallet_transactions
   WHERE order_id=p_order_id
     AND proforma_invoice_id=p_pi_id
     AND commercial_version_id=p_commercial_version_id
     AND direction='debit';

  SELECT coalesce(sum(requested_amount),0) INTO v_credit
    FROM public.credit_requests
   WHERE order_id=p_order_id
     AND proforma_invoice_id=p_pi_id
     AND commercial_version_id=p_commercial_version_id
     AND status='approved'
     AND (expires_at IS NULL OR expires_at>statement_timestamp());

  v_balance:=greatest(0,round(p_final_payable_total-v_verified-v_wallet-v_credit,2));
  v_excess:=greatest(0,round(v_verified+v_wallet+v_credit-p_final_payable_total,2));

  RETURN jsonb_build_object(
    'verified_payment_total',round(v_verified,2),
    'wallet_applied_total',round(v_wallet,2),
    'approved_credit_total',round(v_credit,2),
    'credited_or_paid_total',round(v_verified+v_wallet+v_credit,2),
    'balance_due',v_balance,
    'excess_coverage',v_excess,
    'settled',(v_balance<=0.01),
    'facts_as_of',statement_timestamp()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_sales_order_final_payment_coverage_v1(uuid,uuid,uuid,numeric)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.issue_sales_order_pi_final_payment_request_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid,
  p_finance_dpl_receipt_id uuid,
  p_document_reference text,
  p_payment_action text,
  p_payment_link text,
  p_payment_instructions text,
  p_reason text,
  p_source_channel text,
  p_source_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(
  final_payment_request_id uuid,
  revision_number integer,
  customer_visible_pi_number text,
  final_payable_total numeric,
  balance_due numeric,
  already_issued boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
#variable_conflict use_column
DECLARE
  v_actor uuid := coalesce(p_actor_id,auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_dpl public.finance_dpl_receipts%rowtype;
  v_totals jsonb;
  v_coverage jsonb;
  v_existing public.sales_order_pi_final_payment_request_idempotency%rowtype;
  v_existing_request public.sales_order_pi_final_payment_requests%rowtype;
  v_prior public.sales_order_pi_final_payment_requests%rowtype;
  v_request public.sales_order_pi_final_payment_requests%rowtype;
  v_revision integer;
  v_action text := upper(btrim(coalesce(p_payment_action,'')));
  v_request_fingerprint text;
  v_response jsonb;
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);

  IF p_order_id IS NULL OR p_pi_id IS NULL OR p_commercial_version_id IS NULL
     OR p_finance_dpl_receipt_id IS NULL
     OR nullif(btrim(p_document_reference),'') IS NULL
     OR v_action NOT IN ('PAY_NOW','BANK_TRANSFER','CONTACT_FINANCE')
     OR (v_action='PAY_NOW' AND nullif(btrim(coalesce(p_payment_link,'')),'') IS NULL)
     OR nullif(btrim(p_payment_instructions),'') IS NULL
     OR length(btrim(coalesce(p_reason,'')))<5
     OR nullif(btrim(p_source_channel),'') IS NULL
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('final-payment-pi:'||p_order_id::text,0));

  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR SHARE;
  SELECT * INTO v_pi
    FROM public.sales_order_proforma_invoices
   WHERE id=p_pi_id AND order_id=p_order_id AND commercial_version_id=p_commercial_version_id;
  SELECT * INTO v_dpl
    FROM public.finance_dpl_receipts
   WHERE id=p_finance_dpl_receipt_id
     AND order_id=p_order_id
     AND commercial_version_id=p_commercial_version_id;

  IF v_order.id IS NULL OR v_order.company_id IS NULL OR v_pi.id IS NULL OR v_dpl.id IS NULL THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_BINDING_MISMATCH' USING ERRCODE='40001';
  END IF;
  IF EXISTS(SELECT 1 FROM public.final_invoices f WHERE f.order_id=p_order_id AND f.status='ISSUED') THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_AFTER_FINAL_INVOICE_FORBIDDEN' USING ERRCODE='55000';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_dpl_receipts newer
     WHERE newer.order_id=p_order_id
       AND newer.commercial_version_id=p_commercial_version_id
       AND newer.created_at>v_dpl.created_at
  ) THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_REQUIRES_LATEST_FINANCE_DPL' USING ERRCODE='40001';
  END IF;

  v_totals:=public.calculate_finance_dpl_commercial_totals_v1(
    p_order_id,p_pi_id,p_commercial_version_id,p_finance_dpl_receipt_id
  );
  v_coverage:=public.get_sales_order_final_payment_coverage_v1(
    p_order_id,p_pi_id,p_commercial_version_id,(v_totals->>'final_payable_total')::numeric
  );

  v_request_fingerprint:=encode(extensions.digest(jsonb_build_object(
    'operation','ISSUE_FINAL_PAYMENT_PI_REVISION',
    'order_id',p_order_id,
    'pi_id',p_pi_id,
    'commercial_version_id',p_commercial_version_id,
    'finance_dpl_receipt_id',p_finance_dpl_receipt_id,
    'dpl_fingerprint',v_totals->>'dpl_fingerprint',
    'final_payable_total',(v_totals->>'final_payable_total')::numeric,
    'document_reference',btrim(p_document_reference),
    'payment_action',v_action,
    'payment_link',coalesce(nullif(btrim(p_payment_link),''),''),
    'payment_instructions',btrim(p_payment_instructions),
    'reason',btrim(p_reason),
    'source_channel',upper(btrim(p_source_channel)),
    'source_reference',coalesce(nullif(btrim(p_source_reference),''),''),
    'correlation_id',btrim(p_correlation_id)
  )::text,'sha256'),'hex');

  SELECT * INTO v_existing
    FROM public.sales_order_pi_final_payment_request_idempotency
   WHERE idempotency_key=btrim(p_idempotency_key)
   FOR UPDATE;
  IF FOUND THEN
    IF v_existing.operation <> 'ISSUE'
       OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.request_fingerprint IS DISTINCT FROM v_request_fingerprint THEN
      RAISE EXCEPTION 'FINAL_PAYMENT_PI_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    SELECT * INTO v_existing_request
      FROM public.sales_order_pi_final_payment_requests
     WHERE id=v_existing.final_payment_request_id;
    v_coverage:=public.get_sales_order_final_payment_coverage_v1(
      v_existing_request.order_id,
      v_existing_request.proforma_invoice_id,
      v_existing_request.commercial_version_id,
      v_existing_request.final_payable_total
    );
    RETURN QUERY SELECT
      v_existing_request.id,
      v_existing_request.revision_number,
      v_existing_request.customer_visible_pi_number,
      v_existing_request.final_payable_total,
      (v_coverage->>'balance_due')::numeric,
      true;
    RETURN;
  END IF;

  SELECT * INTO v_prior
    FROM public.sales_order_pi_final_payment_requests
   WHERE order_id=p_order_id
   ORDER BY revision_number DESC
   LIMIT 1
   FOR SHARE;

  v_revision:=coalesce(v_prior.revision_number,0)+1;

  INSERT INTO public.sales_order_pi_final_payment_requests(
    order_id,company_id,proforma_invoice_id,commercial_version_id,finance_dpl_receipt_id,
    revision_number,supersedes_request_id,customer_visible_pi_number,dpl_fingerprint,
    currency,taxable_total,tax_total,final_payable_total,
    verified_payment_at_issue,wallet_applied_at_issue,approved_credit_at_issue,balance_due_at_issue,
    payment_action,payment_link,payment_instructions,document_reference,request_fingerprint,
    reason,source_channel,source_reference,correlation_id,idempotency_key,issued_by,issued_role
  ) VALUES (
    p_order_id,v_order.company_id,p_pi_id,p_commercial_version_id,p_finance_dpl_receipt_id,
    v_revision,v_prior.id,v_pi.customer_visible_pi_number,v_totals->>'dpl_fingerprint',
    'INR',(v_totals->>'taxable_total')::numeric,(v_totals->>'tax_total')::numeric,
    (v_totals->>'final_payable_total')::numeric,
    (v_coverage->>'verified_payment_total')::numeric,
    (v_coverage->>'wallet_applied_total')::numeric,
    (v_coverage->>'approved_credit_total')::numeric,
    (v_coverage->>'balance_due')::numeric,
    v_action,nullif(btrim(p_payment_link),''),btrim(p_payment_instructions),
    btrim(p_document_reference),v_request_fingerprint,btrim(p_reason),
    upper(btrim(p_source_channel)),nullif(btrim(p_source_reference),''),
    btrim(p_correlation_id),btrim(p_idempotency_key),v_actor,v_role
  ) RETURNING * INTO v_request;

  INSERT INTO public.sales_order_pi_final_payment_request_audit(
    final_payment_request_id,order_id,proforma_invoice_id,commercial_version_id,
    finance_dpl_receipt_id,action,revision_number,actor_id,actor_role,reason,
    source_channel,source_reference,correlation_id,idempotency_key,metadata
  ) VALUES (
    v_request.id,p_order_id,p_pi_id,p_commercial_version_id,p_finance_dpl_receipt_id,
    CASE WHEN v_prior.id IS NULL THEN 'ISSUED' ELSE 'REISSUED' END,
    v_revision,v_actor,v_role,btrim(p_reason),upper(btrim(p_source_channel)),
    nullif(btrim(p_source_reference),''),btrim(p_correlation_id),btrim(p_idempotency_key),
    jsonb_build_object(
      'customer_visible_pi_number',v_pi.customer_visible_pi_number,
      'supersedes_request_id',v_prior.id,
      'dpl_fingerprint',v_request.dpl_fingerprint,
      'final_payable_total',v_request.final_payable_total,
      'balance_due_at_issue',v_request.balance_due_at_issue
    )
  );

  v_response:=jsonb_build_object(
    'final_payment_request_id',v_request.id,
    'revision_number',v_request.revision_number,
    'customer_visible_pi_number',v_request.customer_visible_pi_number,
    'final_payable_total',v_request.final_payable_total
  );
  INSERT INTO public.sales_order_pi_final_payment_request_idempotency(
    idempotency_key,operation,request_fingerprint,final_payment_request_id,actor_id,response
  ) VALUES (
    btrim(p_idempotency_key),'ISSUE',v_request_fingerprint,v_request.id,v_actor,v_response
  );

  RETURN QUERY SELECT
    v_request.id,v_request.revision_number,v_request.customer_visible_pi_number,
    v_request.final_payable_total,(v_coverage->>'balance_due')::numeric,false;
END;
$$;

REVOKE ALL ON FUNCTION public.issue_sales_order_pi_final_payment_request_v1(
  uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid
) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.issue_sales_order_pi_final_payment_request_v1(
  uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid
) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_sales_order_pi_final_payment_request_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_request public.sales_order_pi_final_payment_requests%rowtype;
  v_coverage jsonb;
  v_latest_delivery jsonb;
  v_effective_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_AUTHENTICATION_REQUIRED' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_PAYMENT_PI_ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  IF NOT public.is_internal_staff(auth.uid())
     AND v_order.company_id IS DISTINCT FROM public.auth_buyer_company_id() THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_COMPANY_MISMATCH' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_request
    FROM public.sales_order_pi_final_payment_requests
   WHERE order_id=p_order_id
   ORDER BY revision_number DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'order_id',p_order_id,
      'available',false,
      'final_payment_request',null
    );
  END IF;

  v_coverage:=public.get_sales_order_final_payment_coverage_v1(
    v_request.order_id,v_request.proforma_invoice_id,v_request.commercial_version_id,
    v_request.final_payable_total
  );
  v_effective_status:=CASE WHEN (v_coverage->>'settled')::boolean THEN 'SETTLED' ELSE 'PAYMENT_DUE' END;

  SELECT jsonb_build_object(
    'delivery_id',d.id,
    'channel',d.channel,
    'destination_reference',d.destination_reference,
    'provider_message_id',d.provider_message_id,
    'delivery_status',d.delivery_status,
    'evidence_reference',d.evidence_reference,
    'delivered_at',d.delivered_at,
    'created_at',d.created_at
  ) INTO v_latest_delivery
  FROM public.sales_order_pi_final_payment_request_deliveries d
  WHERE d.final_payment_request_id=v_request.id
  ORDER BY d.created_at DESC,d.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'order_id',v_request.order_id,
    'company_id',v_request.company_id,
    'available',true,
    'final_payment_request_id',v_request.id,
    'pi_id',v_request.proforma_invoice_id,
    'customer_visible_pi_number',v_request.customer_visible_pi_number,
    'revision_number',v_request.revision_number,
    'effective_status',v_effective_status,
    'finance_dpl_receipt_id',v_request.finance_dpl_receipt_id,
    'commercial_version_id',v_request.commercial_version_id,
    'dpl_fingerprint',v_request.dpl_fingerprint,
    'currency',v_request.currency,
    'taxable_total',v_request.taxable_total,
    'tax_total',v_request.tax_total,
    'final_payable_total',v_request.final_payable_total,
    'verified_payment_total',(v_coverage->>'verified_payment_total')::numeric,
    'wallet_applied_total',(v_coverage->>'wallet_applied_total')::numeric,
    'approved_credit_total',(v_coverage->>'approved_credit_total')::numeric,
    'credited_or_paid_total',(v_coverage->>'credited_or_paid_total')::numeric,
    'balance_due',(v_coverage->>'balance_due')::numeric,
    'settled',(v_coverage->>'settled')::boolean,
    'payment_action',v_request.payment_action,
    'payment_link',v_request.payment_link,
    'payment_instructions',v_request.payment_instructions,
    'document_reference',v_request.document_reference,
    'reason',v_request.reason,
    'source_channel',v_request.source_channel,
    'source_reference',v_request.source_reference,
    'issued_at',v_request.issued_at,
    'latest_delivery',v_latest_delivery,
    'facts_as_of',v_coverage->'facts_as_of',
    'final_invoice_must_not_request_payment',true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_sales_order_pi_final_payment_request_v1(uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_order_pi_final_payment_request_v1(uuid)
  TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.record_sales_order_pi_final_payment_delivery_v1(
  p_final_payment_request_id uuid,
  p_channel text,
  p_destination_reference text,
  p_provider_message_id text,
  p_delivery_status text,
  p_evidence_reference text,
  p_delivered_at timestamptz,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(delivery_id uuid, already_recorded boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_role text;
  v_request public.sales_order_pi_final_payment_requests%rowtype;
  v_channel text:=upper(btrim(coalesce(p_channel,'')));
  v_status text:=upper(btrim(coalesce(p_delivery_status,'')));
  v_fingerprint text;
  v_existing public.sales_order_pi_final_payment_request_idempotency%rowtype;
  v_delivery public.sales_order_pi_final_payment_request_deliveries%rowtype;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_DELIVERY_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;
  v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');

  IF p_final_payment_request_id IS NULL
     OR v_channel NOT IN ('WHATSAPP','IN_APP','EMAIL','SMS','OTHER')
     OR v_status NOT IN ('QUEUED','SENT','DELIVERED','FAILED')
     OR nullif(btrim(p_destination_reference),'') IS NULL
     OR nullif(btrim(p_evidence_reference),'') IS NULL
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL
     OR (v_status='DELIVERED' AND p_delivered_at IS NULL)
     OR (v_status<>'DELIVERED' AND p_delivered_at IS NOT NULL) THEN
    RAISE EXCEPTION 'FINAL_PAYMENT_PI_DELIVERY_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  SELECT * INTO v_request
    FROM public.sales_order_pi_final_payment_requests
   WHERE id=p_final_payment_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINAL_PAYMENT_PI_REQUEST_NOT_FOUND' USING ERRCODE='P0001'; END IF;

  v_fingerprint:=encode(extensions.digest(jsonb_build_object(
    'operation','DELIVER',
    'final_payment_request_id',p_final_payment_request_id,
    'channel',v_channel,
    'destination_reference',btrim(p_destination_reference),
    'provider_message_id',coalesce(nullif(btrim(p_provider_message_id),''),''),
    'delivery_status',v_status,
    'evidence_reference',btrim(p_evidence_reference),
    'delivered_at',p_delivered_at,
    'correlation_id',btrim(p_correlation_id)
  )::text,'sha256'),'hex');

  SELECT * INTO v_existing
    FROM public.sales_order_pi_final_payment_request_idempotency
   WHERE idempotency_key=btrim(p_idempotency_key)
   FOR UPDATE;
  IF FOUND THEN
    IF v_existing.operation<>'DELIVER'
       OR v_existing.actor_id IS DISTINCT FROM v_actor
       OR v_existing.request_fingerprint IS DISTINCT FROM v_fingerprint
       OR v_existing.final_payment_request_id IS DISTINCT FROM p_final_payment_request_id THEN
      RAISE EXCEPTION 'FINAL_PAYMENT_PI_DELIVERY_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT (v_existing.response->>'delivery_id')::uuid,true;
    RETURN;
  END IF;

  INSERT INTO public.sales_order_pi_final_payment_request_deliveries(
    final_payment_request_id,channel,destination_reference,provider_message_id,
    delivery_status,evidence_reference,delivered_at,actor_id,actor_role,
    correlation_id,idempotency_key
  ) VALUES (
    p_final_payment_request_id,v_channel,btrim(p_destination_reference),
    nullif(btrim(p_provider_message_id),''),v_status,btrim(p_evidence_reference),
    p_delivered_at,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)
  ) RETURNING * INTO v_delivery;

  INSERT INTO public.sales_order_pi_final_payment_request_idempotency(
    idempotency_key,operation,request_fingerprint,final_payment_request_id,actor_id,response
  ) VALUES (
    btrim(p_idempotency_key),'DELIVER',v_fingerprint,p_final_payment_request_id,v_actor,
    jsonb_build_object('delivery_id',v_delivery.id,'delivery_status',v_delivery.delivery_status)
  );

  RETURN QUERY SELECT v_delivery.id,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_sales_order_pi_final_payment_delivery_v1(
  uuid,text,text,text,text,text,timestamptz,text,text,uuid
) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_sales_order_pi_final_payment_delivery_v1(
  uuid,text,text,text,text,text,timestamptz,text,text,uuid
) TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_final_invoice_latest_final_payment_request_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_request public.sales_order_pi_final_payment_requests%rowtype;
  v_totals jsonb;
  v_coverage jsonb;
BEGIN
  SELECT * INTO v_request
    FROM public.sales_order_pi_final_payment_requests
   WHERE order_id=NEW.order_id
   ORDER BY revision_number DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FINAL_INVOICE_FINAL_PAYMENT_REQUEST_REQUIRED' USING ERRCODE='55000';
  END IF;

  IF v_request.proforma_invoice_id IS DISTINCT FROM NEW.proforma_invoice_id
     OR v_request.commercial_version_id IS DISTINCT FROM NEW.commercial_version_id
     OR v_request.finance_dpl_receipt_id IS DISTINCT FROM NEW.finance_dpl_receipt_id THEN
    RAISE EXCEPTION 'FINAL_INVOICE_FINAL_PAYMENT_REQUEST_STALE' USING ERRCODE='40001';
  END IF;

  v_totals:=public.calculate_finance_dpl_commercial_totals_v1(
    NEW.order_id,NEW.proforma_invoice_id,NEW.commercial_version_id,NEW.finance_dpl_receipt_id
  );

  IF NEW.invoice_date < (v_request.issued_at AT TIME ZONE 'Asia/Kolkata')::date THEN
    RAISE EXCEPTION 'FINAL_INVOICE_DATE_PRECEDES_FINAL_PAYMENT_REQUEST' USING ERRCODE='22007';
  END IF;

  IF round(NEW.gross_total,2) IS DISTINCT FROM round((v_totals->>'final_payable_total')::numeric,2)
     OR round(v_request.final_payable_total,2) IS DISTINCT FROM round((v_totals->>'final_payable_total')::numeric,2)
     OR v_request.dpl_fingerprint IS DISTINCT FROM v_totals->>'dpl_fingerprint' THEN
    RAISE EXCEPTION 'FINAL_INVOICE_FINAL_PAYMENT_TOTAL_MISMATCH' USING ERRCODE='40001';
  END IF;

  v_coverage:=public.get_sales_order_final_payment_coverage_v1(
    NEW.order_id,NEW.proforma_invoice_id,NEW.commercial_version_id,v_request.final_payable_total
  );
  IF coalesce((v_coverage->>'settled')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FINAL_INVOICE_FINAL_PAYMENT_NOT_SETTLED: balance_due=%',
      v_coverage->>'balance_due' USING ERRCODE='55000';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.enforce_final_invoice_latest_final_payment_request_v1()
  FROM PUBLIC,anon,authenticated,service_role;

DROP TRIGGER IF EXISTS trg_final_invoice_requires_final_payment_request
  ON public.final_invoices;
CREATE TRIGGER trg_final_invoice_requires_final_payment_request
  BEFORE INSERT ON public.final_invoices
  FOR EACH ROW EXECUTE FUNCTION public.enforce_final_invoice_latest_final_payment_request_v1();

COMMENT ON TABLE public.sales_order_pi_final_payment_requests IS
  'Immutable DPL-bound final-payment revisions under the existing customer-visible PI identity. No second PI number is created.';
COMMENT ON TABLE public.sales_order_pi_final_payment_request_deliveries IS
  'Append-only M4 delivery evidence for final-payment PI revisions.';
COMMENT ON FUNCTION public.issue_sales_order_pi_final_payment_request_v1(
  uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid
) IS
  'Issues/reissues the final-payment demand under the existing PI number, bound to exact Finance DPL and commercial truth.';
COMMENT ON FUNCTION public.get_sales_order_pi_final_payment_request_v1(uuid) IS
  'Buyer/internal projection of the latest final-payment PI revision with current verified payment, wallet, credit and exact balance due.';
COMMENT ON FUNCTION public.enforce_final_invoice_latest_final_payment_request_v1() IS
  'Final invoice fail-closed gate: latest exact DPL-bound final-payment PI revision must exist, match final total, and be fully settled. Final invoice never requests payment.';