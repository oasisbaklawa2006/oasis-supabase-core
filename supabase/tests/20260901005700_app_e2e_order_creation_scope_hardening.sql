-- Contract for 20260901005300_app_e2e_order_creation_scope_hardening.sql.

select plan(14);

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
    like '%DELETE FROM public.sales_order_creation_scopes%',
  'Buyer checkout opens and closes only the CUSTOMER_CHECKOUT transaction scope'
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
     and p.prosrc ilike '%insert into public.orders%'),
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
     and p.prosrc ilike '%insert into public.orders%'),
  'every live public order-creation function is bound to the private scope'
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

select * from finish();
