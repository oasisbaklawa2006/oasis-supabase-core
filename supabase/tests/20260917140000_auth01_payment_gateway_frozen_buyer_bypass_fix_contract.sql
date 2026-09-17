-- Contract test for 20260917140000_auth01_payment_gateway_frozen_buyer_bypass_fix.sql
--
-- Regression for the AUTH-01 RPC security certification finding: a buyer
-- whose company has been frozen must NOT be able to create a payment-
-- gateway payable intent, or read an existing intent's status, for that
-- company's order -- even though their own profiles.company_id row is
-- still on file. Before this fix, both RPCs resolved company via the
-- weaker auth_buyer_company_id() helper, which has no frozen/approved
-- check; this test fails against the pre-fix definitions and passes
-- against the fixed ones.
--
-- create_payment_gateway_payable_intent_v1's company-scope check fires
-- BEFORE purpose/provider validation and before touching
-- payment_gateway_payable_intents/payment_gateway_idempotency at all, so
-- the negative case needs no further schema. The positive control
-- deliberately supplies an invalid payment purpose so the function raises
-- PAYMENT_GATEWAY_INTENT_EVIDENCE_REQUIRED (P0001) rather than the
-- company-scope error (42501) -- reaching that later exception proves the
-- auth gate was passed, without needing the full intent-creation machinery
-- (derive_payment_gateway_canonical_amount_v1 and its supporting tables,
-- which are Finance-lane infrastructure out of scope for this AUTH-01 pass)
-- to exist in this harness.
begin;

select plan(4);

-- ── create_payment_gateway_payable_intent_v1 ──────────────────────────

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen) values ('Frozen Payment Gateway Co', 'active', false) returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'frozen-pg@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'frozen-pg@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-FROZEN-PG-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;

  update public.companies set is_frozen = true where id = v_company;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.create_payment_gateway_payable_intent_v1(
      v_order, gen_random_uuid(), gen_random_uuid(), 'advance', 'razorpay', 'corr-1', 'idem-1', v_buyer
    );
    raise exception 'SECURITY REGRESSION: buyer of a FROZEN company can create a payment-gateway payable intent for their own order';
  exception
    when sqlstate '42501' then
      null; -- expected: PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('frozen-company buyer is denied at the company-scope gate for create_payment_gateway_payable_intent_v1');

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen) values ('Active Payment Gateway Co', 'active', false) returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'active-pg@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'active-pg@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-ACTIVE-PG-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    -- Deliberately invalid purpose: reaching PAYMENT_GATEWAY_INTENT_EVIDENCE_REQUIRED
    -- (not the company-scope error) proves the auth gate was passed.
    perform public.create_payment_gateway_payable_intent_v1(
      v_order, gen_random_uuid(), gen_random_uuid(), 'not_a_real_purpose', 'razorpay', 'corr-2', 'idem-2', v_buyer
    );
    raise exception 'REGRESSION: invalid payment purpose was not rejected -- test setup is unsound';
  exception
    when sqlstate '42501' then
      raise exception 'REGRESSION: approved active-company buyer was denied at the company-scope gate after the fix';
    when sqlstate 'P0001' then
      null; -- expected: PAYMENT_GATEWAY_INTENT_EVIDENCE_REQUIRED -- auth gate passed
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('approved active-company buyer passes the company-scope gate for create_payment_gateway_payable_intent_v1');

-- ── get_payment_gateway_payable_status_v1 ─────────────────────────────

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
  v_intent uuid := gen_random_uuid();
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen) values ('Frozen Payment Status Co', 'active', false) returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'frozen-pg-status@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'frozen-pg-status@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-FROZEN-PG-STATUS-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;
  insert into public.payment_gateway_payable_intents (id, order_id, company_id, payment_purpose, provider_code, canonical_amount, currency, status)
  values (v_intent, v_order, v_company, 'advance', 'razorpay', 1000, 'INR', 'created');

  update public.companies set is_frozen = true where id = v_company;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.get_payment_gateway_payable_status_v1(v_intent);
    raise exception 'SECURITY REGRESSION: buyer of a FROZEN company can read payment-gateway intent status for their own order';
  exception
    when sqlstate '42501' then
      null; -- expected: PAYMENT_GATEWAY_COMPANY_SCOPE_REQUIRED
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('frozen-company buyer cannot read payment-gateway intent status after the fix');

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
  v_intent uuid := gen_random_uuid();
  v_result jsonb;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen) values ('Active Payment Status Co', 'active', false) returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'active-pg-status@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'active-pg-status@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-ACTIVE-PG-STATUS-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;
  insert into public.payment_gateway_payable_intents (id, order_id, company_id, payment_purpose, provider_code, canonical_amount, currency, status)
  values (v_intent, v_order, v_company, 'advance', 'razorpay', 1000, 'INR', 'created');

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select public.get_payment_gateway_payable_status_v1(v_intent) into v_result;
  if v_result is null or (v_result->>'intent_id')::uuid is distinct from v_intent then
    raise exception 'REGRESSION: approved active-company buyer lost access to own payment-gateway intent status after the fix';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('approved buyer of an active company retains payment-gateway intent status access after the fix');

select * from finish();
rollback;
