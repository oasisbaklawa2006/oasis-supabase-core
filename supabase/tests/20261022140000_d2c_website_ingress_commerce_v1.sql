-- Contract for 20261022140000_d2c_website_ingress_commerce_v1.sql
-- Test fixtures are transaction-local and rolled back. No production product is created.

begin;
select plan(47);

select has_table('public','d2c_catalogue_publications','D2C publication authority exists');
select has_table('public','d2c_product_commerce_authority','D2C commerce authority exists');
select has_table('public','d2c_cart_sessions','D2C carts exist');
select has_table('public','d2c_checkout_sessions','D2C checkout sessions exist');
select has_table('public','d2c_payment_attempts','D2C payment attempts exist');
select has_table('public','d2c_order_intents','D2C order intents exist');
select has_table('public','d2c_order_events','D2C order timeline exists');
select has_table('public','d2c_outbox_events','D2C Appverse outbox exists');
select has_table('public','d2c_integration_webhook_events','D2C webhook replay ledger exists');
select has_table('public','d2c_cart_recovery_sessions','D2C cart recovery exists');
select has_table('public','d2c_support_requests','D2C support request intake exists');

select ok(
  not has_table_privilege('anon','public.d2c_cart_sessions','SELECT')
  and not has_table_privilege('anon','public.d2c_checkout_sessions','SELECT')
  and not has_table_privilege('anon','public.d2c_payment_attempts','SELECT')
  and not has_table_privilege('anon','public.d2c_order_intents','SELECT')
  and not has_table_privilege('anon','public.d2c_integration_webhook_events','INSERT'),
  'anonymous callers cannot read/write private D2C commerce state'
);

select ok(
  not has_table_privilege('authenticated','public.d2c_cart_sessions','INSERT')
  and not has_table_privilege('authenticated','public.d2c_checkout_sessions','INSERT')
  and not has_table_privilege('authenticated','public.d2c_payment_attempts','INSERT')
  and not has_table_privilege('authenticated','public.d2c_order_intents','INSERT'),
  'authenticated browsers cannot bypass server commerce authority'
);

select ok(
  has_function_privilege('anon','public.d2c_public_catalogue_v1()','EXECUTE')
  and has_function_privilege('anon','public.d2c_track_order_v1(uuid)','EXECUTE'),
  'anonymous surface is limited to public catalogue and bearer tracking RPCs'
);

select is((select count(*)::bigint from public.d2c_catalogue_publications),0::bigint,
  'migration seeds no D2C product publication');
select is((select count(*)::bigint from public.d2c_product_commerce_authority),0::bigint,
  'migration seeds no D2C price or sale authority');
select is(
  (select count(*)::bigint from public.d2c_resolve_product_offer_v1('7d2c0000-0000-4000-8000-000000000001'::uuid)),
  0::bigint,
  'resolving an unknown product never invents an offer'
);

-- Behavioural fixture. Everything below is rolled back.
set local session_replication_role = replica;
insert into public.products(
  id,sku,product_name,name,category,hsn_code,is_active,visible_in_catalog,is_catalogue_ready,
  moq_value,increment_value,base_price,price_b2b
) values (
  '7d2c0000-0000-4000-8000-000000000001','D2C-FIXTURE-1','D2C Fixture','D2C Fixture','Bakery','19059090',
  true,true,true,1,1,1000,1000
);
set local session_replication_role = default;

insert into public.d2c_catalogue_publications(
  id,product_id,version,slug,display_name,presentation,source_reference,status,approved_at,published_at
) values (
  '7d2c1000-0000-4000-8000-000000000001','7d2c0000-0000-4000-8000-000000000001',1,
  'd2c-fixture','D2C Fixture','{"hero":"fixture"}'::jsonb,'test:ai-studio:v1','PUBLISHED',now(),now()
);

insert into public.d2c_product_commerce_authority(
  id,product_id,current_price,compare_at_price,currency,tax_rate,tax_inclusive,uom,sale_enabled,source_reference
) values (
  '7d2c2000-0000-4000-8000-000000000001','7d2c0000-0000-4000-8000-000000000001',1000,1200,'INR',18,false,'box',true,'test:finance:v1'
);

select is(
  (select price from public.d2c_resolve_product_offer_v1('7d2c0000-0000-4000-8000-000000000001')),
  1000::numeric,
  'offer resolver returns only explicit D2C commerce price'
);
select is((select count(*)::bigint from public.d2c_public_catalogue_v1()),1::bigint,
  'published presentation plus enabled commerce authority becomes publicly discoverable');

insert into public.d2c_cart_sessions(id,guest_session_hash)
values('7d2c3000-0000-4000-8000-000000000001','fixture-session-hash');
insert into public.d2c_cart_lines(cart_id,product_id,quantity)
values('7d2c3000-0000-4000-8000-000000000001','7d2c0000-0000-4000-8000-000000000001',2);

select is((public.d2c_quote_cart_v1('7d2c3000-0000-4000-8000-000000000001')->>'subtotal')::numeric,2000::numeric,
  'server quote derives subtotal from governed D2C price');
select is((public.d2c_quote_cart_v1('7d2c3000-0000-4000-8000-000000000001')->>'tax_total')::numeric,360::numeric,
  'server quote derives tax from governed D2C tax authority');
select is((public.d2c_quote_cart_v1('7d2c3000-0000-4000-8000-000000000001')->>'total')::numeric,2360::numeric,
  'server quote derives payable total without browser-authoritative arithmetic');

create temporary table _d2c_checkout_result as
select * from public.d2c_create_checkout_v1(
  '7d2c3000-0000-4000-8000-000000000001','checkout-fixture-1',
  '{"email":"fixture@example.test"}'::jsonb,
  '{"address1":"Fixture Street","city":"Delhi","postal_code":"110015"}'::jsonb,
  null
);
select is((select total from _d2c_checkout_result),2360::numeric,'checkout freezes the authoritative quote total');
select is((select duplicate from public.d2c_create_checkout_v1(
  '7d2c3000-0000-4000-8000-000000000001','checkout-fixture-1',
  '{"email":"fixture@example.test"}'::jsonb,
  '{"address1":"Fixture Street"}'::jsonb,null
)),true,'checkout idempotency returns the existing checkout');

create temporary table _d2c_payment_result as
select * from public.d2c_register_payment_attempt_v1(
  (select checkout_id from _d2c_checkout_result),'RAZORPAY','pay-fixture-1'
);
select is((select amount from _d2c_payment_result),2360::numeric,'payment attempt amount is copied from server checkout authority');

create temporary table _d2c_payment_second as
select * from public.d2c_register_payment_attempt_v1(
  (select checkout_id from _d2c_checkout_result),'RAZORPAY','pay-fixture-2'
);

select throws_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-1','event-1','hash-1',2360,'INR','CAPTURED',false)$$,
    (select payment_attempt_id from _d2c_payment_result)
  ),
  'P0001','D2C_WEBHOOK_SIGNATURE_NOT_VERIFIED',
  'unverified provider webhook cannot capture payment'
);

select throws_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-1','event-null-signature','hash-null-signature',2360,'INR','CAPTURED',null)$$,
    (select payment_attempt_id from _d2c_payment_result)
  ),
  'P0001','D2C_WEBHOOK_SIGNATURE_NOT_VERIFIED',
  'a NULL signature_verified argument fails closed instead of passing the gate'
);

select throws_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-1','event-amount-mismatch','hash-amount-mismatch',2359,'INR','CAPTURED',true)$$,
    (select payment_attempt_id from _d2c_payment_result)
  ),
  'P0001','D2C_PAYMENT_AMOUNT_AUTHORITY_MISMATCH',
  'verified provider capture amount must equal server-authoritative payment amount'
);
select throws_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-1','event-currency-mismatch','hash-currency-mismatch',2360,'USD','CAPTURED',true)$$,
    (select payment_attempt_id from _d2c_payment_result)
  ),
  'P0001','D2C_PAYMENT_AMOUNT_AUTHORITY_MISMATCH',
  'verified provider capture currency must equal server-authoritative payment currency'
);

create temporary table _d2c_orders_before as select count(*)::bigint as row_count from public.orders;
create temporary table _d2c_capture_result as
select * from public.d2c_record_verified_payment_v1(
  (select payment_attempt_id from _d2c_payment_result),'provider-pay-1','event-1','hash-1',2360,'INR','CAPTURED',true
);
select ok((select order_intent_id is not null and public_tracking_id is not null from _d2c_capture_result),
  'verified captured payment creates a website order intent and public tracking id');
select is((select count(*)::bigint from public.d2c_outbox_events where event_type='D2C_ORDER_PAID'),1::bigint,
  'captured payment emits exactly one Appverse handoff event');
select is((select count(*)::bigint from public.orders),(select row_count from _d2c_orders_before),
  'D2C capture path does not manufacture a canonical Appverse order');
select is(
  (public.d2c_track_order_v1((select public_tracking_id from _d2c_capture_result))->>'status'),
  'PAID_AWAITING_HANDOFF',
  'public tracking exposes safe initial order status'
);
select is(
  (select duplicate from public.d2c_record_verified_payment_v1(
    (select payment_attempt_id from _d2c_payment_result),'provider-pay-1','event-1','hash-1',2360,'INR','CAPTURED',true
  )),
  true,
  'same verified provider event is replay-idempotent'
);
select throws_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-1','event-1','different-hash',2360,'INR','CAPTURED',true)$$,
    (select payment_attempt_id from _d2c_payment_result)
  ),
  'P0001','D2C_WEBHOOK_REPLAY_HASH_MISMATCH',
  'same provider event id with different payload hash is rejected'
);

select lives_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-1','event-late-authorized','hash-late-authorized',2360,'INR','AUTHORIZED',true)$$,
    (select payment_attempt_id from _d2c_payment_result)
  ),
  'late authorized provider event is recorded without regressing a captured attempt'
);
select is(
  (select status from public.d2c_payment_attempts where id=(select payment_attempt_id from _d2c_payment_result)),
  'CAPTURED',
  'captured payment attempt is forward-only under out-of-order provider events'
);

select lives_ok(
  format(
    $$select * from public.d2c_record_verified_payment_v1(%L::uuid,'provider-pay-2','event-2','hash-2',2360,'INR','CAPTURED',true)$$,
    (select payment_attempt_id from _d2c_payment_second)
  ),
  'second real capture is persisted and surfaced for finance follow-up'
);
select is(
  (select count(*)::bigint from public.d2c_support_requests
    where request_type='PAYMENT_HELP' and idempotency_key like 'duplicate-capture:%'),
  1::bigint,
  'duplicate capture creates exactly one payment-help case'
);
select is(
  (select count(*)::bigint from public.d2c_outbox_events where event_type='D2C_ORDER_PAID'),
  1::bigint,
  'duplicate capture does not emit a second paid-order handoff'
);

insert into public.orders(id,order_number,tracking_token,order_origin) values
  ('7d2c5000-0000-4000-8000-000000000001','PGTAP-D2C-LINK-1','pgtap-d2c-link-token-1','MANUAL'),
  ('7d2c5000-0000-4000-8000-000000000002','PGTAP-D2C-LINK-2','pgtap-d2c-link-token-2','MANUAL');
select lives_ok(
  format(
    $$select public.d2c_link_canonical_order_v1(%L::uuid,'7d2c5000-0000-4000-8000-000000000001'::uuid)$$,
    (select order_intent_id from _d2c_capture_result)
  ),
  'paid intent is linked to its canonical order'
);
select lives_ok(
  format(
    $$select public.d2c_append_order_event_v1(%L::uuid,'COURIER_DISPATCH','DISPATCHED','Your order is on the way.')$$,
    (select order_intent_id from _d2c_capture_result)
  ),
  'server may append a governed public-safe tracking event'
);
select is(
  (public.d2c_track_order_v1((select public_tracking_id from _d2c_capture_result))->>'status'),
  'DISPATCHED',
  'public tracking follows governed order status updates'
);

-- Idempotent link replay (at-least-once outbox): must not regress status or duplicate the event.
select lives_ok(
  format(
    $$select public.d2c_link_canonical_order_v1(%L::uuid,'7d2c5000-0000-4000-8000-000000000001'::uuid)$$,
    (select order_intent_id from _d2c_capture_result)
  ),
  'replaying the identical canonical-order link is accepted'
);
select is(
  (public.d2c_track_order_v1((select public_tracking_id from _d2c_capture_result))->>'status'),
  'DISPATCHED',
  'link replay does not move the public status back to HANDED_OFF'
);
select is(
  (select count(*)::bigint from public.d2c_order_events
    where order_intent_id=(select order_intent_id from _d2c_capture_result) and event_type='APPVERSE_HANDOFF'),
  1::bigint,
  'link replay does not add a duplicate APPVERSE_HANDOFF timeline event'
);
select throws_ok(
  format(
    $$select public.d2c_link_canonical_order_v1(%L::uuid,'7d2c5000-0000-4000-8000-000000000002'::uuid)$$,
    (select order_intent_id from _d2c_capture_result)
  ),
  'P0001','D2C_CANONICAL_ORDER_LINK_IMMUTABLE',
  'a different canonical order cannot replace an existing link'
);

select * from finish();
rollback;
