-- Retail commerce configuration contract coverage for
-- 20261119020200_retail_commerce_configuration_v1.sql (PENDING OWNER APPROVAL, not activated).
-- All values below are synthetic test values inside a rolled-back transaction; none is a proposal.

begin;

select plan(73);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('94000000-0000-0000-0000-000000000001', 'rc-admin@example.invalid'),
  ('94000000-0000-0000-0000-000000000002', 'rc-inactive@example.invalid'),
  ('94000000-0000-0000-0000-000000000003', 'rc-support@example.invalid');
insert into public.users (id, role, email, is_active) values
  ('94000000-0000-0000-0000-000000000001', 'admin', 'rc-admin@example.invalid', true),
  ('94000000-0000-0000-0000-000000000002', 'admin', 'rc-inactive@example.invalid', false),
  ('94000000-0000-0000-0000-000000000003', 'support_executive', 'rc-support@example.invalid', true);

create or replace function pg_temp.as_admin() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '94000000-0000-0000-0000-000000000001', true)
$$;

create or replace function pg_temp.approve(p_key text, p_value jsonb) returns jsonb language sql as $$
  select public.retail_commerce_set_setting_v1(p_key, p_value, 'approved', 'TEST-REF-1')
$$;

create or replace function pg_temp.action(p_name text) returns jsonb language sql stable as $$
  select public.retail_commerce_readiness_v1() -> 'actions' -> p_name
$$;

create or replace function pg_temp.valid_request() returns jsonb language sql stable as $$
  select jsonb_build_object(
    'idempotencyKey', '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d6e',
    'items', jsonb_build_array(jsonb_build_object('productId', '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d6f', 'quantity', 2)),
    'shipTo', jsonb_build_object('pincode', '110015', 'stateCode', '07'),
    'currency', 'INR')
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
select ok(
  not has_table_privilege('anon', 'public.retail_commerce_settings', 'SELECT')
  and not has_table_privilege('authenticated', 'public.retail_commerce_settings', 'SELECT')
  and not has_table_privilege('authenticated', 'public.retail_commerce_settings', 'INSERT')
  and not has_table_privilege('authenticated', 'public.retail_commerce_settings', 'UPDATE'),
  'anon and authenticated have no direct access to the settings table'
);
select ok(
  not has_table_privilege('service_role', 'public.retail_commerce_settings', 'INSERT')
  and not has_table_privilege('service_role', 'public.retail_commerce_settings', 'UPDATE')
  and not has_table_privilege('service_role', 'public.retail_commerce_settings', 'DELETE')
  and has_table_privilege('service_role', 'public.retail_commerce_settings', 'SELECT'),
  'service_role can read but never write settings directly'
);
select ok(
  not has_table_privilege('service_role', 'public.retail_commerce_setting_history', 'INSERT')
  and not has_table_privilege('service_role', 'public.retail_commerce_setting_history', 'UPDATE')
  and not has_table_privilege('service_role', 'public.retail_commerce_setting_history', 'DELETE')
  and not has_table_privilege('authenticated', 'public.retail_commerce_setting_history', 'SELECT'),
  'the history table is append-only and not readable by authenticated'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.retail_commerce_settings'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.retail_commerce_setting_history'::regclass),
  'RLS is enabled on both tables'
);
select ok(
  has_function_privilege('authenticated', 'public.retail_commerce_set_setting_v1(text,jsonb,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retail_commerce_set_setting_v1(text,jsonb,text,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.retail_commerce_readiness_v1()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retail_commerce_readiness_v1()', 'EXECUTE'),
  'setter and readiness are callable by authenticated (runtime-gated), never by anon'
);
select ok(
  not has_function_privilege('authenticated', 'public.retail_commerce_assert_action_v1(text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.retail_quote_create_v1(jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retail_quote_create_v1(jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.retail_quote_create_v1(jsonb)', 'EXECUTE'),
  'the guard and the quote entry point are service_role only'
);
select ok(
  (select bool_and(prosecdef and proconfig @> array['search_path=pg_catalog, public'])
     from pg_proc
    where oid in (
      'public.retail_commerce_set_setting_v1(text,jsonb,text,text)'::regprocedure,
      'public.retail_commerce_readiness_v1()'::regprocedure,
      'public.retail_commerce_assert_action_v1(text)'::regprocedure,
      'public.retail_quote_create_v1(jsonb)'::regprocedure)),
  'security definer functions have a fixed search_path'
);

-- ---------------------------------------------------------------------------
-- Value validation (types and ranges only)
-- ---------------------------------------------------------------------------
select ok(public.retail_commerce_validate_value_v1('payment.provider', '"razorpay"'), 'known enum value accepted');
select ok(not public.retail_commerce_validate_value_v1('payment.provider', '"paypal"'), 'unknown enum value rejected');
select ok(not public.retail_commerce_validate_value_v1('payment.provider', '5'), 'wrong JSON type rejected');
select ok(public.retail_commerce_validate_value_v1('tax.seller_state_code', '"07"'), 'two-digit state code accepted');
select ok(not public.retail_commerce_validate_value_v1('tax.seller_state_code', '"7"'), 'one-digit state code rejected');
select ok(not public.retail_commerce_validate_value_v1('tax.seller_state_code', '"ABC"'), 'non-numeric state code rejected');
select ok(public.retail_commerce_validate_value_v1('quote.validity_minutes', '15'), 'in-range integer accepted');
select ok(not public.retail_commerce_validate_value_v1('quote.validity_minutes', '0'), 'integer below range rejected');
select ok(not public.retail_commerce_validate_value_v1('quote.validity_minutes', '121'), 'integer above range rejected');
select ok(not public.retail_commerce_validate_value_v1('quote.validity_minutes', '15.5'), 'fractional integer rejected');
select ok(public.retail_commerce_validate_value_v1('shipping.free_above_amount_inr', '0'), 'zero free-above amount accepted');
select ok(not public.retail_commerce_validate_value_v1('shipping.free_above_amount_inr', '-1'), 'negative amount rejected');
select ok(not public.retail_commerce_validate_value_v1('checkout.guest_allowed', '"yes"'), 'boolean given as string rejected');
select ok(not public.retail_commerce_validate_value_v1('no.such.key', 'true'), 'unknown setting key rejected');
select ok(not public.retail_commerce_validate_value_v1('checkout.guest_allowed', null), 'null value rejected');

-- ---------------------------------------------------------------------------
-- Default state: everything blocked, nothing configured
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.retail_commerce_settings), 0, 'no setting exists by default');
select is(public.retail_commerce_readiness_v1() ->> 'architectureStatus', 'pending_owner_approval', 'architecture is pending owner approval by default');
select is(public.retail_commerce_readiness_v1() ->> 'activated', 'false', 'commerce is not activated by default');
select ok(
  not coalesce((pg_temp.action('quote') ->> 'allowed')::boolean, true)
  and not coalesce((pg_temp.action('order') ->> 'allowed')::boolean, true)
  and not coalesce((pg_temp.action('payment') ->> 'allowed')::boolean, true)
  and not coalesce((pg_temp.action('refund') ->> 'allowed')::boolean, true),
  'quote, order, payment and refund are all blocked by default'
);
select ok(
  (pg_temp.action('quote') -> 'missing') @> '["tax.price_display_mode","shipping.fee_table_ref","quote.validity_minutes","stock.reservation_minutes","architecture_approved","activation_enabled"]'::jsonb,
  'the quote action names every missing setting, including both gates'
);
select ok(
  (pg_temp.action('refund') -> 'missing') @> '["refund.window_hours","refund.approver_role"]'::jsonb
  and not ((pg_temp.action('refund') -> 'missing') ? 'shipping.model'),
  'refund lists only its own dependencies'
);

-- ---------------------------------------------------------------------------
-- Authorization of the setter
-- ---------------------------------------------------------------------------
reset request.jwt.claim.sub;
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '15') $$,
  '42501', 'RETAIL_CONFIG_FORBIDDEN', 'an unauthenticated or service_role caller cannot write a setting'
);
set local request.jwt.claim.sub = '94000000-0000-0000-0000-000000000003';
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '15') $$,
  '42501', 'RETAIL_CONFIG_FORBIDDEN', 'ordinary staff cannot write a setting'
);
set local request.jwt.claim.sub = '94000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '15', 'approved', 'X') $$,
  '42501', 'RETAIL_CONFIG_FORBIDDEN', 'an inactive admin cannot approve a setting'
);
select is((select count(*)::int from public.retail_commerce_settings), 0, 'rejected callers wrote nothing');

-- ---------------------------------------------------------------------------
-- Setter behaviour (active admin)
-- ---------------------------------------------------------------------------
do $$ begin perform pg_temp.as_admin(); end $$;
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '0') $$,
  '22023', 'RETAIL_CONFIG_INVALID', 'an out-of-range value is rejected'
);
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('no.such.key', 'true') $$,
  '22023', 'RETAIL_CONFIG_INVALID', 'an unknown key is rejected'
);
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '15', 'live') $$,
  '22023', 'RETAIL_CONFIG_INVALID', 'an unknown status is rejected'
);
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '15', 'approved') $$,
  '22023', 'RETAIL_CONFIG_APPROVAL_REFERENCE_REQUIRED', 'approval without a reference is rejected'
);
select throws_ok(
  $$ select public.retail_commerce_set_setting_v1('quote.validity_minutes', '15', 'approved', '   ') $$,
  '22023', 'RETAIL_CONFIG_APPROVAL_REFERENCE_REQUIRED', 'a blank approval reference is rejected'
);
-- SQL contract for forward migration 20261119020300_retail_commerce_setting_history_serialization_v1.sql.
-- A per-key transaction advisory lock must precede the old-row read.
-- This guards first-write concurrency; a FOR UPDATE on an absent row cannot.
select ok(
  position('pg_advisory_xact_lock' in pg_get_functiondef(
    'public.retail_commerce_set_setting_v1(text,jsonb,text,text)'::regprocedure
  )) > 0
  and position('pg_advisory_xact_lock' in pg_get_functiondef(
    'public.retail_commerce_set_setting_v1(text,jsonb,text,text)'::regprocedure
  )) < position('SELECT * INTO v_old' in pg_get_functiondef(
    'public.retail_commerce_set_setting_v1(text,jsonb,text,text)'::regprocedure
  )),
  'per-key transaction lock must occur before the first or subsequent history read'
);

-- Migration 20261119020300 (retail_commerce_setting_history_serialization_v1) keeps the original ACL.
select ok(
  not has_function_privilege('anon', 'public.retail_commerce_set_setting_v1(text,jsonb,text,text)', 'EXECUTE'),
  '20261119020300: anon cannot execute the setting writer'
);
select ok(
  has_function_privilege('authenticated', 'public.retail_commerce_set_setting_v1(text,jsonb,text,text)', 'EXECUTE'),
  '20261119020300: authenticated (admin-checked in body) can execute the setting writer'
);

select is(public.retail_commerce_set_setting_v1('quote.validity_minutes', '15') ->> 'status', 'proposed', 'a proposal is stored as proposed');
select is((select approved_by is null from public.retail_commerce_settings where setting_key = 'quote.validity_minutes'), true, 'a proposal carries no approver');
select ok(
  not coalesce((pg_temp.action('quote') ->> 'allowed')::boolean, true)
  and (pg_temp.action('quote') -> 'unapproved') ? 'quote.validity_minutes',
  'a proposed value is reported as unapproved and does not count'
);
select is(pg_temp.approve('quote.validity_minutes', '15') ->> 'status', 'approved', 'an admin can approve with a reference');
select is(
  (select approved_by::text from public.retail_commerce_settings where setting_key = 'quote.validity_minutes'),
  '94000000-0000-0000-0000-000000000001',
  'the approving admin is recorded'
);
select is(
  (select count(*)::int from public.retail_commerce_setting_history where setting_key = 'quote.validity_minutes'),
  2,
  'every change is appended to the history'
);
select is(public.retail_commerce_set_setting_v1('quote.validity_minutes', '20') ->> 'status', 'proposed', 'editing an approved value drops it back to a proposal');
select is(
  (select approval_reference is null and approved_by is null and approved_at is null
     from public.retail_commerce_settings where setting_key = 'quote.validity_minutes'),
  true,
  'an edit clears the earlier approval evidence'
);

-- ---------------------------------------------------------------------------
-- Readiness per action
-- ---------------------------------------------------------------------------
do $$ begin perform pg_temp.approve('quote.validity_minutes', '15'); end $$;
do $$ begin perform pg_temp.approve('stock.reservation_minutes', '30'); end $$;
do $$ begin perform pg_temp.approve('tax.price_display_mode', '"inclusive"'); end $$;
do $$ begin perform pg_temp.approve('tax.seller_state_code', '"07"'); end $$;
do $$ begin perform pg_temp.approve('shipping.model', '"slab"'); end $$;
do $$ begin perform pg_temp.approve('shipping.fee_table_ref', '"RATECARD-TEST-1"'); end $$;
do $$ begin perform pg_temp.approve('shipping.serviceable_pin_policy_ref', '"PINLIST-TEST-1"'); end $$;
do $$ begin perform pg_temp.approve('shipping.delivery_promise_days', '5'); end $$;

select ok(
  not coalesce((pg_temp.action('quote') ->> 'allowed')::boolean, true)
  and (pg_temp.action('quote') -> 'missing') @> '["architecture_approved","activation_enabled"]'::jsonb,
  'every quote setting approved is still blocked without the two gates'
);

do $$ begin perform pg_temp.approve('architecture_approved', 'true'); end $$;
select ok(
  not coalesce((pg_temp.action('quote') ->> 'allowed')::boolean, true)
  and (pg_temp.action('quote') -> 'missing') @> '["activation_enabled"]'::jsonb,
  'architecture approval alone does not activate anything'
);
do $$ begin perform pg_temp.approve('activation_enabled', 'true'); end $$;
select ok((pg_temp.action('quote') ->> 'allowed')::boolean, 'quote is allowed once every dependency and both gates are approved');
select ok(
  not (pg_temp.action('order') ->> 'allowed')::boolean
  and (pg_temp.action('order') -> 'missing') @> '["checkout.guest_allowed"]'::jsonb,
  'order stays blocked on its own missing setting'
);
select ok(
  not (pg_temp.action('payment') ->> 'allowed')::boolean
  and (pg_temp.action('payment') -> 'missing') @> '["payment.provider","payment.settlement_account_ref"]'::jsonb,
  'payment stays blocked on provider and settlement reference'
);
select ok(not (pg_temp.action('refund') ->> 'allowed')::boolean, 'refund stays blocked on its own missing settings');

-- cross-field and conditional rules
do $$ begin perform pg_temp.approve('stock.reservation_minutes', '10'); end $$;
select ok(
  not (pg_temp.action('quote') ->> 'allowed')::boolean
  and (pg_temp.action('quote') -> 'invalid') ? 'stock.reservation_minutes<quote.validity_minutes',
  'stock reserved for less time than the quote is valid blocks the action'
);
do $$ begin perform pg_temp.approve('stock.reservation_minutes', '30'); end $$;
select ok((pg_temp.action('quote') ->> 'allowed')::boolean, 'correcting the reservation unblocks the quote');

do $$ begin perform pg_temp.approve('shipping.model', '"free_above"'); end $$;
select ok(
  not (pg_temp.action('quote') ->> 'allowed')::boolean
  and (pg_temp.action('quote') -> 'missing') @> '["shipping.free_above_amount_inr"]'::jsonb,
  'free_above shipping requires its threshold'
);
do $$ begin perform pg_temp.approve('shipping.free_above_amount_inr', '1000'); end $$;
select ok((pg_temp.action('quote') ->> 'allowed')::boolean, 'the threshold completes the free_above model');

do $$ begin perform pg_temp.approve('activation_enabled', 'false'); end $$;
select ok(
  not (pg_temp.action('quote') ->> 'allowed')::boolean
  and (pg_temp.action('quote') -> 'invalid') ? 'activation_enabled',
  'an approved "false" gate keeps every action blocked'
);
do $$ begin perform pg_temp.approve('activation_enabled', 'true'); end $$;

-- ---------------------------------------------------------------------------
-- The guard and the quote entry point
-- ---------------------------------------------------------------------------
select lives_ok($$ select public.retail_commerce_assert_action_v1('quote') $$, 'the guard passes for an allowed action');
select throws_ok(
  $$ select public.retail_commerce_assert_action_v1('payment') $$,
  'P0001', 'RETAIL_COMMERCE_BLOCKED', 'the guard raises for a blocked action'
);
select throws_ok(
  $$ select public.retail_commerce_assert_action_v1('teleport') $$,
  '22023', 'RETAIL_COMMERCE_INVALID_ACTION', 'the guard rejects an unknown action'
);
select throws_ok(
  format($q$ select public.retail_quote_create_v1(%L::jsonb) $q$, pg_temp.valid_request()::text),
  '0A000', 'RETAIL_QUOTE_NOT_IMPLEMENTED', 'even with everything approved, no quote is ever produced yet'
);

-- ---------------------------------------------------------------------------
-- Request validation
-- ---------------------------------------------------------------------------
select is(
  public.retail_quote_request_validate_v1(pg_temp.valid_request() || '{"idempotencyKey":"6F1C1C58-5B7E-4A0E-9D6C-1F2A3B4C5D6E"}'::jsonb) ->> 'idempotencyKey',
  '6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d6e',
  'a valid request is normalised'
);
select throws_ok(format($q$ select public.retail_quote_request_validate_v1(%L::jsonb) $q$, (pg_temp.valid_request() || '{"extra":1}')::text), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'unknown request fields are rejected');
select throws_ok(format($q$ select public.retail_quote_request_validate_v1(%L::jsonb) $q$, (pg_temp.valid_request() || '{"currency":"USD"}')::text), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'a non-INR currency is rejected');
select throws_ok(format($q$ select public.retail_quote_request_validate_v1(%L::jsonb) $q$, (pg_temp.valid_request() || '{"shipTo":{"pincode":"012345","stateCode":"07"}}')::text), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'a PIN code starting with 0 is rejected');
select throws_ok(format($q$ select public.retail_quote_request_validate_v1(%L::jsonb) $q$, (pg_temp.valid_request() || '{"items":[{"productId":"6f1c1c58-5b7e-4a0e-9d6c-1f2a3b4c5d6f","quantity":0}]}')::text), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'a zero quantity is rejected');
select throws_ok(format($q$ select public.retail_quote_request_validate_v1(%L::jsonb) $q$, (pg_temp.valid_request() || '{"items":[]}')::text), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'an empty basket is rejected');
select throws_ok(format($q$ select public.retail_quote_request_validate_v1(%L::jsonb) $q$, (pg_temp.valid_request() || '{"items":[{"productId":"nope","quantity":1}]}')::text), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'a non-UUID product id is rejected');
select throws_ok($$ select public.retail_quote_request_validate_v1('[]'::jsonb) $$, '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'a non-object request is rejected');
select throws_ok(format($q$ select public.retail_quote_create_v1(%L::jsonb) $q$, '{"items":[]}'), '22023', 'RETAIL_QUOTE_REQUEST_INVALID', 'a malformed request is rejected before readiness is consulted');

-- ---------------------------------------------------------------------------
-- Readiness exposes names and statuses, never values
-- ---------------------------------------------------------------------------
do $$ begin perform pg_temp.approve('payment.provider', '"razorpay"'); end $$;
select ok(
  position('razorpay' in public.retail_commerce_readiness_v1()::text) = 0
  and position('RATECARD-TEST-1' in public.retail_commerce_readiness_v1()::text) = 0,
  'readiness output contains no configured values'
);

select * from finish();

rollback;
