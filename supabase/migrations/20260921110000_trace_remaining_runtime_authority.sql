-- Task 2 Trace runtime authority completion.
-- Contract coverage: 20260921110000_trace_remaining_runtime_authority.sql
--
-- Closes five live Trace client RPC gaps discovered by read-only production
-- census. Forward-only; production application remains subject to the
-- canonical Task 5 release gate.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

DO $$
DECLARE
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'ols_carton_contents',
    'ols_cartons',
    'ols_production_labels',
    'ols_inventory_movements',
    'ols_orders_cache',
    'orders',
    'ols_shipping_labels',
    'ols_finance_pi',
    'ols_gate_scans',
    'ols_scan_history',
    'ols_audit_logs',
    'ols_trace_mutation_receipts'
  ]
  LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN
      RAISE EXCEPTION 'TRACE_SCHEMA_PREREQUISITE_MISSING: %', v_name
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  IF to_regprocedure('public.trace_assert_role_v1(text)') IS NULL
     OR to_regprocedure('public.is_internal_staff(uuid)') IS NULL THEN
    RAISE EXCEPTION 'TRACE_AUTHORITY_PREREQUISITE_MISSING'
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.ols_carton_contents
     WHERE production_label_id IS NOT NULL
     GROUP BY production_label_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'TRACE_DUPLICATE_LABEL_CARTON_MEMBERSHIP_REMEDIATION_REQUIRED'
      USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.ols_cartons
     WHERE order_ref IS NOT NULL
       AND carton_index IS NOT NULL
     GROUP BY order_ref, carton_index
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'TRACE_DUPLICATE_CARTON_INDEX_REMEDIATION_REQUIRED'
      USING ERRCODE = 'P0001';
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS ols_carton_contents_one_label_membership_uniq
  ON public.ols_carton_contents(production_label_id)
  WHERE production_label_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ols_cartons_order_carton_index_uniq
  ON public.ols_cartons(order_ref, carton_index)
  WHERE order_ref IS NOT NULL AND carton_index IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.ols_trace_carton_index_sequences (
  order_ref text PRIMARY KEY,
  last_value integer NOT NULL CHECK (last_value > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.ols_trace_carton_index_sequences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ols_trace_carton_index_sequences
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE
  ON TABLE public.ols_trace_carton_index_sequences TO service_role;

CREATE OR REPLACE FUNCTION public.trace_add_carton_content_v1(
  p_carton_id uuid,
  p_production_label_id uuid,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fingerprint text := md5(jsonb_build_array(p_carton_id, p_production_label_id)::text);
  v_prior record;
  v_carton public.ols_cartons;
  v_label public.ols_production_labels;
  v_content public.ols_carton_contents;
  v_result jsonb;
BEGIN
  PERFORM public.trace_assert_role_v1('packing');
  IF nullif(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'INVALID_TRACE_MUTATION' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
  SELECT payload_fingerprint, response
    INTO v_prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_prior.payload_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_prior.response;
  END IF;

  SELECT * INTO v_carton
    FROM public.ols_cartons
   WHERE id = p_carton_id
   FOR UPDATE;
  IF NOT FOUND OR v_carton.status <> 'draft' THEN
    RAISE EXCEPTION 'CARTON_NOT_PACKABLE' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_label
    FROM public.ols_production_labels
   WHERE id = p_production_label_id
   FOR UPDATE;
  IF NOT FOUND OR coalesce(v_label.status, '') <> 'active' THEN
    RAISE EXCEPTION 'PRODUCTION_LABEL_NOT_PACKABLE' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ols_carton_contents
     WHERE production_label_id = p_production_label_id
  ) THEN
    RAISE EXCEPTION 'PRODUCTION_LABEL_ALREADY_PACKED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.ols_carton_contents(carton_id, production_label_id)
  VALUES(p_carton_id, p_production_label_id)
  RETURNING * INTO v_content;

  INSERT INTO public.ols_inventory_movements(
    production_label_id, from_location, to_location, movement_type,
    reference_no, user_id
  ) VALUES(
    p_production_label_id, 'store', 'packing', 'carton_pack',
    v_carton.carton_no, auth.uid()
  );

  v_result := to_jsonb(v_content);

  INSERT INTO public.ols_audit_logs(
    action, entity_type, entity_id, user_id, details, idempotency_key
  ) VALUES(
    'trace_carton_content_added', 'carton', p_carton_id, auth.uid(),
    jsonb_build_object('production_label_id', p_production_label_id),
    p_idempotency_key
  );

  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key, operation, payload_fingerprint, response, actor_id
  ) VALUES(
    p_idempotency_key, 'add_carton_content', v_fingerprint, v_result, auth.uid()
  );

  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION public.trace_allocate_carton_index_v1(
  p_order_ref text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_ref text := btrim(coalesce(p_order_ref, ''));
  v_current_max integer;
  v_allocated integer;
BEGIN
  PERFORM public.trace_assert_role_v1('packing');
  IF v_order_ref = '' OR length(v_order_ref) > 160 THEN
    RAISE EXCEPTION 'TRACE_ORDER_REF_INVALID' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('trace-carton-index:' || v_order_ref, 0));

  SELECT coalesce(max(carton_index), 0)
    INTO v_current_max
    FROM public.ols_cartons
   WHERE order_ref = v_order_ref;

  INSERT INTO public.ols_trace_carton_index_sequences(order_ref, last_value, updated_at)
  VALUES(v_order_ref, v_current_max + 1, now())
  ON CONFLICT (order_ref)
  DO UPDATE SET
    last_value = greatest(
      public.ols_trace_carton_index_sequences.last_value,
      v_current_max
    ) + 1,
    updated_at = now()
  RETURNING last_value INTO v_allocated;

  RETURN v_allocated;
END
$$;

CREATE OR REPLACE FUNCTION public.trace_reconcile_external_refs_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_bindings jsonb := '[]'::jsonb;
  v_applied integer := 0;
BEGIN
  IF v_actor IS NULL OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'TRACE_EXTERNAL_REF_AUTHORITY_REQUIRED' USING ERRCODE = '42501';
  END IF;

  WITH candidates AS (
    SELECT c.id AS cache_id, o.id::text AS external_ref
      FROM public.ols_orders_cache c
      JOIN public.orders o ON o.order_number = c.order_number
     WHERE c.external_ref IS DISTINCT FROM o.id::text
  ),
  updated AS (
    UPDATE public.ols_orders_cache c
       SET external_ref = x.external_ref
      FROM candidates x
     WHERE c.id = x.cache_id
    RETURNING c.id AS cache_id, c.external_ref
  )
  SELECT
    coalesce(jsonb_agg(jsonb_build_object(
      'cache_id', cache_id,
      'external_ref', external_ref
    )), '[]'::jsonb),
    count(*)::integer
    INTO v_bindings, v_applied
    FROM updated;

  RETURN jsonb_build_object(
    'bindings', v_bindings,
    'applied', v_applied
  );
END
$$;

CREATE OR REPLACE FUNCTION public.trace_record_gate_scan_v1(
  p_qr_ref text,
  p_shipping_label_id uuid,
  p_result text,
  p_reason text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result text := lower(btrim(coalesce(p_result, '')));
  v_fingerprint text := md5(jsonb_build_array(
    p_qr_ref, p_shipping_label_id, v_result, p_reason
  )::text);
  v_prior record;
  v_scan public.ols_gate_scans;
  v_response jsonb;
BEGIN
  PERFORM public.trace_assert_role_v1('dispatch');
  IF nullif(btrim(p_idempotency_key), '') IS NULL
     OR nullif(btrim(p_qr_ref), '') IS NULL
     OR v_result NOT IN ('green', 'red') THEN
    RAISE EXCEPTION 'TRACE_GATE_SCAN_INVALID' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
  SELECT payload_fingerprint, response
    INTO v_prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_prior.payload_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_prior.response;
  END IF;

  INSERT INTO public.ols_gate_scans(
    qr_ref, shipping_label_id, result, reason, scanned_by
  ) VALUES(
    btrim(p_qr_ref), p_shipping_label_id, v_result,
    nullif(btrim(coalesce(p_reason, '')), ''), auth.uid()
  )
  RETURNING * INTO v_scan;

  INSERT INTO public.ols_scan_history(
    scan_value, scan_context, user_id, result, metadata
  ) VALUES(
    btrim(p_qr_ref), 'gate_shipping_qr', auth.uid(), v_result,
    jsonb_build_object(
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'legacy_flow', true
    )
  );

  IF v_result = 'red' AND p_shipping_label_id IS NOT NULL THEN
    INSERT INTO public.ols_audit_logs(
      action, entity_type, entity_id, user_id, details, idempotency_key
    ) VALUES(
      'gate_hold', 'shipping_label', p_shipping_label_id, auth.uid(),
      jsonb_build_object('qr_ref', btrim(p_qr_ref), 'reason', p_reason),
      p_idempotency_key || ':audit'
    );
  END IF;

  v_response := to_jsonb(v_scan);
  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key, operation, payload_fingerprint, response, actor_id
  ) VALUES(
    p_idempotency_key, 'record_gate_scan', v_fingerprint, v_response, auth.uid()
  );

  RETURN v_response;
END
$$;

CREATE OR REPLACE FUNCTION public.trace_legacy_gate_clear_v1(
  p_qr_ref text,
  p_shipping_label_id uuid,
  p_carton_id uuid,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fingerprint text := md5(jsonb_build_array(
    p_qr_ref, p_shipping_label_id, p_carton_id
  )::text);
  v_prior record;
  v_label public.ols_shipping_labels;
  v_carton public.ols_cartons;
  v_pi public.ols_finance_pi;
  v_response jsonb;
BEGIN
  PERFORM public.trace_assert_role_v1('dispatch');
  IF nullif(btrim(p_idempotency_key), '') IS NULL
     OR nullif(btrim(p_qr_ref), '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_GATE_CLEAR_INVALID' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
  SELECT payload_fingerprint, response
    INTO v_prior
    FROM public.ols_trace_mutation_receipts
   WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_prior.payload_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_prior.response;
  END IF;

  SELECT * INTO v_label
    FROM public.ols_shipping_labels
   WHERE id = p_shipping_label_id
   FOR UPDATE;
  SELECT * INTO v_carton
    FROM public.ols_cartons
   WHERE id = p_carton_id
   FOR UPDATE;

  IF v_label.id IS NULL OR v_carton.id IS NULL
     OR v_label.carton_id IS DISTINCT FROM v_carton.id
     OR v_label.qr_ref IS DISTINCT FROM btrim(p_qr_ref) THEN
    RAISE EXCEPTION 'TRACE_GATE_BINDING_MISMATCH' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_pi
    FROM public.ols_finance_pi
   WHERE id = v_label.pi_id;
  IF v_pi.id IS NULL
     OR v_pi.status <> 'cleared'
     OR nullif(btrim(coalesce(v_pi.invoice_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TRACE_GATE_FINANCE_CLEARANCE_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF v_label.status = 'dispatched' OR v_carton.status = 'dispatched' THEN
    IF v_label.status <> 'dispatched' OR v_carton.status <> 'dispatched' THEN
      RAISE EXCEPTION 'TRACE_GATE_PARTIAL_DISPATCH_STATE' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF v_label.status <> 'generated'
       OR v_carton.status <> 'shipping_labelled' THEN
      RAISE EXCEPTION 'TRACE_GATE_STATE_INVALID' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.ols_cartons
       SET status = 'dispatched', updated_at = now()
     WHERE id = v_carton.id
    RETURNING * INTO v_carton;

    UPDATE public.ols_shipping_labels
       SET status = 'dispatched'
     WHERE id = v_label.id
    RETURNING * INTO v_label;

    INSERT INTO public.ols_inventory_movements(
      production_label_id, from_location, to_location, movement_type,
      reference_no, user_id
    ) VALUES(
      NULL, 'shipping', 'dispatched', 'gate_clear',
      v_carton.carton_no, auth.uid()
    );
  END IF;

  v_response := jsonb_build_object(
    'carton', to_jsonb(v_carton),
    'shipping_label', to_jsonb(v_label),
    'already_dispatched', v_label.status = 'dispatched'
  );

  INSERT INTO public.ols_audit_logs(
    action, entity_type, entity_id, user_id, details, idempotency_key
  ) VALUES(
    'trace_gate_dispatched', 'shipping_label', v_label.id, auth.uid(),
    jsonb_build_object(
      'carton_id', v_carton.id,
      'qr_ref', btrim(p_qr_ref),
      'pi_id', v_pi.id
    ),
    p_idempotency_key
  );

  INSERT INTO public.ols_trace_mutation_receipts(
    idempotency_key, operation, payload_fingerprint, response, actor_id
  ) VALUES(
    p_idempotency_key, 'legacy_gate_clear', v_fingerprint, v_response, auth.uid()
  );

  RETURN v_response;
END
$$;

REVOKE ALL ON FUNCTION public.trace_add_carton_content_v1(uuid,uuid,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_allocate_carton_index_v1(text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_reconcile_external_refs_v1()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_record_gate_scan_v1(text,uuid,text,text,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trace_legacy_gate_clear_v1(text,uuid,uuid,text)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.trace_add_carton_content_v1(uuid,uuid,text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_allocate_carton_index_v1(text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_reconcile_external_refs_v1()
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_record_gate_scan_v1(text,uuid,text,text,text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.trace_legacy_gate_clear_v1(text,uuid,uuid,text)
  TO authenticated, service_role;
