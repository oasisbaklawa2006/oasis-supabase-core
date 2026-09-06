-- Point75 — order amendment / cancel / substitute canonical closure audit.
-- Authority: migration 20260827063731 (PF-4 commercial) + 20260827204931 (PI freeze).
-- Test/evidence-only closure; no new migration while #209→#215→#226→#228 is active.
-- Separates Point75 from Point72 intake provenance, Point76 split fulfilment, Finance refund/credit-note.
begin;

select plan(22);

-- Census: core amendment/version tables and RPCs
select has_table('public', 'sales_order_commercial_versions', 'commercial version ledger exists');
select has_table('public', 'sales_order_commercial_mutation_scopes', 'transaction-scoped mutation scope exists');
select has_function(
  'public', 'amend_sales_order_commercial_v1',
  array['uuid', 'integer', 'jsonb', 'text', 'text', 'text'],
  'governed amendment RPC exists'
);
select has_function(
  'public', 'create_sales_order_commercial_version_v1',
  array['uuid', 'text', 'text', 'text', 'uuid'],
  'commercial version writer exists'
);
select has_function(
  'public', 'build_sales_order_commercial_snapshot_v1',
  array['uuid'],
  'commercial snapshot builder exists'
);
select has_function(
  'public', 'recalculate_governed_sales_order_financials_v1',
  array['uuid'],
  'governed financial recalculation exists'
);

-- Census: PI cancellation is governed; governed SO cancellation RPC is intentionally absent (Point76/Finance scope)
select has_function(
  'public', 'cancel_sales_order_proforma_invoice_v1',
  array['uuid', 'text', 'text', 'text', 'text', 'uuid'],
  'governed PI cancellation RPC exists (document-level cancel, not SO body cancel)'
);
select ok(
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'cancel_sales_order_commercial_v1'
  ),
  'no competing governed SO cancellation RPC — order cancel remains status-level until future gate'
);

-- Census: WhatsApp substitution proposal path (case layer; execution routes through amend RPC)
select has_table('public', 'whatsapp_case_proposed_changes', 'WhatsApp proposed-change ledger exists');
select has_function(
  'public', 'whatsapp_propose_case_change',
  array['uuid', 'uuid', 'text', 'jsonb', 'jsonb', 'text', 'text'],
  'WhatsApp substitution/amendment proposal RPC exists'
);

-- Census: guards embedded in amendment authority
select ok(
  pg_get_functiondef('public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)'::regprocedure)
    like '%STALE_SALES_ORDER_VERSION%',
  'amendment rejects stale commercial versions'
);
select ok(
  pg_get_functiondef('public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)'::regprocedure)
    like '%pg_advisory_xact_lock%',
  'amendment serializes concurrent writes'
);
select ok(
  pg_get_functiondef('public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)'::regprocedure)
    like '%ORDER_ITEM_PRODUCT_IDENTITY_IMMUTABLE%',
  'substitution cannot mutate product identity on an existing line'
);
select ok(
  pg_get_functiondef('public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)'::regprocedure)
    like '%SALES_ORDER_ALREADY_ENTERED_OPERATIONS%',
  'amendment blocked after operational downstream binding'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.amend_sales_order_commercial_v1(uuid, integer, jsonb, text, text, text)',
    'EXECUTE'
  ),
  'anon cannot amend commercial SOs'
);
select ok(
  not has_table_privilege('authenticated', 'public.sales_order_commercial_versions', 'INSERT'),
  'authenticated cannot directly insert commercial versions'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.sales_order_commercial_versions'::regclass),
  'commercial versions have RLS enabled'
);
select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid = 'public.sales_order_commercial_versions'::regclass
      and tgname = 'trg_sales_order_commercial_versions_immutable'
      and not tgisinternal
  ),
  'commercial version immutability trigger is present'
);
select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid = 'public.order_items'::regclass
      and tgname = 'trg_order_items_governed_commercial_mutation'
      and not tgisinternal
  ),
  'direct commercial line mutation trigger is present'
);
select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid = 'public.order_items'::regclass
      and tgname = 'trg_sales_order_pi_frozen_order_item_mutation'
      and not tgisinternal
  ),
  'issued-PI commercial freeze trigger is present on order_items'
);
select ok(
  not has_table_privilege('authenticated', 'public.sales_order_commercial_mutation_scopes', 'INSERT'),
  'mutation scope table is not client-writable'
);

do $$
declare
  v_actor uuid := '75000000-0000-0000-0000-000000000001';
  v_buyer uuid := '75000000-0000-0000-0000-000000000002';
  v_company uuid;
  v_product_a uuid;
  v_product_b uuid;
  v_order uuid;
  v_item_a uuid;
  v_version_1 uuid;
  v_version_2 uuid;
  v_amended uuid;
  v_snapshot_v1 jsonb;
  v_snapshot_v2 jsonb;
  v_pi uuid;
  v_cancel_pi uuid;
  v_cancel_order uuid;
  v_cancel_item uuid;
  v_cancel_version uuid;
begin
  set local session_replication_role = replica;
  insert into auth.users(id, email) values
    (v_actor, 'point75-amend@test.invalid'),
    (v_buyer, 'point75-buyer@test.invalid');
  insert into public.users(id, role, name, is_active) values
    (v_actor, 'SUPER_ADMIN', 'Point75 amendment test', true),
    (v_buyer, 'B2B_BUYER', 'Point75 buyer', true);
  insert into public.companies (business_name, status)
  values ('Point75 Amendment Co', 'active') returning id into v_company;
  insert into public.products (sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
  values ('P75-SKU-A', 'Point75 Product A', 'Point75 Product A', 'Bakery', '19059090', true, true, true, 1, 1, 650, 650)
  returning id into v_product_a;
  insert into public.products (sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
  values ('P75-SKU-B', 'Point75 Product B', 'Point75 Product B', 'Bakery', '19059090', true, true, true, 1, 1, 700, 700)
  returning id into v_product_b;
  insert into public.product_pricing_rules (product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
  values
    (v_product_a, 'b2b', 'approved', 650, 650, 'INR', 'kg', 18, false),
    (v_product_b, 'b2b', 'approved', 700, 700, 'INR', 'kg', 18, false);
  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values
    (v_product_a, 'b2b', true, 1, 1, 1),
    (v_product_b, 'b2b', true, 1, 1, 1);
  set local session_replication_role = default;

  -- Baseline governed SO with truthful SALES provenance (WhatsApp lineage is Point72; requires draft linkage)
  insert into public.orders (company_id, status, order_origin, order_number, tracking_token)
  values (v_company, 'submitted', 'SALES', 'SO-P75-000001', md5(random()::text))
  returning id into v_order;
  insert into public.order_items (order_id, product_id, quantity, pack_size, carton_type)
  values (v_order, v_product_a, 10, 'kg', 'carton') returning id into v_item_a;
  perform public.recalculate_governed_sales_order_financials_v1(v_order);
  v_version_1 := public.create_sales_order_commercial_version_v1(
    v_order, 'POINT75_INITIAL', 'point75:initial', 'point75-version-1', v_actor
  );

  select commercial_snapshot into v_snapshot_v1
  from public.sales_order_commercial_versions where id = v_version_1;
  if v_snapshot_v1 #>> '{source_channel}' <> 'SALES'
     or v_snapshot_v1 #>> '{lines,0,product_id}' <> v_product_a::text
     or (v_snapshot_v1 #>> '{advance_required}')::numeric <> 2500 then
    raise exception 'POINT75 SOURCE/FINANCIAL SNAPSHOT REGRESSION: %', v_snapshot_v1;
  end if;

  -- Direct line mutation forbidden after versioning
  begin
    update public.order_items set quantity = 11 where id = v_item_a;
    raise exception 'POINT75 DIRECT MUTATION REGRESSION';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  set local role authenticated;

  -- Product identity immutable on existing line (substitution must add new line)
  begin
    perform * from public.amend_sales_order_commercial_v1(
      v_order, 1,
      jsonb_build_array(jsonb_build_object('order_item_id', v_item_a, 'product_id', v_product_b, 'quantity', 10)),
      'POINT75_SWAP_ATTEMPT', 'point75:swap', 'point75-swap-fail'
    );
    raise exception 'POINT75 PRODUCT SWAP REGRESSION';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'ORDER_ITEM_PRODUCT_IDENTITY_IMMUTABLE' then raise; end if;
  end;

  -- Governed substitution: remove line A, add line B (new line, no order_item_id)
  select commercial_version_id into v_amended from public.amend_sales_order_commercial_v1(
    v_order, 1,
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'quantity', 8, 'pack_size', 'kg', 'carton_type', 'carton')),
    'POINT75_PRODUCT_SUBSTITUTION', 'point75:substitute', 'point75-version-2'
  );
  v_version_2 := v_amended;

  if (select commercial_current_version from public.orders where id = v_order) <> 2 then
    raise exception 'POINT75 VERSION INCREMENT REGRESSION';
  end if;
  if (select count(*) from public.order_items where order_id = v_order) <> 1 then
    raise exception 'POINT75 LINE COUNT REGRESSION';
  end if;
  if (select product_id from public.order_items where order_id = v_order) is distinct from v_product_b then
    raise exception 'POINT75 SUBSTITUTION PRODUCT REGRESSION';
  end if;
  if (select commercial_snapshot #>> '{lines,0,quantity}' from public.sales_order_commercial_versions where id = v_version_1) <> '10' then
    raise exception 'POINT75 IMMUTABLE HISTORY REGRESSION';
  end if;
  if (select previous_commercial_snapshot #>> '{lines,0,product_id}' from public.sales_order_commercial_versions where id = v_version_2)
     is distinct from v_product_a::text then
    raise exception 'POINT75 PREVIOUS SNAPSHOT REGRESSION';
  end if;

  select commercial_snapshot into v_snapshot_v2
  from public.sales_order_commercial_versions where id = v_version_2;
  if v_snapshot_v2 #>> '{source_channel}' <> 'SALES'
     or (v_snapshot_v2 #>> '{sales_order_value}')::numeric <= 0
     or (v_snapshot_v2 #>> '{advance_required}')::numeric <> public.calculate_sales_order_advance_v1((v_snapshot_v2 #>> '{sales_order_value}')::numeric) then
    raise exception 'POINT75 RECALCULATION REGRESSION: %', v_snapshot_v2;
  end if;

  -- Idempotent amendment replay
  if (select commercial_version_id from public.amend_sales_order_commercial_v1(
        v_order, 1,
        jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'quantity', 8)),
        'POINT75_PRODUCT_SUBSTITUTION', 'point75:substitute', 'point75-version-2'
      )) is distinct from v_version_2 then
    raise exception 'POINT75 AMENDMENT IDEMPOTENCY REGRESSION';
  end if;

  -- Stale version denial
  begin
    perform * from public.amend_sales_order_commercial_v1(
      v_order, 1,
      jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'quantity', 9)),
      'POINT75_STALE', 'point75:stale', 'point75-stale'
    );
    raise exception 'POINT75 STALE VERSION REGRESSION';
  exception when sqlstate '40001' then null;
  end;

  -- Operations lifecycle cutoff
  set local role postgres;
  insert into public.packing_lists (order_item_id, product_id, packed_quantity)
  values ((select id from public.order_items where order_id = v_order limit 1), v_product_b, 1);
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  set local role authenticated;
  begin
    perform * from public.amend_sales_order_commercial_v1(
      v_order, 2,
      jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'quantity', 7)),
      'POINT75_OPS_BLOCK', 'point75:ops', 'point75-ops-block'
    );
    raise exception 'POINT75 OPERATIONS CUTOFF REGRESSION';
  exception when sqlstate '55000' then
    if sqlerrm <> 'SALES_ORDER_ALREADY_ENTERED_OPERATIONS' then raise; end if;
  end;
  set local role postgres;
  delete from public.packing_lists where order_item_id = (select id from public.order_items where order_id = v_order limit 1);
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;

  -- Issued PI freezes commercial amendment (finance downstream lock)
  select pi_id into v_pi from public.create_sales_order_proforma_invoice_v1(
    v_order, v_version_2, 'POINT75_PI', 'MANUAL', 'point75:pi:create', 'point75-pi-create', v_actor
  );
  perform public.issue_sales_order_proforma_invoice_v1(
    v_pi, 'POINT75_ISSUE', 'MANUAL', 'point75:pi:issue', 'point75-pi-issue', v_actor
  );
  begin
    perform * from public.amend_sales_order_commercial_v1(
      v_order, 2,
      jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'quantity', 6)),
      'POINT75_AFTER_PI', 'point75:pi:block', 'point75-pi-block'
    );
    raise exception 'POINT75 PI FREEZE REGRESSION';
  exception when sqlstate '55000' then
    if sqlerrm <> 'SALES_ORDER_PI_FROZEN' then raise; end if;
  end;

  -- PI cancellation is governed and idempotent (document cancel semantics at PI layer)
  set local role postgres;
  insert into public.orders (company_id, status, order_origin, tracking_token)
  values (v_company, 'submitted', 'MANUAL', md5(random()::text))
  returning id into v_cancel_order;
  insert into public.order_items (order_id, product_id, quantity, pack_size, carton_type)
  values (v_cancel_order, v_product_a, 5, 'kg', 'carton') returning id into v_cancel_item;
  perform public.recalculate_governed_sales_order_financials_v1(v_cancel_order);
  v_cancel_version := public.create_sales_order_commercial_version_v1(
    v_cancel_order, 'POINT75_CANCEL_PREP', 'point75:cancel:prep', 'point75-cancel-version', v_actor
  );
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  select pi_id into v_cancel_pi from public.create_sales_order_proforma_invoice_v1(
    v_cancel_order, v_cancel_version, 'POINT75_PI_CANCEL', 'MANUAL', 'point75:pi:cancel:create', 'point75-pi-cancel-create', v_actor
  );
  perform public.cancel_sales_order_proforma_invoice_v1(
    v_cancel_pi, 'POINT75_CANCEL', 'MANUAL', 'point75:pi:cancel', 'point75-pi-cancel', v_actor
  );
  if (select count(*) from public.cancel_sales_order_proforma_invoice_v1(
        v_cancel_pi, 'POINT75_CANCEL', 'MANUAL', 'point75:pi:cancel', 'point75-pi-cancel', v_actor
      )) <> 1 then
    raise exception 'POINT75 PI CANCEL IDEMPOTENCY REGRESSION';
  end if;

  -- Non-staff cannot amend
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  begin
    perform * from public.amend_sales_order_commercial_v1(
      v_order, 2,
      jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'quantity', 5)),
      'POINT75_BUYER', 'point75:buyer', 'point75-buyer'
    );
    raise exception 'POINT75 BUYER AMEND REGRESSION';
  exception when sqlstate '42501' then
    if sqlerrm <> 'COMMERCIAL_AMENDMENT_AUTHORITY_REQUIRED' then raise; end if;
  end;

  reset role;
end $$;

select pass('Point75 governed amendment/substitution/cancel boundary contract is behaviorally closed');
select * from finish();
rollback;
