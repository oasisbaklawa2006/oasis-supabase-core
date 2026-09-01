-- Contract for 20260901005700_app_e2e_order_creation_scope_hardening.sql.

select plan(16);

select has_table('public','sales_order_creation_scopes',
  'private transaction-local SO creation scope table exists');

select ok(
  (select relrowsecurity from pg_class where oid='public.sales_order_creation_scopes'::regclass),
  'SO creation scope table has RLS enabled'
);

select ok(
  not has_table_privilege('authenticated','public.sales_order_creation_scopes','SELECT')
  and not has_table_privilege('authenticated','public.sales_order_creation_scopes','INSERT')
  and not has_table_privilege('service_role','public.sales_order_creation_scopes','INSERT'),
  'browser and service roles cannot mint or inspect SO creation scopes'
);

select ok(
  coalesce((
    select bool_or(
      pg_get_constraintdef(oid) like '%CUSTOMER_CHECKOUT%'
      and pg_get_constraintdef(oid) like '%WHATSAPP_DRAFT_PROMOTION%'
    )
    from pg_constraint
    where conrelid='public.sales_order_creation_scopes'::regclass
      and contype='c'
  ),false),
  'scope vocabulary is restricted to the two canonical order creation authorities'
);

select ok(
  pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%sales_order_creation_scopes%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%pg_backend_pid()%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%txid_current()%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%SALES_ORDER_CREATION_RPC_REQUIRED%',
  'SO trigger requires the private backend+transaction capability before runtime allocation'
);

select ok(
  pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%session_user=''postgres''%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%auth.uid() IS NULL%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%request.jwt.claim.role%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%request.jwt.claim.sub%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%v_authority IS NULL%',
  'explicit fixture identity is limited to direct no-JWT postgres maintenance context, not SECURITY DEFINER runtime'
);

select ok(
  pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%SO_NUMBER_SERVER_ASSIGNED%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%allocate_commercial_document_number_v1(''SO'')%',
  'runtime caller-supplied SO numbers fail closed and approved runtime creation uses canonical allocator'
);

select ok(
  pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure)
    like '%sales_order_creation_scopes%'
  and pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure)
    like '%CUSTOMER_CHECKOUT%'
  and pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure)
    like '%ORDER BY d.updated_at DESC, d.created_at DESC, d.id%'
  and pg_get_functiondef('public.submit_customer_order_v1(text,date)'::regprocedure)
    like '%DELETE FROM public.sales_order_creation_scopes%',
  'Buyer checkout opens and closes only the CUSTOMER_CHECKOUT transaction scope and selects the active draft deterministically'
);

select ok(
  pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure)
    like '%sales_order_creation_scopes%'
  and pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure)
    like '%WHATSAPP_DRAFT_PROMOTION%'
  and pg_get_functiondef('public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)'::regprocedure)
    like '%DELETE FROM public.sales_order_creation_scopes%',
  'WhatsApp promotion opens and closes only the WHATSAPP_DRAFT_PROMOTION transaction scope'
);

select is(
  (select count(*)::integer
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.prokind='f'
     and p.prosrc ~* 'insert[[:space:]]+into[[:space:]]+(public[[:space:]]*\.)?[[:space:]]*orders([[:space:]]*\(|;)'),
  2,
  'only the two canonical public functions insert into orders'
);

select ok(
  (select bool_and(
      pg_get_functiondef(p.oid) like '%sales_order_creation_scopes%'
    )
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.prokind='f'
     and p.prosrc ~* 'insert[[:space:]]+into[[:space:]]+(public[[:space:]]*\.)?[[:space:]]*orders([[:space:]]*\(|;)'),
  'every live public order-creation function is bound to the private scope'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='customer_order_drafts'
      and indexname='uq_customer_order_drafts_one_active_per_company'
  ),
  'one active customer draft per company is enforced by partial unique index'
);

select ok(
  has_function_privilege('authenticated','public.submit_customer_order_v1(text,date)','EXECUTE'),
  'Buyer checkout execution privilege is preserved'
);

select ok(
  has_function_privilege('service_role','public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)','EXECUTE')
  and not has_function_privilege('authenticated','public.promote_sales_order_draft_to_order_governed_v1(uuid,text,uuid,text,text,jsonb)','EXECUTE'),
  'WhatsApp promotion retains service-role-only execution authority'
);

select ok(
  not has_function_privilege('authenticated','public.allocate_commercial_document_number_v1(text)','EXECUTE')
  and not has_function_privilege('service_role','public.allocate_commercial_document_number_v1(text)','EXECUTE'),
  'document allocator remains private despite scoped order creation'
);

begin;

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_product uuid;
  v_order_number text;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Scope Census Co', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'scope-census@example.com');
  insert into public.users (id, email, role, company_id)
  values (v_buyer, 'scope-census@example.com', 'b2b_buyer', v_company);
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'scope-census@example.com');
  insert into public.products (
    sku, product_name, name, category, hsn_code,
    is_active, visible_in_catalog, is_catalogue_ready,
    moq_value, increment_value, base_price, price_b2b
  ) values (
    'SCOPE-SKU-1', 'Scope Product', 'Scope Product', 'Bakery', '19059090',
    true, true, true, 1, 1, 400, 400
  ) returning id into v_product;
  insert into public.product_pricing_rules (
    product_id, price_channel, approval_status, base_price, calculated_price, currency, uom, gst_rate, tax_inclusive
  ) values (v_product, 'b2b', 'approved', 400, 400, 'INR', 'kg', 18, false);
  insert into public.product_moq_rules (product_id, channel, moq_applicable, moq_value, increment_value, min_carton_qty)
  values (v_product, 'b2b', true, 1, 1, 1);

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.add_customer_order_draft_line_v1(v_product, 2);

  select order_number into v_order_number
  from public.submit_customer_order_v1('scope-checkout-key-1', current_date)
  limit 1;

  if v_order_number is null or v_order_number !~ '^SO[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{4}$' then
    raise exception 'BUYER_CHECKOUT_CANONICAL_SO_REGRESSION: %', v_order_number;
  end if;

  begin
    insert into public.sales_order_creation_scopes(backend_pid, transaction_id, authority)
    values (pg_backend_pid(), txid_current(), 'CUSTOMER_CHECKOUT');
    raise exception 'SCOPE_MINT_REGRESSION';
  exception when insufficient_privilege or sqlstate '42501' then
    null;
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('Buyer checkout remains a scoped canonical writer and authenticated users cannot mint scopes directly');

select * from finish();
rollback;
