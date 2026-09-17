-- Contract assertion for support_ticket_set_customer_context()
-- (20260723161256_legacy_role_authority_baseline.sql, never redefined
-- since -- current effective definition).
--
-- AUTH-01 finding, resolved as OUTCOME B: NO SECURITY IMPACT. Documented
-- here rather than "fixed" because there is nothing reachable to fix.
--
-- The trigger's actor_company_id derivation (its `profiles` branch) has
-- the same missing role/staff-exclusion filter found and fixed elsewhere
-- in this AUTH-01 pass (customer_order_status_v1 and siblings,
-- get_sales_order_pi_final_payment_request_v1, the two payment-gateway
-- RPCs). In every one of those, that same drift meant a staff-shaped
-- profile could READ another company's data. This trigger is different in
-- kind: it governs a WRITE (ticket creation), and it has its own
-- independent, correctly-enforced order-ownership check --
--
--   if new.order_id is null or ... or not exists (
--     select 1 from public.orders o
--     where o.id = new.order_id::uuid and o.company_id = actor_company_id ...
--   ) then raise exception 'order is not available to the authenticated company';
--
-- -- which ties the created ticket to an order that ACTUALLY belongs to
-- actor_company_id, whatever company that resolved to. A staff-shaped
-- profile (is_approved, status='approved', company_id set) can therefore
-- only ever create a ticket against an order belonging to the SAME company
-- their own profile.company_id already points at -- never an arbitrary or
-- different company's order, and never with visibility into any data they
-- don't already have via that company_id. The missing role/staff filter
-- changes WHO can end up attributed as the ticket creator for that one
-- company (a data-attribution question), not WHAT company's data becomes
-- reachable. There is no cross-company disclosure and no privilege
-- escalation reachable through this trigger, so no code change is made.
begin;

select plan(2);

-- A staff-shaped profile (is_approved/status='approved'/company_id set,
-- exactly the fixture shape used in the three read-side fixes above) can
-- create a ticket for company A's own order, but is still correctly
-- rejected when it points the ticket at a DIFFERENT company's order --
-- proving the order-ownership check, not the role filter, is what's
-- actually load-bearing here, and that it holds regardless of the
-- unfixed role-filter gap.
do $$
declare
  v_company_a uuid;
  v_company_b uuid;
  v_staff uuid := gen_random_uuid();
  v_order_a uuid;
  v_order_b uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Ticket Trigger Co A', 'active') returning id into v_company_a;
  insert into public.companies (business_name, status) values ('Ticket Trigger Co B', 'active') returning id into v_company_b;
  insert into auth.users (id, email) values (v_staff, 'staff-ticket-trigger@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_staff, v_company_a, 'ADMIN', true, 'approved', 'staff-ticket-trigger@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company_a, 'SO-TICKET-TRIGGER-A', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order_a;
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company_b, 'SO-TICKET-TRIGGER-B', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order_b;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- Own-company order: the trigger permits this (attribution question only,
  -- not a disclosure -- the staff profile already has company_id = A).
  insert into public.support_tickets (order_id, issue_type, description, status)
  values (v_order_a::text, 'quality', 'Contract assertion: own-company order is accepted.', 'open');

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('staff-shaped profile can create a ticket for the order belonging to its OWN company_id (attribution only, not a disclosure)');

do $$
declare
  v_company_a uuid;
  v_company_b uuid;
  v_staff uuid := gen_random_uuid();
  v_order_b uuid;
  v_denied boolean := false;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Ticket Trigger Co A2', 'active') returning id into v_company_a;
  insert into public.companies (business_name, status) values ('Ticket Trigger Co B2', 'active') returning id into v_company_b;
  insert into auth.users (id, email) values (v_staff, 'staff-ticket-trigger-2@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_staff, v_company_a, 'ADMIN', true, 'approved', 'staff-ticket-trigger-2@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate)
  values (gen_random_uuid(), v_company_b, 'SO-TICKET-TRIGGER-B2', 'submitted', 'awaiting_advance', false, false)
  returning id into v_order_b;

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    -- Company B's order, but this profile's company_id is A: the
    -- order-ownership check must still deny it, proving no cross-company
    -- reach exists despite the unfixed role-filter gap.
    insert into public.support_tickets (order_id, issue_type, description, status)
    values (v_order_b::text, 'quality', 'Contract assertion: cross-company order must be denied.', 'open');
  exception
    when others then
      v_denied := true;
  end;

  if not v_denied then
    raise exception 'SECURITY REGRESSION: staff-shaped profile created a ticket against a DIFFERENT company''s order';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('staff-shaped profile is denied when creating a ticket against a DIFFERENT company''s order -- no cross-company reach despite the unfixed role-filter gap');

select * from finish();
rollback;
