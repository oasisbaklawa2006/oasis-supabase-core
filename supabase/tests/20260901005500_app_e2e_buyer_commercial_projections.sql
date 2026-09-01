-- Contract for 20260901005500_app_e2e_buyer_commercial_projections.sql.

select plan(20);

select has_function('public','derive_customer_order_finance_status_v1',array['text','uuid','text','numeric','numeric'],
  'canonical buyer finance status helper exists');
select has_function('public','customer_sales_order_commercial_facts_v1',array[]::text[],
  'buyer-safe SO commercial projection exists');
select has_function('public','customer_proforma_invoice_facts_v1',array[]::text[],
  'buyer-safe PI projection exists');
select has_function('public','customer_order_finance_facts_v1',array['uuid'],
  'buyer-safe order Finance projection exists');

select ok(
  has_function_privilege('authenticated','public.customer_sales_order_commercial_facts_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_sales_order_commercial_facts_v1()','EXECUTE')
  and not has_function_privilege('service_role','public.customer_sales_order_commercial_facts_v1()','EXECUTE'),
  'SO projection is an authenticated buyer surface only'
);

select ok(
  has_function_privilege('authenticated','public.customer_proforma_invoice_facts_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_proforma_invoice_facts_v1()','EXECUTE'),
  'PI projection is authenticated and never anonymous'
);

select ok(
  has_function_privilege('authenticated','public.customer_order_finance_facts_v1(uuid)','EXECUTE')
  and not has_function_privilege('anon','public.customer_order_finance_facts_v1(uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.customer_order_finance_facts_v1(uuid)','EXECUTE'),
  'customer Finance projection is not an anonymous/service-role convenience bypass'
);

select ok(
  pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%'
  and pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%derive_customer_order_finance_status_v1%',
  'SO projection is company-scoped and uses the canonical finance status helper'
);

select ok(
  pg_get_function_result('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%order_number text%commercial_version_id uuid%commercial_version_number integer%frozen_sales_order_value numeric%requested_dispatch_date date%promised_dispatch_date date%commercial_status text%finance_status text%',
  'SO projection exposes required customer-safe identity, frozen value, dates and statuses'
);

select ok(
  pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%CASE WHEN p.status=''ISSUED'' THEN p.customer_visible_pi_number ELSE NULL END%'
  and pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%p.status IN (''READY_FOR_ISSUE'',''ISSUED'')%'
  and pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%p.frozen_commercial_snapshot%''sales_order_value''%',
  'PI projection exposes only READY_FOR_ISSUE and ISSUED rows and reveals a number only after ISSUE'
);

select ok(
  pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%b.company_id=o.company_id%',
  'PI projection cannot cross the authenticated buyer-company boundary'
);

select ok(
  pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%derive_customer_order_finance_status_v1%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%get_order_payment_facts_v1(v_pi.id)%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%wallet_transactions%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%credit_requests%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%finance_clearance_events%',
  'Finance projection composes existing payment, wallet, credit and clearance authorities through the shared helper'
);

select ok(
  pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%r.reversal_of_id=w.id%',
  'customer wallet coverage excludes reversed governed debits'
);

select ok(
  pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%company_id=v_company_id%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%BUYER_FINANCE_ORDER_NOT_AVAILABLE%',
  'cross-company order Finance access fails closed'
);

select ok(
  pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    not like '%external_reference%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    not like '%source_reference%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    not like '%latest_clearance_event_id%'
  and pg_get_function_result('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    not like '%jsonb%',
  'buyer projections omit payment references, internal event ids and raw commercial snapshots'
);

begin;

do $$
declare
  v_company_a uuid;
  v_company_b uuid;
  v_buyer_a uuid := gen_random_uuid();
  v_buyer_b uuid := gen_random_uuid();
  v_finance uuid := gen_random_uuid();
  v_product uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_item uuid := gen_random_uuid();
  v_version uuid;
  v_pi_ready uuid;
  v_pi_draft uuid;
  v_pi_cancelled uuid;
  v_list_status text;
  v_detail_status text;
begin
  set local session_replication_role = replica;

  insert into public.companies (id, business_name, status) values
    (gen_random_uuid(), 'Buyer Facts Co A', 'active') returning id into v_company_a;
  insert into public.companies (id, business_name, status) values
    (gen_random_uuid(), 'Buyer Facts Co B', 'active') returning id into v_company_b;
  insert into auth.users (id, email) values
    (v_buyer_a, 'buyer-facts-a@example.com'),
    (v_buyer_b, 'buyer-facts-b@example.com'),
    (v_finance, 'buyer-facts-finance@example.com');
  insert into public.users (id, role, name, is_active) values
    (v_finance, 'FINANCE_EXEC', 'Buyer Facts Finance', true);
  insert into public.profiles (id, company_id, role, is_approved, status, email) values
    (v_buyer_a, v_company_a, 'b2b_buyer', true, 'approved', 'buyer-facts-a@example.com'),
    (v_buyer_b, v_company_b, 'b2b_buyer', true, 'approved', 'buyer-facts-b@example.com');
  insert into public.products (id, sku, product_name, name, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, moq_value, increment_value, base_price, price_b2b)
  values (v_product, 'BF-SKU-1', 'Buyer Facts Product', 'Buyer Facts Product', 'Bakery', '19059090', true, true, true, 1, 1, 500, 500);
  insert into public.product_pricing_rules (product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive)
  values (v_product, 'b2b', 'approved', 500, 500, 'INR', 'kg', 18, false);
  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 1, 1, 1);
  insert into public.orders (id, company_id, status, order_origin, order_number, tracking_token)
  values (v_order, v_company_a, 'submitted', 'CUSTOMER_APP', 'SO-BF-1', md5(random()::text));
  insert into public.order_items (id, order_id, product_id, quantity, pack_size, carton_type)
  values (v_item, v_order, v_product, 5, 'kg', 'carton');

  set local session_replication_role = default;

  perform public.recalculate_customer_app_order_financials(v_order);
  v_version := public.create_sales_order_commercial_version_v1(
    v_order, 'BUYER_FACTS_TEST', 'buyer-facts:so:1', 'buyer-facts-version-1', v_finance
  );

  set local session_replication_role = replica;
  insert into public.sales_order_proforma_invoices (
    id, order_id, commercial_version_id, commercial_version_number, status,
    frozen_commercial_snapshot, frozen_snapshot_fingerprint, reason, source, correlation_id, idempotency_key
  )
  select gen_random_uuid(), v_order, v_version, 1, 'READY_FOR_ISSUE',
    v.commercial_snapshot, v.snapshot_fingerprint, 'BF_READY', 'TEST', 'bf:ready', 'bf-ready-1'
  from public.sales_order_commercial_versions v where v.id = v_version
  returning id into v_pi_ready;

  insert into public.sales_order_proforma_invoices (
    id, order_id, commercial_version_id, commercial_version_number, status,
    frozen_commercial_snapshot, frozen_snapshot_fingerprint, reason, source, correlation_id, idempotency_key
  )
  select gen_random_uuid(), v_order, v_version, 1, 'DRAFT',
    v.commercial_snapshot, v.snapshot_fingerprint, 'BF_DRAFT', 'TEST', 'bf:draft', 'bf-draft-1'
  from public.sales_order_commercial_versions v where v.id = v_version
  returning id into v_pi_draft;

  insert into public.sales_order_proforma_invoices (
    id, order_id, commercial_version_id, commercial_version_number, status,
    frozen_commercial_snapshot, frozen_snapshot_fingerprint, reason, source, correlation_id, idempotency_key
  )
  select gen_random_uuid(), v_order, v_version, 1, 'CANCELLED',
    v.commercial_snapshot, v.snapshot_fingerprint, 'BF_CANCEL', 'TEST', 'bf:cancel', 'bf-cancel-1'
  from public.sales_order_commercial_versions v where v.id = v_version
  returning id into v_pi_cancelled;
  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  if exists (
    select 1 from public.customer_proforma_invoice_facts_v1()
    where pi_id in (v_pi_draft, v_pi_cancelled)
  ) then
    raise exception 'PI_VISIBILITY_REGRESSION: DRAFT/CANCELLED PIs must not appear in buyer projection';
  end if;

  if not exists (
    select 1 from public.customer_proforma_invoice_facts_v1()
    where pi_id = v_pi_ready and status = 'READY_FOR_ISSUE' and customer_visible_pi_number is null
  ) then
    raise exception 'PI_VISIBILITY_REGRESSION: READY_FOR_ISSUE PI must be visible without customer number';
  end if;

  select finance_status into v_list_status
  from public.customer_sales_order_commercial_facts_v1()
  where order_id = v_order;

  v_detail_status := public.customer_order_finance_facts_v1(v_order)->>'finance_status';

  if v_list_status is distinct from v_detail_status then
    raise exception 'FINANCE_STATUS_PARITY_REGRESSION: list=% detail=%', v_list_status, v_detail_status;
  end if;

  begin
    perform public.customer_order_finance_facts_v1(v_order);
    perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_b::text, 'role', 'authenticated')::text, true);
    perform public.customer_order_finance_facts_v1(v_order);
    raise exception 'CROSS_COMPANY_FINANCE_REGRESSION';
  exception when sqlstate '42501' then
    null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('buyer PI visibility, finance status parity and cross-company finance isolation hold behaviorally');

select * from finish();
rollback;
