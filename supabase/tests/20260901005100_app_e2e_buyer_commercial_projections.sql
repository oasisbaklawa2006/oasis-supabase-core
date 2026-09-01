-- Contract for 20260901005100_app_e2e_buyer_commercial_projections.sql.

select plan(14);

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
    like '%version_number=o.commercial_current_version%',
  'SO projection is company-scoped and bound to the canonical current commercial version'
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
    like '%p.frozen_commercial_snapshot%''sales_order_value''%',
  'PI projection reveals a number only after ISSUE and totals only from frozen commercial truth'
);

select ok(
  pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%b.company_id=o.company_id%',
  'PI projection cannot cross the authenticated buyer-company boundary'
);

select ok(
  pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%get_order_payment_facts_v1(v_pi.id)%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%wallet_transactions%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%credit_requests%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%finance_clearance_events%',
  'Finance projection composes existing payment, wallet, credit and clearance authorities'
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

select * from finish();
