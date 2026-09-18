begin;

select plan(15);

select has_function(
  'public', 'auth_buyer_company_id', array[]::text[],
  'shared Buyer/customer company authority exists'
);

select is(
  (
    select p.prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'auth_buyer_company_id'
      and pg_get_function_identity_arguments(p.oid) = ''
  ),
  true,
  'shared Buyer/customer authority is SECURITY DEFINER with governed internal reads'
);

select is(
  has_function_privilege('authenticated', 'public.auth_buyer_company_id()', 'EXECUTE'),
  true,
  'authenticated callers may resolve governed Buyer/customer company authority'
);
select is(
  has_function_privilege('anon', 'public.auth_buyer_company_id()', 'EXECUTE'),
  false,
  'anonymous callers cannot invoke Buyer/customer company authority'
);
select is(
  has_function_privilege('service_role', 'public.auth_buyer_company_id()', 'EXECUTE'),
  true,
  'service role retains governed execution compatibility'
);

insert into public.companies (id, business_name, status, is_frozen) values
  ('18100000-0000-0000-0000-000000000001', 'AUTH01 Active Company', 'active', false),
  ('18100000-0000-0000-0000-000000000002', 'AUTH01 Frozen Company', 'active', true),
  ('18100000-0000-0000-0000-000000000003', 'AUTH01 Pending Company', 'pending', false);

insert into auth.users (id, email) values
  ('18110000-0000-0000-0000-000000000001', 'auth01-modern-buyer@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000002', 'auth01-staff-shaped@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000003', 'auth01-legacy-valid@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000004', 'auth01-frozen-buyer@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000005', 'auth01-deapproved-buyer@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000006', 'auth01-legacy-inactive@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000007', 'auth01-legacy-deleted@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000008', 'auth01-legacy-wrong-role@pgtap.invalid'),
  ('18110000-0000-0000-0000-000000000009', 'auth01-legacy-pending-company@pgtap.invalid');

insert into public.profiles (
  id, company_id, email, role, is_approved, status
) values
  (
    '18110000-0000-0000-0000-000000000001',
    '18100000-0000-0000-0000-000000000001',
    'auth01-modern-buyer@pgtap.invalid',
    'b2b_buyer', true, 'approved'
  ),
  (
    '18110000-0000-0000-0000-000000000002',
    '18100000-0000-0000-0000-000000000001',
    'auth01-staff-shaped@pgtap.invalid',
    'b2b_buyer', true, 'approved'
  ),
  (
    '18110000-0000-0000-0000-000000000004',
    '18100000-0000-0000-0000-000000000002',
    'auth01-frozen-buyer@pgtap.invalid',
    'b2b_buyer', true, 'approved'
  ),
  (
    '18110000-0000-0000-0000-000000000005',
    '18100000-0000-0000-0000-000000000001',
    'auth01-deapproved-buyer@pgtap.invalid',
    'b2b_buyer', false, 'pending'
  )
on conflict (id) do update set
  company_id = excluded.company_id,
  email = excluded.email,
  role = excluded.role,
  is_approved = excluded.is_approved,
  status = excluded.status;

insert into public.users (
  id, company_id, email, role, is_active, deleted_at
) values
  (
    '18110000-0000-0000-0000-000000000002',
    '18100000-0000-0000-0000-000000000001',
    'auth01-staff-shaped@pgtap.invalid',
    'super_admin', true, null
  ),
  (
    '18110000-0000-0000-0000-000000000003',
    '18100000-0000-0000-0000-000000000001',
    'auth01-legacy-valid@pgtap.invalid',
    'customer_user', true, null
  ),
  (
    '18110000-0000-0000-0000-000000000006',
    '18100000-0000-0000-0000-000000000001',
    'auth01-legacy-inactive@pgtap.invalid',
    'customer_user', false, null
  ),
  (
    '18110000-0000-0000-0000-000000000007',
    '18100000-0000-0000-0000-000000000001',
    'auth01-legacy-deleted@pgtap.invalid',
    'customer_user', true, now()
  ),
  (
    '18110000-0000-0000-0000-000000000008',
    '18100000-0000-0000-0000-000000000001',
    'auth01-legacy-wrong-role@pgtap.invalid',
    'vendor', true, null
  ),
  (
    '18110000-0000-0000-0000-000000000009',
    '18100000-0000-0000-0000-000000000003',
    'auth01-legacy-pending-company@pgtap.invalid',
    'customer_user', true, null
  );

select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'unauthenticated request resolves no Buyer/customer company'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000001', true);
select is(
  public.auth_buyer_company_id(),
  '18100000-0000-0000-0000-000000000001'::uuid,
  'approved modern Buyer on active company resolves its company'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000002', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'internal staff cannot resolve through Buyer/customer authority even with an approved Buyer-shaped profile'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000004', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'approved modern Buyer on frozen company fails closed'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000005', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'de-approved modern Buyer fails closed'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000003', true);
select is(
  public.auth_buyer_company_id(),
  '18100000-0000-0000-0000-000000000001'::uuid,
  'active legitimate legacy customer user retains company authority'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000006', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'inactive legacy customer user fails closed'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000007', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'deleted legacy customer user fails closed'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000008', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'non-customer legacy role cannot obtain Buyer/customer company authority'
);

select set_config('request.jwt.claim.sub', '18110000-0000-0000-0000-000000000009', true);
select is(
  public.auth_buyer_company_id(),
  null::uuid,
  'legacy customer on non-active company fails closed'
);

select * from finish();
rollback;
