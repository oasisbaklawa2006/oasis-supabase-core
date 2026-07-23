-- Extend buyer_product_prices_v1 with customer-safe MOQ and order increment rules.
-- Preference: latest B2B product_moq_rules row; fallback: legacy product fields.

drop function if exists public.buyer_product_prices_v1();

create function public.buyer_product_prices_v1()
returns table (
  product_id uuid,
  selling_price numeric,
  currency text,
  uom text,
  gst_rate numeric,
  tax_inclusive boolean,
  applied_discount_percent numeric,
  minimum_order_quantity numeric,
  minimum_order_uom text,
  order_increment numeric,
  order_increment_uom text,
  valid_from date,
  valid_until date
)
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  with buyer as (
    select p.company_id,
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
    select r.product_id,
      coalesce(r.calculated_price, r.base_price)::numeric as listed_price,
      r.currency, r.uom, r.gst_rate,
      coalesce(r.tax_inclusive, false) as tax_inclusive,
      r.valid_from, r.valid_until,
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
  ), b2b_moq as (
    select m.product_id,
      case when coalesce(m.moq_applicable, true) then m.moq_value::numeric end as moq_value,
      case when coalesce(m.moq_applicable, true) then nullif(btrim(m.moq_uom), '') end as moq_uom,
      case when coalesce(m.moq_applicable, true) then m.increment_value::numeric end as increment_value,
      case when coalesce(m.moq_applicable, true) then nullif(btrim(m.increment_uom), '') end as increment_uom,
      row_number() over (
        partition by m.product_id
        order by m.updated_at desc nulls last, m.created_at desc nulls last, m.id desc
      ) as rn
    from public.product_moq_rules m
    where lower(coalesce(m.channel, '')) = 'b2b'
  )
  select rp.product_id,
    round(rp.listed_price * (1 - b.discount_percent / 100), 2),
    coalesce(nullif(btrim(rp.currency), ''), 'INR'),
    rp.uom, rp.gst_rate, rp.tax_inclusive, b.discount_percent,
    coalesce(bm.moq_value, p.moq_value::numeric, p.moq_packs::numeric, p.moq::numeric),
    coalesce(bm.moq_uom, nullif(btrim(p.moq_uom), ''),
      case when p.moq_packs is not null then 'pack' end,
      nullif(btrim(p.b2b_uom), ''), nullif(btrim(rp.uom), '')),
    coalesce(bm.increment_value, p.increment_value::numeric, 1::numeric),
    coalesce(bm.increment_uom, nullif(btrim(p.increment_uom), ''),
      nullif(btrim(p.moq_uom), ''), nullif(btrim(p.b2b_uom), ''), nullif(btrim(rp.uom), '')),
    rp.valid_from, rp.valid_until
  from ranked_prices rp
  cross join buyer b
  join public.products p on p.id = rp.product_id
  left join b2b_moq bm on bm.product_id = rp.product_id and bm.rn = 1
  where rp.rn = 1
  order by rp.product_id;
$$;

revoke all on function public.buyer_product_prices_v1() from public;
revoke all on function public.buyer_product_prices_v1() from anon;
grant execute on function public.buyer_product_prices_v1() to authenticated, service_role;
