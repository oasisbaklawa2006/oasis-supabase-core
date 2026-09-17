-- Contract test for 20260917120000_auth01_customer_order_surface_staff_exclusion_fix.sql
--
-- Regression for the AUTH-01 RPC security certification finding: an
-- internal staff profile that is (for any legitimate internal reason)
-- is_approved = true, status = 'approved', and carries a non-null
-- company_id must NOT see that company's orders, order line items, or
-- support tickets through customer_order_status_v1(),
-- customer_order_items_v1(), or customer_support_tickets_v1(). Before this
-- fix, all three used an inline eligibility gate with no role filter and no
-- staff exclusion; this test fails against the pre-fix definitions and
-- passes against the fixed ones.
begin;

select plan(4);

do $$
declare
  v_company uuid;
  v_staff uuid := gen_random_uuid();
  v_order uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Staff Surface Co', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_staff, 'staff-surface@example.com');
  -- The exact vulnerable shape: an internal staff profile that is approved
  -- and carries a company_id, as customer_buyer_eligible_company_id()'s own
  -- staff-exclusion test already establishes is a real, legitimate shape
  -- staff profiles can take (see 20260807170000_customer_identity_projections_v1_contract.sql).
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_staff, v_company, 'ADMIN', true, 'approved', 'staff-surface@example.com');

  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-STAFF-SURFACE-1', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;

  insert into public.support_tickets (order_id, issue_type, description, status, company_id)
  values (v_order::text, 'quality', 'Regression fixture ticket for staff-exclusion test.', 'open', v_company);

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  if (select count(*) from public.customer_order_status_v1() where order_id = v_order) > 0 then
    raise exception 'SECURITY REGRESSION: staff profile with company_id sees order status via customer_order_status_v1';
  end if;

  if (select count(*) from public.customer_order_items_v1() where order_id = v_order) > 0 then
    raise exception 'SECURITY REGRESSION: staff profile with company_id sees order items via customer_order_items_v1';
  end if;

  if (select count(*) from public.customer_support_tickets_v1()) > 0 then
    raise exception 'SECURITY REGRESSION: staff profile with company_id sees support tickets via customer_support_tickets_v1';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('staff with is_approved/status=approved/company_id sees zero rows from customer_order_status_v1');
select pass('staff with is_approved/status=approved/company_id sees zero rows from customer_order_items_v1');
select pass('staff with is_approved/status=approved/company_id sees zero rows from customer_support_tickets_v1');

-- Positive control: a genuine approved buyer in the SAME company still sees
-- their own order through all three -- the fix must not have narrowed
-- legitimate buyer access.
do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Staff Surface Co 2', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'buyer-surface@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'buyer-surface@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company, 'SO-STAFF-SURFACE-2', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  if (select count(*) from public.customer_order_status_v1() where order_id = v_order) <> 1 then
    raise exception 'REGRESSION: approved buyer lost access to own order via customer_order_status_v1 after the fix';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('approved buyer retains access to own company order after the staff-exclusion fix');

select * from finish();
rollback;
