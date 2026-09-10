-- Security regression for migration 20260910040000_b2b_prelogin_access_lifecycle.sql.
-- A client may set arbitrary custom GUCs; those settings must never grant role,
-- approval, company, price-tier, credit, or staff authority.
begin;

select plan(6);

select ok(
  pg_get_functiondef('public.protect_user_privilege_fields()'::regprocedure)
    not like '%current_setting(''oasis.staff_authority''%',
  'public.users privilege guard no longer trusts the client-settable staff marker'
);
select ok(
  pg_get_functiondef('public.prevent_profile_privilege_escalation()'::regprocedure)
    not like '%current_setting(''oasis.staff_authority''%',
  'profile UPDATE guard no longer trusts the client-settable staff marker'
);
select ok(
  pg_get_functiondef('public.prevent_profile_insert_privilege_escalation()'::regprocedure)
    not like '%current_setting(''oasis.staff_authority''%',
  'profile INSERT guard no longer trusts the client-settable staff marker'
);

insert into auth.users (id, email, aud, role, email_confirmed_at, created_at, updated_at)
values (
  '94000000-0000-4000-8000-000000000099'::uuid,
  'marker-attack-cert@example.invalid',
  'authenticated', 'authenticated', now(), now(), now()
);

insert into public.users (id, email, role, is_active, invite_status)
values (
  '94000000-0000-4000-8000-000000000099'::uuid,
  'marker-attack-cert@example.invalid',
  'PENDING', true, 'pending'
)
on conflict (id) do update set role='PENDING', is_active=true, invite_status='pending';

insert into public.profiles (
  id, full_name, email, role, is_approved, status, company_id, price_tier, credit_limit
) values (
  '94000000-0000-4000-8000-000000000099'::uuid,
  'Marker Attack Cert',
  'marker-attack-cert@example.invalid',
  'pending_buyer', false, 'pending', null, null, 0
)
on conflict (id) do update set
  role='pending_buyer', is_approved=false, status='pending', company_id=null, price_tier=null, credit_limit=0;

select set_config(
  'request.jwt.claims',
  '{"sub":"94000000-0000-4000-8000-000000000099","role":"authenticated"}',
  true
);
set local role authenticated;
select set_config('oasis.staff_authority', 'governed', true);

select throws_ok(
  $$ update public.users
       set role='super_admin'
       where id='94000000-0000-4000-8000-000000000099'::uuid $$,
  'P0001',
  null,
  'forged staff marker cannot escalate public.users role'
);

update public.profiles
set role='super_admin',
    is_approved=true,
    status='approved',
    price_tier='PRIVATE',
    credit_limit=999999
where id='94000000-0000-4000-8000-000000000099'::uuid;

reset role;

select is(
  upper((select role from public.users where id='94000000-0000-4000-8000-000000000099'::uuid)),
  'PENDING'::text,
  'public.users role remains unprivileged after forged marker attempt'
);

select ok(
  (select lower(role)='pending_buyer'
          and is_approved is false
          and lower(status)='pending'
          and price_tier is null
          and coalesce(credit_limit,0)=0
   from public.profiles
   where id='94000000-0000-4000-8000-000000000099'::uuid),
  'profile privilege fields remain protected after forged marker attempt'
);

select * from finish();
rollback;
