-- Finance Exit F4: immutable receipt of Dispatch's finalized DPL.
-- Finance does not create cartons, packing lines, or DPL truth. It accepts a
-- finalized external DPL packet, validates its exact SO/commercial binding and
-- freezes that packet as Finance evidence for invoicing and settlement.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE IF NOT EXISTS public.finance_dpl_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  company_id uuid NOT NULL REFERENCES public.companies(id),
  commercial_version_id uuid NOT NULL REFERENCES public.sales_order_commercial_versions(id),
  external_dpl_id text NOT NULL,
  dpl_version integer NOT NULL CHECK (dpl_version > 0),
  dpl_fingerprint text NOT NULL CHECK (dpl_fingerprint ~ '^[0-9a-f]{64}$'),
  dpl_snapshot jsonb NOT NULL,
  finalized_at timestamptz NOT NULL,
  received_by uuid NOT NULL REFERENCES auth.users(id),
  received_role text NOT NULL,
  source_channel text NOT NULL,
  source_reference text,
  evidence_reference text NOT NULL,
  correlation_id text NOT NULL,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  UNIQUE (external_dpl_id, dpl_version),
  UNIQUE (idempotency_key)
);
CREATE INDEX IF NOT EXISTS finance_dpl_receipts_order_idx
  ON public.finance_dpl_receipts(order_id, created_at DESC);

ALTER TABLE public.finance_dpl_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.finance_dpl_receipts FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.finance_dpl_receipts TO authenticated, service_role;
DROP POLICY IF EXISTS finance_dpl_receipts_internal_read ON public.finance_dpl_receipts;
CREATE POLICY finance_dpl_receipts_internal_read ON public.finance_dpl_receipts
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));

CREATE TABLE IF NOT EXISTS public.finance_dpl_receipt_idempotency (
  idempotency_key text PRIMARY KEY,
  request_fingerprint text NOT NULL,
  receipt_id uuid NOT NULL REFERENCES public.finance_dpl_receipts(id),
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE public.finance_dpl_receipt_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.finance_dpl_receipt_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_finance_dpl_receipt_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'FINANCE_DPL_RECEIPT_IMMUTABLE' USING ERRCODE='42501';
END;
$$;
DROP TRIGGER IF EXISTS trg_finance_dpl_receipts_immutable ON public.finance_dpl_receipts;
CREATE TRIGGER trg_finance_dpl_receipts_immutable
  BEFORE UPDATE OR DELETE ON public.finance_dpl_receipts
  FOR EACH ROW EXECUTE FUNCTION public.prevent_finance_dpl_receipt_mutation();
REVOKE ALL ON FUNCTION public.prevent_finance_dpl_receipt_mutation() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.receive_finance_dpl_v1(
  p_order_id uuid,
  p_commercial_version_id uuid,
  p_external_dpl_id text,
  p_dpl_version integer,
  p_dpl_snapshot jsonb,
  p_dpl_fingerprint text,
  p_finalized_at timestamptz,
  p_evidence_reference text,
  p_source_channel text,
  p_source_reference text,
  p_correlation_id text,
  p_idempotency_key text,
  p_actor_id uuid DEFAULT auth.uid()
) RETURNS TABLE(receipt_id uuid, already_received boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_actor uuid := coalesce(p_actor_id, auth.uid());
  v_role text;
  v_order public.orders%rowtype;
  v_version public.sales_order_commercial_versions%rowtype;
  v_existing public.finance_dpl_receipt_idempotency%rowtype;
  v_receipt public.finance_dpl_receipts%rowtype;
  v_computed_fingerprint text;
  v_request_fingerprint text;
  v_line_count integer;
  v_distinct_line_count integer;
  v_invalid_count integer;
BEGIN
  IF auth.uid() IS NULL OR v_actor IS DISTINCT FROM auth.uid() OR NOT public.is_internal_staff(v_actor) THEN
    RAISE EXCEPTION 'FINANCE_DPL_ACTOR_REQUIRED' USING ERRCODE='42501';
  END IF;
  -- DPL finalization/handoff belongs to packing/dispatch/operations authority,
  -- not ordinary Finance users. Established admin/owner roles remain permitted.
  PERFORM public.assert_order_transition_role('mark_packed_ready');
  v_role := coalesce(upper(public.get_user_role(v_actor)), 'UNKNOWN');

  IF p_order_id IS NULL OR p_commercial_version_id IS NULL
     OR nullif(btrim(p_external_dpl_id),'') IS NULL OR p_dpl_version IS NULL OR p_dpl_version <= 0
     OR p_finalized_at IS NULL OR p_finalized_at > statement_timestamp() + interval '5 minutes'
     OR jsonb_typeof(p_dpl_snapshot) IS DISTINCT FROM 'object'
     OR nullif(btrim(p_dpl_fingerprint),'') IS NULL
     OR nullif(btrim(p_evidence_reference),'') IS NULL
     OR nullif(btrim(p_source_channel),'') IS NULL
     OR nullif(btrim(p_correlation_id),'') IS NULL
     OR nullif(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'FINANCE_DPL_EVIDENCE_REQUIRED' USING ERRCODE='P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('finance-dpl:' || p_order_id::text, 0));
  PERFORM public.assert_active_operations_clearance_v1(p_order_id);

  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR SHARE;
  SELECT * INTO v_version FROM public.sales_order_commercial_versions
   WHERE id=p_commercial_version_id AND order_id=p_order_id;
  IF NOT FOUND OR v_order.company_id IS NULL OR v_order.commercial_current_version IS DISTINCT FROM v_version.version_number THEN
    RAISE EXCEPTION 'FINANCE_DPL_COMMERCIAL_BINDING_MISMATCH' USING ERRCODE='40001';
  END IF;

  IF p_dpl_snapshot->>'order_id' IS DISTINCT FROM p_order_id::text
     OR p_dpl_snapshot->>'commercial_version_id' IS DISTINCT FROM p_commercial_version_id::text
     OR p_dpl_snapshot->>'external_dpl_id' IS DISTINCT FROM btrim(p_external_dpl_id)
     OR coalesce((p_dpl_snapshot->>'dpl_version')::integer,0) IS DISTINCT FROM p_dpl_version
     OR jsonb_typeof(p_dpl_snapshot->'lines') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_dpl_snapshot->'lines') = 0
     OR jsonb_typeof(p_dpl_snapshot->'carton_ids') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_dpl_snapshot->'carton_ids') = 0 THEN
    RAISE EXCEPTION 'FINANCE_DPL_PACKET_BINDING_MISMATCH' USING ERRCODE='40001';
  END IF;

  v_computed_fingerprint := encode(extensions.digest(p_dpl_snapshot::text,'sha256'),'hex');
  IF lower(btrim(p_dpl_fingerprint)) IS DISTINCT FROM v_computed_fingerprint THEN
    RAISE EXCEPTION 'FINANCE_DPL_FINGERPRINT_MISMATCH' USING ERRCODE='40001';
  END IF;

  SELECT count(*), count(DISTINCT x.order_item_id)
    INTO v_line_count, v_distinct_line_count
    FROM jsonb_to_recordset(p_dpl_snapshot->'lines')
      AS x(order_item_id uuid, product_id uuid, actual_dispatch_qty numeric, uom text);
  IF v_line_count = 0 OR v_line_count IS DISTINCT FROM v_distinct_line_count THEN
    RAISE EXCEPTION 'FINANCE_DPL_DUPLICATE_OR_EMPTY_LINES' USING ERRCODE='P0001';
  END IF;

  SELECT count(*) INTO v_invalid_count
    FROM jsonb_to_recordset(p_dpl_snapshot->'lines')
      AS x(order_item_id uuid, product_id uuid, actual_dispatch_qty numeric, uom text)
    LEFT JOIN public.order_items oi
      ON oi.id=x.order_item_id AND oi.order_id=p_order_id AND oi.product_id=x.product_id
   WHERE oi.id IS NULL OR x.actual_dispatch_qty IS NULL OR x.actual_dispatch_qty <= 0
      OR x.actual_dispatch_qty > oi.quantity OR nullif(btrim(x.uom),'') IS NULL;
  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION 'FINANCE_DPL_LINE_TRUTH_INVALID' USING ERRCODE='40001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(p_dpl_snapshot->'carton_ids') c(value)
     WHERE nullif(btrim(c.value),'') IS NULL
  ) OR (
    SELECT count(*) FROM jsonb_array_elements_text(p_dpl_snapshot->'carton_ids')
  ) IS DISTINCT FROM (
    SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_dpl_snapshot->'carton_ids')
  ) THEN
    RAISE EXCEPTION 'FINANCE_DPL_CARTON_IDENTITY_INVALID' USING ERRCODE='40001';
  END IF;

  v_request_fingerprint := encode(extensions.digest(jsonb_build_object(
    'order_id',p_order_id,'commercial_version_id',p_commercial_version_id,
    'external_dpl_id',btrim(p_external_dpl_id),'dpl_version',p_dpl_version,
    'dpl_fingerprint',v_computed_fingerprint,'finalized_at',p_finalized_at,
    'evidence_reference',btrim(p_evidence_reference),'source_channel',upper(btrim(p_source_channel)),
    'source_reference',coalesce(nullif(btrim(p_source_reference),''),''),
    'correlation_id',btrim(p_correlation_id)
  )::text,'sha256'),'hex');

  SELECT * INTO v_existing FROM public.finance_dpl_receipt_idempotency
   WHERE idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
  IF FOUND THEN
    IF v_existing.actor_id IS DISTINCT FROM v_actor OR v_existing.request_fingerprint IS DISTINCT FROM v_request_fingerprint THEN
      RAISE EXCEPTION 'FINANCE_DPL_IDEMPOTENCY_CONFLICT' USING ERRCODE='23505';
    END IF;
    RETURN QUERY SELECT v_existing.receipt_id,true;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.finance_dpl_receipts r
     WHERE r.external_dpl_id=btrim(p_external_dpl_id) AND r.dpl_version=p_dpl_version
       AND (r.dpl_fingerprint IS DISTINCT FROM v_computed_fingerprint OR r.order_id IS DISTINCT FROM p_order_id)
  ) THEN
    RAISE EXCEPTION 'FINANCE_DPL_VERSION_CONFLICT' USING ERRCODE='23505';
  END IF;

  INSERT INTO public.finance_dpl_receipts(
    order_id,company_id,commercial_version_id,external_dpl_id,dpl_version,dpl_fingerprint,dpl_snapshot,
    finalized_at,received_by,received_role,source_channel,source_reference,evidence_reference,
    correlation_id,idempotency_key
  ) VALUES (
    p_order_id,v_order.company_id,p_commercial_version_id,btrim(p_external_dpl_id),p_dpl_version,
    v_computed_fingerprint,p_dpl_snapshot,p_finalized_at,v_actor,v_role,upper(btrim(p_source_channel)),
    nullif(btrim(p_source_reference),''),btrim(p_evidence_reference),btrim(p_correlation_id),btrim(p_idempotency_key)
  ) RETURNING * INTO v_receipt;

  INSERT INTO public.finance_dpl_receipt_idempotency(idempotency_key,request_fingerprint,receipt_id,actor_id,response)
  VALUES(btrim(p_idempotency_key),v_request_fingerprint,v_receipt.id,v_actor,
    jsonb_build_object('receipt_id',v_receipt.id,'order_id',p_order_id,'external_dpl_id',v_receipt.external_dpl_id,'dpl_version',v_receipt.dpl_version));

  RETURN QUERY SELECT v_receipt.id,false;
END;
$$;

REVOKE ALL ON FUNCTION public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamptz,text,text,text,text,text,uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamptz,text,text,text,text,text,uuid)
  TO authenticated;

COMMENT ON TABLE public.finance_dpl_receipts IS
  'Immutable Finance receipt of a finalized Dispatch-owned DPL packet. This table is evidence, not packing/carton authority.';
