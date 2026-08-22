-- Owner decision (Dispatch customer-visibility model): Dispatch must be
-- split into two governed authority tiers, not the single undifferentiated
-- "any dispatch role" bucket can_manage_b2b_dispatch() currently provides:
--
--   DISPATCH_OPERATOR tier: execution-only. May see dispatch/order
--   references, product/SKU, quantities, cartons, destination city/zone,
--   transporter/logistics state, priority/SLA, finance status collapsed to
--   CLEARED/HOLD, operational blockers, loading/dispatch state. Must NOT see
--   salesperson, CRM history, pricing/discounts/margins, credit details, or
--   unrestricted customer phone/address.
--
--   DISPATCH_MANAGER / label-authority tier: additionally may see, only for
--   the specific shipment being executed: consignee/company name, approved
--   shipping address, approved delivery contact, delivery instructions,
--   transporter/vehicle information, invoice/e-way bill references, and
--   carton/label data. Still not salesperson/CRM/pricing/credit-beyond-
--   cleared-or-hold. This is shipment-scoped visibility, not general
--   customer-database access.
--
-- No role literally named DISPATCH_OPERATOR exists yet in is_staff_role's
-- role set (verified by exhaustive grep across every migration). Owner-
-- confirmed mapping of the existing three dispatch roles onto these tiers:
-- DISPATCH_INCHARGE -> operator tier; DISPATCH_MANAGER and DISPATCH_HEAD ->
-- manager/label-authority tier (matches this codebase's existing naming
-- convention elsewhere, e.g. STORE_INCHARGE as front-line vs. MANAGER/HEAD
-- as elevated authority). is_dispatch_operator_role therefore also accepts
-- the manager-tier roles: a manager can do everything an operator can, plus
-- more, exactly as issue_rgs_stock/pick_rgs_reservation's is_internal_staff
-- gate already lets any elevated role perform base-tier operational actions.
--
-- These predicates are additive -- can_manage_b2b_dispatch() is NOT modified
-- or removed, since existing b2b_dispatch_* RLS policies already depend on
-- it and it has zero live RPC callers to migrate yet (the whole b2b_dispatch_*
-- schema has no governed mutation RPCs at all -- confirmed by exhaustive
-- grep). This migration only establishes the vocabulary; the shipment-scoped
-- read/label RPCs that consume it are a separate, subsequent PR.

CREATE OR REPLACE FUNCTION public.is_dispatch_manager_role(_role text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER',
    'DISPATCH_MANAGER', 'DISPATCH_HEAD'
  ]);
$$;

CREATE OR REPLACE FUNCTION public.is_dispatch_operator_role(_role text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER',
    'DISPATCH_MANAGER', 'DISPATCH_HEAD', 'DISPATCH_INCHARGE'
  ]);
$$;

COMMENT ON FUNCTION public.is_dispatch_manager_role(text) IS
  'Dispatch label/shipment-scoped-customer-visibility authority tier: DISPATCH_MANAGER, DISPATCH_HEAD, plus admin/ops override. May see consignee/address/delivery-contact/transporter for the specific shipment being executed. Never CRM, salesperson, pricing, or credit detail beyond CLEARED/HOLD.';
COMMENT ON FUNCTION public.is_dispatch_operator_role(text) IS
  'Dispatch execution-only authority tier: DISPATCH_INCHARGE plus every is_dispatch_manager_role role (a manager can do everything an operator can). No consignee/address/phone/salesperson/CRM/pricing visibility.';

REVOKE ALL ON FUNCTION public.is_dispatch_manager_role(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_dispatch_operator_role(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_dispatch_manager_role(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_dispatch_operator_role(text) TO authenticated;
