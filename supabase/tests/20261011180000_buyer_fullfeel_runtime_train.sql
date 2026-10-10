-- Contract test for migration 20261011180000_buyer_fullfeel_runtime_train.sql.
begin;
select plan(58);

-- WhatsApp terminal retry + expired-lease rejection.
select ok(
  (select pg_get_constraintdef(oid)
   from pg_constraint
   where conrelid='public.whatsapp_packet_ai_dispatch_jobs'::regclass
     and conname='whatsapp_packet_ai_dispatch_jobs_state_check')
  like '%BLOCKED_PERMANENT%',
  'packet AI dispatch state contract includes BLOCKED_PERMANENT'
);

select ok(
  position('LEASE_EXPIRES_AT > STATEMENT_TIMESTAMP()' in upper(pg_get_functiondef(
    'public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)'::regprocedure))) > 0,
  'packet AI failure disposition rejects expired leases'
);

insert into public.whatsapp_contacts(id,phone_number,customer_name)
values ('97200000-0000-0000-0000-000000000001','919720000991','Runtime train contact');

insert into public.whatsapp_messages(
  id,contact_id,direction,message_type,content,provider,provider_message_id,status,message_timestamp,created_at
) values (
  '97200000-0000-0000-0000-000000000011',
  '97200000-0000-0000-0000-000000000001',
  'inbound','text','expired lease contract fixture','click2api',
  'runtime-train-expired-lease','received',
  '2026-10-06 03:00:00+00','2026-10-06 03:00:00+00'
);

select public.stitch_whatsapp_messages_atomic(
  '97200000-0000-0000-0000-000000000001',
  array['97200000-0000-0000-0000-000000000011'::uuid],
  300
);

update public.whatsapp_packet_ai_dispatch_jobs
set state='LEASED',
    attempt_count=1,
    claimed_at=statement_timestamp()-interval '10 minutes',
    last_attempt_at=statement_timestamp()-interval '10 minutes',
    lease_expires_at=statement_timestamp()-interval '1 minute',
    lease_token='97200000-0000-0000-0000-000000000101'::uuid
where packet_id=(select packet_id from public.whatsapp_messages where id='97200000-0000-0000-0000-000000000011')
  and execution_kind='PACKET';

select is(
  public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='97200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    '97200000-0000-0000-0000-000000000101'::uuid,
    (select packet_revision from public.whatsapp_packet_ai_dispatch_jobs
      where packet_id=(select packet_id from public.whatsapp_messages where id='97200000-0000-0000-0000-000000000011')
        and execution_kind='PACKET'),
    'AI_TIMEOUT','expired worker',false
  ),
  false,
  'expired packet-AI worker cannot disposition the job'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id=(select packet_id from public.whatsapp_messages where id='97200000-0000-0000-0000-000000000011')
     and execution_kind='PACKET'),
  'LEASED',
  'expired worker rejection leaves durable job state unchanged'
);

-- Exhaustive product hard-delete guard.
select has_function(
  'public','guard_referenced_product_hard_delete_v1',array[]::text[],
  'product hard-delete guard exists'
);

select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid='public.products'::regclass
      and tgname='trg_guard_referenced_product_hard_delete_v1'
      and not tgisinternal
  ),
  'products have the hard-delete guard trigger'
);

select ok(
  not exists (
    select 1
    from pg_constraint con
    join pg_class rel on rel.oid=con.conrelid
    join pg_namespace ns on ns.oid=rel.relnamespace
    join pg_class ref on ref.oid=con.confrelid
    join pg_namespace refns on refns.oid=ref.relnamespace
    join lateral unnest(con.conkey) with ordinality ck(attnum,ord) on true
    join lateral unnest(con.confkey) with ordinality fk(attnum,ord) on fk.ord=ck.ord
    join pg_attribute att on att.attrelid=rel.oid and att.attnum=ck.attnum
    where con.contype='f'
      and ns.nspname='public'
      and refns.nspname='public'
      and ref.relname='products'
      and con.confdeltype in ('c','n')
      and lower(pg_get_functiondef(
            'public.guard_referenced_product_hard_delete_v1()'::regprocedure))
          !~ ('public\.' || lower(rel.relname) || ' x where [^)]*\mx\.'
              || lower(att.attname) || '\M')
  ),
  'hard-delete guard covers every current CASCADE/SET NULL foreign-key path to products'
);

set local session_replication_role=replica;

insert into public.products(
  id,sku,product_name,name,category,hsn_code,is_active,visible_in_catalog
) values
  ('97400000-0000-0000-0000-000000000001','HIST-FK-1','History FK Product','History FK Product','Bakery','19059090',false,false),
  ('97400000-0000-0000-0000-000000000002','ACTIVE-1','Active Product','Active Product','Bakery','19059090',true,false),
  ('97400000-0000-0000-0000-000000000003','UNUSED-1','Unused Product','Unused Product','Bakery','19059090',false,false);

insert into public.factory_inventory(id,product_id,quantity)
values ('97400000-0000-0000-0000-000000000011','97400000-0000-0000-0000-000000000001',1);

insert into public.product_aliases(id,alias_text,canonical_name,product_id)
values ('97400000-0000-0000-0000-000000000012','history-fk-alias','History FK Product','97400000-0000-0000-0000-000000000001');

set local session_replication_role=default;

select throws_ok(
  $$delete from public.products where id='97400000-0000-0000-0000-000000000001'$$,
  '23503',
  'PRODUCT_HARD_DELETE_FORBIDDEN: referenced product must be archived/deactivated to preserve historical identity',
  'inactive product referenced by destructive FKs cannot be hard-deleted'
);

select is(
  (select count(*)::int from public.factory_inventory where id='97400000-0000-0000-0000-000000000011'),
  1,
  'blocked delete preserves factory inventory history'
);

select is(
  (select product_id from public.product_aliases where id='97400000-0000-0000-0000-000000000012'),
  '97400000-0000-0000-0000-000000000001'::uuid,
  'blocked delete preserves product alias identity'
);

select throws_ok(
  $$delete from public.products where id='97400000-0000-0000-0000-000000000002'$$,
  '23503',
  'PRODUCT_HARD_DELETE_FORBIDDEN: deactivate/archive active product first',
  'active product cannot be hard-deleted'
);

select lives_ok(
  $$delete from public.products where id='97400000-0000-0000-0000-000000000003'$$,
  'unused inactive product remains hard-deletable'
);

select is(
  (select count(*)::int from public.products where id='97400000-0000-0000-0000-000000000003'),
  0,
  'unused inactive product is deleted'
);

-- Production department mutation authority.
select has_function('public','dispatch_production_to_rgs',array['uuid','numeric','text','text'],
  'dispatch production-to-RGS RPC exists');
select has_function('public','report_production_issue',array['uuid','text','text','text','text','text'],
  'report production issue RPC exists');
select has_function('public','resolve_production_issue',array['uuid','text'],
  'resolve production issue RPC exists');

select ok(
  position('V_JOB.CANONICAL_DEPARTMENT IS NULL' in upper(pg_get_functiondef(
    'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0
  and position('ROLE_CANONICAL_DEPARTMENT(V_ACTOR_ROLE) IS NULL' in upper(pg_get_functiondef(
    'public.dispatch_production_to_rgs(uuid,numeric,text,text)'::regprocedure))) > 0,
  'dispatch authority fails NULL/unmapped department closed'
);

select ok(
  position('V_JOB_CANONICAL_DEPARTMENT IS NULL' in upper(pg_get_functiondef(
    'public.report_production_issue(uuid,text,text,text,text,text)'::regprocedure))) > 0
  and position('ROLE_CANONICAL_DEPARTMENT(V_ACTOR_ROLE) IS NULL' in upper(pg_get_functiondef(
    'public.report_production_issue(uuid,text,text,text,text,text)'::regprocedure))) > 0,
  'issue-report authority fails NULL/unmapped department closed'
);

select ok(
  position('V_JOB_CANONICAL_DEPARTMENT IS NULL' in upper(pg_get_functiondef(
    'public.resolve_production_issue(uuid,text)'::regprocedure))) > 0
  and position('ROLE_CANONICAL_DEPARTMENT(V_ACTOR_ROLE) IS NULL' in upper(pg_get_functiondef(
    'public.resolve_production_issue(uuid,text)'::regprocedure))) > 0,
  'issue-resolution authority fails NULL/unmapped department closed'
);

set local session_replication_role=replica;
insert into auth.users(id,email)
values ('97800000-0000-0000-0000-000000000001','runtime-finance@example.com');
insert into public.users(id,email,name,role,is_active)
values ('97800000-0000-0000-0000-000000000001','runtime-finance@example.com','Runtime Finance','FINANCE_EXEC',true);
insert into public.production_jobs(
  id,department,canonical_department,status,locked,produced_qty
) values (
  '97800000-0000-0000-0000-000000000011','Bakery','BAKERY','completed',true,1
);
insert into public.production_issues(
  id,job_id,department,issue_type,comment,status
) values (
  '97800000-0000-0000-0000-000000000012',
  '97800000-0000-0000-0000-000000000011',
  'Bakery','delay','runtime RBAC fixture','open'
);
set local session_replication_role=default;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub','97800000-0000-0000-0000-000000000001',
    'role','authenticated'
  )::text,
  true
);
set local role authenticated;

select throws_ok(
  $$select public.resolve_production_issue(
    '97800000-0000-0000-0000-000000000012'::uuid,
    'should fail'
  )$$,
  '42501',
  'Actor is not authorised for department BAKERY',
  'unmapped Finance actor cannot resolve Bakery production issue'
);

reset role;
select set_config('request.jwt.claims',null,true);

-- B2B review and rescue-payment authority.
select has_function('public','enforce_b2b_application_review_authority_v1',array[]::text[],
  'B2B application review guard exists');

select ok(exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='b2b_applications'
    and policyname='Admins delete applications'
), 'B2B application delete policy is Admin scoped');

select ok(not exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='b2b_applications'
    and policyname='Staff delete applications'
), 'broad B2B staff-delete policy is absent');

select ok(exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='order_payments'
    and policyname='Finance update legacy credit rescue payments'
), 'legacy rescue update is Finance scoped');

select ok(exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='order_payments'
    and policyname='Finance delete legacy credit rescue payments'
), 'legacy rescue delete is Finance scoped');

select ok(not exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='order_payments'
    and policyname='Staff update legacy credit rescue payments'
), 'broad legacy rescue update policy is absent');

select ok(not exists(
  select 1 from pg_policies
  where schemaname='public' and tablename='order_payments'
    and policyname='Staff delete legacy credit rescue payments'
), 'broad legacy rescue delete policy is absent');

-- Buyer address + transporter tenant-safe writes.
select has_function('public','customer_upsert_delivery_address_v1',
  array['uuid','text','text','text','text','text','text','text','boolean'],
  'Buyer address upsert RPC exists');

select has_function('public','customer_delete_delivery_address_v1',array['uuid'],
  'Buyer address delete RPC exists');

select ok(
  has_function_privilege('authenticated',
    'public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)','execute'),
  'authenticated Buyer may call address upsert'
);

select ok(
  not has_function_privilege('anon',
    'public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)','execute'),
  'anonymous caller cannot call address upsert'
);

set local session_replication_role=replica;
insert into public.companies(id,business_name,status,is_frozen)
values
  ('97900000-0000-0000-0000-000000000001','Runtime Buyer A','active',false),
  ('97900000-0000-0000-0000-000000000002','Runtime Buyer B','active',false);

insert into auth.users(id,email)
values ('97900000-0000-0000-0000-000000000101','runtime-buyer@example.com');

insert into public.profiles(id,company_id,role,is_approved,status,email)
values (
  '97900000-0000-0000-0000-000000000101',
  '97900000-0000-0000-0000-000000000001',
  'b2b_buyer',true,'approved','runtime-buyer@example.com'
);

insert into public.delivery_addresses(
  id,company_id,user_id,label,street_address,city,state,pincode,is_default
) values (
  '97900000-0000-0000-0000-000000000299',
  '97900000-0000-0000-0000-000000000002',
  null,'Foreign','2 Foreign Street','Delhi','Delhi','110002',false
);
set local session_replication_role=default;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub','97900000-0000-0000-0000-000000000101',
    'role','authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select * from public.customer_upsert_delivery_address_v1(
    '97900000-0000-0000-0000-000000000201'::uuid,
    'Warehouse','1 Buyer Street','Delhi','Delhi','110001',
    'Buyer Contact','9999999999',true
  )$$,
  'approved Buyer can upsert own company address'
);

reset role;

select is(
  (select company_id from public.delivery_addresses where id='97900000-0000-0000-0000-000000000201'),
  '97900000-0000-0000-0000-000000000001'::uuid,
  'address write binds to eligible Buyer company without caller-supplied tenant id'
);

set local role authenticated;

select throws_ok(
  $$select * from public.customer_upsert_delivery_address_v1(
    '97900000-0000-0000-0000-000000000299'::uuid,
    'Hijack','x','Delhi','Delhi','110002',null,null,false
  )$$,
  '42501',
  'BUYER_ADDRESS_SCOPE_REQUIRED',
  'Buyer cannot overwrite another company address by UUID'
);

reset role;

select has_table('public','customer_saved_transporters','saved transporter master exists');

select ok(
  (select relrowsecurity from pg_class where oid='public.customer_saved_transporters'::regclass),
  'saved transporter master has RLS enabled'
);

select has_function('public','customer_saved_transporters_v1',array[]::text[],
  'Buyer saved-transporter read projection exists');

select ok(
  has_function_privilege('authenticated',
    'public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)','execute'),
  'authenticated Buyer may call saved-transporter upsert'
);

set local role authenticated;

select lives_ok(
  $$select * from public.customer_upsert_saved_transporter_v1(
    '97900000-0000-0000-0000-000000000301'::uuid,
    'Runtime Logistics','ACC-001',true,true
  )$$,
  'approved Buyer can save a default transporter'
);

reset role;

select is(
  (select company_id from public.customer_saved_transporters
   where id='97900000-0000-0000-0000-000000000301'),
  '97900000-0000-0000-0000-000000000001'::uuid,
  'saved transporter is tenant-bound to eligible Buyer company'
);

select is(
  (select preferred_courier from public.companies
   where id='97900000-0000-0000-0000-000000000001'),
  'Runtime Logistics',
  'default saved transporter updates existing company shipping preference compatibility field'
);

set local role authenticated;

select lives_ok(
  $q$select * from public.customer_upsert_saved_transporter_v1(
    '97900000-0000-0000-0000-000000000301'::uuid,
    'Runtime Logistics','ACC-001',true,false
  )$q$,
  'deactivating the current transporter normalizes it away from default'
);

reset role;

select is(
  (select preferred_courier from public.companies
   where id='97900000-0000-0000-0000-000000000001'),
  null::text,
  'legacy preferred courier clears when no active default transporter remains'
);

-- Payment-provider adapter authority.
select has_function('public','record_payment_gateway_verified_provider_event_v1',
  array['uuid','text','text','text','numeric','text','jsonb','text','text','text'],
  'verified provider-event adapter exists');

select ok(
  not has_function_privilege('authenticated',
    'public.record_payment_gateway_verified_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,text,text)','execute'),
  'authenticated client cannot record verified provider events'
);

select ok(
  has_function_privilege('service_role',
    'public.record_payment_gateway_verified_provider_event_v1(uuid,text,text,text,numeric,text,jsonb,text,text,text)','execute'),
  'service role can record provider-authenticated events'
);

select has_function('public','get_payment_gateway_intent_by_provider_order_v1',array['text'],
  'provider-order lookup helper exists');

select ok(
  not has_function_privilege('authenticated',
    'public.get_payment_gateway_intent_by_provider_order_v1(text)','execute'),
  'authenticated client cannot use provider-order lookup'
);

select ok(
  has_function_privilege('service_role',
    'public.get_payment_gateway_intent_by_provider_order_v1(text)','execute'),
  'service role can resolve provider order to canonical intent'
);

select ok(
  not has_table_privilege('authenticated','public.customer_saved_transporters','SELECT'),
  'Buyer accesses saved transporters only through governed RPCs'
);

select ok(
  position('P_COMPANY' in upper(pg_get_function_arguments(
    'public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)'::regprocedure)))=0,
  'address write RPC accepts no caller-supplied company id'
);

select ok(
  position('P_COMPANY' in upper(pg_get_function_arguments(
    'public.customer_upsert_saved_transporter_v1(uuid,text,text,boolean,boolean)'::regprocedure)))=0,
  'saved-transporter write RPC accepts no caller-supplied company id'
);


-- Provider-neutral runtime config is service-only and intentionally unseeded.
select has_table('public','payment_gateway_provider_config',
  'provider-neutral payment runtime config exists');

select ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema='public'
      and table_name='payment_gateway_provider_config'
      and column_name='create_session_url'
  ),
  'provider runtime config cannot control outbound payment endpoint'
);

select ok(
  not has_table_privilege('authenticated','public.payment_gateway_provider_config','SELECT')
  and not has_table_privilege('anon','public.payment_gateway_provider_config','SELECT'),
  'client roles cannot read provider adapter configuration'
);

select has_function('public','get_payment_gateway_provider_config_v1',array[]::text[],
  'provider-neutral config lookup exists');

select ok(
  has_function_privilege('service_role','public.get_payment_gateway_provider_config_v1()','EXECUTE')
  and not has_function_privilege('authenticated','public.get_payment_gateway_provider_config_v1()','EXECUTE')
  and not has_function_privilege('anon','public.get_payment_gateway_provider_config_v1()','EXECUTE'),
  'provider config lookup is service-role only'
);

select is(
  (select count(*)::int from public.payment_gateway_provider_config),
  0,
  'provider runtime ships inactive with no seeded provider row'
);

select * from finish();
rollback;
