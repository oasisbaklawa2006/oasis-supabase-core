-- PF-6C correction: Operations Clearance must consume the advance requirement
-- frozen in the exact commercial version/PI. It must never independently
-- recompute policy, because historical versions preserve the rule in force when
-- the SO was frozen. Wallet coverage is current effective coverage only: a
-- reversed debit cannot continue to finance a release decision.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.get_finance_operations_clearance_facts_v1(
  p_order_id uuid,
  p_pi_id uuid,
  p_commercial_version_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_payment jsonb;
  v_value numeric;
  v_required numeric;
  v_verified numeric;
  v_wallet_applied numeric;
  v_credit numeric;
  v_covered numeric;
  v_latest_decision text;
  v_latest_event uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_internal_staff(auth.uid()) THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_FACTS_INTERNAL_ONLY' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_order_payment_binding_v1(p_order_id, p_pi_id, p_commercial_version_id);
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices
   WHERE id = p_pi_id AND order_id = p_order_id AND commercial_version_id = p_commercial_version_id;
  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE id = p_commercial_version_id AND order_id = p_order_id;
  IF v_order.company_id IS NULL OR v_pi.id IS NULL OR v_version.id IS NULL THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_BINDING_INCOMPLETE' USING ERRCODE = '40001';
  END IF;

  v_value := v_version.sales_order_value;
  v_required := v_version.advance_required;
  IF v_value IS NULL OR v_value < 0 OR v_required IS NULL OR v_required < 0
     OR (v_value > 0 AND v_required <= 0)
     OR v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot
     OR v_pi.frozen_snapshot_fingerprint IS DISTINCT FROM v_version.snapshot_fingerprint
     OR md5(v_pi.frozen_commercial_snapshot::text) IS DISTINCT FROM v_pi.frozen_snapshot_fingerprint
     OR (v_pi.frozen_commercial_snapshot ->> 'sales_order_value')::numeric IS DISTINCT FROM v_value
     OR (v_pi.frozen_commercial_snapshot ->> 'advance_required')::numeric IS DISTINCT FROM v_required THEN
    RAISE EXCEPTION 'FINANCE_CLEARANCE_COMMERCIAL_TRUTH_INCOMPLETE' USING ERRCODE = '40001';
  END IF;

  v_payment := public.get_order_payment_facts_v1(p_pi_id);
  v_verified := coalesce((v_payment ->> 'verified_total')::numeric, 0);

  -- Only a positive, still-effective governed debit applied to this exact
  -- commercial obligation contributes. A later reversal_of_id removes the
  -- original debit from coverage instead of leaving stale funding behind.
  SELECT coalesce(sum(w.amount), 0) INTO v_wallet_applied
    FROM public.wallet_transactions w
   WHERE w.order_id = p_order_id
     AND w.proforma_invoice_id = p_pi_id
     AND w.commercial_version_id = p_commercial_version_id
     AND w.direction = 'debit'
     AND w.amount > 0
     AND NOT EXISTS (
       SELECT 1 FROM public.wallet_transactions r
        WHERE r.reversal_of_id = w.id
     );

  SELECT coalesce(sum(c.requested_amount), 0) INTO v_credit
    FROM public.credit_requests c
   WHERE c.order_id = p_order_id
     AND c.proforma_invoice_id = p_pi_id
     AND c.commercial_version_id = p_commercial_version_id
     AND c.status = 'approved'
     AND c.requested_amount > 0
     AND (c.expires_at IS NULL OR c.expires_at > statement_timestamp());

  v_covered := v_verified + v_wallet_applied + v_credit;

  SELECT e.id, e.decision INTO v_latest_event, v_latest_decision
    FROM public.finance_clearance_events e
   WHERE e.order_id = p_order_id AND e.clearance_type = 'OPERATIONS'
   ORDER BY e.created_at DESC, e.id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'company_id', v_order.company_id,
    'pi_id', p_pi_id,
    'commercial_version_id', p_commercial_version_id,
    'commercial_value', v_value,
    'advance_rule_version', v_version.advance_rule_version,
    'required_advance', v_required,
    'verified_payment_amount', v_verified,
    'wallet_applied_amount', v_wallet_applied,
    'approved_credit_amount', v_credit,
    'covered_amount', v_covered,
    'eligible_for_operations_clearance', (v_covered >= v_required),
    'latest_clearance_event_id', v_latest_event,
    'latest_clearance_decision', v_latest_decision,
    'payment_facts', v_payment,
    'facts_as_of', statement_timestamp(),
    'payment_verified_is_not_clearance', true,
    'advance_requirement_is_frozen_commercial_truth', true,
    'wallet_coverage_excludes_reversed_debits', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid) TO authenticated;

COMMENT ON FUNCTION public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid) IS
  'PF-6C Finance clearance facts. Required advance is consumed from the exact immutable commercial version/PI; policy is never recomputed here. Reversed wallet debits do not fund clearance.';
