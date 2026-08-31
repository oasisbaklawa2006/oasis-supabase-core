-- Finance/Exit hardening after the invoice-date complaint clock correction.
--
-- 1. Keep final_invoices private while restoring the customer-facing complaint
--    window for the buyer's own company through an explicitly scoped SECURITY
--    DEFINER row function behind the mandatory SECURITY INVOKER view.
-- 2. Preserve delivery-proof idempotency even if invoice status/lineage changes
--    after the original proof was recorded. Replay eligibility is decided from
--    the immutable existing proof first; create-time eligibility still requires
--    a currently ISSUED final invoice.

SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

-- The helper owns the privileged base-table read and carries the full caller
-- scope explicitly. Buyers are not granted direct SELECT on final_invoices.
CREATE OR REPLACE FUNCTION public.get_commercial_complaint_window_rows_v1()
RETURNS TABLE(
  order_id uuid,
  delivery_proof_id uuid,
  delivered_at timestamptz,
  complaint_deadline timestamptz,
  window_status text,
  complaint_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
  SELECT
    f.order_id,
    d.id AS delivery_proof_id,
    d.delivered_at,
    public.complaint_deadline_from_invoice_v1(f.invoice_date) AS complaint_deadline,
    CASE
      WHEN EXISTS(
        SELECT 1 FROM public.commercial_complaints c
        WHERE c.order_id=f.order_id
          AND NOT EXISTS(
            SELECT 1 FROM public.commercial_adjustments a
            WHERE a.complaint_id=c.id
          )
      ) THEN 'RESOLUTION_PENDING'
      WHEN statement_timestamp()<public.complaint_deadline_from_invoice_v1(f.invoice_date) THEN 'OPEN'
      WHEN EXISTS(
        SELECT 1 FROM public.commercial_complaints c
        WHERE c.order_id=f.order_id
      ) THEN 'RESOLVED'
      ELSE 'EXPIRED_NO_COMPLAINT'
    END::text AS window_status,
    (
      SELECT count(*)
      FROM public.commercial_complaints c
      WHERE c.order_id=f.order_id
    ) AS complaint_count
  FROM public.final_invoices f
  LEFT JOIN public.delivery_proofs d ON d.order_id=f.order_id
  WHERE f.status='ISSUED'
    AND (
      auth.role()='service_role'
      OR public.is_internal_staff(auth.uid())
      OR f.company_id=public.auth_buyer_company_id()
    );
$$;
REVOKE ALL ON FUNCTION public.get_commercial_complaint_window_rows_v1()
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_commercial_complaint_window_rows_v1()
  TO authenticated,service_role;
COMMENT ON FUNCTION public.get_commercial_complaint_window_rows_v1() IS
  'Privileged but caller-scoped complaint-window rows. Returns all rows only to service_role, internal staff rows to authenticated staff, and own-company rows to authenticated buyers.';

CREATE OR REPLACE VIEW public.commercial_complaint_window_v1
WITH (security_invoker=true) AS
SELECT *
FROM public.get_commercial_complaint_window_rows_v1();
REVOKE ALL ON public.commercial_complaint_window_v1 FROM PUBLIC,anon;
GRANT SELECT ON public.commercial_complaint_window_v1 TO authenticated,service_role;
COMMENT ON VIEW public.commercial_complaint_window_v1 IS
  'Canonical final-invoice-date ticket window exposed through a SECURITY INVOKER view over a bounded caller-scoped helper. Delivery proof is optional logistics evidence and never controls the clock.';

CREATE OR REPLACE FUNCTION public.record_delivery_proof_v1(
  p_order_id uuid,
  p_delivered_at timestamptz,
  p_recipient_reference text,
  p_evidence_references jsonb,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(
  delivery_proof_id uuid,
  complaint_deadline timestamptz,
  already_recorded boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public,auth,extensions
AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_role text;
  v_dispatch public.dispatch_proof_packets%rowtype;
  v_invoice public.final_invoices%rowtype;
  v_existing public.delivery_proofs%rowtype;
  v_fp text;
  v_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL
     OR v_actor IS DISTINCT FROM auth.uid()
     OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;

  PERFORM public.assert_order_transition_role('gate_release');
  v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');

  IF p_delivered_at IS NULL
     OR p_delivered_at>statement_timestamp()+interval '5 minutes'
     OR nullif(btrim(p_recipient_reference),'') IS NULL
     OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references)=0
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  SELECT * INTO v_dispatch
  FROM public.dispatch_proof_packets
  WHERE order_id=p_order_id;
  IF NOT FOUND OR p_delivered_at<v_dispatch.dispatched_at THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_DISPATCH_BINDING_INVALID' USING ERRCODE='40001';
  END IF;

  v_fp:=encode(
    extensions.digest(
      jsonb_build_object(
        'order_id',p_order_id,
        'dispatch_proof_id',v_dispatch.id,
        'delivered_at',p_delivered_at,
        'recipient_reference',btrim(p_recipient_reference),
        'evidence_references',p_evidence_references
      )::text,
      'sha256'
    ),
    'hex'
  );

  -- Replay is authoritative before create-time invoice eligibility. This keeps
  -- an already-recorded proof replayable after compensating invoice activity.
  SELECT * INTO v_existing
  FROM public.delivery_proofs
  WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.recorded_by IS DISTINCT FROM v_actor
       OR v_existing.proof_fingerprint IS DISTINCT FROM v_fp THEN
      RAISE EXCEPTION 'DELIVERY_PROOF_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;

    -- Recover the invoice lineage that existed when this immutable proof was
    -- recorded. For legacy proofs that pre-date final-invoice issuance, fall
    -- forward to the earliest invoice for the order. Status is deliberately
    -- ignored on replay so a later compensating/void state cannot break it.
    SELECT * INTO v_invoice
    FROM public.final_invoices
    WHERE order_id=v_existing.order_id
    ORDER BY
      (created_at<=v_existing.created_at) DESC,
      CASE WHEN created_at<=v_existing.created_at THEN created_at END DESC,
      CASE WHEN created_at>v_existing.created_at THEN created_at END ASC,
      id
    LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'DELIVERY_PROOF_INVOICE_LINEAGE_MISSING' USING ERRCODE='55000';
    END IF;

    v_deadline:=public.complaint_deadline_from_invoice_v1(v_invoice.invoice_date);
    RETURN QUERY SELECT v_existing.id,v_deadline,true;
    RETURN;
  END IF;

  -- New proof creation still requires the currently issued canonical invoice.
  SELECT * INTO v_invoice
  FROM public.final_invoices
  WHERE order_id=p_order_id AND status='ISSUED'
  ORDER BY created_at DESC,id DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_FINAL_INVOICE_REQUIRED' USING ERRCODE='55000';
  END IF;
  v_deadline:=public.complaint_deadline_from_invoice_v1(v_invoice.invoice_date);

  IF EXISTS(
    SELECT 1 FROM public.delivery_proofs WHERE order_id=p_order_id
  ) THEN
    RAISE EXCEPTION 'DELIVERY_PROOF_ALREADY_RECORDED' USING ERRCODE='55000';
  END IF;

  INSERT INTO public.delivery_proofs(
    order_id,
    dispatch_proof_id,
    delivered_at,
    recipient_reference,
    evidence_references,
    proof_fingerprint,
    recorded_by,
    recorded_role,
    correlation_id,
    idempotency_key
  ) VALUES (
    p_order_id,
    v_dispatch.id,
    p_delivered_at,
    btrim(p_recipient_reference),
    p_evidence_references,
    v_fp,
    v_actor,
    v_role,
    btrim(p_correlation_id),
    btrim(p_idempotency_key)
  ) RETURNING * INTO v_existing;

  RETURN QUERY SELECT v_existing.id,v_deadline,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid)
  TO authenticated;

COMMENT ON FUNCTION public.record_delivery_proof_v1(uuid,timestamptz,text,jsonb,text,text,uuid) IS
  'Records immutable delivery evidence. New writes require an issued final invoice; exact idempotent replays recover the original invoice-date complaint deadline even after later invoice status/lineage changes.';
