-- AUTH-01 Buyer authority hardening, tranche 1.
--
-- Replace three legacy inline profile/company eligibility CTEs with the
-- canonical customer_buyer_eligible_company_id() authority. The legacy
-- inline predicates checked approval/company-active/frozen state but did
-- not enforce Buyer role or exclude internal staff.
--
-- No signatures, grants, return shapes, ordering, or customer payloads change.

create or replace function public.customer_order_items_v1()
returns table(
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
set search_path to 'pg_catalog', 'public', 'auth'
as $function$
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
$function$;

create or replace function public.customer_order_status_v1()
returns table(
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
set search_path to 'pg_catalog', 'public'
as $function$
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
$function$;

create or replace function public.customer_support_tickets_v1()
returns table(
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
set search_path to 'pg_catalog', 'public', 'auth'
as $function$
  with eligible_companies as (
    -- Canonical native Buyer authority: approved Buyer role, non-staff,
    -- active/not-frozen company. This replaces the legacy profiles branch.
    select public.customer_buyer_eligible_company_id() as company_id
    where public.customer_buyer_eligible_company_id() is not null

    union

    -- Preserve the pre-existing legacy customer-user compatibility branch.
    select u.company_id
    from public.users u
    join public.companies c on c.id = u.company_id
    where u.id = auth.uid()
      and lower(coalesce(u.role, '')) in ('customer_user', 'customer_admin', 'buyer', 'b2b_customer')
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
$function$;

comment on function public.customer_order_items_v1() is
  'Customer-safe order-line projection for the canonical eligible Buyer company. Packed quantity is withheld until the order is packed-ready, cleared for dispatch, or dispatched.';
comment on function public.customer_order_status_v1() is
  'Customer-safe order status projection for the canonical eligible Buyer company. Excludes internal notes, staff identities, raw workflow metadata, payment proofs and logistics-sensitive fields.';
comment on function public.customer_support_tickets_v1() is
  'Customer-safe support ticket projection scoped to the canonical eligible Buyer company, with legacy customer-user compatibility preserved.';
