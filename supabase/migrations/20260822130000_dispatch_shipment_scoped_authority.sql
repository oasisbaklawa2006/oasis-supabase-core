-- Owner decision (Dispatch customer-visibility model, simplified per
-- explicit correction): Dispatch is ONE operational/permission domain, not a
-- tiered hierarchy. An earlier revision of this migration introduced
-- is_dispatch_operator_role/is_dispatch_manager_role -- a two-tier split the
-- owner explicitly rejected: "do not create additional Dispatch tiers ...
-- treat Dispatch as one operational department/permission domain ... do not
-- solve confidentiality by proliferating roles." That revision is replaced
-- entirely by this one. The existing DISPATCH_INCHARGE/DISPATCH_MANAGER/
-- DISPATCH_HEAD role literals remain (kept for backward compatibility /
-- employee designation, per the owner), all mapped to the SAME operational
-- capability -- which is exactly what the existing can_manage_b2b_dispatch()
-- already provides (verified: SUPER_ADMIN, ADMIN, OPERATIONS_MANAGER,
-- DISPATCH_MANAGER, DISPATCH_INCHARGE, DISPATCH_HEAD, one flat list, no
-- tiers). can_manage_b2b_dispatch() and its many existing RLS-policy
-- consumers on the b2b_dispatch_* tables are NOT modified here.
--
-- Confidentiality is instead enforced by restricting what a NEW governed
-- view/RPC surface returns, per the owner's approved/forbidden lists:
--
-- Dispatch MAY see (this view/RPC surface): order/dispatch reference,
-- consignee/customer name, approved ship-to address, delivery contact,
-- destination, products/quantities/cartons, transporter/vehicle, delivery
-- instructions, invoice/e-way-bill references, finance status collapsed to
-- CLEARED/HOLD, dispatch readiness and operational exceptions.
--
-- Dispatch must NOT see (and this surface never joins the tables that would
-- expose it): salesperson/account-owner identity (companies.account_manager_id),
-- CRM history (crm_tasks), margins/discounts (companies.discount_percentage,
-- price_tier), credit/outstanding/payment history (companies.credit_limit,
-- total_outstanding, current_balance), or raw commercial order value
-- (orders.sales_order_value). None of those tables/columns are referenced
-- anywhere below -- this is a structural guarantee, not a column filter that
-- could be forgotten later.
--
-- Favouritism protection: system-derived priority ordering (committed_cutoff)
-- cannot be changed by a direct client UPDATE -- a guard trigger blocks any
-- write to it outside the governed override_dispatch_priority() RPC below,
-- which requires a reason and leaves an immutable audit trail. The same
-- guard protects destination_snapshot (the approved shipping identity):
-- Dispatch has no path to edit it directly, only to raise a correction
-- exception via raise_dispatch_shipping_data_exception() below.

-- =================================================================================
-- 1. Shipment-scoped execution view: the single, flat-capability read
--    surface every Dispatch-authorised role uses. security_invoker = true
--    relies on the existing "Internal staff read" RLS on the underlying
--    tables for row visibility; the view's own column list is what
--    implements the purpose-limited data exposure -- it structurally cannot
--    return salesperson/CRM/pricing/credit data because it never joins
--    companies or crm_tasks at all.
-- =================================================================================
CREATE OR REPLACE VIEW public.b2b_dispatch_shipment_execution_view
WITH (security_invoker = true)
AS
SELECT
  c.id AS consignment_id,
  c.consignment_number,
  c.order_id,
  o.order_number,
  c.status AS consignment_status,
  c.dispatch_mode,
  c.committed_cutoff,
  c.planned_departure_at,
  c.actual_departure_at,
  -- Approved shipping identity for THIS shipment only -- never a browsable
  -- customer database. destination_snapshot is populated by the upstream
  -- order-approval flow (not by Dispatch); expected keys documented on the
  -- column comment below.
  nullif(btrim(c.destination_snapshot ->> 'consignee_name'), '') AS consignee_name,
  nullif(btrim(c.destination_snapshot ->> 'address_line1'), '') AS ship_to_address_line1,
  nullif(btrim(c.destination_snapshot ->> 'address_line2'), '') AS ship_to_address_line2,
  nullif(btrim(c.destination_snapshot ->> 'city'), '') AS destination_city,
  nullif(btrim(c.destination_snapshot ->> 'state'), '') AS destination_state,
  nullif(btrim(c.destination_snapshot ->> 'pincode'), '') AS destination_pincode,
  nullif(btrim(c.destination_snapshot ->> 'delivery_contact_name'), '') AS delivery_contact_name,
  nullif(btrim(c.destination_snapshot ->> 'delivery_contact_phone'), '') AS delivery_contact_phone,
  nullif(btrim(c.handling_instructions ->> 'delivery_instructions'), '') AS delivery_instructions,
  coalesce(carton.carton_count, 0::bigint) AS carton_count,
  coalesce(line.selected_qty, 0::numeric) AS selected_qty,
  coalesce(line.packed_qty, 0::numeric) AS packed_qty,
  coalesce(line.dispatched_qty, 0::numeric) AS dispatched_qty,
  shipment.transporter_name,
  shipment.vehicle_number,
  shipment.tracking_lr_awb,
  shipment.delivery_state,
  release.pi_reference AS invoice_pi_reference,
  release.invoice_reference,
  o.eway_bill_number,
  o.eway_bill_url,
  -- Finance status collapsed to exactly CLEARED / HOLD -- never the raw
  -- release_state, sales_order_value, payment_status or advance figures.
  CASE
    WHEN release.release_state IN (
      'commercially_clear', 'approved_credit_dispatch', 'cod_collection_instruction', 'exception_approved'
    ) THEN 'CLEARED'
    ELSE 'HOLD'
  END AS finance_status,
  coalesce(exception.open_exception_count, 0::bigint) AS open_exception_count
FROM public.b2b_dispatch_consignments c
JOIN public.orders o ON o.id = c.order_id
LEFT JOIN LATERAL (
  SELECT count(*) AS carton_count
  FROM public.b2b_dispatch_cartons bc
  WHERE bc.consignment_id = c.id
) carton ON true
LEFT JOIN LATERAL (
  SELECT
    sum(cl.selected_qty) AS selected_qty,
    sum(cl.packed_qty) AS packed_qty,
    sum(cl.dispatched_qty) AS dispatched_qty
  FROM public.b2b_dispatch_consignment_lines cl
  WHERE cl.consignment_id = c.id
) line ON true
LEFT JOIN LATERAL (
  SELECT r.release_state, r.pi_reference, r.invoice_reference
  FROM public.b2b_dispatch_releases r
  WHERE r.consignment_id = c.id
  ORDER BY r.created_at DESC
  LIMIT 1
) release ON true
LEFT JOIN public.b2b_dispatch_shipments shipment ON shipment.consignment_id = c.id
LEFT JOIN LATERAL (
  SELECT count(*) AS open_exception_count
  FROM public.b2b_dispatch_exceptions be
  WHERE be.consignment_id = c.id
    AND be.status NOT IN ('resolved', 'voided')
) exception ON true;

COMMENT ON VIEW public.b2b_dispatch_shipment_execution_view IS
  'Single, flat-capability Dispatch read surface (DISPATCH_INCHARGE/MANAGER/HEAD all get identical access via can_manage_b2b_dispatch RLS on the underlying tables). Never joins companies or crm_tasks -- structurally cannot expose salesperson, CRM history, margins/discounts, or credit/outstanding data. Finance status is always collapsed to CLEARED/HOLD.';

-- =================================================================================
-- 2. Favouritism protection: committed_cutoff (system dispatch priority) and
--    destination_snapshot (approved shipping identity) can only be changed
--    from inside a governed RPC, never by a direct client UPDATE, even
--    though the existing "Dispatch operators maintain consignments" RLS
--    policy otherwise permits any can_manage_b2b_dispatch() role to UPDATE
--    the row. A local (transaction-scoped) session setting, set only by the
--    RPCs below immediately before their UPDATE, is the governed-context
--    marker this trigger checks for.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.guard_b2b_dispatch_consignment_governed_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.committed_cutoff IS DISTINCT FROM OLD.committed_cutoff
     AND coalesce(current_setting('app.dispatch_governed_context', true), '') <> 'priority_override' THEN
    RAISE EXCEPTION 'committed_cutoff can only be changed via override_dispatch_priority()' USING ERRCODE = '42501';
  END IF;
  IF NEW.destination_snapshot IS DISTINCT FROM OLD.destination_snapshot THEN
    RAISE EXCEPTION 'destination_snapshot is approved shipping identity and cannot be edited directly -- raise a correction via raise_dispatch_shipping_data_exception()' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_b2b_dispatch_consignment_governed_fields
  BEFORE UPDATE ON public.b2b_dispatch_consignments
  FOR EACH ROW EXECUTE FUNCTION public.guard_b2b_dispatch_consignment_governed_fields();

-- =================================================================================
-- 3. Priority override: system-derived by default (committed_cutoff set at
--    consignment creation); any change requires a governed reason and
--    leaves an immutable audit trail. Ordinary Dispatch action (packing,
--    loading, scanning) never touches this RPC.
-- =================================================================================
CREATE TABLE IF NOT EXISTS public.b2b_dispatch_priority_overrides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_id uuid NOT NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  previous_committed_cutoff timestamptz NULL,
  new_committed_cutoff timestamptz NOT NULL,
  reason text NOT NULL,
  actor_id uuid NOT NULL,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.b2b_dispatch_priority_overrides ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Dispatch-authorised staff read dispatch priority overrides"
  ON public.b2b_dispatch_priority_overrides FOR SELECT TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()));

CREATE OR REPLACE FUNCTION public.prevent_b2b_dispatch_priority_override_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'b2b_dispatch_priority_overrides is append-only' USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE TRIGGER trg_b2b_dispatch_priority_overrides_no_update
  BEFORE UPDATE ON public.b2b_dispatch_priority_overrides
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_priority_override_mutation();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_priority_overrides_no_delete
  BEFORE DELETE ON public.b2b_dispatch_priority_overrides
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_priority_override_mutation();

REVOKE ALL ON TABLE public.b2b_dispatch_priority_overrides FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.b2b_dispatch_priority_overrides TO authenticated;

CREATE OR REPLACE FUNCTION public.override_dispatch_priority(
  p_consignment_id uuid,
  p_new_committed_cutoff timestamptz,
  p_reason text,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_consignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_existing public.b2b_dispatch_priority_overrides%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to override dispatch priority' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'A reason is required to override dispatch priority';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_new_committed_cutoff IS NULL THEN
    RAISE EXCEPTION 'A new committed cutoff is required';
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_priority_overrides WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    IF v_existing.consignment_id <> p_consignment_id THEN
      RAISE EXCEPTION 'correlation_id % is already in use by a different consignment', p_correlation_id;
    END IF;
    SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id;
    RETURN v_consignment;
  END IF;

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Consignment not found'; END IF;

  INSERT INTO public.b2b_dispatch_priority_overrides (
    consignment_id, previous_committed_cutoff, new_committed_cutoff, reason, actor_id, correlation_id
  ) VALUES (
    p_consignment_id, v_consignment.committed_cutoff, p_new_committed_cutoff, btrim(p_reason), v_actor_id, p_correlation_id
  );

  PERFORM pg_catalog.set_config('app.dispatch_governed_context', 'priority_override', true);
  UPDATE public.b2b_dispatch_consignments
  SET committed_cutoff = p_new_committed_cutoff, updated_at = now()
  WHERE id = p_consignment_id
  RETURNING * INTO v_consignment;
  PERFORM pg_catalog.set_config('app.dispatch_governed_context', '', true);

  RETURN v_consignment;
END;
$$;

COMMENT ON FUNCTION public.override_dispatch_priority(uuid, timestamptz, text, text) IS
  'Only governed path to change a consignment''s dispatch priority (committed_cutoff). Requires a non-blank reason; leaves an immutable audit row in b2b_dispatch_priority_overrides (old value, new value, actor, timestamp). Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.override_dispatch_priority(uuid, timestamptz, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.override_dispatch_priority(uuid, timestamptz, text, text) TO authenticated;

-- =================================================================================
-- 4. Shipping-data correction: Dispatch raises an exception, it never edits
--    the approved shipping identity itself. Reuses the existing
--    b2b_dispatch_exceptions table -- no new ledger.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.raise_dispatch_shipping_data_exception(
  p_consignment_id uuid,
  p_description text,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_exceptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_existing public.b2b_dispatch_exceptions%ROWTYPE;
  v_exception public.b2b_dispatch_exceptions%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to raise a dispatch exception' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_description), '') IS NULL THEN
    RAISE EXCEPTION 'A description is required';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_exceptions WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    IF v_existing.consignment_id <> p_consignment_id THEN
      RAISE EXCEPTION 'correlation_id % is already in use by a different consignment', p_correlation_id;
    END IF;
    RETURN v_existing;
  END IF;

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Consignment not found'; END IF;

  -- b2b_dispatch_exceptions has no dedicated "raised_by" column; owner_id
  -- is the closest fit and starts as the raiser, reassignable by whoever
  -- picks up resolution.
  INSERT INTO public.b2b_dispatch_exceptions (
    order_id, consignment_id, exception_type, source_department, severity,
    owner_id, evidence_ref, correlation_id
  ) VALUES (
    v_consignment.order_id, p_consignment_id, 'shipping_data_correction_required', 'DISPATCH', 'S3',
    v_actor_id, btrim(p_description), p_correlation_id
  )
  RETURNING * INTO v_exception;

  RETURN v_exception;
END;
$$;

COMMENT ON FUNCTION public.raise_dispatch_shipping_data_exception(uuid, text, text) IS
  'Dispatch''s only path to flag incorrect approved shipping data -- raises an exception for the authorised upstream owner to correct, never edits destination_snapshot directly (blocked by trg_b2b_dispatch_consignment_governed_fields regardless).';

REVOKE ALL ON FUNCTION public.raise_dispatch_shipping_data_exception(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.raise_dispatch_shipping_data_exception(uuid, text, text) TO authenticated;
