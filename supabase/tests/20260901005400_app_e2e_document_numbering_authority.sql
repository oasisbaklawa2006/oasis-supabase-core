-- Contract for 20260901005400_app_e2e_document_numbering_authority.sql.

select plan(18);

select has_table('public','commercial_document_number_counters',
  'commercial document numbering has one private counter authority');

select ok(
  not has_table_privilege('authenticated','public.commercial_document_number_counters','SELECT')
  and not has_table_privilege('authenticated','public.commercial_document_number_counters','INSERT')
  and not has_table_privilege('service_role','public.commercial_document_number_counters','UPDATE'),
  'counter state is not a browser or service-role mutation surface'
);

select ok(
  pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%Asia/Kolkata%',
  'document allocation uses the Asia/Kolkata business clock'
);

select ok(
  pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%pg_advisory_xact_lock%'
  and pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%document_kind=v_kind%business_period=v_business_period%',
  'allocation serializes one company-wide counter per document kind and month'
);

select ok(
  pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%WHEN ''SO'' THEN 9999 ELSE 999 END%',
  'SO and PI monthly exhaustion limits are fail-closed at 9999 and 999'
);

select ok(
  pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%''SO''||v_business_period||''-''||lpad(v_next::text,4,''0'')%'
  and pg_get_functiondef('public.allocate_commercial_document_number_v1(text)'::regprocedure)
    like '%''PI''||v_business_period||''-''||lpad(v_next::text,3,''0'')%',
  'allocator emits only approved SOYYYY/MM-NNNN and PIYYYY/MM-NNN shapes'
);

select ok(
  pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%SALES_ORDER_CREATION_RPC_REQUIRED%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%SO_NUMBER_SERVER_ASSIGNED%',
  'raw runtime order inserts and caller-supplied SO numbers fail closed'
);

select ok(
  pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%sales_order_creation_scopes%'
  and pg_get_functiondef('public.assign_order_number_on_insert()'::regprocedure)
    like '%SALES_ORDER_CREATION_RPC_REQUIRED%',
  'runtime order creation requires the scoped canonical authority introduced by 05700'
);

select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid='public.orders'::regclass
      and tgname='trg_orders_order_number_immutable'
      and not tgisinternal
  ),
  'canonical SO number is immutable after assignment'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname='public' and tablename='orders'
      and indexname='orders_order_number_key'
      and indexdef like 'CREATE UNIQUE INDEX%'
  ),
  'canonical SO identity remains globally unique'
);

select ok(
  (select pg_get_constraintdef(oid)
   from pg_constraint
   where conrelid='public.sales_order_proforma_invoices'::regclass
     and conname='sales_order_proforma_invoices_customer_visible_pi_number_check')
    like '%READY_FOR_ISSUE%customer_visible_pi_number IS NULL%'
  and (select pg_get_constraintdef(oid)
   from pg_constraint
   where conrelid='public.sales_order_proforma_invoices'::regclass
     and conname='sales_order_proforma_invoices_customer_visible_pi_number_check')
    like '%ISSUED%customer_visible_pi_number IS NOT NULL%',
  'PI has no predicted customer number before issue and requires one on issue'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname='public' and tablename='sales_order_proforma_invoices'
      and indexname='uq_sales_order_pi_customer_visible_number'
      and indexdef like '%UNIQUE INDEX%'
  ),
  'issued PI customer number is globally unique'
);

select ok(
  pg_get_functiondef('public.prevent_sales_order_proforma_invoice_mutation()'::regprocedure)
    like '%SALES_ORDER_PI_NUMBER_IMMUTABLE%',
  'PI number cannot be changed after its governed issue transition'
);

select ok(
  pg_get_function_result('public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)'::regprocedure)
    like '%customer_visible_pi_number text%',
  'canonical PI issue RPC returns the issued customer-visible number'
);

select ok(
  lower(regexp_replace(
    pg_get_functiondef('public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)'::regprocedure),
    '[[:space:]]+','','g'
  )) like '%coalesce(v_existing.response->>''customer_visible_pi_number''%',
  'PI issue idempotency replay backfills customer_visible_pi_number from immutable PI truth when legacy response JSON omitted it'
);

with ordering as (
  select
    strpos(
      lower(regexp_replace(pg_get_functiondef('public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)'::regprocedure),'[[:space:]]+','','g')),
      'v_pi_number:=public.allocate_commercial_document_number_v1(''pi'')'
    ) as alloc_pos,
    strpos(
      lower(regexp_replace(pg_get_functiondef('public.issue_sales_order_proforma_invoice_v1(uuid,text,text,text,text,uuid)'::regprocedure),'[[:space:]]+','','g')),
      'setstatus=''issued'',customer_visible_pi_number=v_pi_number'
    ) as persist_pos
)
select ok(
  alloc_pos > 0 and persist_pos > 0 and alloc_pos < persist_pos,
  'PI number is allocated inside the same locked issue transaction before canonical ISSUE state is persisted'
) from ordering;

with allocated as (
  select public.allocate_commercial_document_number_v1('SO') as first_no
), allocated2 as (
  select first_no, public.allocate_commercial_document_number_v1('SO') as second_no from allocated
)
select ok(
  first_no ~ '^SO[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{4}$'
  and second_no ~ '^SO[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{4}$'
  and first_no<>second_no,
  'successive SO allocations are unique and monotonic within the locked monthly authority'
) from allocated2;

with allocated as (
  select public.allocate_commercial_document_number_v1('PI') as pi_no
)
select ok(
  pi_no ~ '^PI[0-9]{4}/(0[1-9]|1[0-2])-[0-9]{3}$'
  and pi_no not like 'SO%',
  'PI monthly sequence is independent from SO numbering'
) from allocated;

select * from finish();
