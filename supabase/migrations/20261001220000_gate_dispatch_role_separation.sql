-- Final certification: restore segregation of duties between independent
-- Security Gate release and Dispatch-owned post-gate proof/finalization.
-- No data rewrite. Existing signatures, evidence, idempotency and finance gates remain unchanged.
begin;

create or replace function public.assert_order_transition_role(p_action text)
returns void language plpgsql stable set search_path = public, pg_temp as $$
declare v_role text := upper(coalesce(public.get_user_role(auth.uid()), ''));
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='P0001'; end if;
  if p_action in ('release_manufacturing','finance_review','record_full_payment') and v_role not in ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: finance authority required' using errcode='P0001';
  elsif p_action='confirm_awaiting_advance' and v_role not in ('SALES_EXECUTIVE','SALES_EXEC','OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: sales or operations authority required' using errcode='P0001';
  elsif p_action='mark_packed_ready' and v_role not in ('PACKING_SUPERVISOR','OPERATIONS_MANAGER','ASSEMBLY_SUPERVISOR','ASSEMBLY_HEAD','DISPATCH_HEAD','DISPATCH_MANAGER','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: packing or operations authority required' using errcode='P0001';
  elsif p_action='clear_dispatch' and v_role not in ('FINANCE_HEAD','FINANCE_EXEC','DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','OPERATIONS_MANAGER','PACKING_SUPERVISOR','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: dispatch clearance authority required' using errcode='P0001';
  elsif p_action='gate_release' and v_role not in ('SECURITY_CONTROL','GATE_SECURITY','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: independent security gate authority required' using errcode='P0001';
  elsif p_action='dispatch_proof' and v_role not in ('DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: dispatch proof authority required' using errcode='P0001';
  elsif p_action='dispatch_finalize' and v_role not in ('DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: dispatch finalization authority required' using errcode='P0001';
  elsif p_action='delivery_proof' and v_role not in ('DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','ADMIN','SUPER_ADMIN','OWNER') then
    raise exception 'NOT_AUTHORIZED: delivery proof authority required' using errcode='P0001';
  elsif p_action not in ('release_manufacturing','finance_review','record_full_payment','confirm_awaiting_advance','mark_packed_ready','clear_dispatch','gate_release','dispatch_proof','dispatch_finalize','delivery_proof') then
    raise exception 'INVALID_ACTION: %',p_action using errcode='P0001';
  end if;
end $$;

create or replace function public.is_advance_verification_path_cleared(p_payment_status text)
returns boolean language sql immutable set search_path=pg_catalog,public as $$
  select lower(btrim(coalesce(p_payment_status,''))) in ('paid','short_term_credit','verified_advance','advance_paid','on_credit')
$$;

CREATE OR REPLACE FUNCTION public.record_dispatch_proof_packet_v1(
  p_order_id uuid,p_transport_snapshot jsonb,p_evidence_references jsonb,p_dispatched_at timestamptz,
  p_correlation_id text,p_idempotency_key text,p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(dispatch_proof_id uuid,proof_fingerprint text,already_recorded boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,auth,extensions AS $$
DECLARE v_actor uuid:=coalesce(p_actor_id,auth.uid()); v_role text; v_invoice public.final_invoices%rowtype; v_dpl public.finance_dpl_receipts%rowtype;
  v_clearance uuid; v_remaining integer; v_gate_ids jsonb; v_fingerprint text; v_existing public.dispatch_proof_packets%rowtype;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN RAISE EXCEPTION 'DISPATCH_PROOF_ACTOR_REQUIRED' USING ERRCODE='42501'; END IF;
  PERFORM public.assert_order_transition_role('dispatch_proof'); v_role:=coalesce(upper(public.get_user_role(v_actor)),'UNKNOWN');
  IF jsonb_typeof(p_transport_snapshot) IS DISTINCT FROM 'object' OR nullif(btrim(p_transport_snapshot->>'transporter'),'') IS NULL
     OR nullif(btrim(p_transport_snapshot->>'lr_awb_bilty'),'') IS NULL OR jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references)=0 OR p_dispatched_at IS NULL OR p_dispatched_at>statement_timestamp()+interval '5 minutes'
     OR nullif(btrim(p_correlation_id),'') IS NULL OR nullif(btrim(p_idempotency_key),'') IS NULL THEN RAISE EXCEPTION 'DISPATCH_PROOF_EVIDENCE_REQUIRED' USING ERRCODE='P0001'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('dispatch-proof:'||p_order_id::text,0));
  v_clearance:=public.assert_active_dispatch_clearance_v1(p_order_id);
  SELECT * INTO v_invoice FROM public.final_invoices WHERE order_id=p_order_id AND status='ISSUED' ORDER BY created_at DESC LIMIT 1;
  IF v_invoice.id IS NULL THEN RAISE EXCEPTION 'FINAL_INVOICE_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT * INTO v_dpl FROM public.finance_dpl_receipts WHERE id=v_invoice.finance_dpl_receipt_id;
  IF v_dpl.id IS NULL OR v_dpl.dpl_snapshot->>'source_authority' IS DISTINCT FROM 'b2b_dispatch_packing_list_versions' THEN RAISE EXCEPTION 'FINAL_B2B_DPL_NOT_FOUND' USING ERRCODE='P0001'; END IF;
  SELECT count(*) INTO v_remaining FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value)
   WHERE NOT EXISTS(SELECT 1 FROM public.b2b_dispatch_cartons bc WHERE bc.id::text=c.value AND bc.status='handed_over');
  IF v_remaining>0 THEN RAISE EXCEPTION 'DISPATCH_PROOF_GATE_RELEASE_INCOMPLETE' USING ERRCODE='55000'; END IF;
  SELECT coalesce(jsonb_agg(g.id ORDER BY g.created_at,g.id),'[]'::jsonb) INTO v_gate_ids FROM public.b2b_dispatch_gate_decisions g
   WHERE g.order_id=p_order_id AND g.decision='released' AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(v_dpl.dpl_snapshot->'carton_ids') c(value) WHERE c.value=g.carton_id::text);
  IF jsonb_array_length(v_gate_ids) IS DISTINCT FROM jsonb_array_length(v_dpl.dpl_snapshot->'carton_ids') THEN RAISE EXCEPTION 'DISPATCH_PROOF_GATE_LINEAGE_INCOMPLETE' USING ERRCODE='55000'; END IF;
  v_fingerprint:=encode(extensions.digest(jsonb_build_object('order_id',p_order_id,'final_invoice_id',v_invoice.id,'finance_dpl_receipt_id',v_dpl.id,
    'finance_dispatch_clearance_event_id',v_clearance,'transport_snapshot',p_transport_snapshot,'gate_decision_ids',v_gate_ids,
    'evidence_references',p_evidence_references,'dispatched_at',p_dispatched_at)::text,'sha256'),'hex');
  SELECT * INTO v_existing FROM public.dispatch_proof_packets WHERE idempotency_key=btrim(p_idempotency_key);
  IF FOUND THEN IF v_existing.recorded_by IS DISTINCT FROM v_actor OR v_existing.proof_fingerprint IS DISTINCT FROM v_fingerprint THEN RAISE EXCEPTION 'DISPATCH_PROOF_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505'; END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.proof_fingerprint,true; RETURN; END IF;
  IF EXISTS(SELECT 1 FROM public.dispatch_proof_packets WHERE order_id=p_order_id) THEN RAISE EXCEPTION 'DISPATCH_PROOF_ALREADY_FROZEN' USING ERRCODE='55000'; END IF;
  INSERT INTO public.dispatch_proof_packets(order_id,final_invoice_id,finance_dpl_receipt_id,finance_dispatch_clearance_event_id,transport_snapshot,gate_decision_ids,evidence_references,
    dispatched_at,proof_fingerprint,recorded_by,recorded_role,correlation_id,idempotency_key)
  VALUES(p_order_id,v_invoice.id,v_dpl.id,v_clearance,p_transport_snapshot,v_gate_ids,p_evidence_references,p_dispatched_at,v_fingerprint,v_actor,v_role,btrim(p_correlation_id),btrim(p_idempotency_key)) RETURNING * INTO v_existing;
  RETURN QUERY SELECT v_existing.id,v_existing.proof_fingerprint,false;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_order_to_dispatched_v1(
  p_order_id uuid,
  p_tracking_number text DEFAULT NULL,
  p_courier_name text DEFAULT NULL,
  p_finalize_reason text DEFAULT NULL,
  p_correlation_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
SET lock_timeout = '5s'
SET statement_timeout = '60s'
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_role text;
  v_order public.orders%rowtype;
  v_proof public.dispatch_proof_packets%rowtype;
  v_clearance uuid;
  v_tracking text := nullif(btrim(p_tracking_number), '');
  v_courier text := nullif(btrim(p_courier_name), '');
  v_reason text := nullif(btrim(p_finalize_reason), '');
  v_correlation text;
  v_blockers jsonb := '[]'::jsonb;
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'DISPATCH_FINALIZATION_ACTOR_REQUIRED' USING ERRCODE = '42501';
  END IF;

  -- Dispatch finalization occurs only after immutable evidence proves every DPL
  -- carton passed the independent Security Gate. Dispatch owns this post-gate
  -- commercial/transport finalization; Security does not mutate order status.
  PERFORM public.assert_order_transition_role('dispatch_finalize');
  v_role := coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN');

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'DISPATCH_FINALIZATION_ORDER_REQUIRED' USING ERRCODE = 'P0001';
  END IF;
  IF v_reason IS NOT NULL AND length(v_reason) < 5 THEN
    RAISE EXCEPTION 'DISPATCH_FINALIZATION_REASON_TOO_SHORT' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('dispatch-finalize:' || p_order_id::text, 0));

  -- Read order state without a row-exclusive lock first so Finance hold mutations that
  -- join the eligibility lock protocol cannot deadlock waiting on this transaction.
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'blockers', jsonb_build_array(jsonb_build_object('code', 'order_not_found', 'message', 'Order not found'))
    );
  END IF;

  -- The immutable proof packet is the canonical statement that every frozen-DPL
  -- carton passed the independent physical gate. Do not reconstruct that truth here.
  SELECT * INTO v_proof
  FROM public.dispatch_proof_packets
  WHERE order_id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'dispatch_proof_required',
        'message', 'Immutable dispatch proof is required before final dispatch status'
      ))
    );
  END IF;

  -- Optional Central convenience fields are validation-only. Canonical transport
  -- truth remains the frozen dispatch proof packet and is never overwritten here.
  IF v_tracking IS NOT NULL
     AND lower(v_tracking) IS DISTINCT FROM lower(btrim(coalesce(v_proof.transport_snapshot->>'tracking_reference', '')))
     AND lower(v_tracking) IS DISTINCT FROM lower(btrim(coalesce(v_proof.transport_snapshot->>'lr_awb_bilty', ''))) THEN
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'tracking_reference_mismatch',
      'message', 'Tracking reference does not match the frozen dispatch proof'
    ));
  END IF;

  IF v_courier IS NOT NULL
     AND lower(v_courier) IS DISTINCT FROM lower(btrim(coalesce(v_proof.transport_snapshot->>'transporter', ''))) THEN
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object(
      'code', 'courier_mismatch',
      'message', 'Courier/transporter does not match the frozen dispatch proof'
    ));
  END IF;

  IF jsonb_array_length(v_blockers) > 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', v_blockers
    );
  END IF;

  -- Idempotent replay is accepted only when the same canonical proof still exists
  -- and the optional transport values above agree with it. Replay does not require
  -- a still-active Finance clearance; the frozen proof already bound the grant.
  IF lower(coalesce(v_order.status, '')) = 'dispatched' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'order_id', p_order_id,
      'previous_status', 'dispatched',
      'new_status', 'dispatched',
      'already_applied', true,
      'dispatch_proof_id', v_proof.id,
      'finance_dispatch_clearance_event_id', v_proof.finance_dispatch_clearance_event_id
    );
  END IF;

  IF lower(coalesce(v_order.status, '')) <> 'cleared_for_dispatch' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status',
        'message', 'Order must be cleared_for_dispatch before final dispatch'
      ))
    );
  END IF;

  -- Serialize with Finance hold/clearance mutations on the canonical per-order and
  -- per-company eligibility locks before the row-exclusive order lock, then revalidate
  -- immediately before transition.
  PERFORM public.lock_finance_dispatch_eligibility_v1(p_order_id);
  PERFORM public.lock_finance_dispatch_eligibility_company_v1(v_order.company_id);

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF lower(coalesce(v_order.status, '')) <> 'cleared_for_dispatch' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'invalid_status',
        'message', 'Order must be cleared_for_dispatch before final dispatch'
      ))
    );
  END IF;

  BEGIN
    v_clearance := public.assert_active_dispatch_clearance_v1(p_order_id);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'finance_dispatch_clearance_required',
        'message', SQLERRM
      ))
    );
  END;

  v_correlation := coalesce(nullif(btrim(p_correlation_id), ''), v_proof.correlation_id);

  -- Revalidate under the held eligibility lock so a concurrent hold/clearance mutation
  -- cannot slip between the first assertion and the atomic status transition.
  BEGIN
    v_clearance := public.assert_active_dispatch_clearance_v1(p_order_id);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    RETURN jsonb_build_object(
      'ok', false,
      'order_id', p_order_id,
      'previous_status', v_order.status,
      'new_status', v_order.status,
      'blockers', jsonb_build_array(jsonb_build_object(
        'code', 'finance_dispatch_clearance_required',
        'message', SQLERRM
      ))
    );
  END;

  UPDATE public.orders
  SET status = 'dispatched'
  WHERE id = p_order_id;

  INSERT INTO public.order_status_history(order_id, old_status, new_status, changed_by)
  VALUES(p_order_id, v_order.status, 'dispatched', v_actor);

  INSERT INTO public.audit_logs(
    action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value
  ) VALUES (
    'ORDER_DISPATCHED',
    'Dispatch',
    'orders',
    p_order_id::text,
    v_actor,
    'high',
    jsonb_build_object(
      'previous_status', v_order.status,
      'new_status', 'dispatched',
      'dispatch_proof_id', v_proof.id,
      'dispatch_proof_fingerprint', v_proof.proof_fingerprint,
      'finance_dispatch_clearance_event_id', v_clearance,
      'final_invoice_id', v_proof.final_invoice_id,
      'finance_dpl_receipt_id', v_proof.finance_dpl_receipt_id,
      'transport_snapshot', v_proof.transport_snapshot,
      'proof_dispatched_at', v_proof.dispatched_at,
      'finalized_at', statement_timestamp(),
      'finalize_reason', v_reason,
      'correlation_id', v_correlation,
      'actor_role', v_role
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'previous_status', v_order.status,
    'new_status', 'dispatched',
    'already_applied', false,
    'dispatch_proof_id', v_proof.id,
    'finance_dispatch_clearance_event_id', v_clearance,
    'correlation_id', v_correlation
  );
END;
$$;

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

  PERFORM public.assert_order_transition_role('delivery_proof');
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

comment on function public.assert_order_transition_role(text) is
  'Canonical order transition RBAC. Independent Security Gate release is separated from Dispatch proof/finalization/delivery authority.';
comment on function public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid) is
  'Dispatch-owned immutable proof freeze after all DPL cartons have independent Security Gate release evidence.';
comment on function public.release_order_to_dispatched_v1(uuid,text,text,text,text) is
  'Dispatch-owned final order transition after independent gate evidence and active Finance clearance.';
comment on function public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid) is
  'Dispatch-owned post-gate delivery evidence; independent Security Gate authority is not reused.';

-- Preserve the existing production execute contract explicitly after CREATE OR REPLACE.
revoke all on function public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid) from public, anon, service_role;
grant execute on function public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid) to authenticated;

revoke all on function public.release_order_to_dispatched_v1(uuid,text,text,text,text) from public, anon, service_role;
grant execute on function public.release_order_to_dispatched_v1(uuid,text,text,text,text) to authenticated;

revoke all on function public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid) from public, anon, service_role;
grant execute on function public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid) to authenticated;

commit;
