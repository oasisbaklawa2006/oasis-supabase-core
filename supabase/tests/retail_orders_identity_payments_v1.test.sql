-- Retail quote / order / payment / identity contract coverage for
-- 20261119200000_retail_orders_identity_payments_v1.sql and
-- 20261119200100_retail_internal_helper_acl.sql.
-- Every value below is a SYNTHETIC TEST VALUE inside a rolled-back transaction. None is a proposal, an approved
-- setting, a price, a rate, a fee or a serviceable PIN list.

begin;

select plan(110);

create temp table t (k text primary key, v text);

-- ---------------------------------------------------------------------------
-- Fixtures (synthetic)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('95000000-0000-0000-0000-000000000001', 'ro-admin@example.invalid'),
  ('95000000-0000-0000-0000-000000000002', 'ro-user-a@example.invalid'),
  ('95000000-0000-0000-0000-000000000003', 'ro-user-b@example.invalid');
insert into public.users (id, role, email, is_active) values
  ('95000000-0000-0000-0000-000000000001', 'admin', 'ro-admin@example.invalid', true);

insert into public.products (id, name, sku, category, hsn_code, is_active, visible_in_catalog, is_catalogue_ready, gst_percentage, gst_rate) values
  ('95100000-0000-0000-0000-00000000000a', 'RO Test A', 'RO-TEST-A', 'ready_goods', '1704.90.90', true, true, true, 5, 5),
  ('95100000-0000-0000-0000-00000000000b', 'RO Test B', 'RO-TEST-B', 'ready_goods', '1806.90.90', true, true, true, 18, 18),
  ('95100000-0000-0000-0000-00000000000c', 'RO Test C (tax conflict)', 'RO-TEST-C', 'ready_goods', '1704.90.90', true, true, true, 5, 18),
  ('95100000-0000-0000-0000-00000000000d', 'RO Test D (fraction scale)', 'RO-TEST-D', 'ready_goods', '1704.90.90', true, true, true, 0.05, 0.05),
  ('95100000-0000-0000-0000-00000000000e', 'RO Test E (no retail price)', 'RO-TEST-E', 'ready_goods', '1704.90.90', true, true, true, 5, 5),
  ('95100000-0000-0000-0000-00000000000f', 'RO Test F (unpublished)', 'RO-TEST-F', 'ready_goods', '1704.90.90', true, true, false, 5, 5),
  ('95100000-0000-0000-0000-000000000010', 'RO Test G (draft price)', 'RO-TEST-G', 'ready_goods', '1704.90.90', true, true, true, 5, 5),
  ('95100000-0000-0000-0000-000000000011', 'RO Test H (exclusive price)', 'RO-TEST-H', 'ready_goods', '1704.90.90', true, true, true, 5, 5);

insert into public.product_pricing_rules (product_id, price_channel, base_price, gst_rate, tax_inclusive, approval_status, approved_at) values
  ('95100000-0000-0000-0000-00000000000a', 'retail', 105.00, 5, true, 'approved', now()),
  ('95100000-0000-0000-0000-00000000000b', 'retail', 118.00, 18, true, 'approved', now()),
  ('95100000-0000-0000-0000-00000000000c', 'retail', 105.00, 5, true, 'approved', now()),
  ('95100000-0000-0000-0000-00000000000d', 'retail', 105.00, 0.05, true, 'approved', now()),
  ('95100000-0000-0000-0000-00000000000f', 'retail', 105.00, 5, true, 'approved', now()),
  ('95100000-0000-0000-0000-000000000010', 'retail', 105.00, 5, true, 'draft', null),
  ('95100000-0000-0000-0000-000000000011', 'retail', 105.00, 5, false, 'approved', now()),
  ('95100000-0000-0000-0000-00000000000e', 'b2b', 99.00, 5, true, 'approved', now());

create or replace function pg_temp.as_admin() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '95000000-0000-0000-0000-000000000001', true)
$$;
create or replace function pg_temp.approve(p_key text, p_value jsonb) returns jsonb language sql as $$
  select public.retail_commerce_set_setting_v1(p_key, p_value, 'approved', 'TEST-REF-1')
$$;
create or replace function pg_temp.req(p_key text, p_items jsonb, p_state text default '07', p_pin text default '110015')
returns jsonb language sql stable as $$
  select jsonb_build_object('idempotencyKey', p_key, 'items', p_items,
    'shipTo', jsonb_build_object('pincode', p_pin, 'stateCode', p_state), 'currency', 'INR')
$$;
create or replace function pg_temp.item(p_id text, p_qty int) returns jsonb language sql immutable as $$
  select jsonb_build_object('productId', p_id, 'quantity', p_qty)
$$;

select pg_temp.as_admin();

-- ---------------------------------------------------------------------------
-- Privileges and isolation of storage
-- ---------------------------------------------------------------------------
select ok(
  not exists (
    select 1 from unnest(array['retail_customers','retail_sessions','retail_serviceable_pincodes','retail_shipping_fee_slabs',
      'retail_quotes','retail_orders','retail_payment_intents','retail_payment_events','retail_payment_event_rejections']) tbl
    cross join unnest(array['anon','service_role']) r
    where has_table_privilege(r, 'public.' || tbl, 'SELECT') or has_table_privilege(r, 'public.' || tbl, 'INSERT')
       or has_table_privilege(r, 'public.' || tbl, 'UPDATE') or has_table_privilege(r, 'public.' || tbl, 'DELETE')),
  'anon and service_role have no direct table access to any retail table');
select ok(
  not exists (
    select 1 from unnest(array['retail_sessions','retail_serviceable_pincodes','retail_shipping_fee_slabs',
      'retail_payment_intents','retail_payment_events','retail_payment_event_rejections']) tbl
    where has_table_privilege('authenticated', 'public.' || tbl, 'SELECT')),
  'authenticated cannot read sessions, shipping config, payment intents or provider events');
select ok(
  has_table_privilege('authenticated', 'public.retail_orders', 'SELECT')
  and not has_table_privilege('authenticated', 'public.retail_orders', 'INSERT')
  and not has_table_privilege('authenticated', 'public.retail_orders', 'UPDATE'),
  'authenticated may only read retail orders (RLS limits it to its own)');
select ok(
  not has_function_privilege('anon', 'public.retail_quote_create_v2(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.retail_quote_create_v2(text,jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.retail_quote_create_v2(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.retail_payment_event_apply_v1(text,text,text,text,bigint,text,jsonb,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.retail_session_issue_v1(text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.retail_session_resolve_v1(text)', 'EXECUTE'),
  'commerce RPCs are service_role only; session resolution is internal');
select ok(
  has_function_privilege('authenticated', 'public.retail_customer_link_account_v1(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retail_customer_link_account_v1(text)', 'EXECUTE'),
  'only authenticated users can link an optional account');

select ok(
  not exists (select 1 from unnest(array['anon','authenticated','service_role']) r
    where has_function_privilege(r, 'public.retail_setting_approved_v1(text)', 'EXECUTE')),
  'retail_setting_approved_v1(text) is internal, including under Supabase default grants');
select ok(
  not exists (select 1 from unnest(array['anon','authenticated','service_role']) r
    where has_function_privilege(r, 'public.retail_session_resolve_v1(text)', 'EXECUTE')),
  'retail_session_resolve_v1(text) is internal, including under Supabase default grants');
select ok(
  not exists (select 1 from unnest(array['anon','authenticated','service_role']) r
    where has_function_privilege(r, 'public.retail_price_resolve_v1(uuid)', 'EXECUTE')),
  'retail_price_resolve_v1(uuid) is internal, including under Supabase default grants');
select ok(
  not exists (select 1 from unnest(array['anon','authenticated','service_role']) r
    where has_function_privilege(r, 'public.retail_tax_breakdown_v1(numeric,numeric,boolean)', 'EXECUTE')),
  'retail_tax_breakdown_v1(numeric,numeric,boolean) is internal, including under Supabase default grants');

-- Retail identity is separate from B2B: no foreign key to anything but retail tables and auth.users.
select is(
  (select count(*)::int from pg_constraint c
    join pg_class r on r.oid = c.conrelid and r.relname like 'retail\_%' and r.relnamespace = 'public'::regnamespace
    join pg_class f on f.oid = c.confrelid
    join pg_namespace fn on fn.oid = f.relnamespace
   where c.contype = 'f'
     and not (f.relname like 'retail\_%' and fn.nspname = 'public')
     and not (f.relname = 'users' and fn.nspname = 'auth')),
  0, 'retail tables reference no B2B company, claim or customer table');

-- ---------------------------------------------------------------------------
-- Everything is blocked while nothing is approved
-- ---------------------------------------------------------------------------
select throws_ok($$ select public.retail_session_issue_v1('919876543210') $$, 'P0001', 'RETAIL_COMMERCE_BLOCKED',
  'no session can be issued while guest checkout is not approved');
select throws_ok($$ select public.retail_price_display_v1(array['95100000-0000-0000-0000-00000000000a'::uuid]) $$,
  'P0001', 'RETAIL_COMMERCE_BLOCKED', 'price display is blocked until architecture and tax settings are approved');

-- Approve guest checkout only (synthetic) so a session can exist for the blocking checks below.
do $$ begin perform pg_temp.approve('checkout.guest_allowed', 'true'); end $$;
select throws_ok($$ select public.retail_session_issue_v1('12345') $$, '22023', 'RETAIL_PHONE_INVALID', 'a malformed phone is refused');
select throws_ok($$ select public.retail_session_issue_v1('915876543210') $$, '22023', 'RETAIL_PHONE_INVALID', 'a non-Indian-mobile phone is refused');

insert into t select 'tokA', public.retail_session_issue_v1('919876543210') ->> 'sessionToken';
select ok((select v from t where k = 'tokA') ~ '^rsess_[0-9a-f]{64}$', 'a verified phone receives an opaque guest session token');
select is((select count(*)::int from public.retail_sessions where token_hash = (select v from t where k = 'tokA')), 0,
  'the plaintext token is never stored');
select is((select count(*)::int from public.retail_sessions where token_hash = encode(sha256(convert_to((select v from t where k = 'tokA'), 'UTF8')), 'hex')), 1,
  'only its SHA-256 is stored');
insert into t select 'tokA2', public.retail_session_issue_v1('919876543210') ->> 'sessionToken';
select is((select count(*)::int from public.retail_customers where phone_e164 = '919876543210'), 1,
  'the same verified phone maps to one retail customer across sessions');
insert into t select 'tokB', public.retail_session_issue_v1('919876543211') ->> 'sessionToken';

select throws_ok($$ select public.retail_quote_create_v2('rsess_' || repeat('0', 64), pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d01', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $$,
  '28000', 'RETAIL_SESSION_INVALID', 'an unknown session cannot quote');
select throws_ok($$ select public.retail_quote_create_v2('not-a-token', '{}'::jsonb) $$, '28000', 'RETAIL_SESSION_INVALID', 'a malformed session token is refused');
select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d01', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_COMMERCE_BLOCKED', 'quote is blocked while pricing, shipping, validity and reservation settings are unapproved');
select throws_ok(format($f$ select public.retail_order_create_v1(%L, gen_random_uuid(), gen_random_uuid()::text) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_COMMERCE_BLOCKED', 'order is blocked while settings are unapproved');
select throws_ok(format($f$ select public.retail_payment_intent_create_v1(%L, gen_random_uuid()) $f$, (select v from t where k = 'tokA')),
  'P0002', 'RETAIL_ORDER_NOT_FOUND', 'a payment intent needs an existing order of the caller');

-- Approve the rest (synthetic). Shipping, refund-adjacent and quote/reservation values stay test-only.
do $$ begin perform pg_temp.approve('tax.price_display_mode', '"inclusive"'); end $$;
do $$ begin perform pg_temp.approve('tax.seller_state_code', '"07"'); end $$;
do $$ begin perform pg_temp.approve('shipping.model', '"slab"'); end $$;
do $$ begin perform pg_temp.approve('shipping.fee_table_ref', '"RATECARD-TEST-1"'); end $$;
do $$ begin perform pg_temp.approve('shipping.serviceable_pin_policy_ref', '"PINLIST-TEST-1"'); end $$;
do $$ begin perform pg_temp.approve('shipping.delivery_promise_days', '5'); end $$;
do $$ begin perform pg_temp.approve('quote.validity_minutes', '15'); end $$;
do $$ begin perform pg_temp.approve('stock.reservation_minutes', '30'); end $$;
do $$ begin perform pg_temp.approve('payment.provider', '"razorpay"'); end $$;
do $$ begin perform pg_temp.approve('payment.settlement_account_ref', '"SETTLE-TEST-1"'); end $$;
do $$ begin perform pg_temp.approve('architecture_approved', 'true'); end $$;

select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d01', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_COMMERCE_BLOCKED', 'architecture approval alone does not activate quoting');
do $$ begin perform pg_temp.approve('activation_enabled', 'true'); end $$;

select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d01', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_PIN_NOT_SERVICEABLE', 'no approved serviceable PIN list means no quote');

-- Shipping configuration infrastructure
select is(public.retail_serviceable_pincodes_replace_v1('PINLIST-TEST-1', array['110015', '400001']) ->> 'pincodes', '2', 'an admin can load the serviceable PIN list');
select throws_ok($$ select public.retail_serviceable_pincodes_replace_v1('PINLIST-TEST-1', array['12']) $$, '22023', 'RETAIL_CONFIG_INVALID', 'a malformed PIN is refused');
select throws_ok(
  $$ select public.retail_shipping_rate_card_replace_v1('RATECARD-TEST-1', '[{"minSubtotalInr":10,"belowSubtotalInr":null,"feeInr":59,"gstRatePercent":18}]'::jsonb) $$,
  '22023', 'RETAIL_CONFIG_INVALID', 'the first slab must start at zero');
select throws_ok(
  $$ select public.retail_shipping_rate_card_replace_v1('RATECARD-TEST-1', '[{"minSubtotalInr":0,"belowSubtotalInr":500,"feeInr":59,"gstRatePercent":18}]'::jsonb) $$,
  '22023', 'RETAIL_CONFIG_INVALID', 'the last slab must be open-ended');
select throws_ok(
  $$ select public.retail_shipping_rate_card_replace_v1('RATECARD-TEST-1', '[{"minSubtotalInr":0,"belowSubtotalInr":500,"feeInr":59,"gstRatePercent":18},{"minSubtotalInr":600,"belowSubtotalInr":null,"feeInr":0,"gstRatePercent":18}]'::jsonb) $$,
  '22023', 'RETAIL_CONFIG_INVALID', 'slabs must be contiguous');

select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d01', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_SHIPPING_UNPRICED', 'no approved rate card means no quote');

select is(public.retail_shipping_rate_card_replace_v1('RATECARD-TEST-1',
  '[{"minSubtotalInr":0,"belowSubtotalInr":500,"feeInr":59,"gstRatePercent":18},{"minSubtotalInr":500,"belowSubtotalInr":null,"feeInr":0,"gstRatePercent":18}]'::jsonb) ->> 'slabs',
  '2', 'an admin can load the rate card');

select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d01', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)), '07', '560001')) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_PIN_NOT_SERVICEABLE', 'a PIN outside the approved list is refused');

-- ---------------------------------------------------------------------------
-- Product sellability and tax authority
-- ---------------------------------------------------------------------------
select is(public.retail_price_resolve_v1('95100000-0000-0000-0000-00000000000f') ->> 'reason', 'not_published', 'an unpublished product is not sellable');
select is(public.retail_price_resolve_v1('95100000-0000-0000-0000-00000000000e') ->> 'reason', 'no_approved_retail_price', 'only the retail channel prices retail (a b2b price never leaks)');
select is(public.retail_price_resolve_v1('95100000-0000-0000-0000-000000000010') ->> 'reason', 'no_approved_retail_price', 'a draft retail price is not used');
select is(public.retail_price_resolve_v1('95100000-0000-0000-0000-000000000011') ->> 'reason', 'no_approved_retail_price', 'a GST-exclusive rule is not used for GST-inclusive display');
select is(public.retail_price_resolve_v1('95100000-0000-0000-0000-00000000000c') ->> 'reason', 'tax_rate_conflict', 'disagreeing GST columns block the product instead of guessing');
select is(public.retail_price_resolve_v1('95100000-0000-0000-0000-00000000000d') ->> 'reason', 'tax_rate_conflict', 'a fractional GST scale is unrecognised and blocks the product');
select is((public.retail_price_resolve_v1('95100000-0000-0000-0000-00000000000a') ->> 'unitPriceInclusive')::numeric, 105.00, 'an approved retail rule resolves to its price');

select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d02', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1), pg_temp.item('95100000-0000-0000-0000-00000000000c', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_PRODUCT_NOT_SELLABLE', 'one non-sellable line blocks the whole quote');

-- Display
select is(public.retail_price_display_v1(array['95100000-0000-0000-0000-00000000000a'::uuid, '95100000-0000-0000-0000-00000000000c'::uuid]) #>> '{items,0,taxIncludedPerUnit}',
  '5.00', 'display shows the GST included in a 105.00 price at 5%');
select is(public.retail_price_display_v1(array['95100000-0000-0000-0000-00000000000a'::uuid, '95100000-0000-0000-0000-00000000000c'::uuid]) #>> '{items,1,available}',
  'false', 'display never shows a price for a conflicted product');

-- ---------------------------------------------------------------------------
-- Quote arithmetic (GST-inclusive)
-- ---------------------------------------------------------------------------
insert into t select 'q1', public.retail_quote_create_v2((select v from t where k = 'tokA'),
  pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d11', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 2), pg_temp.item('95100000-0000-0000-0000-00000000000b', 1)))) ::text;
select is((select v::jsonb #>> '{totals,inclusiveTotal}' from t where k = 'q1'), '387.00', 'inclusive total = 210 + 118 + 59 shipping');
select is((select v::jsonb #>> '{totals,taxableTotal}' from t where k = 'q1'), '350.00', 'taxable total = 200 + 100 + 50');
select is((select v::jsonb #>> '{totals,taxTotal}' from t where k = 'q1'), '37.00', 'tax total = 10 + 18 + 9 (inclusive minus taxable)');
select is((select v::jsonb #>> '{totals,cgst}' from t where k = 'q1') || '/' || (select v::jsonb #>> '{totals,sgst}' from t where k = 'q1') || '/' || (select v::jsonb #>> '{totals,igst}' from t where k = 'q1'),
  '18.50/18.50/0', 'intra-state supply splits CGST and SGST');
select is((select v::jsonb #>> '{totals,supply}' from t where k = 'q1'), 'intra_state', 'seller and destination state match');
select is((select v::jsonb #>> '{lines,0,taxableValue}' from t where k = 'q1'), '200.00', 'line taxable value is derived from the inclusive price');
select is((select v::jsonb ->> 'priceDisplayMode' from t where k = 'q1'), 'inclusive', 'the quote declares GST-inclusive pricing');
select is((select count(*)::int from public.retail_quotes), 1, 'the quote is stored');
select ok((select (settings_snapshot ->> 'quote.validity_minutes') = 'TEST-REF-1' from public.retail_quotes limit 1), 'the quote records which approvals it relied on');
select ok((select expires_at between now() + interval '14 minutes' and now() + interval '16 minutes' from public.retail_quotes limit 1), 'validity comes from the approved setting');

insert into t select 'q1r', public.retail_quote_create_v2((select v from t where k = 'tokA'),
  pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d11', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 2), pg_temp.item('95100000-0000-0000-0000-00000000000b', 1))))::text;
select is((select v::jsonb ->> 'quoteId' from t where k = 'q1r'), (select v::jsonb ->> 'quoteId' from t where k = 'q1'), 'an exact replay returns the same quote');
select is((select v::jsonb ->> 'replayed' from t where k = 'q1r'), 'true', 'the replay is marked');
select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d11', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 3)))) $f$, (select v from t where k = 'tokA')),
  '23505', 'RETAIL_QUOTE_IDEMPOTENCY_CONFLICT', 'the same key with a different request conflicts');

-- Inter-state, merged duplicate lines, free_above
do $$ begin perform pg_temp.approve('shipping.model', '"free_above"'); end $$;
select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d12', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_COMMERCE_BLOCKED', 'free_above without an approved threshold blocks the quote');
do $$ begin perform pg_temp.approve('shipping.free_above_amount_inr', '300'); end $$;
insert into t select 'q2', public.retail_quote_create_v2((select v from t where k = 'tokA'),
  pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d12', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 2), pg_temp.item('95100000-0000-0000-0000-00000000000a', 1), pg_temp.item('95100000-0000-0000-0000-00000000000b', 1)), '27', '400001'))::text;
select is((select v::jsonb #>> '{lines,0,quantity}' from t where k = 'q2'), '3', 'duplicate product lines are merged');
select is((select v::jsonb #>> '{totals,inclusiveTotal}' from t where k = 'q2'), '433.00', 'free_above waives shipping at or above the threshold (315 + 118)');
select is((select v::jsonb #>> '{totals,igst}' from t where k = 'q2') || '/' || (select v::jsonb #>> '{totals,cgst}' from t where k = 'q2'), '33.00/0', 'inter-state supply is IGST only');
do $$ begin perform pg_temp.approve('shipping.model', '"flat"'); end $$;
select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d13', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  'P0001', 'RETAIL_SHIPPING_UNPRICED', 'a flat model over a multi-slab card is unpriced, not guessed');
do $$ begin perform pg_temp.approve('shipping.model', '"slab"'); end $$;
do $$ begin perform pg_temp.approve('tax.price_display_mode', '"exclusive"'); end $$;
select throws_ok(format($f$ select public.retail_quote_create_v2(%L, pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d14', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 1)))) $f$, (select v from t where k = 'tokA')),
  '0A000', 'RETAIL_PRICE_MODE_UNSUPPORTED', 'an approved GST-exclusive mode is not silently rendered as inclusive');
do $$ begin perform pg_temp.approve('tax.price_display_mode', '"inclusive"'); end $$;

-- ---------------------------------------------------------------------------
-- Customer isolation
-- ---------------------------------------------------------------------------
select throws_ok(format($f$ select public.retail_order_create_v1(%L, %L::uuid, '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5e01') $f$,
  (select v from t where k = 'tokB'), (select v::jsonb ->> 'quoteId' from t where k = 'q1')),
  'P0002', 'RETAIL_QUOTE_NOT_FOUND', 'another customer cannot order from my quote, and cannot tell it exists');
select is(public.retail_quote_create_v2((select v from t where k = 'tokB'),
  pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d11', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000a', 3))))->> 'replayed',
  'false', 'idempotency keys are scoped to the customer');

-- ---------------------------------------------------------------------------
-- Order
-- ---------------------------------------------------------------------------
insert into t select 'o1', public.retail_order_create_v1((select v from t where k = 'tokA'), (select (v::jsonb ->> 'quoteId')::uuid from t where k = 'q1'), '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5e02')::text;
select is((select v::jsonb ->> 'status' from t where k = 'o1'), 'pending_payment', 'a new order awaits payment');
select is((select v::jsonb ->> 'stockReservationEnforced' from t where k = 'o1'), 'false', 'the reservation is recorded but declared not inventory-enforced');
select ok((select reservation_expires_at between now() + interval '29 minutes' and now() + interval '31 minutes' from public.retail_orders limit 1), 'the reservation window comes from the approved setting');
select is((select total_inr from public.retail_orders limit 1), 387.00, 'the order total is the quoted total');
select is(public.retail_order_create_v1((select v from t where k = 'tokA2'), (select (v::jsonb ->> 'quoteId')::uuid from t where k = 'q1'), '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5e02') ->> 'replayed',
  'true', 'order creation is idempotent, also from a second session of the same customer');
select throws_ok(format($f$ select public.retail_order_create_v1(%L, %L::uuid, '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5e03') $f$,
  (select v from t where k = 'tokA'), (select v::jsonb ->> 'quoteId' from t where k = 'q1')),
  '23505', 'RETAIL_QUOTE_ALREADY_ORDERED', 'a quote becomes one order');
update public.retail_quotes set expires_at = now() - interval '1 minute' where id = (select (v::jsonb ->> 'quoteId')::uuid from t where k = 'q2');
select throws_ok(format($f$ select public.retail_order_create_v1(%L, %L::uuid, '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5e04') $f$,
  (select v from t where k = 'tokA'), (select v::jsonb ->> 'quoteId' from t where k = 'q2')),
  'P0001', 'RETAIL_QUOTE_EXPIRED', 'an expired quote cannot be ordered');

-- ---------------------------------------------------------------------------
-- Payment intent and Razorpay association
-- ---------------------------------------------------------------------------
select throws_ok(format($f$ select public.retail_payment_intent_create_v1(%L, %L::uuid) $f$, (select v from t where k = 'tokB'), (select v::jsonb ->> 'orderId' from t where k = 'o1')),
  'P0002', 'RETAIL_ORDER_NOT_FOUND', 'another customer cannot pay my order');
insert into t select 'i1', public.retail_payment_intent_create_v1((select v from t where k = 'tokA'), (select (v::jsonb ->> 'orderId')::uuid from t where k = 'o1'))::text;
select is((select v::jsonb ->> 'amountPaise' from t where k = 'i1'), '38700', 'the amount is derived server-side from the order, in paise');
select is(public.retail_payment_intent_create_v1((select v from t where k = 'tokA'), (select (v::jsonb ->> 'orderId')::uuid from t where k = 'o1')) ->> 'intentId',
  (select v::jsonb ->> 'intentId' from t where k = 'i1'), 'creating an intent again returns the open intent');
select throws_ok(format($f$ select public.retail_payment_intent_associate_v1(%L::uuid, 'order_TESTAAAA0001', 100, 'INR') $f$, (select v::jsonb ->> 'intentId' from t where k = 'i1')),
  '22023', 'RETAIL_PAYMENT_ASSOCIATION_INVALID', 'a provider order whose amount differs is refused');
select throws_ok(format($f$ select public.retail_payment_intent_associate_v1(%L::uuid, 'bad id', 38700, 'INR') $f$, (select v::jsonb ->> 'intentId' from t where k = 'i1')),
  '22023', 'RETAIL_PAYMENT_ASSOCIATION_INVALID', 'a malformed provider order id is refused');
select is(public.retail_payment_intent_associate_v1((select (v::jsonb ->> 'intentId')::uuid from t where k = 'i1'), 'order_TESTAAAA0001', 38700, 'INR') ->> 'status',
  'associated', 'the Razorpay order is associated');
select throws_ok(format($f$ select public.retail_payment_intent_associate_v1(%L::uuid, 'order_TESTBBBB0002', 38700, 'INR') $f$, (select v::jsonb ->> 'intentId' from t where k = 'i1')),
  '23505', 'RETAIL_PAYMENT_ASSOCIATION_CONFLICT', 'an intent cannot be re-bound to a different provider order');

do $$ begin perform pg_temp.approve('payment.provider', '"cashfree"'); end $$;
select throws_ok(format($f$ select public.retail_payment_intent_create_v1(%L, %L::uuid) $f$, (select v from t where k = 'tokA'), (select v::jsonb ->> 'orderId' from t where k = 'o1')),
  '0A000', 'RETAIL_PAYMENT_PROVIDER_UNSUPPORTED', 'only the approved Razorpay integration exists; another approved provider is not silently routed');
do $$ begin perform pg_temp.approve('payment.provider', '"razorpay"'); end $$;

-- ---------------------------------------------------------------------------
-- Durable webhook application
-- ---------------------------------------------------------------------------
select is(public.retail_payment_event_apply_v1('evt_unknown', 'payment.captured', 'order_NOSUCH0001', 'pay_1', 38700, 'INR', '{"x":1}'::jsonb, repeat('a', 64)) ->> 'outcome',
  'unknown_intent', 'an event for an unknown provider order changes nothing');
select is(public.retail_payment_event_apply_v1('evt_mismatch', 'payment.captured', 'order_TESTAAAA0001', 'pay_1', 100, 'INR', '{"x":2}'::jsonb, repeat('b', 64)) ->> 'outcome',
  'amount_mismatch', 'a captured amount that differs from the intent is recorded, not applied');
select is((select status from public.retail_orders limit 1), 'pending_payment', 'a mismatched amount never marks the order paid');
select is(public.retail_payment_event_apply_v1('evt_fail', 'payment.failed', 'order_TESTAAAA0001', 'pay_0', 38700, 'INR', '{"x":3}'::jsonb, repeat('c', 64)) ->> 'outcome',
  'failure_recorded', 'a failed attempt is recorded');
select is((select status from public.retail_orders limit 1), 'pending_payment', 'a failed attempt leaves the order payable');
select is(public.retail_payment_event_apply_v1('evt_other', 'refund.processed', 'order_TESTAAAA0001', 'pay_1', 38700, 'INR', '{"x":4}'::jsonb, repeat('d', 64)) ->> 'outcome',
  'ignored_event_type', 'unsupported event types are stored and ignored');
select is(public.retail_payment_event_apply_v1('evt_ok', 'payment.captured', 'order_TESTAAAA0001', 'pay_1', 38700, 'INR', '{"x":5}'::jsonb, repeat('e', 64)) ->> 'outcome',
  'applied', 'a matching captured event is applied');
select is((select status from public.retail_orders limit 1), 'paid', 'the order is paid only by a verified matching event');
select ok((select paid_at is not null and not paid_after_reservation_expiry from public.retail_orders limit 1), 'payment time recorded, not late');
select is(public.retail_payment_event_apply_v1('evt_ok', 'payment.captured', 'order_TESTAAAA0001', 'pay_1', 38700, 'INR', '{"x":5}'::jsonb, repeat('e', 64)) ->> 'duplicate',
  'true', 'a redelivered event is a no-op reporting the original outcome');
select throws_ok($$ select public.retail_payment_event_apply_v1('evt_ok', 'payment.captured', 'order_TESTAAAA0001', 'pay_1', 38700, 'INR', '{"x":6}'::jsonb, repeat('f', 64)) $$,
  '23505', 'RETAIL_PAYMENT_EVENT_CONFLICT', 'the same event id with a different payload is a conflict');
select is((select count(*)::int from public.retail_payment_events), 5, 'every distinct provider event is stored durably (5 stored; the duplicate added none)');
select throws_ok($$ update public.retail_payment_events set processing_status = 'applied' $$, '55000', 'RETAIL_PAYMENT_EVENTS_APPEND_ONLY', 'provider events are append-only');
select throws_ok($$ delete from public.retail_payment_events $$, '55000', 'RETAIL_PAYMENT_EVENTS_APPEND_ONLY', 'provider events cannot be deleted');
select lives_ok($$ select public.retail_payment_event_reject_v1(repeat('1', 64), 'signature_invalid') $$, 'a rejected delivery is logged');
select throws_ok($$ select public.retail_payment_event_reject_v1(repeat('1', 64), 'because') $$, '23514', 'new row for relation "retail_payment_event_rejections" violates check constraint "retail_payment_event_rejections_reason_check"', 'rejection reasons are constrained');
select throws_ok(format($f$ select public.retail_payment_intent_create_v1(%L, %L::uuid) $f$, (select v from t where k = 'tokA'), (select v::jsonb ->> 'orderId' from t where k = 'o1')),
  'P0001', 'RETAIL_ORDER_NOT_PAYABLE', 'a paid order cannot be paid again');

-- A late payment is still money received; it is flagged for operations rather than discarded.
insert into t select 'q3', public.retail_quote_create_v2((select v from t where k = 'tokB'),
  pg_temp.req('6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d21', jsonb_build_array(pg_temp.item('95100000-0000-0000-0000-00000000000b', 1))))::text;
insert into t select 'o3', public.retail_order_create_v1((select v from t where k = 'tokB'), (select (v::jsonb ->> 'quoteId')::uuid from t where k = 'q3'), '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5e31')::text;
insert into t select 'i3', public.retail_payment_intent_create_v1((select v from t where k = 'tokB'), (select (v::jsonb ->> 'orderId')::uuid from t where k = 'o3'))::text;
select public.retail_payment_intent_associate_v1((select (v::jsonb ->> 'intentId')::uuid from t where k = 'i3'), 'order_TESTCCCC0003', 17700, 'INR');
update public.retail_orders set reservation_expires_at = now() - interval '1 minute' where id = (select (v::jsonb ->> 'orderId')::uuid from t where k = 'o3');
select is(public.retail_payment_event_apply_v1('evt_late', 'payment.captured', 'order_TESTCCCC0003', 'pay_9', 17700, 'INR', '{"x":9}'::jsonb, repeat('9', 64)) ->> 'outcome',
  'applied', 'a late captured payment is applied');
select ok((select paid_after_reservation_expiry from public.retail_orders where id = (select (v::jsonb ->> 'orderId')::uuid from t where k = 'o3')), 'and flagged as paid after the reservation expired');

-- ---------------------------------------------------------------------------
-- Sessions: expiry, revoke, optional account, row-level isolation
-- ---------------------------------------------------------------------------
update public.retail_sessions set expires_at = now() - interval '1 second'
 where token_hash = encode(sha256(convert_to((select v from t where k = 'tokA2'), 'UTF8')), 'hex');
select throws_ok(format($f$ select public.retail_order_create_v1(%L, gen_random_uuid(), gen_random_uuid()::text) $f$, (select v from t where k = 'tokA2')),
  '28000', 'RETAIL_SESSION_INVALID', 'an expired session is refused');
select lives_ok(format($f$ select public.retail_session_revoke_v1(%L) $f$, (select v from t where k = 'tokB')), 'a session can be revoked');
select throws_ok(format($f$ select public.retail_session_revoke_v1(%L) $f$, (select v from t where k = 'tokB')), '28000', 'RETAIL_SESSION_INVALID', 'a revoked session is refused');
insert into t select 'tokB2', public.retail_session_issue_v1('919876543211') ->> 'sessionToken';

select set_config('request.jwt.claim.sub', '', true);
select throws_ok(format($f$ select public.retail_customer_link_account_v1(%L) $f$, (select v from t where k = 'tokA')), '42501', 'RETAIL_ACCOUNT_LINK_FORBIDDEN', 'linking needs an authenticated account');
select set_config('request.jwt.claim.sub', '95000000-0000-0000-0000-000000000002', true);
select is(public.retail_customer_link_account_v1((select v from t where k = 'tokA')) ->> 'linked', 'true', 'an account links to a customer that proved phone control');
select is(public.retail_customer_link_account_v1((select v from t where k = 'tokA')) ->> 'linked', 'true', 'linking is idempotent for the same account');
select throws_ok(format($f$ select public.retail_customer_link_account_v1(%L) $f$, (select v from t where k = 'tokB2')), '23505', 'RETAIL_ACCOUNT_LINK_CONFLICT', 'an account cannot be linked to two customers');
select set_config('request.jwt.claim.sub', '95000000-0000-0000-0000-000000000003', true);
select throws_ok(format($f$ select public.retail_customer_link_account_v1(%L) $f$, (select v from t where k = 'tokA')), '23505', 'RETAIL_ACCOUNT_LINK_CONFLICT', 'a customer cannot be taken over by another account');

set local role authenticated;
select set_config('request.jwt.claim.sub', '95000000-0000-0000-0000-000000000002', true);
select is((select count(*)::int from public.retail_orders), 1, 'a linked account sees only its own retail orders');
select is((select count(*)::int from public.retail_quotes), 2, 'and only its own quotes');
select set_config('request.jwt.claim.sub', '95000000-0000-0000-0000-000000000003', true);
select is((select count(*)::int from public.retail_orders), 0, 'an unrelated account sees no retail orders');
select is((select count(*)::int from public.retail_customers), 0, 'and no retail customers');
reset role;

select * from finish();
rollback;
