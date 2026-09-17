-- Contract test for 20260917130000_auth01_final_payment_pi_frozen_buyer_bypass_fix.sql
--
-- Regression for the AUTH-01 RPC security certification finding: a buyer
-- whose company has been frozen must NOT be able to read final-payment-PI
-- details (payment link, instructions, balance due) for that company's
-- orders via get_sales_order_pi_final_payment_request_v1(), even though
-- their own profiles.company_id row is still on file. Before this fix, the
-- function and its governing RLS resolved company via the weaker
-- auth_buyer_company_id() helper, which has no frozen/approved check; this
-- test fails against the pre-fix definition and passes against the fixed
-- one.
begin;

select plan(2);

do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen) values ('Frozen Final-Payment Co', 'active', false) returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'frozen-final-payment@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'frozen-final-payment@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-FROZEN-FINAL-PAYMENT-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;

  -- Freeze the company AFTER the buyer/order already exist -- profiles.company_id
  -- is untouched by freezing, which is exactly what made the old helper unsafe.
  update public.companies set is_frozen = true where id = v_company;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.get_sales_order_pi_final_payment_request_v1(v_order);
    raise exception 'SECURITY REGRESSION: buyer of a FROZEN company can read final-payment-PI details for their own order';
  exception
    when sqlstate '42501' then
      null; -- expected: FINAL_PAYMENT_PI_COMPANY_MISMATCH once the buyer no longer resolves via customer_buyer_eligible_company_id()
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('frozen-company buyer cannot read final-payment-PI details after the fix');

-- Positive control: an approved buyer of an ACTIVE (not frozen) company
-- retains access to their own order's final-payment-PI availability check.
do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
  v_result jsonb;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen) values ('Active Final-Payment Co', 'active', false) returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'active-final-payment@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'active-final-payment@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-ACTIVE-FINAL-PAYMENT-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select public.get_sales_order_pi_final_payment_request_v1(v_order) into v_result;
  if v_result is null or (v_result->>'available') is null then
    raise exception 'REGRESSION: approved active-company buyer lost access to own order final-payment-PI check after the fix';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('approved buyer of an active company retains final-payment-PI access after the fix');

select * from finish();
rollback;
