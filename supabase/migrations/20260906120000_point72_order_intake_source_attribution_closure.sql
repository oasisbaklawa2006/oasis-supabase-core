-- Point 72: canonical order duplicate prevention and source attribution closure.
--
-- Reuses PF-4 commercial versioning, APP-E2E creation scopes, and per-channel
-- replay keys. Adds fail-closed governed-origin immutability, a canonical intake
-- identity resolver, and a read-only near-duplicate review candidate listing.
-- Does not merge orders by fuzzy similarity; exact scoped replay keys continue
-- to suppress replays inside each intake authority.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.enforce_immutable_governed_order_origin_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF tg_op = 'UPDATE'
     AND old.order_origin IS DISTINCT FROM new.order_origin
     AND old.order_origin = ANY (
       ARRAY['CUSTOMER_APP', 'WHATSAPP', 'SALES', 'MANUAL', 'REPEAT_ORDER', 'APPROVED_QUOTE']::text[]
     ) THEN
    RAISE EXCEPTION 'ORDER_ORIGIN_IMMUTABLE'
      USING ERRCODE = '23514',
            DETAIL = format(
              'Governed intake provenance %s cannot be rewritten to %s',
              old.order_origin,
              new.order_origin
            );
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_immutable_governed_order_origin ON public.orders;
CREATE TRIGGER trg_orders_immutable_governed_order_origin
  BEFORE UPDATE OF order_origin ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.enforce_immutable_governed_order_origin_v1();

REVOKE ALL ON FUNCTION public.enforce_immutable_governed_order_origin_v1()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.enforce_immutable_governed_order_origin_v1() IS
  'Point72: governed intake provenance is immutable after order creation; channel corrections must not silently rewrite origin.';

CREATE OR REPLACE FUNCTION public.resolve_order_intake_source_identity_v1(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%rowtype;
  v_source_reference text;
  v_intake_authority text;
  v_scoped_replay_key text;
  v_draft_id uuid;
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_ID_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  SELECT v.source_reference
    INTO v_source_reference
    FROM public.sales_order_commercial_versions v
   WHERE v.order_id = p_order_id
   ORDER BY v.version_number DESC
   LIMIT 1;

  IF v_order.order_origin = 'CUSTOMER_APP' THEN
    v_intake_authority := 'CUSTOMER_CHECKOUT';
    v_source_reference := coalesce(v_source_reference, v_order.checkout_idempotency_key);
    v_scoped_replay_key := 'customer_checkout:' || coalesce(v_order.company_id::text, '') || ':' || coalesce(v_order.checkout_idempotency_key, '');
  ELSIF v_order.order_origin = 'WHATSAPP' THEN
    v_intake_authority := 'WHATSAPP_DRAFT_PROMOTION';
    IF v_source_reference IS NULL THEN
      SELECT d.id INTO v_draft_id
        FROM public.sales_order_drafts d
       WHERE d.promoted_order_id = p_order_id
       ORDER BY d.id
       LIMIT 1;
      IF v_draft_id IS NOT NULL THEN
        v_source_reference := 'wa-draft:' || v_draft_id::text;
      END IF;
    END IF;
    v_scoped_replay_key := coalesce(v_source_reference, 'whatsapp:' || p_order_id::text);
  ELSE
    v_intake_authority := NULL;
    v_source_reference := coalesce(v_source_reference, v_order.checkout_idempotency_key, v_order.order_number);
    v_scoped_replay_key := lower(coalesce(v_order.order_origin, 'unknown')) || ':' || coalesce(v_source_reference, p_order_id::text);
  END IF;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'source_channel', v_order.order_origin,
    'source_reference', v_source_reference,
    'intake_authority', v_intake_authority,
    'scoped_replay_key', v_scoped_replay_key,
    'replay_suppression_scope', CASE
      WHEN v_order.order_origin = 'CUSTOMER_APP' THEN 'company_id + checkout_idempotency_key within CUSTOMER_CHECKOUT'
      WHEN v_order.order_origin = 'WHATSAPP' THEN 'draft promotion + extraction_request_key within WHATSAPP_DRAFT_PROMOTION'
      ELSE 'exact scoped_replay_key only; no cross-channel replay suppression'
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_order_intake_source_identity_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_order_intake_source_identity_v1(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.resolve_order_intake_source_identity_v1(uuid) IS
  'Point72 canonical intake identity for an order: truthful source channel/reference, intake authority, and scoped replay key.';

CREATE OR REPLACE FUNCTION public.list_order_intake_near_duplicate_review_candidates_v1(
  p_company_id uuid DEFAULT NULL,
  p_window interval DEFAULT interval '24 hours'
)
RETURNS TABLE (
  company_id uuid,
  candidate_a_order_id uuid,
  candidate_b_order_id uuid,
  overlapping_product_ids uuid[],
  source_a_channel text,
  source_a_reference text,
  source_b_channel text,
  source_b_reference text,
  review_reason text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH scoped_orders AS (
    SELECT
      o.id AS order_id,
      o.company_id,
      o.created_at,
      i.source_channel,
      i.source_reference,
      i.scoped_replay_key
    FROM public.orders o
    CROSS JOIN LATERAL (
      SELECT
        x.source_channel,
        x.source_reference,
        x.scoped_replay_key
      FROM public.resolve_order_intake_source_identity_v1(o.id) AS payload
      CROSS JOIN LATERAL jsonb_to_record(payload) AS x(
        source_channel text,
        source_reference text,
        scoped_replay_key text
      )
    ) i
    WHERE o.company_id IS NOT NULL
      AND (p_company_id IS NULL OR o.company_id = p_company_id)
      AND o.created_at >= statement_timestamp() - coalesce(p_window, interval '24 hours')
      AND o.order_origin = ANY (
        ARRAY['CUSTOMER_APP', 'WHATSAPP', 'SALES', 'MANUAL', 'REPEAT_ORDER', 'APPROVED_QUOTE']::text[]
      )
  ),
  product_overlap AS (
    SELECT
      a.company_id,
      a.order_id AS candidate_a_order_id,
      b.order_id AS candidate_b_order_id,
      array_agg(DISTINCT oi_a.product_id ORDER BY oi_a.product_id) AS overlapping_product_ids,
      a.source_channel AS source_a_channel,
      a.source_reference AS source_a_reference,
      b.source_channel AS source_b_channel,
      b.source_reference AS source_b_reference
    FROM scoped_orders a
    JOIN scoped_orders b
      ON a.company_id = b.company_id
     AND a.order_id < b.order_id
     AND a.scoped_replay_key IS DISTINCT FROM b.scoped_replay_key
    JOIN public.order_items oi_a ON oi_a.order_id = a.order_id
    JOIN public.order_items oi_b
      ON oi_b.order_id = b.order_id
     AND oi_b.product_id = oi_a.product_id
    GROUP BY
      a.company_id,
      a.order_id,
      b.order_id,
      a.source_channel,
      a.source_reference,
      b.source_channel,
      b.source_reference
  )
  SELECT
    po.company_id,
    po.candidate_a_order_id,
    po.candidate_b_order_id,
    po.overlapping_product_ids,
    po.source_a_channel,
    po.source_a_reference,
    po.source_b_channel,
    po.source_b_reference,
    'same_company_overlapping_products_distinct_intake_identity'::text AS review_reason
  FROM product_overlap po
  WHERE auth.uid() IS NOT NULL
    AND public.is_internal_staff(auth.uid());
$$;

REVOKE ALL ON FUNCTION public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval) IS
  'Point72 read-only near-duplicate review candidates. Never merges orders; flags overlapping commercial lines with distinct intake identity for operator review.';
