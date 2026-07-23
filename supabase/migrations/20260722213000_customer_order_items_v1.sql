-- Customer-safe order line contract.
-- Returns only order items belonging to the authenticated user's approved company.

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
set search_path = pg_catalog, public, auth
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
    oi.order_id,
    oi.id as item_id,
    oi.product_id,
    nullif(btrim(p.sku), '') as sku,
    coalesce(nullif(btrim(p.product_name), ''), nullif(btrim(p.name), ''), 'Product') as product_name,
    oi.quantity::numeric,
    nullif(btrim(oi.pack_size), '') as pack_size,
    oi.weight_kg::numeric,
    case
      when o.status in ('assembled', 'packing', 'packed_ready', 'cleared_for_dispatch', 'dispatched')
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
  'Customer-safe order-line projection for the authenticated user company. Excludes internal notes, departments, task types, raw production status, costing, and operational metadata.';

revoke all on function public.customer_order_items_v1() from public;
revoke all on function public.customer_order_items_v1() from anon;
grant execute on function public.customer_order_items_v1() to authenticated, service_role;
