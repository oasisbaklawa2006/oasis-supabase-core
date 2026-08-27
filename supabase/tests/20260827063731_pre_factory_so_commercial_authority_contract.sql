-- Contract coverage for migration 20260827063731_pre_factory_so_commercial_authority.
begin;

select plan(14);

select has_function('public', 'calculate_sales_order_advance_v1', array['numeric'], 'canonical SO advance calculator exists');
select has_function('public', 'build_sales_order_commercial_snapshot_v1', array['uuid'], 'commercial snapshot builder exists');
select has_function('public', 'create_sales_order_commercial_version_v1', array['uuid', 'text', 'text', 'text', 'uuid'], 'commercial version writer exists');
select has_function('public', 'amend_sales_order_commercial_v1', array['uuid', 'integer', 'jsonb', 'text', 'text', 'text'], 'governed amendment RPC exists');

select is(public.calculate_sales_order_advance_v1(5850::numeric), 2000::numeric, '30 percent advance rounds upward to the next INR 500');
select ok(pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb)'::regprocedure) like '%''WHATSAPP''%', 'WhatsApp promotion preserves WhatsApp provenance');
select ok(pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid, text, uuid, text, text, jsonb)'::regprocedure) not like '%''LEGACY_ERP''%', 'WhatsApp promotion does not select legacy financial provenance');
select ok(pg_get_functiondef('public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)'::regprocedure) like '%STALE_SALES_ORDER_VERSION%', 'amendment rejects stale commercial versions');
select ok(pg_get_functiondef('public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)'::regprocedure) like '%pg_advisory_xact_lock%', 'amendment serializes concurrent writes');
select ok(not has_function_privilege('anon', 'public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)', 'EXECUTE'), 'anon cannot amend commercial SOs');
select ok(not has_table_privilege('authenticated', 'public.sales_order_commercial_versions', 'INSERT'), 'authenticated cannot directly insert commercial versions');
select ok((select relrowsecurity from pg_class where oid = 'public.sales_order_commercial_versions'::regclass), 'commercial versions have RLS enabled');
-- Contract coverage for 20260827090000_validate_pre_factory_so_commercial_origin.
select ok(
  (select convalidated from pg_constraint where conname = 'orders_order_origin_check' and conrelid = 'public.orders'::regclass),
  'expanded source provenance constraint is validated in its later migration'
);

do $$
declare
  v_company uuid;
  v_product uuid;
  v_order uuid;
  v_order_item uuid;
  v_other_order uuid;
  v_other_order_item uuid;
  v_version uuid;
  v_retry uuid;
  v_amended uuid;
  v_snapshot jsonb;
  v_actor uuid := '85000000-0000-0000-0000-000000000001';
begin
  set local session_replication_role = replica;
  insert into auth.users(id,email) values(v_actor,'pf4-amendment@test.invalid');
  insert into public.users(id,role,name,is_active) values(v_actor,'SUPER_ADMIN','PF4 amendment test',true);
  insert into public.companies (business_name, status) values ('PF4 Commercial Contract Co', 'active') returning id into v_company;
  insert into public.products (sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
  values ('PF4-SKU-1', 'PF4 Product', 'PF4 Product', 'Bakery', '19059090', true, true, true, 1, 1, 650, 650) returning id into v_product;
  insert into public.product_pricing_rules (product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
  values (v_product, 'b2b', 'approved', 650, 650, 'INR', 'kg', 18, false);
  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 1, 1, 1);
  set local session_replication_role = default;

  insert into public.orders (company_id, status, order_origin, order_number, tracking_token)
  values (v_company, 'submitted', 'SALES', 'SO-PF4-CONTRACT-000001', md5(random()::text)) returning id into v_order;
  insert into public.order_items (order_id, product_id, quantity, pack_size, carton_type)
  values (v_order, v_product, 10, 'kg', 'carton') returning id into v_order_item;
  perform public.recalculate_governed_sales_order_financials_v1(v_order);
  insert into public.orders (company_id, status, order_origin, order_number, tracking_token)
  values (v_company, 'submitted', 'APPROVED_QUOTE', 'SO-PF4-CONTRACT-000002', md5(random()::text)) returning id into v_other_order;
  insert into public.order_items (order_id, product_id, quantity, pack_size, carton_type)
  values (v_other_order, v_product, 10, 'kg', 'carton') returning id into v_other_order_item;
  perform public.recalculate_governed_sales_order_financials_v1(v_other_order);
  if (select (a.sales_order_value,a.advance_required) is distinct from (b.sales_order_value,b.advance_required)
        from public.orders a cross join public.orders b where a.id=v_order and b.id=v_other_order) then
    raise exception 'SOURCE CONVERGENCE REGRESSION';
  end if;
  v_version := public.create_sales_order_commercial_version_v1(v_order, 'CONTRACT_CREATION', 'contract:pf4', 'contract:pf4:1', null);
  v_retry := public.create_sales_order_commercial_version_v1(v_order, 'CONTRACT_CREATION', 'contract:pf4', 'contract:pf4:1', null);
  if v_version is distinct from v_retry then raise exception 'IDEMPOTENCY REGRESSION'; end if;
  if has_table_privilege('authenticated','public.sales_order_commercial_mutation_scopes','INSERT')
     or has_table_privilege('service_role','public.sales_order_commercial_mutation_scopes','INSERT') then
    raise exception 'MUTATION SCOPE GRANT REGRESSION';
  end if;
  begin
    perform public.create_sales_order_commercial_version_v1(v_other_order,'CONFLICT','contract:pf4:conflict','contract:pf4:1',null);
    raise exception 'CROSS ORDER IDEMPOTENCY REGRESSION';
  exception when unique_violation then null;
  end;
  select commercial_snapshot into v_snapshot from public.sales_order_commercial_versions where id = v_version;
  if v_snapshot #>> '{source_channel}' <> 'SALES'
     or v_snapshot #>> '{lines,0,sku}' <> 'PF4-SKU-1'
     or (v_snapshot #>> '{lines,0,taxable_value}') is null
     or (v_snapshot #>> '{advance_required}') <> '2500' then
    raise exception 'SNAPSHOT REGRESSION: %', v_snapshot;
  end if;
  begin
    update public.sales_order_commercial_versions set change_reason = 'tamper' where id = v_version;
    raise exception 'IMMUTABILITY REGRESSION';
  exception when sqlstate 'P0001' then null;
  end;
  begin
    update public.order_items set quantity = 11 where order_id = v_order;
    raise exception 'DIRECT MUTATION REGRESSION';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claims',json_build_object('sub',v_actor::text,'role','authenticated','aal','aal2')::text,true);
  select commercial_version_id into v_amended from public.amend_sales_order_commercial_v1(
    v_order,1,jsonb_build_array(jsonb_build_object('order_item_id',v_order_item,'product_id',v_product,'quantity',11,'pack_size','kg','carton_type','carton')),
    'AUTHOR_REQUESTED_QUANTITY_CHANGE','contract:pf4:amend','contract:pf4:2');
  if (select commercial_current_version from public.orders where id=v_order) <> 2 then raise exception 'VERSION CREATION REGRESSION'; end if;
  if (select id from public.order_items where order_id=v_order) is distinct from v_order_item then raise exception 'LINE IDENTITY REGRESSION'; end if;
  if (select commercial_snapshot #>> '{lines,0,quantity}' from public.sales_order_commercial_versions where id=v_version) <> '10' then
    raise exception 'HISTORICAL VERSION MUTATION REGRESSION';
  end if;
  if (select previous_commercial_snapshot #>> '{lines,0,quantity}' from public.sales_order_commercial_versions where id=v_amended) <> '10' then
    raise exception 'BEFORE SNAPSHOT REGRESSION';
  end if;
  if (select commercial_version_id from public.amend_sales_order_commercial_v1(
        v_order,1,jsonb_build_array(jsonb_build_object('order_item_id',v_order_item,'product_id',v_product,'quantity',11)),
        'AUTHOR_REQUESTED_QUANTITY_CHANGE','contract:pf4:amend','contract:pf4:2')) is distinct from v_amended then
    raise exception 'AMENDMENT IDEMPOTENCY REGRESSION';
  end if;
  begin
    perform * from public.amend_sales_order_commercial_v1(
      v_order,1,jsonb_build_array(jsonb_build_object('order_item_id',v_order_item,'product_id',v_product,'quantity',12)),
      'STALE_CHANGE','contract:pf4:stale','contract:pf4:stale');
    raise exception 'STALE VERSION REGRESSION';
  exception when sqlstate '40001' then null;
  end;
  perform * from public.amend_sales_order_commercial_v1(
    v_other_order,0,jsonb_build_array(jsonb_build_object('order_item_id',v_other_order_item,'product_id',v_product,'quantity',10,'pack_size','kg','carton_type','carton')),
    'INITIAL_STAFF_GOVERNANCE','contract:pf4:initial','contract:pf4:initial');
  if (select commercial_current_version from public.orders where id=v_other_order) <> 1 then
    raise exception 'INITIAL VERSION REGRESSION';
  end if;
end $$;

select pass('source-neutral SO snapshot/version contract is immutable and idempotent');
select * from finish();
rollback;
