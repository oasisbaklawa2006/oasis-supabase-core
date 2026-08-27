-- Contract test for 20260807172000_customer_checkout_submit_v1.sql
begin;

select plan(13);

select has_function('public', 'calculate_customer_advance_v1', array['numeric'], 'calculate_customer_advance_v1 exists');
select has_function('public', 'submit_customer_order_v1', array['text', 'date'], 'submit_customer_order_v1 exists');

select has_column('public', 'orders', 'order_origin', 'orders.order_origin column exists');
select has_column('public', 'orders', 'checkout_idempotency_key', 'orders.checkout_idempotency_key column exists');

select is(
  public.calculate_customer_advance_v1(5850::numeric),
  2000::numeric,
  'advance for SO 5850 is 2000 (30%=1755 rounded up to ₹500)'
);

select is(
  public.calculate_customer_advance_v1(10000::numeric),
  3000::numeric,
  'advance for SO 10000 is 3000'
);

select is(
  public.calculate_customer_advance_v1(12345.67::numeric),
  4000::numeric,
  'advance for SO 12345.67 is 4000 (fractional rupees)'
);

select is(
  public.calculate_customer_advance_v1(501::numeric),
  500::numeric,
  'advance for SO 501 is 500 (₹1 above ₹500 increment boundary)'
);

select ok(
  pg_get_functiondef('public.recalculate_erp_order_financials()'::regprocedure) like '%recalculate_governed_sales_order_financials_v1%',
  'recalculate_erp_order_financials routes non-legacy sources through the canonical SO engine'
);

select ok(
  pg_get_functiondef('public.recalculate_erp_order_financials()'::regprocedure) like '%tg_op = ''DELETE''%',
  'recalculate_erp_order_financials handles DELETE via OLD.order_id'
);

-- Live: CUSTOMER_APP checkout + idempotency + legacy trigger INSERT/DELETE
do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_product uuid;
  v_legacy_product uuid;
  v_order_id uuid;
  v_order_number text;
  v_so_value numeric;
  v_advance numeric;
  v_draft_id uuid;
  v_dup boolean;
  v_legacy_order_id uuid;
  v_legacy_advance numeric;
  v_legacy_so numeric;
  v_legacy_item_id uuid;
  v_initial_so numeric;
  v_initial_advance numeric;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Checkout Spine Co', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'checkout-spine@example.com');
  insert into public.users (id, email, role, company_id)
  values (v_buyer, 'checkout-spine@example.com', 'b2b_buyer', v_company);
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'checkout-spine@example.com');

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price, price_b2b
  ) values (
    'CHK-SKU-1', 'Checkout Product', 'Checkout Product', 'Bakery', '19059090',
    true, true, true,
    9, 9, 650, 650
  ) returning id into v_product;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product, 'b2b', 'approved', 650, 650, 'INR', 'kg', 0, true
  );

  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 9, 9, 9);

  insert into public.products (sku, product_name, name, category, hsn_code, base_price, price_b2b)
  values ('LEG-SKU-1', 'Legacy Product', 'Legacy Product', 'Bakery', '19059090', 1000, 1000)
  returning id into v_legacy_product;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.add_customer_order_draft_line_v1(v_product, 9);

  select order_id, order_number, sales_order_value, advance_required, draft_id, is_duplicate_submission
  into v_order_id, v_order_number, v_so_value, v_advance, v_draft_id, v_dup
  from public.submit_customer_order_v1('checkout-key-001');

  if v_order_id is null or v_dup then
    raise exception 'REGRESSION: first checkout did not create an order';
  end if;

  if (select order_origin from public.orders where id = v_order_id) <> 'CUSTOMER_APP' then
    raise exception 'REGRESSION: submitted order is not CUSTOMER_APP origin';
  end if;

  if v_advance <> public.calculate_customer_advance_v1(v_so_value) then
    raise exception 'REGRESSION: CUSTOMER_APP advance mismatch (so=%, advance=%)', v_so_value, v_advance;
  end if;

  select is_duplicate_submission into v_dup
  from public.submit_customer_order_v1('checkout-key-001');
  if not v_dup then
    raise exception 'IDEMPOTENCY REGRESSION: retry did not report duplicate submission';
  end if;

  if (select count(*) from public.orders where company_id = v_company and checkout_idempotency_key = 'checkout-key-001') <> 1 then
    raise exception 'IDEMPOTENCY REGRESSION: duplicate checkout created multiple orders';
  end if;

  if (select status from public.customer_order_drafts where id = v_draft_id) <> 'promoted' then
    raise exception 'REGRESSION: draft was not marked promoted after checkout';
  end if;

  reset role;

  if (select count(*) from public.sales_order_commercial_versions where order_id = v_order_id and source_channel = 'CUSTOMER_APP') <> 1 then
    raise exception 'REGRESSION: CUSTOMER_APP checkout did not create exactly one canonical commercial version';
  end if;

  -- PF-4 regression: a snapshot-backed SO rejects direct commercial-line mutation.
  select sales_order_value, advance_required into v_initial_so, v_initial_advance
  from public.orders where id = v_order_id;

  if v_initial_so is null or v_initial_advance is null then
    raise exception 'REGRESSION: CUSTOMER_APP order missing financials before trigger INSERT test';
  end if;

  begin
    insert into public.order_items (order_id, product_id, quantity)
    values (v_order_id, v_product, 9);
    raise exception 'REGRESSION: snapshot-backed CUSTOMER_APP line mutation was accepted';
  exception when sqlstate '42501' then
    null;
  end;

  -- Trigger regression (superuser): LEGACY_ERP 50% advance on INSERT/DELETE
  insert into public.orders (company_id, status, order_origin, order_number, tracking_token)
  values (v_company, 'submitted', 'LEGACY_ERP', 'SO-TEST-LEGACY-000001', md5(random()::text))
  returning id into v_legacy_order_id;

  insert into public.order_items (order_id, product_id, quantity)
  values (v_legacy_order_id, v_legacy_product, 10)
  returning id into v_legacy_item_id;

  select sales_order_value, advance_required into v_legacy_so, v_legacy_advance
  from public.orders where id = v_legacy_order_id;

  if v_legacy_so is null or v_legacy_advance is null then
    raise exception 'LEGACY REGRESSION: trigger did not populate financials on INSERT';
  end if;

  if v_legacy_advance is distinct from v_legacy_so * 0.5 then
    raise exception 'LEGACY REGRESSION: ERP order advance is not 50%% (so=%, advance=%)', v_legacy_so, v_legacy_advance;
  end if;

  delete from public.order_items where id = v_legacy_item_id;

  select sales_order_value, advance_required into v_legacy_so, v_legacy_advance
  from public.orders where id = v_legacy_order_id;

  if v_legacy_so is distinct from 0 or v_legacy_advance is distinct from 0 then
    raise exception 'LEGACY REGRESSION: expected zero financials after DELETE of all items (so=%, advance=%)', v_legacy_so, v_legacy_advance;
  end if;

  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('CUSTOMER_APP checkout idempotent with 30% round-up advance; LEGACY_ERP retains 50% on INSERT/DELETE');

select ok(
  not has_function_privilege('anon', 'public.submit_customer_order_v1(text, date)', 'EXECUTE'),
  'anon cannot execute submit_customer_order_v1'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'orders'
      and indexname = 'uq_orders_customer_app_checkout_idempotency'
  ),
  'checkout idempotency unique index exists on orders'
);

select * from finish();
rollback;
