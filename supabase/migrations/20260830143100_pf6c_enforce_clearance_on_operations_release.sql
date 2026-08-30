-- PF-6C enforcement: legacy lifecycle RPCs may transition an order into
-- manufacturing/production only when the canonical Finance Operations
-- Clearance projection is currently GRANTED for the exact current commercial
-- version and PI. Payment-status fields are retained only as compatibility
-- evidence and are no longer release authority.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.assert_active_operations_clearance_v1(p_order_id uuid)
RETURNS public.finance_operations_clearance_authority_v1
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_clear public.finance_operations_clearance_authority_v1%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_pi public.sales_order_proforma_invoices%rowtype;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPERATIONS_RELEASE_ORDER_NOT_FOUND' USING ERRCODE='P0001'; END IF;

  SELECT * INTO v_clear FROM public.finance_operations_clearance_authority_v1
   WHERE order_id=p_order_id;
  IF NOT FOUND OR NOT coalesce(v_clear.operations_cleared,false) THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_REQUIRED' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE id=v_clear.commercial_version_id AND order_id=p_order_id;
  IF NOT FOUND OR v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_STALE_VERSION' USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_pi FROM public.sales_order_proforma_invoices
   WHERE id=v_clear.proforma_invoice_id
     AND order_id=p_order_id
     AND commercial_version_id=v_clear.commercial_version_id
     AND status IN ('READY_FOR_ISSUE','ISSUED');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FINANCE_OPERATIONS_CLEARANCE_PI_STALE' USING ERRCODE='40001';
  END IF;

  RETURN v_clear;
END;
$$;
REVOKE ALL ON FUNCTION public.assert_active_operations_clearance_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_active_operations_clearance_v1(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.release_order_to_manufacturing_v1(
  p_order_id uuid,
  p_payment_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v public.orders%rowtype;
  v_clear public.finance_operations_clearance_authority_v1%rowtype;
BEGIN
  PERFORM public.assert_order_transition_role('release_manufacturing');
  SELECT * INTO v FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found')));
  END IF;
  IF v.status IN ('manufacturing','in_production','packed_ready','cleared_for_dispatch','dispatched','delivered') THEN
    RETURN jsonb_build_object('ok',true,'order_id',p_order_id,'new_status',v.status,'already_applied',true);
  END IF;
  IF v.status NOT IN ('awaiting_advance','confirmed','submitted','awaiting_payment','awaiting_final_payment') THEN
    RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status')));
  END IF;

  BEGIN
    v_clear := public.assert_active_operations_clearance_v1(p_order_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok',false,
      'blockers',jsonb_build_array(jsonb_build_object('code','finance_operations_clearance_required','message',SQLERRM))
    );
  END;

  UPDATE public.orders SET status='manufacturing' WHERE id=p_order_id;
  INSERT INTO public.order_status_history(order_id,old_status,new_status,changed_by)
  VALUES(p_order_id,v.status,'manufacturing',auth.uid());
  INSERT INTO public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value)
  VALUES('ORDER_RELEASED_TO_MANUFACTURING','Finance','orders',p_order_id::text,auth.uid(),'high',
    jsonb_build_object('finance_clearance_event_id',v_clear.clearance_event_id,
      'payment_status_argument_ignored_as_authority',p_payment_status));
  RETURN jsonb_build_object('ok',true,'order_id',p_order_id,'new_status','manufacturing','already_applied',false,
    'finance_clearance_event_id',v_clear.clearance_event_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.release_order_to_in_production_v1(
  p_order_id uuid,
  p_payment_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,auth
AS $$
DECLARE
  v public.orders%rowtype;
  v_clear public.finance_operations_clearance_authority_v1%rowtype;
BEGIN
  PERFORM public.assert_order_transition_role('release_manufacturing');
  SELECT * INTO v FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found')));
  END IF;
  IF v.status IN ('in_production','packed_ready','cleared_for_dispatch','dispatched','delivered') THEN
    RETURN jsonb_build_object('ok',true,'order_id',p_order_id,'new_status',v.status,'already_applied',true);
  END IF;
  IF v.status NOT IN ('manufacturing','awaiting_advance','confirmed','submitted','awaiting_payment') THEN
    RETURN jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status')));
  END IF;

  BEGIN
    v_clear := public.assert_active_operations_clearance_v1(p_order_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok',false,
      'blockers',jsonb_build_array(jsonb_build_object('code','finance_operations_clearance_required','message',SQLERRM))
    );
  END;

  UPDATE public.orders SET status='in_production' WHERE id=p_order_id;
  INSERT INTO public.order_status_history(order_id,old_status,new_status,changed_by)
  VALUES(p_order_id,v.status,'in_production',auth.uid());
  INSERT INTO public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value)
  VALUES('ORDER_RELEASED_TO_PRODUCTION','Finance','orders',p_order_id::text,auth.uid(),'high',
    jsonb_build_object('finance_clearance_event_id',v_clear.clearance_event_id,
      'payment_status_argument_ignored_as_authority',p_payment_status));
  RETURN jsonb_build_object('ok',true,'order_id',p_order_id,'new_status','in_production','already_applied',false,
    'finance_clearance_event_id',v_clear.clearance_event_id);
END;
$$;

REVOKE ALL ON FUNCTION public.release_order_to_manufacturing_v1(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.release_order_to_in_production_v1(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_order_to_manufacturing_v1(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.release_order_to_in_production_v1(uuid,text) TO authenticated, service_role;

COMMENT ON FUNCTION public.assert_active_operations_clearance_v1(uuid) IS 'PF-6C fail-closed guard: exact current SO/PI/commercial version must have latest Operations Clearance GRANTED.';
