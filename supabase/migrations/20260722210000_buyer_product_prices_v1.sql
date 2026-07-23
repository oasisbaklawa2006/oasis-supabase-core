-- Buyer-specific, read-only selling-price contract.
--
-- Security rules:
--   * authenticated buyer only
--   * profile must be approved and linked to a company
--   * company must be active/approved and not frozen
--   * product must exist in published_products_v1()
--   * only approved, current, positive B2B prices are eligible
--   * internal base-price, notes, approval actors, and cost metadata are hidden

create or replace function public.buyer_product_prices_v1()
returns table (
  product_id uuid,
  selling_price numeric,
  currency text,
  uom text,
  gst_rate numeric,
  tax_inclusive boolean,
  applied_discount_percent numeric,
  valid_from date,
  valid_until date
)
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  with buyer as (
    select
      p.company_id,
      greatest(least(coalesce(c.discount_percentage, 0), 100), 0)::numeric as discount_percent
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and p.is_approved is true
      and lower(coalesce(p.status, '')) = 'approved'
      and lower(coalesce(c.status, '')) in ('active', 'approved')
      and coalesce(c.is_frozen, false) is false
    limit 1
  ), ranked_prices as (
    select
      r.product_id,
      coalesce(r.calculated_price, r.base_price)::numeric as listed_price,
      r.currency,
      r.uom,
      r.gst_rate,
      coalesce(r.tax_inclusive, false) as tax_inclusive,
      r.valid_from,
      r.valid_until,
      row_number() over (
        partition by r.product_id
        order by r.valid_from desc nulls last,
                 r.approved_at desc nulls last,
                 r.updated_at desc nulls last,
                 r.id desc
      ) as rn
    from public.product_pricing_rules r
    join public.published_products_v1() pp on pp.product_id = r.product_id
    where lower(coalesce(r.price_channel, '')) = 'b2b'
      and lower(coalesce(r.approval_status, '')) = 'approved'
      and coalesce(r.calculated_price, r.base_price) > 0
      and (r.valid_from is null or r.valid_from <= current_date)
      and (r.valid_until is null or r.valid_until >= current_date)
  )
  select
    rp.product_id,
    round(rp.listed_price * (1 - b.discount_percent / 100), 2) as selling_price,
    coalesce(nullif(btrim(rp.currency), ''), 'INR') as currency,
    rp.uom,
    rp.gst_rate,
    rp.tax_inclusive,
    b.discount_percent as applied_discount_percent,
    rp.valid_from,
    rp.valid_until
  from ranked_prices rp
  cross join buyer b
  where rp.rn = 1
  order by rp.product_id;
$$;

comment on function public.buyer_product_prices_v1() is
  'Authenticated buyer price contract v1. Returns one current positive approved B2B selling price per published product for approved buyers linked to active, non-frozen companies.';

revoke all on function public.buyer_product_prices_v1() from public;
revoke all on function public.buyer_product_prices_v1() from anon;
grant execute on function public.buyer_product_prices_v1() to authenticated, service_role;
