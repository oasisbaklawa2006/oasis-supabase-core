-- Contract test for 20260807171000_customer_order_draft_v1.sql
begin;

select plan(14);

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

-- Live: draft lifecycle + MOQ rejection
do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_intruder uuid := gen_random_uuid();
  v_product uuid;
  v_draft_id uuid;
  v_line_id uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Draft Spine Co', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'draft-spine@example.com');
  insert into auth.users (id, email) values (v_intruder, 'draft-intruder@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'draft-spine@example.com');
  update public.profiles
  set role = 'b2b_buyer', is_approved = true, status = 'approved'
  where id = v_buyer;

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price
  ) values (
    'SPINE-SKU-1', 'Spine Test Product', 'Spine Test Product', 'Bakery', '19059090',
    true, true, true,
    9, 9, 650
  ) returning id into v_product;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product, 'b2b', 'approved', 650, 650, 'INR', 'kg', 0, true
  );

  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 9, 9, 9);

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select draft_id into v_draft_id from public.get_customer_order_draft_v1() limit 1;
  select draft_id, line_id into v_draft_id, v_line_id
  from public.add_customer_order_draft_line_v1(v_product, 9);

  if v_line_id is null then
    raise exception 'REGRESSION: add_customer_order_draft_line_v1 did not return a line';
  end if;

  begin
    perform public.add_customer_order_draft_line_v1(v_product, 10);
    raise exception 'REGRESSION: MOQ violation was accepted (quantity 10 with MOQ/increment 9)';
  exception
    when others then
      if sqlerrm not like 'QUANTITY_RULE_VIOLATION%' then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_intruder::text, 'role', 'authenticated')::text, true);
  begin
    perform public.add_customer_order_draft_line_v1(v_product, 9);
    raise exception 'SECURITY REGRESSION: unrelated buyer added line to another company draft';
  exception
    when sqlstate '42501' then null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('customer draft RPCs enforce MOQ rules and reject cross-company mutation');

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
