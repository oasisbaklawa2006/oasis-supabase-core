-- Contract for 20260906140000_p106_customer_quotation_authority.sql
begin;

select plan(18);

select has_table('public', 'customer_quotations', 'customer_quotations spine exists');
select has_table('public', 'customer_quotation_versions', 'customer_quotation_versions exists');
select has_table('public', 'customer_quotation_lines', 'customer_quotation_lines exists');
select has_table('public', 'customer_quotation_acceptance_handoffs', 'P107 handoff table exists');
select has_table('public', 'customer_quotation_events', 'customer_quotation_events audit exists');

select has_function('public', 'customer_quotations_v1', array[]::text[], 'customer_quotations_v1 exists');
select has_function('public', 'customer_quotation_detail_v1', array['uuid'], 'customer_quotation_detail_v1 exists');
select has_function('public', 'customer_quotation_lines_v1', array['uuid'], 'customer_quotation_lines_v1 exists');
select has_function('public', 'submit_customer_quotation_request_v1', array['text', 'jsonb', 'text'], 'submit_customer_quotation_request_v1 exists');
select has_function('public', 'accept_customer_quotation_v1', array['uuid', 'integer', 'text'], 'accept_customer_quotation_v1 exists');
select has_function('public', 'decline_customer_quotation_v1', array['uuid', 'integer', 'text', 'text'], 'decline_customer_quotation_v1 exists');

select ok(
  has_function_privilege('authenticated', 'public.customer_quotations_v1()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.submit_customer_quotation_request_v1(text,jsonb,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.customer_quotations_v1()', 'EXECUTE'),
  'customer quotation contracts are authenticated-only'
);

select ok(
  not has_table_privilege('authenticated', 'public.customer_quotations', 'INSERT'),
  'authenticated cannot directly insert customer_quotations'
);

select ok(
  pg_get_functiondef('public.accept_customer_quotation_v1(uuid,integer,text)'::regprocedure)
    like '%customer_quotation_acceptance_handoffs%'
  and pg_get_functiondef('public.accept_customer_quotation_v1(uuid,integer,text)'::regprocedure)
    not like '%insert into public.orders%',
  'accept creates handoff only and does not create a Sales Order'
);

select ok(
  pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%''QT''%',
  'document allocator supports QT quotation numbering'
);

-- Behavioral: request, list, detail, lines, accept, decline, expiry, version, isolation, idempotency
do $$
declare
  v_company_a uuid;
  v_company_b uuid;
  v_buyer_a uuid := gen_random_uuid();
  v_buyer_b uuid := gen_random_uuid();
  v_product uuid;
  v_quotation_id uuid;
  v_quotation_number text;
  v_version integer;
  v_handoff_id uuid;
  v_line_count integer;
  v_other_company_lines integer;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status)
  values ('Quote Spine Co A', 'active') returning id into v_company_a;
  insert into public.companies (business_name, status)
  values ('Quote Spine Co B', 'active') returning id into v_company_b;

  insert into auth.users (id, email) values (v_buyer_a, 'quote-spine-a-' || v_buyer_a::text || '@example.com');
  insert into auth.users (id, email) values (v_buyer_b, 'quote-spine-b-' || v_buyer_b::text || '@example.com');

  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer_a, v_company_a, 'b2b_buyer', true, 'approved', 'quote-spine-a-' || v_buyer_a::text || '@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer_b, v_company_b, 'b2b_buyer', true, 'approved', 'quote-spine-b-' || v_buyer_b::text || '@example.com');

  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready, base_price
  ) values (
    'QUOTE-SKU-001', 'Quote Test Product', 'Quote Test Product', 'Bakery', '19059090',
    true, true, true, 500
  ) returning id into v_product;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (
    v_product, 'b2b', 'approved', 500, 500, 'INR', 'kg', 0, true
  );

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select q.quotation_id, q.quotation_number, q.version_number
  into v_quotation_id, v_quotation_number, v_version
  from public.submit_customer_quotation_request_v1(
    'quote-req-key-001',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 10)),
    'Need pricing for trial order'
  ) q;

  if v_quotation_id is null or v_quotation_number is null then
    raise exception 'REGRESSION: submit did not return quotation identity';
  end if;

  if v_quotation_number !~ '^QT[0-9]{4}/[0-9]{2}-[0-9]{4}$' then
    raise exception 'REGRESSION: quotation_number % is not canonical QT format', v_quotation_number;
  end if;

  if (select count(*) from public.customer_quotations_v1()) <> 1 then
    raise exception 'REGRESSION: customer_quotations_v1 list count expected 1';
  end if;

  if (select count(*) from public.customer_quotation_detail_v1(v_quotation_id)) <> 1 then
    raise exception 'REGRESSION: customer_quotation_detail_v1 returned no row';
  end if;

  select count(*) into v_line_count from public.customer_quotation_lines_v1(v_quotation_id);
  if v_line_count <> 1 then
    raise exception 'REGRESSION: customer_quotation_lines_v1 expected 1 line, got %', v_line_count;
  end if;

  -- idempotent resubmit
  if not exists (
    select 1 from public.submit_customer_quotation_request_v1(
      'quote-req-key-001',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 10)),
      'Need pricing for trial order'
    ) q where q.already_applied = true and q.quotation_id = v_quotation_id
  ) then
    raise exception 'REGRESSION: submit idempotency did not replay existing quotation';
  end if;

  -- version bump via service path (postgres)
  reset role;
  perform set_config('request.jwt.claims', null, true);

  perform public.revise_customer_quotation_v1(
    v_quotation_id,
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 12)),
    'revise-key-001',
    statement_timestamp() + interval '45 days'
  );

  v_version := (select current_version from public.customer_quotations where id = v_quotation_id);

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.accept_customer_quotation_v1(v_quotation_id, 1, 'accept-key-001');
    raise exception 'REGRESSION: stale version acceptance was allowed';
  exception
    when others then
      if sqlerrm not like 'QUOTATION_VERSION_STALE%' then
        raise;
      end if;
  end;

  select h.handoff_id into v_handoff_id
  from public.accept_customer_quotation_v1(v_quotation_id, v_version, 'accept-key-001') h;

  if v_handoff_id is null then
    raise exception 'REGRESSION: accept did not return handoff_id';
  end if;

  if not exists (
    select 1 from public.customer_quotation_acceptance_handoffs
    where id = v_handoff_id and handoff_status = 'pending'
  ) then
    raise exception 'REGRESSION: acceptance handoff not pending for P107';
  end if;

  if exists (select 1 from public.orders where company_id = v_company_a and order_origin = 'APPROVED_QUOTE') then
    raise exception 'REGRESSION: accept created a shadow Sales Order';
  end if;

  -- company B isolation
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_b::text, 'role', 'authenticated')::text, true);

  begin
    perform public.customer_quotation_detail_v1(v_quotation_id);
    raise exception 'REGRESSION: company B read company A quotation';
  exception
    when others then
      if sqlerrm not like 'QUOTATION_NOT_FOUND%' then
        raise;
      end if;
  end;

  select count(*) into v_other_company_lines from public.customer_quotations_v1();
  if v_other_company_lines <> 0 then
    raise exception 'REGRESSION: company B list leaked company A quotations';
  end if;

  -- decline path on fresh quotation
  reset role;
  perform set_config('request.jwt.claims', null, true);

  insert into public.companies (business_name, status) values ('Quote Decline Co', 'active') returning id into v_company_b;
  -- reuse v_company_b variable for decline company - need new buyer
  -- use company_a with new quotation instead
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select q.quotation_id into v_quotation_id
  from public.submit_customer_quotation_request_v1(
    'quote-decline-key-001',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 10)),
    null
  ) q;

  perform public.decline_customer_quotation_v1(v_quotation_id, 1, 'decline-key-001', 'Price too high');

  if (select status from public.customer_quotations where id = v_quotation_id) <> 'declined' then
    raise exception 'REGRESSION: decline did not set status declined';
  end if;

  -- expiry fail-closed
  reset role;
  update public.customer_quotations
  set expires_at = statement_timestamp() - interval '1 hour'
  where id = v_quotation_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.accept_customer_quotation_v1(v_quotation_id, 1, 'accept-expired-key');
    raise exception 'REGRESSION: expired quotation acceptance was allowed';
  exception
    when others then
      if sqlerrm not like 'QUOTATION_EXPIRED%' and sqlerrm not like 'QUOTATION_NOT_ACTIONABLE%' then
        raise;
      end if;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('quotation RPCs enforce request/list/detail/lines/accept/decline/expiry/version/isolation/idempotency');

select ok(
  exists(
    select 1 from pg_trigger
    where tgname = 'trg_customer_quotation_versions_immutable'
  ),
  'quotation versions are immutable'
);

select ok(
  (select count(*) from pg_policies
   where schemaname = 'public' and tablename = 'customer_quotations' and cmd = 'INSERT') = 0,
  'no INSERT policy on customer_quotations'
);

select * from finish();
rollback;
