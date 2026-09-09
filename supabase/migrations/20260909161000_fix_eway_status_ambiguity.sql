-- Point100 blocker repair: qualify final_invoices.status inside the E-way
-- evidence RPC. The function RETURNS a column named status, so the original
-- unqualified predicate `status='ISSUED'` is ambiguous in PL/pgSQL at runtime.
-- Preserve the existing Finance+AAL2, immutability and idempotency authority;
-- this migration changes only the ambiguous relation-column reference.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.record_eway_bill_evidence_v1(
  p_final_invoice_id uuid,
  p_status text,
  p_eway_bill_number text,
  p_document_reference text,
  p_policy_reason text,
  p_valid_from timestamptz,
  p_valid_until timestamptz,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(eway_evidence_id uuid,status text,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v_actor uuid:=coalesce(p_actor_id,auth.uid());
  v_role text;
  v_invoice public.final_invoices%rowtype;
  v_existing public.eway_bill_evidence%rowtype;
  v_status text:=upper(btrim(coalesce(p_status,'')));
BEGIN
  v_role:=public.assert_finance_clearance_actor_v1(v_actor);
  IF v_status NOT IN('VALIDATED','NOT_REQUIRED') OR length(btrim(coalesce(p_policy_reason,'')))<5
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'EWAY_BILL_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;
  IF v_status='VALIDATED' AND (nullif(btrim(p_eway_bill_number),'') IS NULL OR nullif(btrim(p_document_reference),'') IS NULL) THEN
    RAISE EXCEPTION 'EWAY_BILL_VALIDATION_DOCUMENT_REQUIRED' USING ERRCODE='P0001';
  END IF;
  IF v_status='NOT_REQUIRED' AND nullif(btrim(coalesce(p_eway_bill_number,'')),'') IS NOT NULL THEN
    RAISE EXCEPTION 'EWAY_BILL_NOT_REQUIRED_CANNOT_HAVE_NUMBER' USING ERRCODE='P0001';
  END IF;
  IF p_valid_until IS NOT NULL AND p_valid_from IS NOT NULL AND p_valid_until<=p_valid_from THEN
    RAISE EXCEPTION 'EWAY_BILL_VALIDITY_INVALID' USING ERRCODE='P0001';
  END IF;

  SELECT fi.* INTO v_invoice
  FROM public.final_invoices fi
  WHERE fi.id=p_final_invoice_id AND fi.status='ISSUED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('eway:'||v_invoice.order_id::text,0));
  SELECT * INTO v_existing FROM public.eway_bill_evidence WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.final_invoice_id IS DISTINCT FROM p_final_invoice_id
       OR v_existing.status IS DISTINCT FROM v_status OR coalesce(v_existing.eway_bill_number,'') IS DISTINCT FROM coalesce(nullif(btrim(p_eway_bill_number),''),'')
       OR v_existing.policy_reason IS DISTINCT FROM btrim(p_policy_reason) THEN
      RAISE EXCEPTION 'EWAY_BILL_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.status,true;
    RETURN;
  END IF;
  IF EXISTS(SELECT 1 FROM public.eway_bill_evidence e WHERE e.final_invoice_id=p_final_invoice_id) THEN
    RAISE EXCEPTION 'EWAY_BILL_DECISION_ALREADY_RECORDED' USING ERRCODE='55000';
  END IF;
  INSERT INTO public.eway_bill_evidence(order_id,final_invoice_id,status,eway_bill_number,document_reference,policy_reason,
    valid_from,valid_until,actor_id,actor_role,correlation_id,idempotency_key)
  VALUES(v_invoice.order_id,p_final_invoice_id,v_status,CASE WHEN v_status='VALIDATED' THEN btrim(p_eway_bill_number) ELSE NULL END,
    CASE WHEN v_status='VALIDATED' THEN btrim(p_document_reference) ELSE nullif(btrim(p_document_reference),'') END,btrim(p_policy_reason),
    p_valid_from,p_valid_until,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id,v_existing.status,false;
END;
$$;

REVOKE ALL ON FUNCTION public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamptz,timestamptz,text,text,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.record_eway_bill_evidence_v1(uuid,text,text,text,text,timestamptz,timestamptz,text,text,uuid) TO authenticated;
