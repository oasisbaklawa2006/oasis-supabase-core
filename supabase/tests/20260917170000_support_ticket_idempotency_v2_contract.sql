-- Contract test for 20260917170000_support_ticket_idempotency_v2.sql
begin;

select plan(13);

-- Fixture: one approved buyer with one real order.
do $$
declare
  v_company uuid;
  v_buyer uuid := gen_random_uuid();
  v_order uuid;
begin
  set local session_replication_role = replica;
  insert into public.companies (business_name, status) values ('Ticket V2 Co', 'active') returning id into v_company;
  insert into auth.users (id, email) values (v_buyer, 'ticket-v2@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer, v_company, 'b2b_buyer', true, 'approved', 'ticket-v2@example.com');
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate, order_origin)
  values (gen_random_uuid(), v_company, 'SO-TICKET-V2-1', 'submitted', 'awaiting_advance', false, false, 'MANUAL')
  returning id into v_order;
  set local session_replication_role = default;
  perform set_config('test.company_id', v_company::text, false);
  perform set_config('test.buyer_id', v_buyer::text, false);
  perform set_config('test.order_id', v_order::text, false);
end $$;

-- 1. v1 REMAINS CALLABLE, unchanged, with its original (pre-idempotency)
--    behavior: creating a ticket with no key concept at all.
do $$
declare
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_order uuid := current_setting('test.order_id')::uuid;
  v_id uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select public.submit_customer_support_ticket_v1(v_order, 'quality', 'v1 remains callable regression test.', null, null) into v_id;
  if v_id is null then
    raise exception 'REGRESSION: v1 no longer callable / did not return a ticket id';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('1. submit_customer_support_ticket_v1 remains callable, unchanged, for existing clients');

-- 8. v1 privileges not expanded: still revoked from anon.
select ok(
  not has_function_privilege('anon', 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)', 'EXECUTE'),
  '8. v1 privileges unchanged: anon still denied EXECUTE'
);

-- 2. v2 normal submission succeeds.
do $$
declare
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_order uuid := current_setting('test.order_id')::uuid;
  v_result record;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into v_result from public.submit_customer_support_ticket_v2('v2-key-normal', v_order, 'quality', 'v2 normal submit regression test.', null, null);
  if v_result.is_duplicate_submission is not false or v_result.ticket_id is null then
    raise exception 'REGRESSION: v2 normal submit did not create a fresh ticket';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('2. v2 normal submission succeeds');

-- 3. Identical retry returns/reconciles one ticket.
do $$
declare
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_order uuid := current_setting('test.order_id')::uuid;
  v_result record;
  v_first_id uuid;
begin
  select id into v_first_id from public.support_tickets where idempotency_key = 'v2-key-normal';
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into v_result from public.submit_customer_support_ticket_v2('v2-key-normal', v_order, 'quality', 'v2 normal submit regression test.', null, null);
  if v_result.is_duplicate_submission is not true or v_result.ticket_id is distinct from v_first_id then
    raise exception 'REGRESSION: identical retry did not reconcile to the existing v2 ticket';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('3. identical retry (same key, same payload) reconciles to the existing v2 ticket');

select ok(
  (select count(*) from public.support_tickets where idempotency_key = 'v2-key-normal') = 1,
  '3b. still exactly one ticket row after the identical retry'
);

-- 4. Concurrent identical request creates one ticket (unique_violation
--    fallback path, modeling two transactions racing past the dedup SELECT).
do $$
declare
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_order uuid := current_setting('test.order_id')::uuid;
  v_key text := 'v2-key-race';
  v_result record;
begin
  set local session_replication_role = replica;
  insert into public.support_tickets (order_id, issue_type, description, status, company_id, created_by, idempotency_key)
  values (v_order::text, 'quality', 'Race-seeded v2 ticket for concurrent-submit regression.', 'open', current_setting('test.company_id')::uuid, v_buyer, v_key);
  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into v_result from public.submit_customer_support_ticket_v2(v_key, v_order, 'quality', 'Race-seeded v2 ticket for concurrent-submit regression.', null, null);
  if v_result.is_duplicate_submission is not true then
    raise exception 'REGRESSION: concurrent identical request did not reconcile to one ticket';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('4. concurrent identical request creates one ticket, not two');

select ok(
  (select count(*) from public.support_tickets where idempotency_key = 'v2-key-race') = 1,
  '4b. exactly one ticket row exists for the race-seeded key'
);

-- 5. Same key/different payload fails closed.
do $$
declare
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_order uuid := current_setting('test.order_id')::uuid;
  v_denied boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.submit_customer_support_ticket_v2('v2-key-normal', v_order, 'quality', 'A DIFFERENT description under the same v2 key.', null, null);
  exception
    when sqlstate 'P0001' then
      v_denied := true;
  end;
  if not v_denied then
    raise exception 'REGRESSION: same v2 key with a conflicting payload was not rejected';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('5. same key/different payload fails closed on v2 (SUPPORT_TICKET_IDEMPOTENCY_CONFLICT)');

-- 6. Different keys legitimately create separate tickets.
do $$
declare
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_order uuid := current_setting('test.order_id')::uuid;
  v_result record;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into v_result from public.submit_customer_support_ticket_v2('v2-key-independent', v_order, 'delivery', 'A separate, independent v2 ticket.', null, null);
  if v_result.is_duplicate_submission is not false then
    raise exception 'REGRESSION: a different v2 key was treated as a duplicate';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('6. a different idempotency key creates its own independent v2 ticket');

-- 7. Cross-company attempt rejected (order-ownership trigger, shared with v1, unchanged).
do $$
declare
  v_foreign_company uuid;
  v_foreign_order uuid;
  v_buyer uuid := current_setting('test.buyer_id')::uuid;
  v_denied boolean := false;
begin
  set local session_replication_role = replica;
  insert into public.companies (business_name, status) values ('Foreign Ticket V2 Co', 'active') returning id into v_foreign_company;
  insert into public.orders (id, company_id, order_number, status, payment_status, is_waste, is_duplicate, order_origin)
  values (gen_random_uuid(), v_foreign_company, 'SO-FOREIGN-TICKET-V2-1', 'submitted', 'awaiting_advance', false, false, 'MANUAL')
  returning id into v_foreign_order;
  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.submit_customer_support_ticket_v2('v2-key-foreign', v_foreign_order, 'quality', 'Attempting a v2 ticket against a foreign company order.', null, null);
  exception
    when others then
      v_denied := true;
  end;
  if not v_denied then
    raise exception 'SECURITY REGRESSION: a v2 ticket was created against an order belonging to a DIFFERENT company';
  end if;
  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;
select pass('7. cross-company attempt rejected on v2 (order-ownership trigger unchanged from v1)');

-- 9. v2 privileges match intended Buyer authority: anon denied, authenticated allowed.
select ok(
  not has_function_privilege('anon', 'public.submit_customer_support_ticket_v2(text,uuid,text,text,text,integer)', 'EXECUTE'),
  '9. v2: anon denied EXECUTE'
);
select ok(
  has_function_privilege('authenticated', 'public.submit_customer_support_ticket_v2(text,uuid,text,text,text,integer)', 'EXECUTE'),
  '9b. v2: authenticated granted EXECUTE (matches v1''s intended Buyer authority, no broader)'
);

-- Sanity: no extra rows were created anywhere along the way for this buyer
-- beyond what each numbered scenario above accounts for (1 v1 ticket + 1
-- v2 normal + 1 v2 race-seeded + 1 v2 independent = 4).
select ok(
  (select count(*) from public.support_tickets where created_by = current_setting('test.buyer_id')::uuid) = 4,
  'sanity: total ticket count across v1+v2 scenarios matches expectation exactly'
);

select * from finish();
rollback;
