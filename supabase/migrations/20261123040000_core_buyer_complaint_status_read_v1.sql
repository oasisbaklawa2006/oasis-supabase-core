-- Buyer-scoped, read-only complaint status (ASM-CORE-BUYER-COMPLAINT-STATUS-READ-1E).
--
-- Core PR #598 shipped get_commercial_complaint_handoff_facts_v1 as a STAFF-ONLY read (Support/Finance/admin).
-- A Buyer calling it gets zero rows, and commercial_adjustments / return links are staff-read-only, so the Buyer app
-- cannot show physical-return or Finance status. This migration adds a separate, narrow, Buyer-safe projection:
--
--   public.customer_commercial_complaint_status_v1()
--
-- It changes nothing that exists: no table, no policy, no existing RPC signature, body or grant. The staff RPC stays
-- staff-only; resolve_commercial_complaint_v1 (Finance AAL2) is untouched. This function only READS, and only for the
-- authenticated, eligible Buyer's OWN company.
--
-- What a Buyer may learn (deliberately coarse; owner to confirm on the PR):
--   * return_receipt_status: a four-value enum. It never exposes quarantine, QA, stock or liability state, and physical
--     receipt is NOT acceptance of the claim (the return-arrival contract is conditional receipt only).
--   * finance_status: PENDING_FINANCE_REVIEW or RESOLVED, with a whitelisted outcome. Internal recovery, write-off and
--     debit types collapse to OTHER_RESOLUTION with no amount. Amounts are returned only for the three money-back
--     outcomes.
--   * Never returned: actor ids, decision reasons, correlation/idempotency keys, evidence, document or payment
--     references, internal notes, event history.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.customer_commercial_complaint_status_v1()
RETURNS TABLE (
  support_ticket_id uuid,
  order_id uuid,
  order_number text,
  complaint_id uuid,
  complaint_type text,
  complaint_filed_at timestamptz,
  complaint_deadline timestamptz,
  complaint_status text,
  return_receipt_status text,
  return_case_count integer,
  finance_status text,
  finance_outcome text,
  finance_amount numeric,
  finance_resolved_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH eligible AS (
    SELECT public.customer_buyer_eligible_company_id() AS company_id
  )
  SELECT
    l.support_ticket_id,
    c.order_id,
    o.order_number,
    c.id,
    c.complaint_type,
    c.filed_at,
    c.complaint_deadline,
    -- A recorded resolution always reports RESOLVED (even if event timestamps tie); otherwise the newest event.
    CASE
      WHEN adj.id IS NOT NULL THEN 'RESOLVED'
      ELSE coalesce(ev.status, 'OPEN')
    END,
    -- Coarse physical-return state across every return case linked to this complaint. Precedence: received >
    -- arrival recorded > refused at gate > none. An unknown future arrival state is reported as the non-committal
    -- RETURN_ARRIVAL_RECORDED.
    CASE
      WHEN rc.total = 0 THEN 'NO_RETURN_RECORDED'
      WHEN rc.received > 0 THEN 'RETURN_PHYSICALLY_RECEIVED'
      WHEN rc.refused = rc.total THEN 'RETURN_REFUSED_AT_GATE'
      ELSE 'RETURN_ARRIVAL_RECORDED'
    END,
    rc.total,
    CASE WHEN adj.id IS NULL THEN 'PENDING_FINANCE_REVIEW' ELSE 'RESOLVED' END,
    -- Whitelisted outcome. No adjustment => NULL (a simple CASE cannot match NULL, so test the row explicitly).
    CASE
      WHEN adj.id IS NULL THEN NULL
      ELSE CASE adj.adjustment_type
        WHEN 'NO_FINANCIAL_ACTION' THEN 'NO_FINANCIAL_ACTION'
        WHEN 'CREDIT_NOTE' THEN 'CREDIT_NOTE'
        WHEN 'REFUND_TO_BANK' THEN 'REFUND_TO_BANK'
        WHEN 'REFUND_TO_WALLET' THEN 'REFUND_TO_WALLET'
        WHEN 'REPLACEMENT_NO_CHARGE' THEN 'REPLACEMENT_NO_CHARGE'
        WHEN 'REPLACEMENT_CHARGEABLE' THEN 'REPLACEMENT_CHARGEABLE'
        ELSE 'OTHER_RESOLUTION'
      END
    END,
    CASE
      WHEN adj.adjustment_type IN ('CREDIT_NOTE', 'REFUND_TO_BANK', 'REFUND_TO_WALLET') THEN adj.amount
    END,
    adj.created_at
  FROM eligible e
  JOIN public.commercial_complaints c ON c.company_id = e.company_id
  JOIN public.support_commercial_complaint_links l ON l.complaint_id = c.id
  LEFT JOIN public.orders o ON o.id = c.order_id AND o.company_id = e.company_id
  LEFT JOIN LATERAL (
    SELECT ce.status
    FROM public.commercial_complaint_events ce
    WHERE ce.complaint_id = c.id
    ORDER BY ce.created_at DESC, (ce.status = 'RESOLVED') DESC, ce.id DESC
    LIMIT 1
  ) ev ON true
  LEFT JOIN LATERAL (
    SELECT a.id, a.adjustment_type, a.amount, a.created_at
    FROM public.commercial_adjustments a
    WHERE a.complaint_id = c.id
    ORDER BY a.created_at DESC, a.id DESC
    LIMIT 1
  ) adj ON true
  LEFT JOIN LATERAL (
    SELECT
      count(*)::integer AS total,
      count(*) FILTER (WHERE r.arrival_state IN (
        'conditionally_received', 'partially_received', 'quarantined', 'under_investigation',
        'commercially_decided', 'closed'
      ))::integer AS received,
      count(*) FILTER (WHERE r.arrival_state = 'rejected_at_gate')::integer AS refused
    FROM public.commercial_complaint_return_links rl
    JOIN public.b2b_return_arrival_cases r ON r.id = rl.return_case_id
    WHERE rl.complaint_id = c.id
  ) rc ON true
  WHERE e.company_id IS NOT NULL
  ORDER BY c.filed_at DESC, c.id;
$$;

REVOKE ALL ON FUNCTION public.customer_commercial_complaint_status_v1() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.customer_commercial_complaint_status_v1() TO authenticated;

COMMENT ON FUNCTION public.customer_commercial_complaint_status_v1() IS
  'Buyer-scoped read-only status of the caller''s own-company commercial complaints that are linked to a support ticket: complaint deadline/status, a coarse physical-return state (never an acceptance of the claim) and a whitelisted Finance outcome. Returns nothing to staff, anonymous callers, unapproved buyers or other companies, and never exposes actors, reasons, keys, evidence or references.';
