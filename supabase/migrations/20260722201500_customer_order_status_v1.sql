-- Customer-safe order status contract.
-- Returns only orders belonging to the authenticated user's approved company.

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
set search_path = pg_catalog, public
as $$
  with eligible_company as (
    select p.company_id
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
    limit 1
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
    greatest(
      o.created_at,
      coalesce(o.closed_at, o.created_at),
      coalesce(o.finance_verified_at, o.created_at)
    ) as updated_at
  from public.orders o
  join eligible_company ec on ec.company_id = o.company_id
  where coalesce(o.is_waste, false) is false
    and coalesce(o.is_duplicate, false) is false
  order by o.created_at desc, o.id;
$$;

comment on function public.customer_order_status_v1() is
  'Customer-safe order status projection for the authenticated user company. Excludes internal notes, staff identities, raw workflow metadata, payment proofs and logistics-sensitive fields.';

revoke all on function public.customer_order_status_v1() from public;
revoke all on function public.customer_order_status_v1() from anon;
grant execute on function public.customer_order_status_v1() to authenticated, service_role;
