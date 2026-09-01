-- APP-E2E buyer contract certification for 20260901005100..20260901005300.

select plan(30);

select ok(
  to_regprocedure('public.customer_sales_order_commercial_facts_v1()') is not null,
  'buyer Sales Order commercial projection exists'
);

select ok(
  (select prosecdef and provolatile='s' from pg_proc where oid='public.customer_sales_order_commercial_facts_v1()'::regprocedure)
  and has_function_privilege('authenticated','public.customer_sales_order_commercial_facts_v1()','EXECUTE')
  and not has_function_privilege('service_role','public.customer_sales_order_commercial_facts_v1()','EXECUTE'),
  'Sales Order projection is stable SECURITY DEFINER and user-session only'
);

select ok(
  pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%'
  and pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%commercial_current_version%'
  and pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%finance_clearance_events%',
  'Sales Order projection composes buyer company, current commercial version and canonical Finance clearance'
);

select ok(
  pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%WHEN ''GRANTED'' THEN ''cleared''%'
  and pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%WHEN ''DENIED'' THEN ''hold''%'
  and pg_get_functiondef('public.customer_sales_order_commercial_facts_v1()'::regprocedure)
    like '%WHEN ''REVOKED'' THEN ''clearance_revoked''%',
  'buyer Finance status maps canonical GRANTED/DENIED/REVOKED decisions without shadow state'
);

select ok(
  to_regprocedure('public.customer_proforma_invoice_facts_v1()') is not null,
  'buyer PI projection exists'
);

select ok(
  pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%CASE WHEN p.status=''ISSUED'' THEN p.customer_visible_pi_number ELSE NULL END%'
  and pg_get_functiondef('public.customer_proforma_invoice_facts_v1()'::regprocedure)
    like '%frozen_commercial_snapshot%',
  'PI projection exposes no predicted number and derives total from frozen commercial truth'
);

select ok(
  has_function_privilege('authenticated','public.customer_proforma_invoice_facts_v1()','EXECUTE')
  and not has_function_privilege('service_role','public.customer_proforma_invoice_facts_v1()','EXECUTE'),
  'PI projection is authenticated buyer-session only'
);

select ok(
  to_regprocedure('public.customer_order_finance_facts_v1(uuid)') is not null,
  'buyer order Finance projection exists'
);

select ok(
  pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%company_id=v_company_id%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    like '%get_order_payment_facts_v1%'
  and pg_get_functiondef('public.customer_order_finance_facts_v1(uuid)'::regprocedure)
    not like '%''external_reference''%',
  'buyer Finance facts are same-company scoped, compose canonical payment truth and omit payment references'
);

select ok(
  to_regprocedure('public.customer_documents_v1()') is not null,
  'buyer documents projection exists'
);

select ok(
  pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%''SALES_ORDER''%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%''PROFORMA_INVOICE''%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%''FINAL_INVOICE''%',
  'documents projection covers SO, PI and final invoice from canonical sources'
);

select ok(
  pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    not like '%document_reference%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    not like '%storage%'
  and not has_function_privilege('service_role','public.customer_documents_v1()','EXECUTE'),
  'documents projection does not expose internal document/storage references and is user-session only'
);

select ok(
  to_regprocedure('public.customer_statement_v1()') is not null
  and pg_get_functiondef('public.customer_statement_v1()'::regprocedure)
    like '%get_customer_financial_360_v1%'
  and pg_get_functiondef('public.customer_statement_v1()'::regprocedure)
    like '%commercial_closure_id%',
  'customer statement composes canonical financial 360 and explicitly strips internal closure id'
);

select has_table('public','customer_product_favourites',
  'durable buyer favourites table exists');

select ok(
  (select relrowsecurity from pg_class where oid='public.customer_product_favourites'::regclass)
  and not has_table_privilege('authenticated','public.customer_product_favourites','SELECT')
  and not has_table_privilege('authenticated','public.customer_product_favourites','INSERT')
  and not has_table_privilege('service_role','public.customer_product_favourites','UPDATE'),
  'favourites are RLS-enabled and have no raw browser/service-role mutation surface'
);

select ok(
  to_regprocedure('public.set_customer_product_favourite_v1(uuid,boolean)') is not null
  and pg_get_functiondef('public.set_customer_product_favourite_v1(uuid,boolean)'::regprocedure)
    like '%customer_buyer_eligible_company_id%'
  and pg_get_functiondef('public.set_customer_product_favourite_v1(uuid,boolean)'::regprocedure)
    like '%customer_resolve_buyer_product_authority_v1%',
  'favourite mutation requires eligible buyer company and current product authority'
);

select ok(
  pg_get_functiondef('public.customer_product_favourites_v1()'::regprocedure)
    like '%f.user_id=auth.uid()%'
  and pg_get_functiondef('public.customer_product_favourites_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'favourite reads are scoped to exact buyer user and eligible company'
);

select has_table('public','customer_general_queries',
  'general non-order enquiry table exists');

select ok(
  not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='customer_general_queries' and column_name='order_id'
  ),
  'general enquiry state has deliberately no order_id'
);

select ok(
  (select relrowsecurity from pg_class where oid='public.customer_general_queries'::regclass)
  and not has_table_privilege('authenticated','public.customer_general_queries','SELECT')
  and not has_table_privilege('authenticated','public.customer_general_queries','INSERT')
  and not has_table_privilege('service_role','public.customer_general_queries','UPDATE'),
  'general enquiry table is private behind governed RPCs'
);

select ok(
  to_regprocedure('public.submit_customer_general_query_v1(text,text,text,text)') is not null
  and pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    like '%pg_advisory_xact_lock%'
  and pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    like '%GENERAL_QUERY_IDEMPOTENCY_CONFLICT%',
  'general enquiry capture is serialized and fail-closed on changed idempotent replay'
);

select ok(
  lower(pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure))
    not like '%insert into public.orders%'
  and lower(pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure))
    not like '%support_tickets%',
  'general enquiry capture cannot create an SO or broaden order-bound support tickets'
);

select has_table('public','customer_general_query_idempotency',
  'internal general-query lifecycle has private idempotency evidence');

select ok(
  (select relrowsecurity from pg_class where oid='public.customer_general_query_idempotency'::regclass)
  and not has_table_privilege('authenticated','public.customer_general_query_idempotency','SELECT')
  and not has_table_privilege('service_role','public.customer_general_query_idempotency','SELECT'),
  'general-query management idempotency evidence is not directly readable'
);

select ok(
  to_regprocedure('public.manage_customer_general_query_v1(uuid,text,text,text,uuid)') is not null
  and has_function_privilege('authenticated','public.manage_customer_general_query_v1(uuid,text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.manage_customer_general_query_v1(uuid,text,text,text,uuid)','EXECUTE'),
  'general-query lifecycle RPC exists only on authenticated user sessions'
);

select ok(
  pg_get_functiondef('public.manage_customer_general_query_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%is_internal_staff%'
  and pg_get_functiondef('public.manage_customer_general_query_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%v_query.status=''SUBMITTED''%''ACKNOWLEDGED''%''RESOLVED''%'
  and pg_get_functiondef('public.manage_customer_general_query_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%v_query.status=''RESOLVED'' AND v_target=''CLOSED''%',
  'query lifecycle requires internal staff and permits only forward status transitions'
);

select ok(
  pg_get_functiondef('public.manage_customer_general_query_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%v_target IN (''RESOLVED'',''CLOSED'') AND v_response IS NULL%'
  and pg_get_functiondef('public.manage_customer_general_query_v1(uuid,text,text,text,uuid)'::regprocedure)
    like '%GENERAL_QUERY_CUSTOMER_RESPONSE_REQUIRED%',
  'resolved or closed enquiry requires a customer-visible response'
);

select ok(
  pg_get_function_result('public.customer_general_queries_v1()'::regprocedure)
    like '%customer_response text%'
  and pg_get_function_result('public.customer_general_queries_v1()'::regprocedure)
    like '%responded_at timestamp with time zone%',
  'buyer enquiry read projection exposes resolution text and response timestamp'
);

select ok(
  pg_get_functiondef('public.support_ticket_set_customer_context()'::regprocedure)
    like '%order is not available to the authenticated company%'
  and pg_get_functiondef('public.support_ticket_set_customer_context()'::regprocedure)
    like '%o.id = new.order_id::uuid%',
  'existing support_tickets remain same-company order-bound after adding general queries'
);

select ok(
  has_function_privilege('authenticated','public.customer_general_queries_v1()','EXECUTE')
  and not has_function_privilege('service_role','public.customer_general_queries_v1()','EXECUTE'),
  'buyer enquiry list remains authenticated buyer-session only'
);

select ok(
  has_function_privilege('authenticated','public.customer_statement_v1()','EXECUTE')
  and has_function_privilege('authenticated','public.customer_documents_v1()','EXECUTE')
  and has_function_privilege('authenticated','public.customer_order_finance_facts_v1(uuid)','EXECUTE'),
  'buyer documents, statement and Finance facts are callable through governed authenticated RPCs'
);

select * from finish();
