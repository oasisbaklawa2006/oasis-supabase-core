-- Point72 contract: canonical order source attribution and duplicate-prevention closure.
-- Schema authority: 20260906120000_point72_order_intake_source_attribution_closure.sql
begin;

select plan(24);

select has_function(
  'public',
  'resolve_order_intake_source_identity_v1',
  array['uuid'],
  'canonical intake identity resolver exists'
);

select has_function(
  'public',
  'list_order_intake_near_duplicate_review_candidates_v1',
  array['uuid', 'interval'],
  'near-duplicate review candidate listing exists'
);

select ok(
  exists(
    select 1
    from pg_trigger
    where tgrelid = 'public.orders'::regclass
      and tgname = 'trg_orders_immutable_governed_order_origin'
      and not tgisinternal
  ),
  'governed order_origin immutability trigger is installed'
);

select ok(
  has_function_privilege('authenticated', 'public.resolve_order_intake_source_identity_v1(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.resolve_order_intake_source_identity_v1(uuid)', 'EXECUTE'),
  'intake identity resolver is authenticated/service only'
);

select ok(
  has_function_privilege('authenticated', 'public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval)', 'EXECUTE'),
  'near-duplicate review listing is authenticated/service only'
);

do $$
declare
  v_company uuid;
  v_buyer uuid := '72000000-0000-0000-0000-000000000001';
  v_staff uuid := '72000000-0000-0000-0000-000000000002';
  v_actor uuid := '72000000-0000-0000-0000-000000000003';
  v_product uuid;
  v_packet uuid := '72000000-0000-0000-0000-000000000010';
  v_draft uuid := '72000000-0000-0000-0000-000000000020';
  v_contact uuid := '72000000-0000-0000-0000-000000000011';
  v_checkout_order uuid;
  v_wa_order uuid;
  v_identity jsonb;
  v_dup boolean;
  v_promoted uuid;
  v_already boolean;
  v_candidate_count integer;
begin
  set local session_replication_role = replica;

  insert into public.companies (id, business_name, status)
  values ('72000000-0000-0000-0000-000000000100', 'Point72 Census Co', 'active')
  returning id into v_company;

  insert into auth.users (id, email) values
    (v_buyer, 'p72-buyer@example.test'),
    (v_staff, 'p72-staff@example.test'),
    (v_actor, 'p72-actor@example.test');

  insert into public.users (id, email, role, company_id, is_active)
  values
    (v_buyer, 'p72-buyer@example.test', 'b2b_buyer', v_company, true),
    (v_staff, 'p72-staff@example.test', 'SUPER_ADMIN', null, true),
    (v_actor, 'p72-actor@example.test', 'SUPER_ADMIN', null, true);

  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'p72-buyer@example.test');

  insert into public.products (
    id, sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price, price_b2b
  ) values (
    '72000000-0000-0000-0000-000000000200',
    'P72-SKU', 'Point72 Product', 'Point72 Product', 'Bakery', '19059090',
    true, true, true, 1, 1, 500, 500
  ) returning id into v_product;

  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (v_product, 'b2b', 'approved', 500, 500, 'INR', 'box', 0, true);

  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 1, 1, 1);

  insert into public.whatsapp_contacts (id, phone_number, customer_name)
  values (v_contact, '919720000001', 'Point72 WA Contact');

  insert into public.whatsapp_message_packets (
    id, contact_id, stitched_content, first_message_at, last_message_at, status
  ) values (
    v_packet, v_contact, '{"text":"send 2 boxes"}'::jsonb, now(), now(), 'closed'
  );

  insert into public.sales_order_drafts (
    id, packet_id, extraction_request_key, status, company_id, company_name,
    readiness_overall_score, readiness_dimensions, original_whatsapp_text,
    created_by, updated_by
  ) values (
    v_draft, v_packet, 'p72-wa-extract-1', 'UNDER_REVIEW', v_company, 'Point72 Census Co',
    100,
    '[
      {"dimension":"client","status":"ready","score":100},
      {"dimension":"product","status":"ready","score":100},
      {"dimension":"quantity","status":"ready","score":100},
      {"dimension":"address","status":"ready","score":100},
      {"dimension":"payment_terms","status":"ready","score":100}
    ]'::jsonb,
    'send 2 boxes',
    v_actor, v_actor
  );

  insert into public.sales_order_draft_lines (
    draft_id, line_index, product_id, product_name, sku, raw_quantity, raw_unit, normalized_quantity, normalized_unit
  ) values (
    v_draft, 0, v_product, 'Point72 Product', 'P72-SKU', 2, 'box', 2, 'box'
  );

  set local session_replication_role = default;

  -- Buyer checkout path
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.add_customer_order_draft_line_v1(v_product, 2);
  select order_id, is_duplicate_submission
    into v_checkout_order, v_dup
    from public.submit_customer_order_v1('p72-shared-key-001');
  if v_checkout_order is null or v_dup then
    raise exception 'CHECKOUT REGRESSION: first submit failed';
  end if;
  select is_duplicate_submission into v_dup
    from public.submit_customer_order_v1('p72-shared-key-001');
  if not v_dup then
    raise exception 'REPLAY REGRESSION: checkout retry did not suppress replay';
  end if;

  v_identity := public.resolve_order_intake_source_identity_v1(v_checkout_order);
  if v_identity->>'source_channel' <> 'CUSTOMER_APP'
     or v_identity->>'source_reference' <> 'p72-shared-key-001'
     or v_identity->>'intake_authority' <> 'CUSTOMER_CHECKOUT' then
    raise exception 'CHECKOUT IDENTITY REGRESSION: %', v_identity;
  end if;

  reset role;

  -- WhatsApp promotion path (service_role)
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  select promoted_order_id, already_promoted
    into v_wa_order, v_already
    from public.promote_sales_order_draft_to_order_governed_v1(
      v_draft, 'p72-wa-extract-1', v_actor, 'Point72 Actor', 'p72 promotion test'
    );
  if v_wa_order is null or v_already then
    raise exception 'WA PROMOTION REGRESSION: first promotion failed';
  end if;
  select promoted_order_id, already_promoted
    into v_promoted, v_already
    from public.promote_sales_order_draft_to_order_governed_v1(
      v_draft, 'p72-wa-extract-1', v_actor, 'Point72 Actor', 'p72 promotion replay'
    );
  if v_promoted is distinct from v_wa_order or not v_already then
    raise exception 'WA REPLAY REGRESSION: promotion replay did not return already_promoted';
  end if;

  v_identity := public.resolve_order_intake_source_identity_v1(v_wa_order);
  if v_identity->>'source_channel' <> 'WHATSAPP'
     or v_identity->>'source_reference' <> ('wa-draft:' || v_draft::text)
     or v_identity->>'intake_authority' <> 'WHATSAPP_DRAFT_PROMOTION' then
    raise exception 'WA IDENTITY REGRESSION: %', v_identity;
  end if;

  if (select order_origin from public.orders where id = v_wa_order) <> 'WHATSAPP' then
    raise exception 'WA ORIGIN REGRESSION';
  end if;

  -- Cross-source non-collision: shared string in checkout key does not affect WA order
  if v_checkout_order = v_wa_order then
    raise exception 'CROSS-SOURCE COLLISION REGRESSION: checkout and WA collapsed to one order';
  end if;
  if (select count(*) from public.orders where company_id = v_company) < 2 then
    raise exception 'CROSS-SOURCE NON-COLLISION REGRESSION: expected distinct channel orders';
  end if;

  -- Governed origin immutability
  begin
    update public.orders set order_origin = 'CUSTOMER_APP' where id = v_wa_order;
    raise exception 'ORIGIN MUTATION REGRESSION: WHATSAPP origin rewrite accepted';
  exception when check_violation then
    if sqlerrm <> 'ORDER_ORIGIN_IMMUTABLE' then raise; end if;
  end;

  begin
    update public.orders set order_origin = 'SALES' where id = v_checkout_order;
    raise exception 'ORIGIN MUTATION REGRESSION: CUSTOMER_APP origin rewrite accepted';
  exception when check_violation then
    if sqlerrm <> 'ORDER_ORIGIN_IMMUTABLE' then raise; end if;
  end;

  -- Commercial snapshot preserves immutable origin lineage
  if (select commercial_snapshot->>'source_channel' from public.sales_order_commercial_versions where order_id = v_wa_order limit 1) <> 'WHATSAPP' then
    raise exception 'COMMERCIAL SOURCE CHANNEL REGRESSION';
  end if;
  if (select source_channel from public.sales_order_commercial_versions where order_id = v_checkout_order limit 1) <> 'CUSTOMER_APP' then
    raise exception 'CHECKOUT COMMERCIAL SOURCE CHANNEL REGRESSION';
  end if;

  -- Near-duplicate review candidates (internal staff only)
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  select count(*)::integer
    into v_candidate_count
    from public.list_order_intake_near_duplicate_review_candidates_v1(v_company, interval '7 days')
   where candidate_a_order_id in (v_checkout_order, v_wa_order)
     and candidate_b_order_id in (v_checkout_order, v_wa_order);
  if v_candidate_count < 1 then
    raise exception 'NEAR-DUPLICATE REVIEW REGRESSION: overlapping channel orders not flagged';
  end if;

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*)::integer
    into v_candidate_count
    from public.list_order_intake_near_duplicate_review_candidates_v1(v_company, interval '7 days');
  if v_candidate_count <> 0 then
    raise exception 'AUTHORIZATION REGRESSION: buyer can see near-duplicate review candidates';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('replay suppression, cross-source non-collision, origin immutability, and review candidates behave as contracted');

select ok(
  exists(
    select 1
    from pg_constraint
    where conname = 'orders_order_origin_check'
      and conrelid = 'public.orders'::regclass
      and pg_get_constraintdef(oid) like '%REPEAT_ORDER%'
  ),
  'REPEAT_ORDER remains in governed provenance vocabulary (writer deferred to future intake RPC)'
);

select ok(
  (select count(*)::integer
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.proname ~* 'repeat.*order'
     and p.prosrc ~* 'insert[[:space:]]+into[[:space:]]+(public[[:space:]]*\.)?[[:space:]]*orders') = 0,
  'no REPEAT_ORDER runtime writer inserts into orders'
);

select ok(
  pg_get_functiondef('public.resolve_order_intake_source_identity_v1(uuid)'::regprocedure)
    like '%CUSTOMER_CHECKOUT%'
  and pg_get_functiondef('public.resolve_order_intake_source_identity_v1(uuid)'::regprocedure)
    like '%WHATSAPP_DRAFT_PROMOTION%',
  'intake identity resolver documents both canonical creation authorities'
);

select ok(
  pg_get_functiondef('public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval)'::regprocedure)
    like '%scoped_replay_key IS DISTINCT FROM%'
  and pg_get_functiondef('public.list_order_intake_near_duplicate_review_candidates_v1(uuid, interval)'::regprocedure)
    like '%is_internal_staff%',
  'near-duplicate review candidates require distinct replay identity and internal staff'
);

select ok(
  not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname = 'list_order_intake_near_duplicate_review_candidates_v1'
      and p.prosrc ~* 'insert[[:space:]]+into[[:space:]]+(public[[:space:]]*\.)?[[:space:]]*orders'
  ),
  'near-duplicate review listing never writes orders'
);

select * from finish();
rollback;
