-- Contract test for 20260807171000_customer_order_draft_v1.sql
begin;

select plan(12);

select has_table('public', 'customer_order_drafts', 'customer_order_drafts exists');
select has_table('public', 'customer_order_draft_lines', 'customer_order_draft_lines exists');
select has_table('public', 'customer_order_draft_audit_log', 'customer_order_draft_audit_log exists');

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'customer_order_drafts'
      and indexname = 'uq_customer_order_drafts_one_active_per_company'
  ),
  'one active draft per company partial unique index exists'
);

select ok(
  not has_table_privilege('authenticated', 'public.customer_order_drafts', 'INSERT'),
  'authenticated cannot directly INSERT customer_order_drafts'
);

select has_function('public', 'get_customer_order_draft_v1', array[]::text[], 'get_customer_order_draft_v1 exists');
select has_function('public', 'add_customer_order_draft_line_v1', array['uuid', 'numeric'], 'add_customer_order_draft_line_v1 exists');
select has_function('public', 'submit_customer_order_v1', array['text', 'date'], 'submit_customer_order_v1 exists (checkout tranche)');

select ok(
  not has_function_privilege('anon', 'public.get_customer_order_draft_v1()', 'EXECUTE'),
  'anon cannot execute get_customer_order_draft_v1'
);

-- Live: draft lifecycle, MOQ rules, and cross-company isolation
do $$
declare
  v_company_a uuid;
  v_company_b uuid;
  v_buyer_a uuid := gen_random_uuid();
  v_buyer_b uuid := gen_random_uuid();
  v_product_moq uuid;
  v_product_no_moq uuid;
  v_product_fallback uuid;
  v_draft_id uuid;
  v_line_id uuid;
  v_moq_qty numeric;
  v_no_moq_qty numeric;
  v_fallback_qty numeric;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Draft Spine Co A', 'active') returning id into v_company_a;
  insert into public.companies (business_name, status) values ('Draft Spine Co B', 'active') returning id into v_company_b;
  insert into auth.users (id, email) values (v_buyer_a, 'draft-spine-a@example.com');
  insert into auth.users (id, email) values (v_buyer_b, 'draft-spine-b@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer_a, v_company_a, 'b2b_buyer', true, 'approved', 'draft-spine-a@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer_b, v_company_b, 'b2b_buyer', true, 'approved', 'draft-spine-b@example.com');

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price
  ) values (
    'SPINE-SKU-MOQ', 'Spine MOQ Product', 'Spine MOQ Product', 'Bakery', '19059090',
    true, true, true,
    9, 9, 650
  ) returning id into v_product_moq;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product_moq, 'b2b', 'approved', 650, 650, 'INR', 'kg', 0, true
  );

  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product_moq, 'b2b', true, 9, 9, 9);

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price
  ) values (
    'SPINE-SKU-NOMOQ', 'Spine No MOQ Product', 'Spine No MOQ Product', 'Bakery', '19059090',
    true, true, true,
    9, 9, 650
  ) returning id into v_product_no_moq;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product_no_moq, 'b2b', 'approved', 650, 650, 'INR', 'kg', 0, true
  );

  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product_no_moq, 'b2b', false, 9, 9, 6);

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price
  ) values (
    'SPINE-SKU-FALLBACK', 'Spine Fallback Product', 'Spine Fallback Product', 'Bakery', '19059090',
    true, true, true,
    5, 5, 650
  ) returning id into v_product_fallback;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product_fallback, 'b2b', 'approved', 650, 650, 'INR', 'kg', 0, true
  );

  set local session_replication_role = default;

  select minimum_order_quantity into v_moq_qty
  from public.customer_resolve_buyer_product_authority_v1(v_company_a, v_product_moq);
  if v_moq_qty is distinct from 9 then
    raise exception 'MOQ REGRESSION: applicable rule should enforce MOQ 9 (got %)', v_moq_qty;
  end if;

  select minimum_order_quantity into v_no_moq_qty
  from public.customer_resolve_buyer_product_authority_v1(v_company_a, v_product_no_moq);
  if v_no_moq_qty is not null then
    raise exception 'MOQ REGRESSION: moq_applicable=false should not apply MOQ fallback (got %)', v_no_moq_qty;
  end if;

  select minimum_order_quantity into v_fallback_qty
  from public.customer_resolve_buyer_product_authority_v1(v_company_a, v_product_fallback);
  if v_fallback_qty is distinct from 5 then
    raise exception 'MOQ REGRESSION: absent rule should fall back to product MOQ 5 (got %)', v_fallback_qty;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select draft_id into v_draft_id from public.get_customer_order_draft_v1() limit 1;
  select draft_id, line_id into v_draft_id, v_line_id
  from public.add_customer_order_draft_line_v1(v_product_moq, 9);

  if v_line_id is null then
    raise exception 'REGRESSION: add_customer_order_draft_line_v1 did not return a line';
  end if;

  begin
    perform public.add_customer_order_draft_line_v1(v_product_moq, 10);
    raise exception 'REGRESSION: MOQ violation was accepted (quantity 10 with MOQ/increment 9)';
  exception
    when others then
      if sqlerrm not like 'QUANTITY_RULE_VIOLATION%' then
        raise;
      end if;
  end;

  begin
    perform public.add_customer_order_draft_line_v1(v_product_no_moq, 3);
    raise exception 'REGRESSION: carton violation accepted for moq_applicable=false product';
  exception
    when others then
      if sqlerrm not like 'QUANTITY_RULE_VIOLATION%' then
        raise;
      end if;
  end;

  perform public.add_customer_order_draft_line_v1(v_product_no_moq, 6);

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_b::text, 'role', 'authenticated')::text, true);
  perform public.get_customer_order_draft_v1();

  if (select count(*) from public.customer_order_draft_lines l
      join public.customer_order_drafts d on d.id = l.draft_id
      where d.company_id = v_company_a) <> 0 then
    raise exception 'SECURITY REGRESSION: buyer B can read company A draft lines via RLS';
  end if;

  reset role;

  if (select count(*) from public.customer_order_draft_lines l
      join public.customer_order_drafts d on d.id = l.draft_id
      where d.company_id = v_company_a) < 2 then
    raise exception 'REGRESSION: buyer A draft lines were not isolated from buyer B activity';
  end if;

  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('draft RPCs enforce MOQ semantics, carton rules, and cross-company isolation');

select ok(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'customer_order_drafts' and cmd = 'INSERT') = 0,
  'no INSERT policy on customer_order_drafts for self-serve callers'
);

select ok(
  exists(select 1 from public.customer_order_draft_audit_log limit 1),
  'draft audit log receives events from governed mutations'
);

select * from finish();
rollback;
