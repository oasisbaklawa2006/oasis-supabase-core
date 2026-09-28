-- AUTH-01 support-ticket UUID text guard compatibility.
-- Contract coverage: 20260918010100_auth01_support_ticket_uuid_text_guard_compat.sql
--
-- Preserve the CASE-guarded text->uuid cast while accepting the full canonical
-- PostgreSQL hyphenated UUID text shape. UUID version/variant bits are not an
-- authorization boundary and must not suppress a valid matching order row.
-- Order metadata remains scoped to the eligible Buyer company even when legacy
-- support-ticket data contains a cross-company order identifier.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

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
  JOIN eligible_company ec
    ON ec.company_id IS NOT NULL
   AND ec.company_id = st.company_id
  LEFT JOIN public.orders o
    ON o.company_id = ec.company_id
   AND o.id = CASE
                WHEN st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  THEN st.order_id::uuid
              END
  ORDER BY st.created_at DESC, st.id;
$$;

REVOKE ALL ON FUNCTION public.customer_support_tickets_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_support_tickets_v1() TO authenticated, service_role;

COMMENT ON FUNCTION public.customer_support_tickets_v1() IS
  'Buyer-scoped support-ticket projection. Order text identifiers are cast only after a full canonical hyphenated hexadecimal UUID-shape guard; matching order metadata is additionally constrained to the eligible Buyer company.';
