-- R4.4 3PGS: governed post-GRN inventory exception authority.
--
-- The existing inventory model already owns available/quarantine stock buckets,
-- append-only movement types, store-scoped authority and GRN/discrepancy truth.
-- What was missing was one governed command for post-GRN quarantine, release,
-- damage write-off and return-to-vendor. This migration adds that command without
-- introducing a parallel stock balance or permitting direct browser writes.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE TABLE public.b2b_3pgs_inventory_exception_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_code text NOT NULL DEFAULT '3PGS' REFERENCES public.b2b_inventory_stores(store_code) ON UPDATE CASCADE ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  sku text NOT NULL,
  action text NOT NULL CHECK (action IN ('quarantine','release_quarantine','damage_writeoff','return_to_vendor')),
  source_bucket text NOT NULL CHECK (source_bucket IN ('available','quarantine')),
  quantity numeric NOT NULL CHECK (quantity > 0),
  reason text NOT NULL CHECK (nullif(btrim(reason),'') IS NOT NULL),
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(evidence) = 'array'),
  actor_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  correlation_id text NOT NULL UNIQUE CHECK (nullif(btrim(correlation_id),'') IS NOT NULL),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_3pgs_inventory_exception_store_check CHECK (store_code = '3PGS')
);

CREATE INDEX idx_b2b_3pgs_inventory_exception_queue
  ON public.b2b_3pgs_inventory_exception_events(action, created_at DESC);
CREATE INDEX idx_b2b_3pgs_inventory_exception_sku
  ON public.b2b_3pgs_inventory_exception_events(product_id, sku, created_at DESC);

ALTER TABLE public.b2b_3pgs_inventory_exception_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Internal staff read 3PGS inventory exception events"
  ON public.b2b_3pgs_inventory_exception_events
  FOR SELECT TO authenticated
  USING (public.is_internal_staff((select auth.uid())));

REVOKE ALL ON public.b2b_3pgs_inventory_exception_events FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_3pgs_inventory_exception_events FROM authenticated;
GRANT SELECT ON public.b2b_3pgs_inventory_exception_events TO authenticated;

CREATE OR REPLACE FUNCTION public.record_b2b_3pgs_inventory_exception(
  p_product_id uuid,
  p_sku text,
  p_action text,
  p_source_bucket text,
  p_quantity numeric,
  p_reason text,
  p_correlation_id text,
  p_evidence jsonb DEFAULT '[]'::jsonb
)
RETURNS public.b2b_3pgs_inventory_exception_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_existing public.b2b_3pgs_inventory_exception_events%ROWTYPE;
  v_event public.b2b_3pgs_inventory_exception_events%ROWTYPE;
  v_available numeric;
  v_quarantine numeric;
  v_movement_type text;
BEGIN
  IF v_actor IS NULL OR NOT public.can_access_b2b_inventory_store(v_actor, '3PGS', 'manage') THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF p_action NOT IN ('quarantine','release_quarantine','damage_writeoff','return_to_vendor') THEN
    RAISE EXCEPTION 'Unsupported 3PGS inventory exception action';
  END IF;
  IF p_source_bucket NOT IN ('available','quarantine') THEN
    RAISE EXCEPTION 'Source bucket must be available or quarantine';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;
  IF nullif(btrim(p_sku),'') IS NULL OR nullif(btrim(p_reason),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL THEN
    RAISE EXCEPTION 'SKU, reason and correlation id are required';
  END IF;
  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'array' THEN
    RAISE EXCEPTION 'Evidence must be a JSON array';
  END IF;

  SELECT * INTO v_existing
  FROM public.b2b_3pgs_inventory_exception_events
  WHERE correlation_id = btrim(p_correlation_id);
  IF FOUND THEN
    IF v_existing.product_id <> p_product_id
       OR v_existing.sku <> btrim(p_sku)
       OR v_existing.action <> p_action
       OR v_existing.source_bucket <> p_source_bucket
       OR v_existing.quantity <> p_quantity THEN
      RAISE EXCEPTION 'Correlation id already belongs to a different inventory exception';
    END IF;
    RETURN v_existing;
  END IF;

  IF p_action = 'quarantine' AND p_source_bucket <> 'available' THEN
    RAISE EXCEPTION 'Quarantine must move stock from available';
  ELSIF p_action = 'release_quarantine' AND p_source_bucket <> 'quarantine' THEN
    RAISE EXCEPTION 'Quarantine release must move stock from quarantine';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_product_id::text || ':' || btrim(p_sku) || ':3PGS', 0)
  );

  SELECT available_qty, quarantine_qty
    INTO v_available, v_quarantine
  FROM public.inventory_stock_balances
  WHERE product_id = p_product_id
    AND sku = btrim(p_sku)
    AND location_code = '3PGS'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '3PGS stock balance not found';
  END IF;

  IF p_source_bucket = 'available' AND v_available < p_quantity THEN
    RAISE EXCEPTION 'Insufficient available stock for inventory exception';
  END IF;
  IF p_source_bucket = 'quarantine' AND v_quarantine < p_quantity THEN
    RAISE EXCEPTION 'Insufficient quarantined stock for inventory exception';
  END IF;

  IF p_action = 'quarantine' THEN
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty - p_quantity,
        quarantine_qty = quarantine_qty + p_quantity,
        version = version + 1,
        updated_at = now()
    WHERE product_id = p_product_id AND sku = btrim(p_sku) AND location_code = '3PGS';
    v_movement_type := 'stock_quarantined';
  ELSIF p_action = 'release_quarantine' THEN
    UPDATE public.inventory_stock_balances
    SET quarantine_qty = quarantine_qty - p_quantity,
        available_qty = available_qty + p_quantity,
        version = version + 1,
        updated_at = now()
    WHERE product_id = p_product_id AND sku = btrim(p_sku) AND location_code = '3PGS';
    v_movement_type := 'stock_quarantine_released';
  ELSIF p_source_bucket = 'available' THEN
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty - p_quantity,
        version = version + 1,
        updated_at = now()
    WHERE product_id = p_product_id AND sku = btrim(p_sku) AND location_code = '3PGS';
    v_movement_type := 'correction_out';
  ELSE
    UPDATE public.inventory_stock_balances
    SET quarantine_qty = quarantine_qty - p_quantity,
        version = version + 1,
        updated_at = now()
    WHERE product_id = p_product_id AND sku = btrim(p_sku) AND location_code = '3PGS';
    v_movement_type := 'correction_out';
  END IF;

  INSERT INTO public.b2b_3pgs_inventory_exception_events(
    store_code, product_id, sku, action, source_bucket, quantity, reason,
    evidence, actor_id, correlation_id
  ) VALUES (
    '3PGS', p_product_id, btrim(p_sku), p_action, p_source_bucket, p_quantity,
    btrim(p_reason), p_evidence, v_actor, btrim(p_correlation_id)
  ) RETURNING * INTO v_event;

  INSERT INTO public.inventory_movements(
    movement_type, product_id, sku, quantity, source_location, destination_location,
    actor_id, reason_code, correlation_id, source_document_type,
    source_document_reference, metadata
  ) VALUES (
    v_movement_type,
    p_product_id,
    btrim(p_sku),
    p_quantity,
    CASE WHEN p_action = 'release_quarantine' THEN NULL ELSE '3PGS' END,
    CASE WHEN p_action IN ('quarantine','release_quarantine') THEN '3PGS' ELSE NULL END,
    v_actor,
    CASE p_action
      WHEN 'quarantine' THEN '3pgs_quarantine'
      WHEN 'release_quarantine' THEN '3pgs_quarantine_release'
      WHEN 'damage_writeoff' THEN '3pgs_damage_writeoff'
      ELSE '3pgs_return_to_vendor'
    END,
    btrim(p_correlation_id) || ':movement',
    '3pgs_inventory_exception',
    v_event.id::text,
    jsonb_build_object(
      'exception_event_id', v_event.id,
      'action', p_action,
      'source_bucket', p_source_bucket,
      'reason', btrim(p_reason),
      'evidence', p_evidence
    )
  );

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb)
  TO authenticated;

COMMENT ON TABLE public.b2b_3pgs_inventory_exception_events IS
  'Append-only 3PGS post-GRN quarantine, damage and return-to-vendor evidence. Stock mutation is RPC-only and reconciles existing inventory_stock_balances buckets.';
COMMENT ON FUNCTION public.record_b2b_3pgs_inventory_exception(uuid,text,text,text,numeric,text,text,jsonb) IS
  'Governed 3PGS inventory exception command. Idempotent by correlation_id; moves only available/quarantine stock and appends inventory_movements evidence.';
