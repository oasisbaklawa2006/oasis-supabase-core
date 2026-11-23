-- Batch 1C: append-only Support <-> Commercial Complaint bridge (ASM-CORE-COMPLAINT-BRIDGE-1C).
--
-- Adds, without touching any deployed object:
--   * public.support_ticket_order_uuid_v1(text)               safe canonical-UUID cast for legacy text order ids
--   * public.support_commercial_complaint_links               immutable ticket -> complaint link
--   * public.submit_customer_commercial_complaint_v1(...)     atomic ticket + canonical complaint + link
--   * public.commercial_complaint_return_links                immutable return-arrival -> complaint link
--   * public.link_return_case_to_commercial_complaint_v1(...) narrow staff link command
--   * public.get_commercial_complaint_handoff_facts_v1(uuid)  scoped read-only Support/Finance handoff facts
--
-- Unchanged by design: submit_customer_support_ticket_v2, file_commercial_complaint_v1 and
-- resolve_commercial_complaint_v1 (signatures, bodies and grants). Complaint filing authority, the complaint window
-- (final-invoice-date clock) and Finance AAL2 resolution stay exactly where they are; this migration only composes them.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ---------------------------------------------------------------------------------------------------------------
-- 0. Safe text -> uuid for legacy support_tickets.order_id (text). Returns NULL, never raises, for anything that is
--    not a full canonical hyphenated hexadecimal UUID. Same shape guard as customer_support_tickets_v1.
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.support_ticket_order_uuid_v1(p_order_id text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN p_order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN p_order_id::uuid
  END;
$$;
REVOKE ALL ON FUNCTION public.support_ticket_order_uuid_v1(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.support_ticket_order_uuid_v1(text) TO authenticated, service_role;
COMMENT ON FUNCTION public.support_ticket_order_uuid_v1(text) IS
  'Returns the uuid for a full canonical hyphenated hexadecimal text value, otherwise NULL. Never raises; legacy non-UUID support_tickets.order_id values yield NULL.';

-- Staff who may read the bridge: Support queue operators plus the Finance and admin roles that already hold
-- finance_review / complaint authority elsewhere. Read access only; Finance resolution keeps its own AAL2 gate.
CREATE OR REPLACE FUNCTION public.is_commercial_complaint_bridge_reader_v1(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  SELECT p_user_id IS NOT NULL
     AND public.is_internal_staff(p_user_id)
     AND upper(coalesce(public.get_user_role(p_user_id), '')) = ANY (
       ARRAY['ADMIN','SUPER_ADMIN','SUPPORT_EXECUTIVE','FINANCE_HEAD','FINANCE_EXEC']::text[]
     );
$$;
REVOKE ALL ON FUNCTION public.is_commercial_complaint_bridge_reader_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_commercial_complaint_bridge_reader_v1(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.is_commercial_complaint_bridge_reader_v1(uuid) IS
  'True for active internal staff who may read the Support/Commercial complaint bridge (Support queue operators, Finance, executives).';

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Append-only guard shared by both link tables.
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_complaint_bridge_link_mutation_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY' USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_complaint_bridge_link_mutation_v1() FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. public.support_commercial_complaint_links
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.support_commercial_complaint_links (
  support_ticket_id uuid PRIMARY KEY REFERENCES public.support_tickets (id) ON DELETE RESTRICT,
  complaint_id uuid NOT NULL UNIQUE REFERENCES public.commercial_complaints (id) ON DELETE RESTRICT,
  linked_by uuid NOT NULL REFERENCES auth.users (id),
  linked_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

-- Lineage guard: the ticket and the complaint must describe the same company and order. The ticket's order id is
-- legacy text, so it is only compared after the safe canonical-UUID cast (never a bare ::uuid).
CREATE OR REPLACE FUNCTION public.validate_support_commercial_complaint_link_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_ticket_company uuid;
  v_ticket_order text;
  v_complaint_company uuid;
  v_complaint_order uuid;
BEGIN
  SELECT t.company_id, t.order_id INTO v_ticket_company, v_ticket_order
  FROM public.support_tickets t WHERE t.id = NEW.support_ticket_id;
  SELECT c.company_id, c.order_id INTO v_complaint_company, v_complaint_order
  FROM public.commercial_complaints c WHERE c.id = NEW.complaint_id;
  IF v_ticket_company IS NULL
     OR v_complaint_company IS NULL
     OR v_ticket_company IS DISTINCT FROM v_complaint_company
     OR public.support_ticket_order_uuid_v1(v_ticket_order) IS DISTINCT FROM v_complaint_order THEN
    RAISE EXCEPTION 'SUPPORT_COMPLAINT_LINK_LINEAGE_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.validate_support_commercial_complaint_link_v1() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_support_commercial_complaint_links_lineage ON public.support_commercial_complaint_links;
CREATE TRIGGER trg_support_commercial_complaint_links_lineage
  BEFORE INSERT ON public.support_commercial_complaint_links
  FOR EACH ROW EXECUTE FUNCTION public.validate_support_commercial_complaint_link_v1();
DROP TRIGGER IF EXISTS trg_support_commercial_complaint_links_append_only ON public.support_commercial_complaint_links;
CREATE TRIGGER trg_support_commercial_complaint_links_append_only
  BEFORE UPDATE OR DELETE ON public.support_commercial_complaint_links
  FOR EACH ROW EXECUTE FUNCTION public.prevent_complaint_bridge_link_mutation_v1();
DROP TRIGGER IF EXISTS trg_support_commercial_complaint_links_no_truncate ON public.support_commercial_complaint_links;
CREATE TRIGGER trg_support_commercial_complaint_links_no_truncate
  BEFORE TRUNCATE ON public.support_commercial_complaint_links
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_complaint_bridge_link_mutation_v1();

ALTER TABLE public.support_commercial_complaint_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.support_commercial_complaint_links FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.support_commercial_complaint_links TO authenticated;

DROP POLICY IF EXISTS support_complaint_links_buyer_read ON public.support_commercial_complaint_links;
CREATE POLICY support_complaint_links_buyer_read ON public.support_commercial_complaint_links
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.commercial_complaints c
      WHERE c.id = support_commercial_complaint_links.complaint_id
        AND c.company_id = public.customer_buyer_eligible_company_id()
    )
  );
DROP POLICY IF EXISTS support_complaint_links_staff_read ON public.support_commercial_complaint_links;
CREATE POLICY support_complaint_links_staff_read ON public.support_commercial_complaint_links
  FOR SELECT TO authenticated
  USING (public.is_commercial_complaint_bridge_reader_v1(auth.uid()));

COMMENT ON TABLE public.support_commercial_complaint_links IS
  'Immutable ticket-to-complaint bridge. Rows are written only by submit_customer_commercial_complaint_v1; direct writes are revoked and UPDATE/DELETE/TRUNCATE are blocked. Reads: own-company eligible Buyer, Support/Finance/executive staff.';

-- ---------------------------------------------------------------------------------------------------------------
-- 3. public.submit_customer_commercial_complaint_v1
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_customer_commercial_complaint_v1(
  p_idempotency_key text,
  p_order_id uuid,
  p_complaint_type text,
  p_description text,
  p_evidence_references jsonb,
  p_product_sku text DEFAULT NULL,
  p_quantity_affected integer DEFAULT NULL
) RETURNS TABLE (ticket_id uuid, complaint_id uuid, complaint_deadline timestamptz, already_filed boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_type text := btrim(coalesce(p_complaint_type, ''));
  v_desc text := btrim(coalesce(p_description, ''));
  v_sku text := nullif(btrim(coalesce(p_product_sku, '')), '');
  v_issue_type text;
  v_company uuid;
  v_ticket public.support_tickets%rowtype;
  v_complaint public.commercial_complaints%rowtype;
  v_ticket_id uuid;
  v_deadline timestamptz;
  v_filed record;
  v_link_exists boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: authentication required' USING ERRCODE = '28000';
  END IF;
  IF v_key = '' OR length(v_key) > 200 THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_IDEMPOTENCY_KEY_REQUIRED' USING ERRCODE = '22023';
  END IF;

  -- Own-company approved/active buyer only (never a client-supplied company, never staff).
  v_company := public.customer_buyer_eligible_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_BUYER_CONTEXT_REQUIRED' USING ERRCODE = '42501';
  END IF;

  -- Explicit canonical type. No case folding, no free text, and 'Other' is not a commercial complaint type.
  IF v_type NOT IN ('DAMAGE', 'SHORTAGE', 'WRONG_PRODUCT') THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_TYPE_INVALID' USING ERRCODE = '22023';
  END IF;
  v_issue_type := lower(v_type);

  IF jsonb_typeof(p_evidence_references) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_evidence_references) = 0
     OR jsonb_array_length(p_evidence_references) > 20
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_evidence_references) AS e(v)
       WHERE NOT (
         (jsonb_typeof(e.v) = 'string' AND length(btrim(e.v #>> '{}')) BETWEEN 1 AND 2048)
         OR (jsonb_typeof(e.v) = 'object' AND e.v <> '{}'::jsonb)
       )
     ) THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED' USING ERRCODE = '22023';
  END IF;

  IF length(v_desc) < 10 OR length(v_desc) > 4000 THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_DESCRIPTION_INVALID' USING ERRCODE = '22023';
  END IF;
  IF p_quantity_affected IS NOT NULL AND p_quantity_affected <= 0 THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_QUANTITY_INVALID' USING ERRCODE = '22023';
  END IF;

  -- Order must belong to the caller's company (and not be waste/duplicate) before anything is written.
  IF NOT EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = p_order_id
      AND o.company_id = v_company
      AND coalesce(o.is_waste, false) IS FALSE
      AND coalesce(o.is_duplicate, false) IS FALSE
  ) THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_ORDER_NOT_AVAILABLE' USING ERRCODE = '42501';
  END IF;

  -- Serialise concurrent retries of the same actor/company/key.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('customer-commercial-complaint-bridge-v1:' || v_company::text || ':' || v_uid::text || ':' || v_key, 0)
  );

  SELECT * INTO v_ticket
  FROM public.support_tickets st
  WHERE st.company_id = v_company AND st.created_by = v_uid AND st.idempotency_key = v_key;

  IF FOUND THEN
    -- Replay / reconcile path. The retry must carry the identical payload and the ticket must be bound to this
    -- actor, company and order; anything else is a conflict, never a silent re-bind.
    IF v_ticket.order_id IS DISTINCT FROM p_order_id::text
       OR v_ticket.issue_type IS DISTINCT FROM v_issue_type
       OR v_ticket.description IS DISTINCT FROM v_desc
       OR v_ticket.product_sku IS DISTINCT FROM v_sku
       OR v_ticket.qty_affected IS DISTINCT FROM p_quantity_affected THEN
      RAISE EXCEPTION 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    SELECT c.* INTO v_complaint
    FROM public.support_commercial_complaint_links l
    JOIN public.commercial_complaints c ON c.id = l.complaint_id
    WHERE l.support_ticket_id = v_ticket.id;
    v_link_exists := FOUND;

    IF v_link_exists THEN
      -- The immutable link is checked BEFORE any window test, so a post-cutoff retry of an already-filed complaint
      -- returns the original result instead of being rejected as late.
      IF v_complaint.order_id IS DISTINCT FROM p_order_id
         OR v_complaint.company_id IS DISTINCT FROM v_company
         OR v_complaint.filed_by IS DISTINCT FROM v_uid
         OR v_complaint.complaint_type IS DISTINCT FROM v_type
         OR v_complaint.description IS DISTINCT FROM v_desc
         OR v_complaint.evidence_references IS DISTINCT FROM p_evidence_references THEN
        RAISE EXCEPTION 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
      END IF;
      RETURN QUERY SELECT v_ticket.id, v_complaint.id, v_complaint.complaint_deadline, true;
      RETURN;
    END IF;
    v_ticket_id := v_ticket.id;
  ELSE
    -- Reuse the already-certified idempotent ticket authority (its own buyer/order checks and trigger apply).
    SELECT t.ticket_id INTO v_ticket_id
    FROM public.submit_customer_support_ticket_v2(v_key, p_order_id, v_issue_type, v_desc, v_sku, p_quantity_affected) AS t;
  END IF;

  -- Canonical complaint authority, with a server-derived idempotency key. The caller never chooses it. Window
  -- expiry for a new filing is raised here (COMPLAINT_WINDOW_EXPIRED); the whole call then rolls back, so no ticket,
  -- complaint, event or link survives, and a historical ticket is never backdated into an open window.
  SELECT f.complaint_id, f.complaint_deadline, f.already_filed INTO v_filed
  FROM public.file_commercial_complaint_v1(
    p_order_id, v_type, v_desc, p_evidence_references, NULL,
    'support-ticket:' || v_ticket_id::text, 'support-ticket:' || v_ticket_id::text, v_uid
  ) AS f;

  SELECT c.* INTO v_complaint FROM public.commercial_complaints c WHERE c.id = v_filed.complaint_id;
  IF NOT FOUND
     OR v_complaint.order_id IS DISTINCT FROM p_order_id
     OR v_complaint.company_id IS DISTINCT FROM v_company
     OR v_complaint.filed_by IS DISTINCT FROM v_uid
     OR v_complaint.complaint_type IS DISTINCT FROM v_type THEN
    RAISE EXCEPTION 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
  END IF;
  v_deadline := v_filed.complaint_deadline;

  INSERT INTO public.support_commercial_complaint_links (support_ticket_id, complaint_id, linked_by)
  VALUES (v_ticket_id, v_complaint.id, v_uid);

  RETURN QUERY SELECT v_ticket_id, v_complaint.id, v_deadline, false;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_customer_commercial_complaint_v1(text, uuid, text, text, jsonb, text, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_customer_commercial_complaint_v1(text, uuid, text, text, jsonb, text, integer)
  TO authenticated;
COMMENT ON FUNCTION public.submit_customer_commercial_complaint_v1(text, uuid, text, text, jsonb, text, integer) IS
  'Atomic Buyer complaint intake: reuses submit_customer_support_ticket_v2 and file_commercial_complaint_v1 (server-derived key support-ticket:<ticket id>) and writes the immutable support link in one transaction. Existing link/idempotency is resolved before any window test.';

-- ---------------------------------------------------------------------------------------------------------------
-- 4. public.commercial_complaint_return_links (+ narrow staff link command)
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.commercial_complaint_return_links (
  return_case_id uuid PRIMARY KEY REFERENCES public.b2b_return_arrival_cases (id) ON DELETE RESTRICT,
  complaint_id uuid NOT NULL REFERENCES public.commercial_complaints (id) ON DELETE RESTRICT,
  linked_by uuid NOT NULL REFERENCES auth.users (id),
  linked_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX IF NOT EXISTS commercial_complaint_return_links_complaint_idx
  ON public.commercial_complaint_return_links (complaint_id);

-- Lineage guard (defence in depth behind the command): a return case must be bound to an order, and that order (and the
-- company that owns it, via orders.company_id) must match the complaint. Unbound legacy arrivals (no order) are never
-- linkable. b2b_return_arrival_cases.customer_id is deliberately NOT used: it has no FK, no documented meaning and no
-- writer anywhere, so it cannot carry lineage authority. orders.company_id is the canonical company binding.
CREATE OR REPLACE FUNCTION public.validate_commercial_complaint_return_link_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_rc_order uuid;
  v_rc_company uuid;
  v_c_order uuid;
  v_c_company uuid;
BEGIN
  SELECT r.order_id, o.company_id INTO v_rc_order, v_rc_company
  FROM public.b2b_return_arrival_cases r
  LEFT JOIN public.orders o ON o.id = r.order_id
  WHERE r.id = NEW.return_case_id;
  SELECT c.order_id, c.company_id INTO v_c_order, v_c_company
  FROM public.commercial_complaints c WHERE c.id = NEW.complaint_id;
  IF v_rc_order IS NULL THEN
    RAISE EXCEPTION 'RETURN_CASE_UNBOUND_LEGACY' USING ERRCODE = '55000';
  END IF;
  IF v_c_order IS NULL OR v_c_company IS NULL
     OR v_rc_order IS DISTINCT FROM v_c_order
     OR v_rc_company IS DISTINCT FROM v_c_company THEN
    RAISE EXCEPTION 'RETURN_COMPLAINT_LINEAGE_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.validate_commercial_complaint_return_link_v1() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_commercial_complaint_return_links_lineage ON public.commercial_complaint_return_links;
CREATE TRIGGER trg_commercial_complaint_return_links_lineage
  BEFORE INSERT ON public.commercial_complaint_return_links
  FOR EACH ROW EXECUTE FUNCTION public.validate_commercial_complaint_return_link_v1();
DROP TRIGGER IF EXISTS trg_commercial_complaint_return_links_append_only ON public.commercial_complaint_return_links;
CREATE TRIGGER trg_commercial_complaint_return_links_append_only
  BEFORE UPDATE OR DELETE ON public.commercial_complaint_return_links
  FOR EACH ROW EXECUTE FUNCTION public.prevent_complaint_bridge_link_mutation_v1();
DROP TRIGGER IF EXISTS trg_commercial_complaint_return_links_no_truncate ON public.commercial_complaint_return_links;
CREATE TRIGGER trg_commercial_complaint_return_links_no_truncate
  BEFORE TRUNCATE ON public.commercial_complaint_return_links
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_complaint_bridge_link_mutation_v1();

ALTER TABLE public.commercial_complaint_return_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.commercial_complaint_return_links FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.commercial_complaint_return_links TO authenticated;
DROP POLICY IF EXISTS complaint_return_links_staff_read ON public.commercial_complaint_return_links;
CREATE POLICY complaint_return_links_staff_read ON public.commercial_complaint_return_links
  FOR SELECT TO authenticated
  USING (public.is_commercial_complaint_bridge_reader_v1(auth.uid()));
COMMENT ON TABLE public.commercial_complaint_return_links IS
  'Immutable return-arrival-to-complaint lineage. Written only by link_return_case_to_commercial_complaint_v1; carries no quarantine, QA, stock or liability state. Staff read only.';

CREATE OR REPLACE FUNCTION public.link_return_case_to_commercial_complaint_v1(
  p_return_case_id uuid,
  p_complaint_id uuid
) RETURNS TABLE (return_case_id uuid, complaint_id uuid, already_linked boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_existing public.commercial_complaint_return_links%rowtype;
  v_case public.b2b_return_arrival_cases%rowtype;
  v_complaint public.commercial_complaints%rowtype;
  v_case_company uuid;
BEGIN
  IF v_uid IS NULL OR NOT public.is_support_ticket_queue_operator(v_uid) THEN
    RAISE EXCEPTION 'RETURN_LINK_ACTOR_NOT_AUTHORIZED' USING ERRCODE = '42501';
  END IF;
  IF p_return_case_id IS NULL OR p_complaint_id IS NULL THEN
    RAISE EXCEPTION 'RETURN_LINK_ARGUMENTS_REQUIRED' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('complaint-return-link-v1:' || p_return_case_id::text, 0));

  SELECT * INTO v_existing FROM public.commercial_complaint_return_links rl WHERE rl.return_case_id = p_return_case_id;
  IF FOUND THEN
    IF v_existing.complaint_id IS DISTINCT FROM p_complaint_id THEN
      RAISE EXCEPTION 'RETURN_LINK_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    RETURN QUERY SELECT v_existing.return_case_id, v_existing.complaint_id, true;
    RETURN;
  END IF;

  SELECT * INTO v_case FROM public.b2b_return_arrival_cases r WHERE r.id = p_return_case_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RETURN_CASE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  IF v_case.order_id IS NULL THEN
    RAISE EXCEPTION 'RETURN_CASE_UNBOUND_LEGACY' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO v_complaint FROM public.commercial_complaints c WHERE c.id = p_complaint_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMPLAINT_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;
  -- Company binding comes from the owning order (orders.company_id); customer_id is never consulted.
  SELECT o.company_id INTO v_case_company FROM public.orders o WHERE o.id = v_case.order_id;
  IF v_case.order_id IS DISTINCT FROM v_complaint.order_id
     OR v_case_company IS DISTINCT FROM v_complaint.company_id THEN
    RAISE EXCEPTION 'RETURN_COMPLAINT_LINEAGE_MISMATCH' USING ERRCODE = 'P0001';
  END IF;

  -- Lineage only: no update to the return case, quarantine, QA, inventory or any liability/finance record.
  INSERT INTO public.commercial_complaint_return_links (return_case_id, complaint_id, linked_by)
  VALUES (p_return_case_id, p_complaint_id, v_uid);

  RETURN QUERY SELECT p_return_case_id, p_complaint_id, false;
END;
$$;
REVOKE ALL ON FUNCTION public.link_return_case_to_commercial_complaint_v1(uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.link_return_case_to_commercial_complaint_v1(uuid, uuid) TO authenticated;
COMMENT ON FUNCTION public.link_return_case_to_commercial_complaint_v1(uuid, uuid) IS
  'Support queue operator command that records return-arrival-to-complaint lineage. Validates matching order and owning-order company (never b2b_return_arrival_cases.customer_id), rejects unbound legacy arrivals (no order), is idempotent, and changes nothing else.';

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Scoped read-only handoff facts (Support -> Finance). Does not call or change resolve_commercial_complaint_v1.
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_commercial_complaint_handoff_facts_v1(p_support_ticket_id uuid)
RETURNS TABLE (
  support_ticket_id uuid,
  ticket_order_id text,
  ticket_status text,
  complaint_id uuid,
  order_id uuid,
  company_id uuid,
  complaint_type text,
  complaint_filed_at timestamptz,
  complaint_deadline timestamptz,
  complaint_status text,
  return_case_ids uuid[],
  adjustment_count bigint,
  adjustments jsonb,
  resolved boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  SELECT
    t.id,
    t.order_id,
    t.status,
    c.id,
    c.order_id,
    c.company_id,
    c.complaint_type,
    c.filed_at,
    c.complaint_deadline,
    (SELECT e.status FROM public.commercial_complaint_events e
      WHERE e.complaint_id = c.id ORDER BY e.created_at DESC, e.id DESC LIMIT 1),
    coalesce((SELECT array_agg(rl.return_case_id ORDER BY rl.linked_at, rl.return_case_id)
      FROM public.commercial_complaint_return_links rl WHERE rl.complaint_id = c.id), ARRAY[]::uuid[]),
    (SELECT count(*) FROM public.commercial_adjustments a WHERE a.complaint_id = c.id),
    coalesce((SELECT jsonb_agg(jsonb_build_object(
        'adjustment_id', a.id,
        'adjustment_type', a.adjustment_type,
        'amount', a.amount,
        'created_at', a.created_at) ORDER BY a.created_at, a.id)
      FROM public.commercial_adjustments a WHERE a.complaint_id = c.id), '[]'::jsonb),
    EXISTS (SELECT 1 FROM public.commercial_adjustments a WHERE a.complaint_id = c.id)
  FROM public.support_tickets t
  JOIN public.support_commercial_complaint_links l ON l.support_ticket_id = t.id
  JOIN public.commercial_complaints c ON c.id = l.complaint_id
  WHERE t.id = p_support_ticket_id
    AND public.is_commercial_complaint_bridge_reader_v1(auth.uid());
$$;
REVOKE ALL ON FUNCTION public.get_commercial_complaint_handoff_facts_v1(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_commercial_complaint_handoff_facts_v1(uuid) TO authenticated;
COMMENT ON FUNCTION public.get_commercial_complaint_handoff_facts_v1(uuid) IS
  'Read-only Support/Finance handoff facts joining support_tickets, support_commercial_complaint_links, commercial_complaints, commercial_complaint_return_links and commercial_adjustments. Returns rows only to bridge readers; buyers and anonymous callers get nothing. Never resolves a complaint.';
