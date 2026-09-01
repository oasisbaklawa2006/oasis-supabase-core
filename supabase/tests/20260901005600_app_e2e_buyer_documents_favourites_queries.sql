-- Contract for 20260901005600_app_e2e_buyer_documents_favourites_queries.sql.

begin;

select plan(19);

select has_function('public','customer_documents_v1',array[]::text[],
  'customer-safe document contract exists');
select has_function('public','customer_statement_v1',array[]::text[],
  'customer statement/ledger contract exists');

select ok(
  has_function_privilege('authenticated','public.customer_documents_v1()','EXECUTE')
  and not has_function_privilege('anon','public.customer_documents_v1()','EXECUTE')
  and not has_function_privilege('service_role','public.customer_documents_v1()','EXECUTE'),
  'documents are exposed only through the authenticated buyer contract'
);

select ok(
  pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    not like '%document_reference%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    not like '%proof_url%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    not like '%storage%',
  'document contract is company-scoped and leaks no storage/internal document reference'
);

select ok(
  pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%CASE WHEN p.status=''ISSUED'' THEN p.customer_visible_pi_number ELSE NULL END%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%CASE WHEN f.status=''ISSUED'' THEN f.invoice_number ELSE NULL END%',
  'PI and final-invoice numbers are never predicted before issuance'
);

select ok(
  pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%''preparing''%'
  and pg_get_functiondef('public.customer_documents_v1()'::regprocedure)
    like '%''unavailable''%',
  'not-yet-issued artifacts use safe preparing/unavailable states'
);

select ok(
  pg_get_functiondef('public.customer_statement_v1()'::regprocedure)
    like '%get_customer_financial_360_v1(v_company_id)%'
  and pg_get_functiondef('public.customer_statement_v1()'::regprocedure)
    like '%commercial_closure_id%',
  'statement composes canonical financial 360 and explicitly strips internal closure ids'
);

select has_table('public','customer_product_favourites',
  'durable buyer favourites table exists');

select ok(
  not has_table_privilege('authenticated','public.customer_product_favourites','SELECT')
  and not has_table_privilege('authenticated','public.customer_product_favourites','INSERT')
  and not has_table_privilege('service_role','public.customer_product_favourites','UPDATE'),
  'favourite storage has no raw browser/service-role mutation surface'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.customer_product_favourites'::regclass
      and contype='u'
      and pg_get_constraintdef(oid) like '%user_id, company_id, product_id%'
  ),
  'favourites are durable and unique by buyer user + company + product'
);

select ok(
  has_function_privilege('authenticated','public.set_customer_product_favourite_v1(uuid,boolean)','EXECUTE')
  and has_function_privilege('authenticated','public.customer_product_favourites_v1()','EXECUTE')
  and not has_function_privilege('anon','public.set_customer_product_favourite_v1(uuid,boolean)','EXECUTE'),
  'favourite mutations and reads are governed authenticated RPCs'
);

select ok(
  pg_get_functiondef('public.set_customer_product_favourite_v1(uuid,boolean)'::regprocedure)
    like '%customer_buyer_eligible_company_id%'
  and pg_get_functiondef('public.customer_product_favourites_v1()'::regprocedure)
    like '%f.user_id=auth.uid()%'
  and pg_get_functiondef('public.customer_product_favourites_v1()'::regprocedure)
    like '%f.company_id=public.customer_buyer_eligible_company_id()%'
  ,
  'favourites persist and read only in the intended buyer/company scope'
);

select has_table('public','customer_general_queries',
  'general non-order query capture table exists');

select ok(
  not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='customer_general_queries' and column_name='order_id'
  ),
  'general query truth deliberately has no order lineage column'
);

select ok(
  not has_table_privilege('authenticated','public.customer_general_queries','INSERT')
  and not has_table_privilege('authenticated','public.customer_general_queries','SELECT')
  and not has_table_privilege('service_role','public.customer_general_queries','UPDATE'),
  'general query storage is not directly writable/readable outside governed RPCs'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.customer_general_queries'::regclass
      and contype='u'
      and pg_get_constraintdef(oid) like '%company_id, user_id, idempotency_key%'
  )
  and pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    like '%pg_advisory_xact_lock%'
  and pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    like '%GENERAL_QUERY_IDEMPOTENCY_CONFLICT%',
  'general query submission is exactly-once and conflict-safe per buyer/company key'
);

select ok(
  pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    not like '%public.orders%'
  and pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    not like '%submit_customer_order_v1%'
  and pg_get_functiondef('public.submit_customer_general_query_v1(text,text,text,text)'::regprocedure)
    not like '%sales_order%',
  'general query submission cannot create or promote a Sales Order'
);

select ok(
  has_function_privilege('authenticated','public.submit_customer_general_query_v1(text,text,text,text)','EXECUTE')
  and has_function_privilege('authenticated','public.customer_general_queries_v1()','EXECUTE')
  and not has_function_privilege('anon','public.submit_customer_general_query_v1(text,text,text,text)','EXECUTE')
  and pg_get_functiondef('public.customer_general_queries_v1()'::regprocedure)
    like '%q.user_id=auth.uid()%q.company_id=public.customer_buyer_eligible_company_id()%'
  ,
  'general enquiry create/read contracts are authenticated and buyer-company scoped'
);

begin;

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_statement jsonb;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Statement Privacy Co', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'statement-privacy@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'statement-privacy@example.com');

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_statement := public.customer_statement_v1();

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_statement->'entries', '[]'::jsonb)) e(value)
    where e.value ? 'commercial_closure_id'
  ) then
    raise exception 'STATEMENT_PRIVACY_REGRESSION: commercial_closure_id leaked to buyer statement';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('customer_statement_v1 strips internal commercial closure identifiers behaviorally');

select * from finish();
rollback;
