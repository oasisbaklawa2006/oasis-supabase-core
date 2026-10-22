-- Contract for 20261022141000_d2c_website_operational_support_v1.sql
begin;
select plan(34);

select ok(
  not has_function_privilege('anon','public.d2c_create_or_get_cart_v1(uuid,text,jsonb)','EXECUTE')
  and not has_function_privilege('anon','public.d2c_set_cart_line_v1(uuid,uuid,integer,jsonb)','EXECUTE')
  and not has_function_privilege('anon','public.d2c_backend_readiness_v1()','EXECUTE'),
  'operational mutation/readiness RPCs remain server-only'
);

select throws_ok(
  $$select * from public.d2c_create_or_get_cart_v1(null,null,'{}'::jsonb)$$,
  'P0001','D2C_CART_EXACTLY_ONE_OWNER_REQUIRED',
  'cart creation requires exactly one owner identity'
);
select throws_ok(
  $$select * from public.d2c_create_or_get_cart_v1(null,'short','{}'::jsonb)$$,
  'P0001','D2C_GUEST_SESSION_HASH_TOO_SHORT',
  'raw or weak guest identifiers are rejected'
);

create temporary table _cart_first as
select * from public.d2c_create_or_get_cart_v1(
  null,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{"utm_source":"test"}'::jsonb
);
select is((select created from _cart_first),true,'first guest cart call creates a cart');

create temporary table _cart_replay as
select * from public.d2c_create_or_get_cart_v1(
  null,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}'::jsonb
);
select is((select created from _cart_replay),false,'same active guest hash reuses the cart');
select is((select cart_id from _cart_replay),(select cart_id from _cart_first),'cart identity is stable across replay');

select throws_ok(
  format(
    $$select public.d2c_set_cart_line_v1(%L::uuid,'7d2c9000-0000-4000-8000-000000000099'::uuid,1,'{}'::jsonb)$$,
    (select cart_id from _cart_first)
  ),
  'P0001','D2C_PRODUCT_NOT_PURCHASABLE:7d2c9000-0000-4000-8000-000000000099',
  'cart cannot accept a product without governed D2C commerce authority'
);

set local session_replication_role=replica;
insert into public.products(
  id,sku,product_name,name,category,hsn_code,is_active,visible_in_catalog,is_catalogue_ready,
  moq_value,increment_value,base_price,price_b2b
) values(
  '7d2c9000-0000-4000-8000-000000000001','D2C-OPS-1','D2C Ops Fixture','D2C Ops Fixture','Bakery','19059090',
  true,true,true,1,1,500,500
);
set local session_replication_role=default;
insert into public.d2c_catalogue_publications(
  product_id,version,slug,display_name,source_reference,status,approved_at,published_at
) values(
  '7d2c9000-0000-4000-8000-000000000001',1,'d2c-ops-fixture','D2C Ops Fixture','test:ai-studio:ops','PUBLISHED',now(),now()
);
insert into public.d2c_product_commerce_authority(
  product_id,current_price,currency,tax_rate,tax_inclusive,uom,sale_enabled,source_reference
) values(
  '7d2c9000-0000-4000-8000-000000000001',500,'INR',5,true,'box',true,'test:finance:ops'
);

select lives_ok(
  format(
    $$select public.d2c_set_cart_line_v1(%L::uuid,'7d2c9000-0000-4000-8000-000000000001'::uuid,2,'{"gift":true}'::jsonb)$$,
    (select cart_id from _cart_first)
  ),
  'governed product can be placed in cart without client price input'
);
select is(
  (select quantity from public.d2c_cart_lines where cart_id=(select cart_id from _cart_first)),
  2,
  'cart line quantity is persisted'
);
select lives_ok(
  format(
    $$select public.d2c_set_cart_line_v1(%L::uuid,'7d2c9000-0000-4000-8000-000000000001'::uuid,0,'{}'::jsonb)$$,
    (select cart_id from _cart_first)
  ),
  'quantity zero removes a cart line'
);
select is(
  (select count(*)::bigint from public.d2c_cart_lines where cart_id=(select cart_id from _cart_first)),
  0::bigint,
  'removed cart line is absent'
);

select public.d2c_set_cart_line_v1(
  (select cart_id from _cart_first),'7d2c9000-0000-4000-8000-000000000001',1,'{}'::jsonb
);
select ok(
  public.d2c_create_cart_recovery_v1(
    (select cart_id from _cart_first),
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    now()+interval '2 days'
  ) is not null,
  'server can create hashed cart recovery session'
);
select throws_ok(
  format(
    $$select public.d2c_create_cart_recovery_v1(%L::uuid,'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',now()-interval '1 minute')$$,
    (select cart_id from _cart_first)
  ),
  'P0001','D2C_RECOVERY_EXPIRY_INVALID',
  'recovery links cannot be born expired'
);

select public.d2c_create_cart_recovery_v1(
  (select cart_id from _cart_first),
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  now()+interval '2 days'
);
update public.d2c_cart_sessions
set status='CHECKED_OUT'
where id=(select cart_id from _cart_first);

select throws_ok(
  $$select public.d2c_redeem_cart_recovery_v1('dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd')$$,
  'P0001','D2C_RECOVERY_CART_NOT_RECOVERABLE',
  'recovery token cannot reactivate a checked-out cart'
);
select is(
  (select status from public.d2c_cart_sessions where id=(select cart_id from _cart_first)),
  'CHECKED_OUT',
  'failed recovery leaves checked-out cart terminal'
);
update public.d2c_cart_sessions
set status='ABANDONED'
where id=(select cart_id from _cart_first);
select is(
  public.d2c_redeem_cart_recovery_v1('dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'),
  (select cart_id from _cart_first),
  'abandoned cart can be deliberately recovered'
);
select is(
  (select status from public.d2c_cart_sessions where id=(select cart_id from _cart_first)),
  'ACTIVE',
  'successful recovery returns abandoned cart to active state'
);

create temporary table _support_first as
select * from public.d2c_create_support_request_v1(
  'GENERAL','{"email":"fixture@example.test"}'::jsonb,'Need assistance','support-ops-1',null
);
select is((select duplicate from _support_first),false,'first support request is created');
select is(
  (select duplicate from public.d2c_create_support_request_v1(
    'GENERAL','{"email":"fixture@example.test"}'::jsonb,'Need assistance','support-ops-1',null
  )),
  true,
  'support request is idempotent'
);

insert into public.d2c_outbox_events(aggregate_type,aggregate_id,event_type,dedupe_key,payload)
values('TEST','7d2c9000-0000-4000-8000-000000000001','TEST_EVENT','ops-outbox-1','{}'::jsonb);
create temporary table _claimed as select * from public.d2c_claim_outbox_v1(1);
select is((select attempts from _claimed),1,'outbox claim is atomic and increments attempt count');
select is(
  (select status from public.d2c_outbox_events where id=(select id from _claimed)),
  'PROCESSING',
  'claimed outbox event is marked processing'
);
select lives_ok(
  format(
    $$select public.d2c_complete_outbox_v1(%L::uuid,%s)$$,
    (select id from _claimed),
    (select attempts from _claimed)
  ),
  'processing outbox event can be acknowledged by its current claim'
);
select is(
  (select status from public.d2c_outbox_events where id=(select id from _claimed)),
  'SENT',
  'acknowledged outbox event is marked sent'
);

insert into public.d2c_outbox_events(aggregate_type,aggregate_id,event_type,dedupe_key,payload)
values('TEST','7d2c9000-0000-4000-8000-000000000001','LEASE_TEST','ops-outbox-lease','{}'::jsonb);
create temporary table _lease_first as select * from public.d2c_claim_outbox_v1(1);
update public.d2c_outbox_events
set available_at=now()-interval '1 second'
where id=(select id from _lease_first);
create temporary table _lease_second as select * from public.d2c_claim_outbox_v1(1);

select is((select attempts from _lease_second),2,'expired processing lease is reclaimed with a new claim attempt');
select throws_ok(
  format(
    $$select public.d2c_complete_outbox_v1(%L::uuid,%s)$$,
    (select id from _lease_first),
    (select attempts from _lease_first)
  ),
  'P0001','D2C_OUTBOX_CLAIM_STALE_OR_NOT_PROCESSING',
  'stale worker cannot acknowledge an event after lease reclamation'
);
select lives_ok(
  format(
    $$select public.d2c_complete_outbox_v1(%L::uuid,%s)$$,
    (select id from _lease_second),
    (select attempts from _lease_second)
  ),
  'current outbox lease holder can acknowledge the event'
);

insert into public.d2c_outbox_events(
  aggregate_type,aggregate_id,event_type,dedupe_key,payload,status,attempts,available_at
) values(
  'TEST','7d2c9000-0000-4000-8000-000000000001','DEAD_LETTER_TEST',
  'ops-outbox-dead-letter','{}'::jsonb,'PROCESSING',10,now()-interval '1 second'
);

update public.d2c_cart_recovery_sessions
set expires_at=now()-interval '1 minute'
where token_hash='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
-- Abandoned-checkout release: a cart whose only checkout lapsed unpaid becomes recoverable;
-- a cart with a paid checkout stays CHECKED_OUT.
create temporary table _cart_lapsed as
select * from public.d2c_create_or_get_cart_v1(
  null,'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee','{}'::jsonb
);
create temporary table _cart_paid as
select * from public.d2c_create_or_get_cart_v1(
  null,'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff','{}'::jsonb
);
update public.d2c_cart_sessions set status='CHECKED_OUT'
where id in ((select cart_id from _cart_lapsed),(select cart_id from _cart_paid));
insert into public.d2c_checkout_sessions(
  cart_id,idempotency_key,contact,shipping_address,quote_snapshot,subtotal,tax_total,total,currency,status,expires_at
) values
  ((select cart_id from _cart_lapsed),'lapse-ops-1','{}'::jsonb,'{}'::jsonb,'{}'::jsonb,100,0,100,'INR','QUOTED',now()-interval '1 minute'),
  ((select cart_id from _cart_paid),'paid-ops-1','{}'::jsonb,'{}'::jsonb,'{}'::jsonb,100,0,100,'INR','PAID_AWAITING_HANDOFF',now()-interval '1 minute');

create temporary table _maintenance_result as
select public.d2c_maintenance_v1() as result;
select is(
  (select (result->>'expired_recoveries')::integer from _maintenance_result),
  1,
  'maintenance expires stale recovery state without deleting history'
);
select is(
  (select (result->>'dead_lettered_outbox')::integer from _maintenance_result),
  1,
  'maintenance dead-letters an expired processing lease at the attempt limit'
);
select is(
  (select (result->>'expired_checkouts')::integer from _maintenance_result),
  1,
  'maintenance expires only the unpaid lapsed checkout'
);
select is(
  (select status from public.d2c_cart_sessions where id=(select cart_id from _cart_lapsed)),
  'ABANDONED',
  'a cart whose only checkout lapsed unpaid is released as recoverable'
);
select is(
  (select status from public.d2c_cart_sessions where id=(select cart_id from _cart_paid)),
  'CHECKED_OUT',
  'a cart with a paid checkout is not released'
);
select is(
  (select status from public.d2c_outbox_events where dedupe_key='ops-outbox-dead-letter'),
  'DEAD_LETTER',
  'maximum-attempt processing event cannot remain stranded'
);
select is(
  public.d2c_backend_readiness_v1()#>>'{hard_boundaries,product_creation_authority}',
  'false',
  'readiness reports that D2C backend has no product-creation authority'
);
select is(
  (public.d2c_backend_readiness_v1()#>>'{catalogue,public_offers}')::integer,
  1,
  'readiness counts only governed public offers'
);

select * from finish();
rollback;
