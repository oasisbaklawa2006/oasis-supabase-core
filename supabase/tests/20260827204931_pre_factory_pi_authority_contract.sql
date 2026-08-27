-- Contract coverage for migration 20260827204931_pre_factory_pi_authority.
begin;

select plan(27);

select has_table('public', 'sales_order_proforma_invoices', 'Core PI authority table exists');
select has_table('public', 'sales_order_proforma_invoice_idempotency', 'PI idempotency ledger exists');
select has_table('public', 'sales_order_proforma_invoice_audit', 'PI audit ledger exists');
select has_function('public', 'create_sales_order_proforma_invoice_v1', array['uuid','uuid','text','text','text','text','uuid'], 'governed PI creation RPC exists');
select has_function('public', 'issue_sales_order_proforma_invoice_v1', array['uuid','text','text','text','text','uuid'], 'governed PI issuance RPC exists');
select has_function('public', 'cancel_sales_order_proforma_invoice_v1', array['uuid','text','text','text','text','uuid'], 'governed PI cancellation RPC exists');
select has_view('public', 'sales_order_proforma_invoice_authority_v1', 'Central read contract exists');
select ok((select relrowsecurity from pg_class where oid = 'public.sales_order_proforma_invoices'::regclass), 'PI authority has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.sales_order_proforma_invoice_audit'::regclass), 'PI audit has RLS enabled');
select ok(not has_function_privilege('anon', 'public.create_sales_order_proforma_invoice_v1(uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'anon cannot create PIs');
select ok(not has_function_privilege('anon', 'public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)', 'EXECUTE'), 'anon cannot issue PIs');
select ok(has_function_privilege('authenticated', 'public.create_sales_order_proforma_invoice_v1(uuid,uuid,text,text,text,text,uuid)', 'EXECUTE'), 'authenticated retains governed PI creation execute');
select ok(has_function_privilege('authenticated', 'public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)', 'EXECUTE'), 'authenticated retains governed PI issuance execute');
select ok(not has_table_privilege('authenticated', 'public.sales_order_proforma_invoices', 'INSERT'), 'authenticated cannot directly insert PIs');
select ok(not has_table_privilege('authenticated', 'public.sales_order_proforma_invoices', 'UPDATE'), 'authenticated cannot directly update PIs');
select ok(not has_table_privilege('authenticated', 'public.sales_order_proforma_invoices', 'DELETE'), 'authenticated cannot directly delete PIs');
select ok(not has_table_privilege('service_role', 'public.sales_order_proforma_invoices', 'INSERT'), 'service_role cannot directly insert PIs');
select ok(not has_table_privilege('service_role', 'public.sales_order_proforma_invoice_audit', 'INSERT'), 'service_role cannot directly insert PI audit rows');
select ok(has_table_privilege('service_role', 'public.sales_order_proforma_invoices', 'SELECT'), 'service_role retains PI read access');
select ok((select 'security_invoker=true' = any(coalesce(reloptions, '{}')) from pg_class where oid = 'public.sales_order_proforma_invoice_authority_v1'::regclass), 'Central PI view is security invoker');
select ok((select pg_get_constraintdef(oid) like '%customer_visible_pi_number IS NULL%' from pg_constraint where conname = 'sales_order_proforma_invoices_customer_visible_pi_number_check'), 'customer-visible PI number is fail-closed absent');

do $$
declare
  v_actor uuid := '91000000-0000-0000-0000-000000000011';
  v_unauthorized uuid := '91000000-0000-0000-0000-000000000012';
  v_company uuid := '91000000-0000-0000-0000-000000000001';
  v_product uuid := '91000000-0000-0000-0000-000000000002';
  v_order uuid := '91000000-0000-0000-0000-000000000003';
  v_item uuid := '91000000-0000-0000-0000-000000000004';
  v_cancel_order uuid := '91000000-0000-0000-0000-000000000005';
  v_cancel_item uuid := '91000000-0000-0000-0000-000000000006';
  v_version uuid;
  v_cancel_version uuid;
  v_pi uuid;
  v_retry uuid;
  v_issue uuid;
  v_issue_retry uuid;
  v_cancel_pi uuid;
  v_cancel_retry uuid;
  v_amended uuid;
begin
  set local session_replication_role = replica;
  insert into auth.users(id, email) values
    (v_actor, 'pf5-finance@test.invalid'),
    (v_unauthorized, 'pf5-sales@test.invalid');
  insert into public.users(id, role, name, is_active) values
    (v_actor, 'FINANCE_EXEC', 'PF5 Finance', true),
    (v_unauthorized, 'SALES_EXECUTIVE', 'PF5 Sales', true);
  insert into public.companies(id, business_name, status) values (v_company, 'PF5 Contract Co', 'active');
  insert into public.products(id, sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
  values (v_product, 'PF5-SKU-1', 'PF5 Product', 'PF5 Product', 'Bakery', '19059090', true, true, true, 1, 1, 650, 650);
  insert into public.product_pricing_rules(product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
  values (v_product, 'b2b', 'approved', 650, 650, 'INR', 'kg', 18, false);
  insert into public.product_moq_rules(product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 1, 1, 1);
  insert into public.orders(id, company_id, status, order_origin, order_number, tracking_token)
  values (v_order, v_company, 'submitted', 'SALES', 'SO-PF5-1', md5(random()::text));
  insert into public.order_items(id, order_id, product_id, quantity, pack_size, carton_type)
  values (v_item, v_order, v_product, 10, 'kg', 'carton');
  insert into public.orders(id, company_id, status, order_origin, order_number, tracking_token)
  values (v_cancel_order, v_company, 'submitted', 'MANUAL', 'SO-PF5-CANCEL', md5(random()::text));
  insert into public.order_items(id, order_id, product_id, quantity, pack_size, carton_type)
  values (v_cancel_item, v_cancel_order, v_product, 10, 'kg', 'carton');
  set local session_replication_role = default;

  perform public.recalculate_governed_sales_order_financials_v1(v_order);
  perform public.recalculate_governed_sales_order_financials_v1(v_cancel_order);
  v_version := public.create_sales_order_commercial_version_v1(v_order, 'PF5_PREPARE', 'pf5:so:1', 'pf5-so-version-1', v_actor);
  v_cancel_version := public.create_sales_order_commercial_version_v1(v_cancel_order, 'PF5_PREPARE', 'pf5:so:cancel', 'pf5-so-version-cancel', v_actor);

  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  select pi_id into v_pi from public.create_sales_order_proforma_invoice_v1(v_order, v_version, 'PF5_CREATE', 'SALES', 'pf5:create:1', 'pf5-create-1', v_actor);
  select pi_id into v_retry from public.create_sales_order_proforma_invoice_v1(v_order, v_version, 'PF5_CREATE', 'SALES', 'pf5:create:1', 'pf5-create-1', v_actor);
  if v_pi is distinct from v_retry then raise exception 'PI_CREATE_IDEMPOTENCY_REGRESSION'; end if;
  select pi_id into v_issue from public.issue_sales_order_proforma_invoice_v1(v_pi, 'PF5_ISSUE', 'SALES', 'pf5:issue:1', 'pf5-issue-1', v_actor);
  select pi_id into v_issue_retry from public.issue_sales_order_proforma_invoice_v1(v_pi, 'PF5_ISSUE', 'SALES', 'pf5:issue:1', 'pf5-issue-1', v_actor);
  if v_issue is distinct from v_issue_retry then raise exception 'PI_ISSUE_IDEMPOTENCY_REGRESSION'; end if;
  select pi_id into v_cancel_pi from public.create_sales_order_proforma_invoice_v1(v_cancel_order, v_cancel_version, 'PF5_CREATE', 'MANUAL', 'pf5:create:cancel', 'pf5-create-cancel', v_actor);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  select pi_id into v_cancel_retry from public.cancel_sales_order_proforma_invoice_v1(v_cancel_pi, 'PF5_CANCEL', 'MANUAL', 'pf5:cancel:1', 'pf5-cancel-1', v_actor);
  select pi_id into v_cancel_retry from public.cancel_sales_order_proforma_invoice_v1(v_cancel_pi, 'PF5_CANCEL', 'MANUAL', 'pf5:cancel:1', 'pf5-cancel-1', v_actor);
  reset role;
  if v_cancel_retry is distinct from v_cancel_pi then raise exception 'PI_CANCEL_IDEMPOTENCY_REGRESSION'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_unauthorized::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  begin
    perform public.issue_sales_order_proforma_invoice_v1(v_pi, 'PF5_UNAUTHORIZED', 'SALES', 'pf5:issue:unauthorized', 'pf5-issue-unauthorized', v_unauthorized);
    raise exception 'PI_UNAUTHORIZED_ISSUE_REGRESSION';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  if (select status from public.sales_order_proforma_invoices where id = v_pi) <> 'ISSUED' then raise exception 'PI_ISSUANCE_REGRESSION'; end if;
  if (select commercial_version_id from public.sales_order_proforma_invoices where id = v_pi) is distinct from v_version then raise exception 'PI_VERSION_LINK_REGRESSION'; end if;
  if (select frozen_snapshot_fingerprint from public.sales_order_proforma_invoices where id = v_pi)
     is distinct from (select snapshot_fingerprint from public.sales_order_commercial_versions where id = v_version) then raise exception 'PI_FINGERPRINT_REGRESSION'; end if;
  if (select customer_visible_pi_number from public.sales_order_proforma_invoices where id = v_pi) is not null then raise exception 'PI_NUMBER_ASSIGNED_REGRESSION'; end if;
  if (select (frozen_commercial_snapshot ->> 'advance_required')::numeric from public.sales_order_proforma_invoices where id = v_pi) <> 2500 then raise exception 'PI_ADVANCE_RULE_REGRESSION'; end if;
  if (select frozen_commercial_snapshot from public.sales_order_proforma_invoices where id = v_pi)
     is distinct from (select commercial_snapshot from public.sales_order_commercial_versions where id = v_version) then raise exception 'PI_SOURCE_CONVERGENCE_REGRESSION'; end if;
  if (select count(*) from public.sales_order_proforma_invoice_audit where pi_id = v_pi and action in ('CREATED','ISSUED')) <> 2 then raise exception 'PI_AUDIT_REGRESSION'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  begin
    update public.sales_order_proforma_invoices set status = 'CANCELLED' where id = v_pi;
    raise exception 'PI_DIRECT_MUTATION_REGRESSION';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.issue_sales_order_proforma_invoice_v1(v_pi, 'PF5_REISSUE', 'SALES', 'pf5:issue:other', 'pf5-issue-other', v_actor);
    raise exception 'PI_REISSUE_REGRESSION';
  exception when sqlstate '55000' then null;
  end;
  begin
    perform public.amend_sales_order_commercial_v1(v_order, 1, jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'product_id', v_product, 'quantity', 11)), 'PF5_AFTER_PI', 'pf5:amend:after', 'pf5-amend-after');
    raise exception 'SO_PI_FREEZE_REGRESSION';
  exception when sqlstate '55000' then null;
  end;
  reset role;

  update public.orders set status = 'cancelled' where id = v_cancel_order;
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  begin
    perform public.issue_sales_order_proforma_invoice_v1(v_cancel_pi, 'PF5_CANCELLED', 'MANUAL', 'pf5:issue:cancel', 'pf5-issue-cancel', v_actor);
    raise exception 'CANCELLED_ORDER_PI_REGRESSION';
  exception when sqlstate '55000' then null;
  end;
  begin
    perform public.create_sales_order_proforma_invoice_v1(v_cancel_order, v_cancel_version, 'PF5_CREATE', 'MANUAL', 'pf5:cross', 'pf5-create-1', v_actor);
    raise exception 'CROSS_PI_IDEMPOTENCY_REGRESSION';
  exception when unique_violation then null;
  end;
  reset role;
end $$;

select ok((select status = 'ISSUED' from public.sales_order_proforma_invoices where idempotency_key = 'pf5-create-1'), 'PI is issued through the governed RPC');
select ok((select status = 'CANCELLED' from public.sales_order_proforma_invoices where idempotency_key = 'pf5-create-cancel'), 'PI cancellation is governed and terminal');
select ok((select cancellation_reason = 'PF5_CANCEL' and cancelled_by = '91000000-0000-0000-0000-000000000011'::uuid from public.sales_order_proforma_invoices where idempotency_key = 'pf5-create-cancel'), 'PI cancellation records actor and reason');
select ok((select count(*) = 1 from public.sales_order_proforma_invoice_audit where idempotency_key = 'pf5-cancel-1' and action = 'CANCELLED'), 'PI cancellation writes one audit event despite retry');
select ok((select count(*) = 1 from public.sales_order_proforma_invoices where commercial_version_id = (select commercial_version_id from public.sales_order_proforma_invoices where idempotency_key = 'pf5-create-1')), 'one canonical PI exists per exact SO commercial version');
select ok(pg_get_functiondef('public.create_sales_order_proforma_invoice_v1(uuid,uuid,text,text,text,text,uuid)'::regprocedure) not like '%LEGACY_ERP%', 'PI creation does not select legacy commercial semantics');

select * from finish();
rollback;
