-- AUTH-01 Buyer RPC identity-gate hardening.
--
-- Purpose:
--   * converge legacy CUSTOMER_APP projections onto the canonical approved-buyer
--     authority introduced by customer_buyer_eligible_company_id();
--   * harden the older auth_buyer_company_id() compatibility helper so non-buyer
--     authenticated identities and internal staff cannot inherit Buyer authority
--     merely from a company_id;
--   * preserve intentional anonymous surfaces: published_products_v1() and
--     submit_b2b_access_request_v2() are NOT changed here.
--
-- No table data is mutated by this migration.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- -----------------------------------------------------------------------------
-- 1. Harden legacy Buyer-company compatibility helper.
-- -----------------------------------------------------------------------------
-- New Buyer sessions resolve through customer_buyer_eligible_company_id(). The
-- public.users fallback exists only for historical customer identities that have
-- not yet been projected into public.profiles. It is deliberately restricted to
-- active, non-staff buyer/customer roles and active, non-frozen companies.
CREATE OR REPLACE FUNCTION public.auth_buyer_company_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT coalesce(
    public.customer_buyer_eligible_company_id(),
    (
      SELECT u.company_id
      FROM public.users u
      JOIN public.companies c ON c.id = u.company_id
      WHERE u.id = auth.uid()
        AND u.company_id IS NOT NULL
        AND coalesce(u.is_active, true) IS TRUE
        AND u.deleted_at IS NULL
        AND lower(coalesce(u.role, '')) IN (
          'b2b_buyer',
          'buyer',
          'customer_user',
          'customer_admin',
          'b2b_customer',
          'special_buyer',
          'horeca_buyer',
          'wholesale_buyer',
          'bulk_buyer',
          'client'
        )
        AND NOT public.is_staff_role(u.role)
        AND NOT coalesce(public.is_internal_staff(auth.uid()), false)
        AND lower(coalesce(c.status, '')) IN ('active', 'approved')
        AND coalesce(c.is_frozen, false) IS FALSE
      LIMIT 1
    )
  );
$$;

COMMENT ON FUNCTION public.auth_buyer_company_id() IS
  'Compatibility Buyer-company resolver. Prefers canonical customer_buyer_eligible_company_id(); legacy public.users fallback is restricted to active non-staff buyer/customer roles in active non-frozen companies. Never grants Buyer company context to internal staff or arbitrary authenticated company members.';

REVOKE ALL ON FUNCTION public.auth_buyer_company_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.auth_buyer_company_id() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. Buyer pricing projection: canonical Buyer identity gate.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.buyer_product_prices_v1()
RETURNS TABLE(
  product_id uuid,
  selling_price numeric,
  currency text,
  uom text,
  gst_rate numeric,
  tax_inclusive boolean,
  applied_discount_percent numeric,
  minimum_order_quantity numeric,
  minimum_order_uom text,
  order_increment numeric,
  order_increment_uom text,
  valid_from date,
  valid_until date
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH buyer AS (
    SELECT
      c.id AS company_id,
      greatest(least(coalesce(c.discount_percentage, 0), 100), 0)::numeric AS discount_percent
    FROM public.companies c
    WHERE c.id = public.customer_buyer_eligible_company_id()
  ), ranked_prices AS (
    SELECT
      r.product_id,
      coalesce(r.calculated_price, r.base_price)::numeric AS listed_price,
      r.currency,
      r.uom,
      r.gst_rate,
      coalesce(r.tax_inclusive, false) AS tax_inclusive,
      r.valid_from,
      r.valid_until,
      row_number() OVER (
        PARTITION BY r.product_id
        ORDER BY r.valid_from DESC NULLS LAST,
                 r.approved_at DESC NULLS LAST,
                 r.updated_at DESC NULLS LAST,
                 r.id DESC
      ) AS rn
    FROM public.product_pricing_rules r
    JOIN public.published_products_v1() pp ON pp.product_id = r.product_id
    WHERE lower(coalesce(r.price_channel, '')) = 'b2b'
      AND lower(coalesce(r.approval_status, '')) = 'approved'
      AND coalesce(r.calculated_price, r.base_price) > 0
      AND (r.valid_from IS NULL OR r.valid_from <= current_date)
      AND (r.valid_until IS NULL OR r.valid_until >= current_date)
  ), b2b_moq AS (
    SELECT
      m.product_id,
      CASE WHEN coalesce(m.moq_applicable, true) THEN m.moq_value::numeric END AS moq_value,
      CASE WHEN coalesce(m.moq_applicable, true) THEN nullif(btrim(m.moq_uom), '') END AS moq_uom,
      CASE WHEN coalesce(m.moq_applicable, true) THEN m.increment_value::numeric END AS increment_value,
      CASE WHEN coalesce(m.moq_applicable, true) THEN nullif(btrim(m.increment_uom), '') END AS increment_uom,
      row_number() OVER (
        PARTITION BY m.product_id
        ORDER BY m.updated_at DESC NULLS LAST, m.created_at DESC NULLS LAST, m.id DESC
      ) AS rn
    FROM public.product_moq_rules m
    WHERE lower(coalesce(m.channel, '')) = 'b2b'
  )
  SELECT
    rp.product_id,
    round(rp.listed_price * (1 - b.discount_percent / 100), 2) AS selling_price,
    coalesce(nullif(btrim(rp.currency), ''), 'INR') AS currency,
    rp.uom,
    rp.gst_rate,
    rp.tax_inclusive,
    b.discount_percent AS applied_discount_percent,
    coalesce(bm.moq_value, p.moq_value::numeric, p.moq_packs::numeric, p.moq::numeric) AS minimum_order_quantity,
    coalesce(
      bm.moq_uom,
      nullif(btrim(p.moq_uom), ''),
      CASE WHEN p.moq_packs IS NOT NULL THEN 'pack' END,
      nullif(btrim(p.b2b_uom), ''),
      nullif(btrim(rp.uom), '')
    ) AS minimum_order_uom,
    coalesce(bm.increment_value, p.increment_value::numeric, 1::numeric) AS order_increment,
    coalesce(
      bm.increment_uom,
      nullif(btrim(p.increment_uom), ''),
      nullif(btrim(p.moq_uom), ''),
      nullif(btrim(p.b2b_uom), ''),
      nullif(btrim(rp.uom), '')
    ) AS order_increment_uom,
    rp.valid_from,
    rp.valid_until
  FROM ranked_prices rp
  CROSS JOIN buyer b
  JOIN public.products p ON p.id = rp.product_id
  LEFT JOIN b2b_moq bm ON bm.product_id = rp.product_id AND bm.rn = 1
  WHERE rp.rn = 1
  ORDER BY rp.product_id;
$$;

REVOKE ALL ON FUNCTION public.buyer_product_prices_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.buyer_product_prices_v1() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. Legacy order list/detail projections: canonical Buyer identity gate.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_order_items_v1()
RETURNS TABLE(
  order_id uuid,
  item_id uuid,
  product_id uuid,
  sku text,
  product_name text,
  quantity numeric,
  pack_size text,
  weight_kg numeric,
  packed_quantity numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH eligible_company AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    oi.order_id,
    oi.id AS item_id,
    oi.product_id,
    nullif(btrim(p.sku), '') AS sku,
    coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), ''), 'Product') AS product_name,
    oi.quantity::numeric,
    nullif(btrim(oi.pack_size), '') AS pack_size,
    oi.weight_kg::numeric,
    CASE
      WHEN o.status IN ('packed_ready', 'cleared_for_dispatch', 'dispatched')
        THEN oi.actual_packed_qty::numeric
      ELSE NULL
    END AS packed_quantity
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN eligible_company ec ON ec.company_id IS NOT NULL AND ec.company_id = o.company_id
  LEFT JOIN public.products p ON p.id = oi.product_id
  WHERE coalesce(o.is_waste, false) IS FALSE
    AND coalesce(o.is_duplicate, false) IS FALSE
  ORDER BY o.created_at DESC, oi.order_id, oi.id;
$$;

CREATE OR REPLACE FUNCTION public.customer_order_status_v1()
RETURNS TABLE(
  order_id uuid,
  order_number text,
  customer_stage text,
  payment_stage text,
  order_value numeric,
  total_weight_kg numeric,
  requested_dispatch_date date,
  promised_dispatch_date date,
  tracking_number text,
  courier_name text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH eligible_company AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    o.id AS order_id,
    o.order_number,
    CASE
      WHEN o.status IN ('draft', 'submitted') THEN 'order_received'
      WHEN o.status IN ('awaiting_advance', 'awaiting_payment') THEN 'payment_pending'
      WHEN o.status IN ('manufacturing', 'in_production') THEN 'in_production'
      WHEN o.status IN ('assembled', 'packing') THEN 'packing'
      WHEN o.status IN ('packed_ready', 'cleared_for_dispatch') THEN 'ready_for_dispatch'
      WHEN o.status = 'dispatched' THEN 'dispatched'
      ELSE 'processing'
    END AS customer_stage,
    CASE
      WHEN o.payment_status IN ('paid', 'advance_paid', 'verified_advance') THEN 'paid_or_verified'
      WHEN o.payment_status IN ('on_credit', 'short_term_credit') THEN 'credit_approved'
      WHEN o.payment_status IN ('under_review', 'awaiting_verification') THEN 'under_review'
      ELSE 'payment_pending'
    END AS payment_stage,
    o.sales_order_value AS order_value,
    o.total_weight_kg,
    o.requested_dispatch_date,
    coalesce(o.admin_promised_date, o.system_estimated_date, o.estimated_despatch_date) AS promised_dispatch_date,
    CASE WHEN o.status = 'dispatched' THEN nullif(btrim(o.tracking_number), '') END AS tracking_number,
    CASE WHEN o.status = 'dispatched' THEN nullif(btrim(o.courier_name), '') END AS courier_name,
    o.created_at,
    greatest(o.created_at, coalesce(o.closed_at, o.created_at), coalesce(o.finance_verified_at, o.created_at)) AS updated_at
  FROM public.orders o
  JOIN eligible_company ec ON ec.company_id IS NOT NULL AND ec.company_id = o.company_id
  WHERE coalesce(o.is_waste, false) IS FALSE
    AND coalesce(o.is_duplicate, false) IS FALSE
  ORDER BY o.created_at DESC, o.id;
$$;

REVOKE ALL ON FUNCTION public.customer_order_items_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_order_items_v1() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.customer_order_status_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_order_status_v1() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Support projections/submission: same canonical Buyer gate.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_support_tickets_v1()
RETURNS TABLE(
  ticket_id uuid,
  order_id text,
  order_number text,
  issue_type text,
  description text,
  customer_status text,
  product_sku text,
  quantity_affected integer,
  created_at timestamptz,
  updated_at timestamptz,
  first_response_due timestamptz,
  resolution_due timestamptz,
  resolved_at timestamptz,
  customer_rating integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH eligible_company AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    st.id AS ticket_id,
    st.order_id,
    o.order_number,
    st.issue_type,
    st.description,
    CASE
      WHEN lower(coalesce(st.status, '')) IN ('resolved', 'closed') THEN 'resolved'
      WHEN lower(coalesce(st.status, '')) IN ('rejected', 'cancelled') THEN 'closed'
      WHEN st.sla_first_response_at IS NOT NULL THEN 'in_progress'
      ELSE 'open'
    END AS customer_status,
    st.product_sku,
    st.qty_affected AS quantity_affected,
    st.created_at,
    st.updated_at,
    st.sla_first_response_due AS first_response_due,
    st.sla_resolution_due AS resolution_due,
    st.sla_resolved_at AS resolved_at,
    st.customer_rating
  FROM public.support_tickets st
  JOIN eligible_company ec ON ec.company_id IS NOT NULL AND ec.company_id = st.company_id
  LEFT JOIN public.orders o
    ON o.id = CASE
                WHEN st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  THEN st.order_id::uuid
              END
  ORDER BY st.created_at DESC, st.id;
$$;

CREATE OR REPLACE FUNCTION public.submit_customer_support_ticket_v1(
  p_order_id uuid,
  p_issue_type text,
  p_description text,
  p_product_sku text DEFAULT NULL,
  p_quantity_affected integer DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_company_id uuid := public.customer_buyer_eligible_company_id();
  new_ticket_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'approved buyer company required' USING ERRCODE = '42501';
  END IF;
  IF p_order_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = p_order_id
      AND o.company_id = v_company_id
      AND coalesce(o.is_waste, false) IS FALSE
      AND coalesce(o.is_duplicate, false) IS FALSE
  ) THEN
    RAISE EXCEPTION 'order is not available to the authenticated company' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_issue_type), '') IS NULL THEN
    RAISE EXCEPTION 'issue type is required';
  END IF;
  IF nullif(btrim(p_description), '') IS NULL OR length(btrim(p_description)) < 10 THEN
    RAISE EXCEPTION 'description must contain at least 10 characters';
  END IF;
  IF length(btrim(p_description)) > 4000 THEN
    RAISE EXCEPTION 'description exceeds 4000 characters';
  END IF;
  IF p_quantity_affected IS NOT NULL AND p_quantity_affected <= 0 THEN
    RAISE EXCEPTION 'quantity affected must be positive';
  END IF;

  INSERT INTO public.support_tickets (
    order_id, company_id, created_by, user_id,
    issue_type, description, product_sku, qty_affected, status
  ) VALUES (
    p_order_id::text,
    v_company_id,
    v_uid,
    v_uid,
    lower(replace(btrim(p_issue_type), ' ', '_')),
    btrim(p_description),
    nullif(btrim(p_product_sku), ''),
    p_quantity_affected,
    'open'
  )
  RETURNING id INTO new_ticket_id;

  RETURN new_ticket_id;
END;
$$;

-- The insert trigger remains the authoritative table-level guard as defense in
-- depth for any future authenticated caller that bypasses the RPC.
CREATE OR REPLACE FUNCTION public.support_ticket_set_customer_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id uuid := auth.uid();
  actor_company_id uuid;
  actor_is_admin boolean := false;
BEGIN
  new.updated_at := now();

  IF tg_op = 'UPDATE' THEN
    RETURN new;
  END IF;
  IF auth.role() = 'service_role' THEN
    RETURN new;
  END IF;
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = actor_id
      AND lower(coalesce(u.role, '')) IN ('admin', 'super_admin')
      AND coalesce(u.is_active, true) IS TRUE
      AND u.deleted_at IS NULL
  ) INTO actor_is_admin;

  IF actor_is_admin THEN
    new.created_by := coalesce(new.created_by, actor_id);
    new.user_id := coalesce(new.user_id, actor_id);
    RETURN new;
  END IF;

  actor_company_id := public.customer_buyer_eligible_company_id();
  IF actor_company_id IS NULL THEN
    RAISE EXCEPTION 'approved customer company required' USING ERRCODE = '42501';
  END IF;

  IF new.order_id IS NULL
     OR new.order_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR NOT EXISTS (
       SELECT 1
       FROM public.orders o
       WHERE o.id = new.order_id::uuid
         AND o.company_id = actor_company_id
         AND coalesce(o.is_waste, false) IS FALSE
         AND coalesce(o.is_duplicate, false) IS FALSE
     ) THEN
    RAISE EXCEPTION 'order is not available to the authenticated company';
  END IF;

  new.company_id := actor_company_id;
  new.created_by := actor_id;
  new.user_id := actor_id;
  new.status := coalesce(nullif(btrim(new.status), ''), 'open');
  new.resolution_notes := NULL;
  new.routed_to_department := NULL;
  new.assigned_employee_id := NULL;
  new.sla_first_response_at := NULL;
  new.sla_action_at := NULL;
  new.sla_resolved_at := NULL;
  new.sla_state := NULL;
  new.estimated_financial_loss := NULL;
  new.admin_rating_speed := NULL;
  new.admin_rating_quality := NULL;
  new.admin_rating_communication := NULL;
  new.rejection_reason_template := NULL;
  new.resolution_template_used := NULL;
  new.ai_rewritten_reply := NULL;
  new.escalated_to_hod := FALSE;
  new.commission_blocked := FALSE;

  RETURN new;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_support_tickets_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_support_tickets_v1() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) TO authenticated, service_role;

COMMENT ON FUNCTION public.submit_customer_support_ticket_v1(uuid,text,text,text,integer) IS
  'Creates a customer support ticket only for an order owned by the canonical authenticated approved Buyer company.';