-- Contract test for 20260807170000_customer_identity_projections_v1.sql
begin;

select plan(10);

select has_function('public', 'customer_buyer_eligible_company_id', array[]::text[], 'customer_buyer_eligible_company_id exists');
select has_function('public', 'customer_company_v1', array[]::text[], 'customer_company_v1 exists');
select has_function('public', 'customer_team_v1', array[]::text[], 'customer_team_v1 exists');

select ok(
  (select prosecdef from pg_proc where oid = 'public.customer_company_v1()'::regprocedure),
  'customer_company_v1 is SECURITY DEFINER'
);

select ok(
  not has_function_privilege('anon', 'public.customer_company_v1()', 'EXECUTE'),
  'anon cannot execute customer_company_v1'
);

select ok(
  has_function_privilege('authenticated', 'public.customer_company_v1()', 'EXECUTE'),
  'authenticated can execute customer_company_v1'
);

select ok(
  not has_function_privilege('anon', 'public.customer_team_v1()', 'EXECUTE'),
  'anon cannot execute customer_team_v1'
);

select ok(
  (select count(*) = 0 from public.customer_company_v1()),
  'no JWT identity receives no customer company row'
);

-- Live: approved buyer sees own company; cross-company isolation
do $$
declare
  v_company_a uuid;
  v_company_b uuid;
  v_buyer_a uuid := gen_random_uuid();
  v_buyer_b uuid := gen_random_uuid();
  v_row record;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Spine Co A', 'active') returning id into v_company_a;
  insert into public.companies (business_name, status) values ('Spine Co B', 'active') returning id into v_company_b;
  insert into auth.users (id, email) values (v_buyer_a, 'spine-a@example.com');
  insert into auth.users (id, email) values (v_buyer_b, 'spine-b@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer_a, v_company_a, 'b2b_buyer', true, 'approved', 'spine-a@example.com');
  insert into public.profiles (id, company_id, role, is_approved, status, email)
  values (v_buyer_b, v_company_b, 'b2b_buyer', true, 'approved', 'spine-b@example.com');

  update public.profiles
  set role = 'b2b_buyer', is_approved = true, status = 'approved'
  where id in (v_buyer_a, v_buyer_b);

  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_a::text, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select * into v_row from public.customer_company_v1();
  if v_row.company_id <> v_company_a then
    raise exception 'REGRESSION: customer_company_v1 did not resolve buyer A company';
  end if;

  if (select count(*) from public.customer_team_v1()) < 1 then
    raise exception 'REGRESSION: customer_team_v1 returned no members for approved buyer';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_buyer_b::text, 'role', 'authenticated')::text, true);
  if (select count(*) from public.customer_company_v1() where company_id = v_company_a) > 0 then
    raise exception 'SECURITY REGRESSION: buyer B can see company A via customer_company_v1';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('customer identity projections resolve profiles-based company and enforce cross-company isolation');

select ok(
  pg_get_functiondef('public.customer_company_v1()'::regprocedure) not like '%p_company_id%',
  'customer_company_v1 exposes no client company_id parameter'
);

select * from finish();
rollback;
