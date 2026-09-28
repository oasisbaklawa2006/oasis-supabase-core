-- AUTH-01 Buyer RPC identity-gate hardening certification.
begin;

select plan(32);

-- -----------------------------------------------------------------------------
-- 1. Required authority and intentional anonymous surfaces.
-- -----------------------------------------------------------------------------
select has_function('public', 'customer_buyer_eligible_company_id', array[]::text[],
  'canonical Buyer eligibility helper exists');
select has_function('public', 'auth_buyer_company_id', array[]::text[],
  'legacy Buyer-company compatibility helper exists');

select ok(
  has_function_privilege('anon', 'public.published_products_v1()', 'EXECUTE'),
  'published_products_v1 intentionally remains anonymous customer-safe catalogue'
);
select ok(
  has_function_privilege(
    'anon',
    'public.submit_b2b_access_request_v2(text,text,text,text,text,text,text,text,boolean,boolean)',
    'EXECUTE'
  ),
  'submit_b2b_access_request_v2 intentionally remains anonymous pre-login intake'
);

select ok(not has_function_privilege('anon', 'public.buyer_product_prices_v1()', 'EXECUTE'),
  'anon cannot execute Buyer pricing');
select ok(not has_function_privilege('anon', 'public.customer_order_status_v1()', 'EXECUTE'),
  'anon cannot execute Buyer order status');
select ok(not has_function_privilege('anon', 'public.customer_order_items_v1()', 'EXECUTE'),
  'anon cannot execute Buyer order items');
select ok(not has_function_privilege('anon', 'public.customer_support_tickets_v1()', 'EXECUTE'),
  'anon cannot execute Buyer support projection');
select ok(not has_function_privilege(
  'anon',
  'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)',
  'EXECUTE'
), 'anon cannot submit Buyer support ticket');

-- -----------------------------------------------------------------------------
-- 2. Function-definition contract: affected legacy surfaces must delegate to the
--    canonical Buyer eligibility authority rather than duplicate profile checks.
-- -----------------------------------------------------------------------------
select ok(
  pg_get_functiondef('public.buyer_product_prices_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'Buyer pricing uses canonical Buyer eligibility helper'
);
select ok(
  pg_get_functiondef('public.customer_order_status_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'customer order status uses canonical Buyer eligibility helper'
);
select ok(
  pg_get_functiondef('public.customer_order_items_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'customer order items uses canonical Buyer eligibility helper'
);
select ok(
  pg_get_functiondef('public.customer_support_tickets_v1()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'customer support projection uses canonical Buyer eligibility helper'
);
select ok(
  pg_get_functiondef('public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'customer support submit RPC uses canonical Buyer eligibility helper'
);
select ok(
  pg_get_functiondef('public.support_ticket_set_customer_context()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'support ticket table trigger uses canonical Buyer eligibility helper'
);

-- auth_buyer_company_id remains a compatibility helper, but must itself prefer
-- the canonical gate and explicitly exclude staff / arbitrary company members.
select ok(
  pg_get_functiondef('public.auth_buyer_company_id()'::regprocedure)
    like '%customer_buyer_eligible_company_id%',
  'auth_buyer_company_id prefers canonical Buyer authority'
);
select ok(
  pg_get_functiondef('public.auth_buyer_company_id()'::regprocedure)
    like '%is_internal_staff%',
  'auth_buyer_company_id explicitly excludes internal staff'
);
select ok(
  pg_get_functiondef('public.auth_buyer_company_id()'::regprocedure)
    like '%is_staff_role%',
  'auth_buyer_company_id explicitly excludes staff roles'
);
select ok(
  pg_get_functiondef('public.auth_buyer_company_id()'::regprocedure)
    like '%is_frozen%',
  'auth_buyer_company_id excludes frozen companies'
);

-- -----------------------------------------------------------------------------
-- 3. Behavioral identity fixtures.
-- -----------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1700000-0000-0000-0000-000000000001', 'auth01-staff@example.invalid'),
  ('a1700000-0000-0000-0000-000000000002', 'auth01-buyer@example.invalid'),
  ('a1700000-0000-0000-0000-000000000003', 'auth01-legacy-buyer@example.invalid'),
  ('a1700000-0000-0000-0000-000000000004', 'auth01-pending@example.invalid'),
  ('a1700000-0000-0000-0000-000000000005', 'auth01-frozen-buyer@example.invalid');

do $$
declare
  v_company uuid;
  v_frozen_company uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status, is_frozen)
  values ('AUTH01 Buyer Gate Co', 'active', false)
  returning id into v_company;

  insert into public.companies (business_name, status, is_frozen)
  values ('AUTH01 Frozen Buyer Gate Co', 'active', true)
  returning id into v_frozen_company;

  insert into public.users (id, email, role, is_active, company_id)
  values
    ('a1700000-0000-0000-0000-000000000001', 'auth01-staff@example.invalid', 'admin', true, v_company),
    ('a1700000-0000-0000-0000-000000000003', 'auth01-legacy-buyer@example.invalid', 'customer_user', true, v_company);

  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values
    ('a1700000-0000-0000-0000-000000000002', v_company, 'b2b_buyer', true, 'approved', 'auth01-buyer@example.invalid'),
    ('a1700000-0000-0000-0000-000000000004', v_company, 'pending_buyer', false, 'pending', 'auth01-pending@example.invalid'),
    ('a1700000-0000-0000-0000-000000000005', v_frozen_company, 'b2b_buyer', true, 'approved', 'auth01-frozen-buyer@example.invalid');

  perform set_config('auth01.company_id', v_company::text, true);
  perform set_config('auth01.frozen_company_id', v_frozen_company::text, true);

  set local session_replication_role = default;
end $$;

set local request.jwt.claim.role = 'authenticated';

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000002';
select is(
  public.customer_buyer_eligible_company_id(),
  current_setting('auth01.company_id')::uuid,
  'approved b2b_buyer receives canonical Buyer company context'
);
select is(
  public.auth_buyer_company_id(),
  current_setting('auth01.company_id')::uuid,
  'approved canonical Buyer resolves through compatibility helper'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000001';
select ok(public.is_internal_staff(auth.uid()),
  'staff fixture is recognized as internal staff');
select ok(public.customer_buyer_eligible_company_id() is null,
  'staff with company_id does not receive canonical Buyer company context');
select ok(public.auth_buyer_company_id() is null,
  'staff with company_id does not receive compatibility Buyer company context');

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000003';
select is(
  public.auth_buyer_company_id(),
  current_setting('auth01.company_id')::uuid,
  'active historical customer_user retains legacy Buyer compatibility'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000004';
select ok(public.customer_buyer_eligible_company_id() is null,
  'pending applicant has no canonical Buyer authority');
select ok(public.auth_buyer_company_id() is null,
  'pending applicant has no compatibility Buyer authority');

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000005';
select ok(public.customer_buyer_eligible_company_id() is null,
  'approved profile on frozen company has no canonical Buyer authority');
select ok(public.auth_buyer_company_id() is null,
  'approved profile on frozen company has no compatibility Buyer authority');

-- -----------------------------------------------------------------------------
-- 4. Shared later Buyer/Finance surfaces that still use auth_buyer_company_id()
--    inherit the hardened helper without rewriting their commercial logic.
-- -----------------------------------------------------------------------------
select ok(
  pg_get_functiondef('public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)'::regprocedure)
    like '%auth_buyer_company_id%',
  'payment gateway intent scopes non-staff callers through hardened Buyer helper'
);
select ok(
  pg_get_functiondef('public.get_payment_gateway_payable_status_v1(uuid)'::regprocedure)
    like '%auth_buyer_company_id%',
  'payment gateway status scopes non-staff callers through hardened Buyer helper'
);
select ok(
  pg_get_functiondef('public.get_sales_order_pi_final_payment_request_v1(uuid)'::regprocedure)
    like '%auth_buyer_company_id%',
  'final-payment Buyer projection scopes non-staff callers through hardened Buyer helper'
);

select * from finish();
rollback;
