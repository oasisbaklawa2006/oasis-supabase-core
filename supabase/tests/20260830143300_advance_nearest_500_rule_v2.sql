-- Contract for migration 20260830143300_advance_nearest_500_rule_v2.sql.

begin;

select plan(13);

select is(public.calculate_sales_order_advance_v1(10000), 3000::numeric, '30 percent exact increment');
select is(public.calculate_sales_order_advance_v1(11000), 3500::numeric, '3300 rounds to nearest 3500');
select is(public.calculate_sales_order_advance_v1(9000), 2500::numeric, '2700 rounds to nearest 2500');
select is(public.calculate_sales_order_advance_v1(501), 500::numeric, 'positive governed SO has minimum INR 500 advance');
select is(public.calculate_sales_order_advance_v1(0), 0::numeric, 'zero value requires no advance');
select is(public.calculate_sales_order_advance_v1(12345.67), 3500::numeric, '12345.67 freezes INR 3500 under v2');
select ok(pg_get_functiondef('public.calculate_sales_order_advance_v1(numeric)'::regprocedure) like '%round((p_sales_order_value * 0.30) / 500) * 500%','canonical calculator uses nearest-500 rounding');
select ok(pg_get_functiondef('public.calculate_sales_order_advance_v1(numeric)'::regprocedure) like '%greatest(500%','canonical calculator enforces positive-SO minimum');
select ok(pg_get_functiondef('public.calculate_sales_order_advance_v1(numeric)'::regprocedure) not like '%ceil(%','upward-only rounding removed for future calculations');
select ok(pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure) like '%advance-30pct-nearest-inr-500/v2%','new snapshots identify rule v2');
select ok(pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure) like '%wa-draft:%','snapshot builder preserves canonical WhatsApp draft lineage');
select ok(pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure) like '%WHATSAPP_SOURCE_REFERENCE_REQUIRED%','snapshot builder remains fail-closed when WhatsApp lineage is missing');

do $$
declare
  v_company uuid;
  v_product uuid;
  v_order uuid;
begin
  insert into public.companies (business_name, status)
  values ('PF4 V2 Stale Advance Contract Co', 'active')
  returning id into v_company;

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price, price_b2b
  ) values (
    'PF4-V2-STALE', 'PF4 V2 Stale Product', 'PF4 V2 Stale Product', 'Bakery', '19059090',
    true, true, true, 1, 1, 12345.67, 12345.67
  ) returning id into v_product;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price,
    currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product, 'b2b', 'approved', 12345.67, 12345.67,
    'INR', 'kg', 0, false
  );

  insert into public.product_moq_rules (
    product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty
  ) values (v_product, 'b2b', true, 1, 1, 1);

  insert into public.orders (
    company_id, status, order_origin, order_number, tracking_token,
    sales_order_value, advance_required
  ) values (
    v_company, 'submitted', 'MANUAL', 'SO-PF4-V2-STALE', md5(random()::text),
    12345.67, 4000
  ) returning id into v_order;

  insert into public.order_items (order_id, product_id, quantity, pack_size, carton_type)
  values (v_order, v_product, 1, 'kg', 'carton');

  begin
    perform public.build_sales_order_commercial_snapshot_v1(v_order);
    raise exception 'STALE ADVANCE SNAPSHOT REGRESSION';
  exception when sqlstate 'P0001' then
    if sqlerrm not like 'GOVERNED_ADVANCE_STALE:%' then
      raise;
    end if;
  end;
end $$;

select pass('snapshot creation rejects a valid governed order whose stored advance is stale');

select * from finish();
rollback;
