-- AUTH-01 RPC security certification: fix a staff-exclusion gap found while
-- body-verifying the native Buyer App's RPC allowlist against current-main.
--
-- customer_order_status_v1(), customer_order_items_v1() and
-- customer_support_tickets_v1() (defined 20260723161256, grants hardened
-- 20260730170000, never redefined since) each duplicate an inline
-- "eligible company" gate instead of calling the canonical
-- public.customer_buyer_eligible_company_id() helper introduced later
-- (20260807170000). That helper's own file header says its authority chain
-- "matches buyer_product_prices_v1 / customer_order_status_v1 family" --
-- it was clearly intended to formalize this exact pattern, but these three
-- functions were never backported to call it, so they drifted from the
-- hardening applied everywhere else.
--
-- The drift: the inline CTE in these three functions checks
--   p.is_approved is true and p.status = 'approved'
-- and company active/not-frozen, but has NO role filter and NO staff
-- exclusion (no `role in ('b2b_buyer','buyer')`, no `not is_staff_role(...)`,
-- no `not is_internal_staff(...)`). The canonical helper added all three of
-- those checks specifically. If any internal staff profile ever carries
-- is_approved = true, status = 'approved', and a non-null company_id (for
-- any legitimate internal reason unrelated to buyer status), these three
-- functions would disclose that company's order status, order line items,
-- and support tickets to that staff member through the customer-facing
-- surface -- exactly the "staff excluded from customer surface" property
-- customer_buyer_eligible_company_id() exists to guarantee everywhere else.
--
-- Fix: replace the duplicated inline CTE with a call to the canonical
-- helper in all three functions. This is a narrowing-only change (the new
-- helper's predicate is a strict subset of rows the old inline predicate
-- allowed: same approved/active/not-frozen checks, PLUS role and staff
-- checks) -- it cannot make any previously-denied access newly allowed, so
-- it carries no risk of breaking a legitimate approved buyer's access.
--
-- customer_support_tickets_v1() additionally has a second `union` branch
-- over the legacy public.users table, gated by
-- role in ('customer_user','customer_admin','buyer','b2b_customer') --
-- that branch's own role whitelist already excludes staff roles by
-- construction and is left unchanged.

create or replace function public.customer_order_status_v1()
returns table (
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
language sql
stable
security definer
set search_path to pg_catalog, public
as $$
  with eligible_company as (
    select public.customer_buyer_eligible_company_id() as company_id
  )
  select
    o.id as order_id,
    o.order_number,
    case
      when o.status in ('draft', 'submitted') then 'order_received'
      when o.status in ('awaiting_advance', 'awaiting_payment') then 'payment_pending'
      when o.status in ('manufacturing', 'in_production') then 'in_production'
      when o.status in ('assembled', 'packing') then 'packing'
      when o.status in ('packed_ready', 'cleared_for_dispatch') then 'ready_for_dispatch'
      when o.status = 'dispatched' then 'dispatched'
      else 'processing'
    end as customer_stage,
    case
      when o.payment_status in ('paid', 'advance_paid', 'verified_advance') then 'paid_or_verified'
      when o.payment_status in ('on_credit', 'short_term_credit') then 'credit_approved'
      when o.payment_status in ('under_review', 'awaiting_verification') then 'under_review'
      else 'payment_pending'
    end as payment_stage,
    o.sales_order_value as order_value,
    o.total_weight_kg,
    o.requested_dispatch_date,
    coalesce(o.admin_promised_date, o.system_estimated_date, o.estimated_despatch_date) as promised_dispatch_date,
    case when o.status = 'dispatched' then nullif(btrim(o.tracking_number), '') end as tracking_number,
    case when o.status = 'dispatched' then nullif(btrim(o.courier_name), '') end as courier_name,
    o.created_at,
    greatest(o.created_at, coalesce(o.closed_at, o.created_at), coalesce(o.finance_verified_at, o.created_at)) as updated_at
  from public.orders o
  join eligible_company ec on ec.company_id = o.company_id
  where coalesce(o.is_waste, false) is false
    and coalesce(o.is_duplicate, false) is false
  order by o.created_at desc, o.id;
$$;

comment on function public.customer_order_status_v1() is
  'Customer-safe order status projection for an approved buyer company. Company resolved exclusively via customer_buyer_eligible_company_id() (role-checked, staff-excluded) -- fixed AUTH-01 to close a staff-exclusion drift; previously used an inline gate with no role/staff filter.';

create or replace function public.customer_order_items_v1()
returns table (
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
language sql
stable
security definer
set search_path to pg_catalog, public, auth
as $$
  with eligible_company as (
    select public.customer_buyer_eligible_company_id() as company_id
  )
  select
    oi.order_id,
    oi.id as item_id,
    oi.product_id,
    nullif(btrim(p.sku), '') as sku,
    coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), ''), 'Product') as product_name,
    oi.quantity::numeric,
    nullif(btrim(oi.pack_size), '') as pack_size,
    oi.weight_kg::numeric,
    case
      when o.status in ('packed_ready', 'cleared_for_dispatch', 'dispatched')
        then oi.actual_packed_qty::numeric
      else null
    end as packed_quantity
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join eligible_company ec on ec.company_id = o.company_id
  left join public.products p on p.id = oi.product_id
  where coalesce(o.is_waste, false) is false
    and coalesce(o.is_duplicate, false) is false
  order by o.created_at desc, oi.order_id, oi.id;
$$;

comment on function public.customer_order_items_v1() is
  'Customer-safe order-line projection for an approved buyer company. Packed quantity withheld until packed-ready/cleared/dispatched. Company resolved exclusively via customer_buyer_eligible_company_id() -- fixed AUTH-01 to close a staff-exclusion drift.';

create or replace function public.customer_support_tickets_v1()
returns table (
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
language sql
stable
security definer
set search_path to pg_catalog, public, auth
as $_$
  with eligible_companies as (
    select public.customer_buyer_eligible_company_id() as company_id

    union

    -- Legacy public.users branch: its own role whitelist already excludes
    -- staff roles by construction (only customer-facing roles listed),
    -- so no staff-exclusion drift exists here -- left unchanged.
    select u.company_id
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = auth.uid()
      and u.role in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
      and coalesce(u.is_active, true) is true
      and u.deleted_at is null
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
  )
  select
    st.id as ticket_id,
    st.order_id,
    o.order_number,
    st.issue_type,
    st.description,
    case
      when lower(coalesce(st.status, '')) in ('resolved', 'closed') then 'resolved'
      when lower(coalesce(st.status, '')) in ('rejected', 'cancelled') then 'closed'
      when st.sla_first_response_at is not null then 'in_progress'
      else 'open'
    end as customer_status,
    st.product_sku,
    st.qty_affected as quantity_affected,
    st.created_at,
    st.updated_at,
    st.sla_first_response_due as first_response_due,
    st.sla_resolution_due as resolution_due,
    st.sla_resolved_at as resolved_at,
    st.customer_rating
  from public.support_tickets st
  join eligible_companies ec on ec.company_id = st.company_id
  left join public.orders o
    on st.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
   and o.id = st.order_id::uuid
  order by st.created_at desc, st.id;
$_$;

comment on function public.customer_support_tickets_v1() is
  'Customer-safe support ticket projection scoped to the authenticated approved company. profiles branch resolved exclusively via customer_buyer_eligible_company_id() -- fixed AUTH-01 to close a staff-exclusion drift; legacy users branch already role-whitelisted and left unchanged.';

-- Grants are unchanged (already correctly anon-revoked, authenticated-only
-- per 20260730170000); CREATE OR REPLACE on an identical signature does not
-- reset existing GRANT/REVOKE state, but re-asserted here for certainty.
revoke all on function public.customer_order_status_v1() from public, anon;
grant execute on function public.customer_order_status_v1() to authenticated, service_role;

revoke all on function public.customer_order_items_v1() from public, anon;
grant execute on function public.customer_order_items_v1() to authenticated, service_role;

revoke all on function public.customer_support_tickets_v1() from public, anon;
grant execute on function public.customer_support_tickets_v1() to authenticated, service_role;
