-- FL-SUP-01: support queue operator RLS certification.
begin;

select plan(18);

select has_function('public', 'is_support_ticket_queue_operator', array['uuid'],
  'support queue operator helper exists');

insert into auth.users (id, email) values
  ('f1010000-0000-0000-0000-000000000001', 'flsup01-admin@example.invalid'),
  ('f1010000-0000-0000-0000-000000000002', 'flsup01-support@example.invalid'),
  ('f1010000-0000-0000-0000-000000000003', 'flsup01-sales@example.invalid'),
  ('f1010000-0000-0000-0000-000000000004', 'flsup01-buyer-a@example.invalid'),
  ('f1010000-0000-0000-0000-000000000005', 'flsup01-buyer-b@example.invalid'),
  ('f1010000-0000-0000-0000-000000000006', 'flsup01-dispatch@example.invalid'),
  ('f1010000-0000-0000-0000-000000000007', 'flsup01-super@example.invalid');

do $$
declare
  v_company_a uuid := 'f1020000-0000-0000-0000-000000000001';
  v_company_b uuid := 'f1020000-0000-0000-0000-000000000002';
  v_order_a uuid := 'f1030000-0000-0000-0000-000000000001';
  v_order_b uuid := 'f1030000-0000-0000-0000-000000000002';
  v_super_role uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (id, business_name, status, is_frozen)
  values
    (v_company_a, 'FL-SUP-01 Buyer A', 'active', false),
    (v_company_b, 'FL-SUP-01 Buyer B', 'active', false);

  insert into public.users (id, email, role, is_active, company_id)
  values
    ('f1010000-0000-0000-0000-000000000001', 'flsup01-admin@example.invalid', 'admin', true, null),
    ('f1010000-0000-0000-0000-000000000002', 'flsup01-support@example.invalid', 'SUPPORT_EXECUTIVE', true, null),
    ('f1010000-0000-0000-0000-000000000003', 'flsup01-sales@example.invalid', 'SALES_EXECUTIVE', true, null),
    ('f1010000-0000-0000-0000-000000000004', 'flsup01-buyer-a@example.invalid', 'customer_user', true, v_company_a),
    ('f1010000-0000-0000-0000-000000000005', 'flsup01-buyer-b@example.invalid', 'customer_user', true, v_company_b),
    ('f1010000-0000-0000-0000-000000000006', 'flsup01-dispatch@example.invalid', 'DISPATCH_MANAGER', true, null),
    ('f1010000-0000-0000-0000-000000000007', 'flsup01-super@example.invalid', 'super_admin', true, null);

  select id into v_super_role from public.roles where role_key = 'super_admin' limit 1;
  if v_super_role is not null then
    insert into public.user_role_map (user_id, role_id)
    values ('f1010000-0000-0000-0000-000000000007', v_super_role)
    on conflict do nothing;
  end if;

  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values
    ('f1010000-0000-0000-0000-000000000004', v_company_a, 'b2b_buyer', true, 'approved', 'flsup01-buyer-a@example.invalid'),
    ('f1010000-0000-0000-0000-000000000005', v_company_b, 'b2b_buyer', true, 'approved', 'flsup01-buyer-b@example.invalid');

  insert into public.orders (id, order_number, tracking_token, company_id, order_origin)
  values
    (v_order_a, 'FL-SUP-01-A', 'flsup01-order-a', v_company_a, 'SALES'),
    (v_order_b, 'FL-SUP-01-B', 'flsup01-order-b', v_company_b, 'SALES');

  insert into public.support_tickets (
    id, order_id, issue_type, description, status, company_id, created_by, user_id
  ) values
    ('f1040000-0000-0000-0000-000000000001', v_order_a::text, 'quality_issue', 'Buyer A ticket', 'open', v_company_a, 'f1010000-0000-0000-0000-000000000004', 'f1010000-0000-0000-0000-000000000004'),
    ('f1040000-0000-0000-0000-000000000002', v_order_b::text, 'missing_item', 'Buyer B ticket', 'open', v_company_b, 'f1010000-0000-0000-0000-000000000005', 'f1010000-0000-0000-0000-000000000005');

  set local session_replication_role = default;
end $$;

select ok(public.is_support_ticket_queue_operator('f1010000-0000-0000-0000-000000000002'),
  'SUPPORT_EXECUTIVE is recognised as a support queue operator');
select ok(public.is_support_ticket_queue_operator('f1010000-0000-0000-0000-000000000001'),
  'ADMIN retains support queue operator authority');
select ok(public.is_support_ticket_queue_operator('f1010000-0000-0000-0000-000000000007'),
  'SUPER_ADMIN retains support queue operator authority');
select ok(not public.is_support_ticket_queue_operator('f1010000-0000-0000-0000-000000000003'),
  'unrelated SALES_EXECUTIVE is not a support queue operator');
select ok(not public.is_support_ticket_queue_operator('f1010000-0000-0000-0000-000000000006'),
  'unrelated DISPATCH_MANAGER is not a support queue operator');

set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.support_tickets),
  2,
  'SUPPORT_EXECUTIVE can read the full support queue'
);
update public.support_tickets
set assigned_employee_id = 'f1010000-0000-0000-0000-000000000002'
where id = 'f1040000-0000-0000-0000-000000000001';
select is(
  (select assigned_employee_id from public.support_tickets where id = 'f1040000-0000-0000-0000-000000000001'),
  'f1010000-0000-0000-0000-000000000002'::uuid,
  'SUPPORT_EXECUTIVE can perform support assignment updates'
);

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000001';
select is(
  (select count(*)::integer from public.support_tickets),
  2,
  'ADMIN retains read access to the support queue'
);

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000007';
select is(
  (select count(*)::integer from public.support_tickets),
  2,
  'SUPER_ADMIN retains read access to the support queue'
);

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000003';
select is(
  (select count(*)::integer from public.support_tickets),
  0,
  'unrelated SALES_EXECUTIVE cannot read the support queue'
);

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000004';
select is(
  (select count(*)::integer from public.support_tickets),
  1,
  'buyer A can read only their own company tickets'
);
select ok(
  not exists (
    select 1 from public.support_tickets
    where company_id = 'f1020000-0000-0000-0000-000000000002'
  ),
  'buyer A cannot read buyer B tickets'
);

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000005';
select is(
  (select count(*)::integer from public.support_tickets),
  1,
  'buyer B retains read access to their own tickets'
);

reset role;
select ok(not has_table_privilege('anon', 'public.support_tickets', 'SELECT'),
  'anon remains denied direct support_tickets access');

set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000004';
select is(
  (select count(*)::integer from public.customer_support_tickets_v1()),
  1,
  'existing customer ticket read behaviour remains functional'
);

set local request.jwt.claim.sub = 'f1010000-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.support_tickets where status = 'open'),
  2,
  'previously empty Support queue regression: operator now sees open tickets'
);

select is(
  (select count(*)::integer from pg_policies where schemaname = 'public' and tablename = 'support_tickets'),
  6,
  'support_tickets retains customer policies plus explicit queue-operator policies'
);

select * from finish();
rollback;
