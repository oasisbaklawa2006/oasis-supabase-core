-- Final certification: CUSTOMER_APP order value must derive from the immutable
-- checkout snapshot captured by submit_customer_order_v1, never from mutable
-- current catalogue/pricing truth after checkout.
--
-- Backward compatibility: historical/synthetic CUSTOMER_APP rows created before
-- checkout_snapshot authority remain recalculable through the governed price
-- resolver only when no snapshot exists.
begin;

create or replace function public.recalculate_customer_app_order_financials(p_order_id uuid)
returns numeric
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_origin text;
  v_snapshot jsonb;
  v_total numeric := 0;
begin
  select o.order_origin, o.checkout_snapshot
    into v_origin, v_snapshot
  from public.orders o
  where o.id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_origin is distinct from 'CUSTOMER_APP' then
    raise exception 'ORDER_SOURCE_MISMATCH' using errcode = 'P0001';
  end if;

  if v_snapshot is not null then
    if jsonb_typeof(v_snapshot) <> 'array' or jsonb_array_length(v_snapshot) = 0 then
      raise exception 'CHECKOUT_SNAPSHOT_INVALID: authoritative checkout snapshot must be a non-empty array'
        using errcode = '22023';
    end if;

    if exists (
      select 1
      from jsonb_array_elements(v_snapshot) as x(line)
      where nullif(btrim(x.line->>'product_id'),'') is null
         or nullif(btrim(x.line->>'quantity'),'') is null
         or nullif(btrim(x.line->>'selling_price'),'') is null
         or nullif(btrim(x.line->>'gst_rate'),'') is null
         or nullif(btrim(x.line->>'tax_inclusive'),'') is null
    ) then
      raise exception 'CHECKOUT_SNAPSHOT_INVALID: required commercial line fields are missing'
        using errcode = '22023';
    end if;

    select round(coalesce(sum(
      (x.line->>'quantity')::numeric
      * (x.line->>'selling_price')::numeric
      * case
          when (x.line->>'tax_inclusive')::boolean then 1::numeric
          else 1::numeric + ((x.line->>'gst_rate')::numeric / 100::numeric)
        end
    ),0),2)
      into v_total
    from jsonb_array_elements(v_snapshot) as x(line);

    update public.orders
       set sales_order_value = v_total,
           advance_required = public.calculate_sales_order_advance_v1(v_total)
     where id = p_order_id;

    return v_total;
  end if;

  -- Compatibility for pre-snapshot synthetic/legacy CUSTOMER_APP rows only.
  return public.recalculate_governed_sales_order_financials_v1(p_order_id);
end;
$$;

revoke all on function public.recalculate_customer_app_order_financials(uuid)
  from public, anon, authenticated;
grant execute on function public.recalculate_customer_app_order_financials(uuid)
  to service_role;

comment on function public.recalculate_customer_app_order_financials(uuid) is
  'CUSTOMER_APP financial authority. Uses immutable orders.checkout_snapshot when present; only pre-snapshot compatibility rows fall back to current governed pricing.';

commit;
