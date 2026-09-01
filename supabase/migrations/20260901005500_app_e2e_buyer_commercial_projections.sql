-- APP-E2E buyer-safe commercial projections.
--
-- These RPCs compose canonical orders, immutable commercial versions, canonical
-- PI truth, payment authority, wallet/credit authority and Finance clearance.
-- They create no shadow commercial state and expose no internal evidence refs.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE OR REPLACE FUNCTION public.derive_customer_order_finance_status_v1(
  p_clearance_decision text,
  p_pi_id uuid,
  p_pi_status text,
  p_covered_amount numeric,
  p_advance_required numeric
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path=pg_catalog,public
AS $$
  SELECT CASE p_clearance_decision
    WHEN 'GRANTED' THEN 'cleared'
    WHEN 'DENIED' THEN 'hold'
    WHEN 'REVOKED' THEN 'clearance_revoked'
    ELSE CASE
      WHEN p_pi_id IS NULL THEN 'pi_pending'
      WHEN coalesce(p_pi_status,'') <> 'ISSUED' THEN 'pi_ready_for_issue'
      WHEN coalesce(p_covered_amount,0) >= coalesce(p_advance_required,0) THEN 'finance_review_pending'
      ELSE 'advance_pending'
    END
  END::text;
$$;
REVOKE ALL ON FUNCTION public.derive_customer_order_finance_status_v1(text,uuid,text,numeric,numeric)
  FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION public.derive_customer_order_finance_status_v1(text,uuid,text,numeric,numeric) IS
  'Canonical buyer Finance status derivation shared by list and detail projections.';

CREATE OR REPLACE FUNCTION public.customer_sales_order_commercial_facts_v1()
RETURNS TABLE(
  order_id uuid,
  order_number text,
  commercial_version_id uuid,
  commercial_version_number integer,
  frozen_sales_order_value numeric,
  requested_dispatch_date date,
  promised_dispatch_date date,
  commercial_status text,
  finance_status text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  WITH buyer AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  ), customer_status AS (
    SELECT * FROM public.customer_order_status_v1()
  ), latest_clearance AS (
    SELECT DISTINCT ON (e.order_id)
      e.order_id,
      e.decision
    FROM public.finance_clearance_events e
    WHERE e.clearance_type='OPERATIONS'
    ORDER BY e.order_id,e.created_at DESC,e.id DESC
  ), current_pi AS (
    SELECT DISTINCT ON (p.order_id)
      p.order_id,
      p.id AS pi_id,
      p.status AS pi_status
    FROM public.sales_order_proforma_invoices p
    JOIN public.orders o ON o.id=p.order_id
    JOIN buyer b ON b.company_id=o.company_id
    WHERE p.status IN ('READY_FOR_ISSUE','ISSUED')
      AND p.commercial_version_number=o.commercial_current_version
    ORDER BY p.order_id, CASE p.status WHEN 'ISSUED' THEN 0 ELSE 1 END, p.created_at DESC, p.id DESC
  ), finance_coverage AS (
    SELECT
      cp.order_id,
      coalesce((public.get_order_payment_facts_v1(cp.pi_id)->>'verified_total')::numeric,0)
      + coalesce(w.wallet_applied,0)
      + coalesce(cr.credit_applied,0) AS covered_amount
    FROM current_pi cp
    LEFT JOIN LATERAL (
      SELECT coalesce(sum(wt.amount),0) AS wallet_applied
      FROM public.wallet_transactions wt
      JOIN public.orders o ON o.id=cp.order_id
      JOIN public.sales_order_commercial_versions v
        ON v.order_id=o.id AND v.version_number=o.commercial_current_version
      WHERE wt.order_id=cp.order_id
        AND wt.proforma_invoice_id=cp.pi_id
        AND wt.commercial_version_id=v.id
        AND wt.direction='debit'
        AND wt.amount>0
        AND NOT EXISTS(SELECT 1 FROM public.wallet_transactions r WHERE r.reversal_of_id=wt.id)
    ) w ON true
    LEFT JOIN LATERAL (
      SELECT coalesce(sum(c.requested_amount),0) AS credit_applied
      FROM public.credit_requests c
      JOIN public.orders o ON o.id=cp.order_id
      JOIN public.sales_order_commercial_versions v
        ON v.order_id=o.id AND v.version_number=o.commercial_current_version
      WHERE c.order_id=cp.order_id
        AND c.proforma_invoice_id=cp.pi_id
        AND c.commercial_version_id=v.id
        AND c.status='approved'
        AND c.requested_amount>0
        AND (c.expires_at IS NULL OR c.expires_at>statement_timestamp())
    ) cr ON true
  )
  SELECT
    o.id,
    o.order_number,
    v.id,
    v.version_number,
    v.sales_order_value,
    o.requested_dispatch_date,
    s.promised_dispatch_date,
    s.customer_stage,
    public.derive_customer_order_finance_status_v1(
      lc.decision,
      cp.pi_id,
      cp.pi_status,
      fc.covered_amount,
      v.advance_required
    ),
    o.created_at,
    s.updated_at
  FROM public.orders o
  JOIN buyer b ON b.company_id IS NOT NULL AND b.company_id=o.company_id
  JOIN customer_status s ON s.order_id=o.id
  LEFT JOIN public.sales_order_commercial_versions v
    ON v.order_id=o.id AND v.version_number=o.commercial_current_version
  LEFT JOIN latest_clearance lc ON lc.order_id=o.id
  LEFT JOIN current_pi cp ON cp.order_id=o.id
  LEFT JOIN finance_coverage fc ON fc.order_id=o.id
  WHERE coalesce(o.is_waste,false)=false
    AND coalesce(o.is_duplicate,false)=false
  ORDER BY o.created_at DESC,o.id;
$$;
REVOKE ALL ON FUNCTION public.customer_sales_order_commercial_facts_v1()
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_sales_order_commercial_facts_v1()
  TO authenticated;
COMMENT ON FUNCTION public.customer_sales_order_commercial_facts_v1() IS
  'Buyer-company scoped Sales Order projection. Uses orders.order_number plus the immutable current commercial version and exposes only customer-safe stage/Finance status.';

CREATE OR REPLACE FUNCTION public.customer_proforma_invoice_facts_v1()
RETURNS TABLE(
  pi_id uuid,
  customer_visible_pi_number text,
  order_id uuid,
  order_number text,
  commercial_version_id uuid,
  commercial_version_number integer,
  status text,
  issued_at timestamptz,
  frozen_customer_total numeric,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  WITH buyer AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    p.id,
    CASE WHEN p.status='ISSUED' THEN p.customer_visible_pi_number ELSE NULL END,
    p.order_id,
    o.order_number,
    p.commercial_version_id,
    p.commercial_version_number,
    p.status,
    CASE WHEN p.status='ISSUED' THEN p.issued_at ELSE NULL END,
    (p.frozen_commercial_snapshot->>'sales_order_value')::numeric,
    p.created_at
  FROM public.sales_order_proforma_invoices p
  JOIN public.orders o ON o.id=p.order_id
  JOIN buyer b ON b.company_id IS NOT NULL AND b.company_id=o.company_id
  WHERE coalesce(o.is_waste,false)=false
    AND coalesce(o.is_duplicate,false)=false
    AND p.status IN ('READY_FOR_ISSUE','ISSUED')
  ORDER BY p.created_at DESC,p.id;
$$;
REVOKE ALL ON FUNCTION public.customer_proforma_invoice_facts_v1()
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_proforma_invoice_facts_v1()
  TO authenticated;
COMMENT ON FUNCTION public.customer_proforma_invoice_facts_v1() IS
  'Buyer-company scoped PI projection. Number and issued_at remain hidden until canonical ISSUE; totals come only from the frozen commercial snapshot.';

CREATE OR REPLACE FUNCTION public.customer_order_finance_facts_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_company_id uuid:=public.customer_buyer_eligible_company_id();
  v_order public.orders%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_payment jsonb:='{}'::jsonb;
  v_verified numeric:=0;
  v_wallet_applied numeric:=0;
  v_credit numeric:=0;
  v_covered numeric:=0;
  v_decision text;
BEGIN
  IF auth.uid() IS NULL OR v_company_id IS NULL THEN
    RAISE EXCEPTION 'BUYER_FINANCE_COMPANY_CONTEXT_REQUIRED' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id=p_order_id
    AND company_id=v_company_id
    AND coalesce(is_waste,false)=false
    AND coalesce(is_duplicate,false)=false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUYER_FINANCE_ORDER_NOT_AVAILABLE' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_version
  FROM public.sales_order_commercial_versions
  WHERE order_id=v_order.id
    AND version_number=v_order.commercial_current_version;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'order_id',v_order.id,
      'order_number',v_order.order_number,
      'finance_status','commercial_version_pending',
      'commercial_version_id',NULL,
      'pi_id',NULL,
      'pi_number',NULL
    );
  END IF;

  SELECT * INTO v_pi
  FROM public.sales_order_proforma_invoices
  WHERE order_id=v_order.id
    AND commercial_version_id=v_version.id
    AND status IN ('READY_FOR_ISSUE','ISSUED')
  ORDER BY CASE status WHEN 'ISSUED' THEN 0 ELSE 1 END,created_at DESC,id DESC
  LIMIT 1;

  IF v_pi.id IS NOT NULL THEN
    v_payment:=public.get_order_payment_facts_v1(v_pi.id);
    v_verified:=coalesce((v_payment->>'verified_total')::numeric,0);

    SELECT coalesce(sum(w.amount),0) INTO v_wallet_applied
    FROM public.wallet_transactions w
    WHERE w.order_id=v_order.id
      AND w.proforma_invoice_id=v_pi.id
      AND w.commercial_version_id=v_version.id
      AND w.direction='debit'
      AND w.amount>0
      AND NOT EXISTS(
        SELECT 1 FROM public.wallet_transactions r WHERE r.reversal_of_id=w.id
      );

    SELECT coalesce(sum(c.requested_amount),0) INTO v_credit
    FROM public.credit_requests c
    WHERE c.order_id=v_order.id
      AND c.proforma_invoice_id=v_pi.id
      AND c.commercial_version_id=v_version.id
      AND c.status='approved'
      AND c.requested_amount>0
      AND (c.expires_at IS NULL OR c.expires_at>statement_timestamp());
  END IF;

  v_covered:=v_verified+v_wallet_applied+v_credit;

  SELECT e.decision INTO v_decision
  FROM public.finance_clearance_events e
  WHERE e.order_id=v_order.id AND e.clearance_type='OPERATIONS'
  ORDER BY e.created_at DESC,e.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'order_id',v_order.id,
    'order_number',v_order.order_number,
    'commercial_version_id',v_version.id,
    'commercial_version_number',v_version.version_number,
    'commercial_value',v_version.sales_order_value,
    'required_advance',v_version.advance_required,
    'pi_id',v_pi.id,
    'pi_number',CASE WHEN v_pi.status='ISSUED' THEN v_pi.customer_visible_pi_number ELSE NULL END,
    'pi_status',v_pi.status,
    'verified_payment_amount',v_verified,
    'wallet_applied_amount',v_wallet_applied,
    'approved_credit_amount',v_credit,
    'covered_amount',v_covered,
    'advance_covered',(v_covered>=v_version.advance_required),
    'finance_status',public.derive_customer_order_finance_status_v1(
      v_decision,
      v_pi.id,
      v_pi.status,
      v_covered,
      v_version.advance_required
    ),
    'facts_as_of',statement_timestamp(),
    'customer_safe_projection',true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.customer_order_finance_facts_v1(uuid)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.customer_order_finance_facts_v1(uuid)
  TO authenticated;
COMMENT ON FUNCTION public.customer_order_finance_facts_v1(uuid) IS
  'Buyer-safe order Finance projection. Composes canonical payment, wallet, approved-credit and OPERATIONS clearance truth while omitting payment references, internal evidence and clearance event IDs.';
