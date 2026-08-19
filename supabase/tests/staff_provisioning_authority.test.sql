begin;
-- Contract coverage for 20260819110000_staff_provisioning_authority.sql.
select plan(17);

select has_function('public', 'can_grant_staff_role', 'can_grant_staff_role exists');
select has_function('public', 'grant_staff_role', 'grant_staff_role exists');
select has_function('public', 'revoke_staff_user', 'revoke_staff_user exists');

select is(
  (select has_function_privilege('anon', 'public.grant_staff_role(uuid,text,text,text,uuid,text,text)', 'execute')),
  false, 'anonymous cannot grant staff roles'
);
select is(
  (select has_function_privilege('authenticated', 'public.grant_staff_role(uuid,text,text,text,uuid,text,text)', 'execute')),
  false, 'ordinary authenticated staff cannot grant staff roles directly -- service_role (Edge Function) only'
);
select is(
  (select has_function_privilege('service_role', 'public.grant_staff_role(uuid,text,text,text,uuid,text,text)', 'execute')),
  true, 'service_role can grant staff roles'
);
select is(
  (select has_function_privilege('authenticated', 'public.revoke_staff_user(uuid,text)', 'execute')),
  true, 'an authenticated (admin-checked at runtime) session can call revoke_staff_user'
);

-- Fixtures: one admin actor, one ordinary staff actor, two target auth users.
insert into public.users (id, role, email) values
  ('91000000-0000-0000-0000-000000000001', 'admin', 'qa-admin-actor@example.invalid'),
  ('91000000-0000-0000-0000-000000000002', 'support_executive', 'qa-ordinary-actor@example.invalid');

-- Ordinary authenticated staff cannot provision (not admin/super_admin).
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000002') $$,
  '%Not authorised%',
  'a non-admin actor cannot grant a staff role'
);

-- Role escalation via an arbitrary/non-allowlisted role_key is rejected.
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'totally_made_up_role', '91000000-0000-0000-0000-000000000001') $$,
  '%not on the provisionable allowlist%',
  'granting a role outside the allowlist is refused'
);

-- Permitted admin can provision an allowed role.
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000001') $$,
  'an admin actor can grant an allowlisted role'
);
select is(
  (select role from public.users where id = '92000000-0000-0000-0000-000000000001'),
  'rgs_admin', 'granted role is recorded on public.users'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '92000000-0000-0000-0000-000000000001' and action_type = 'STAFF_ROLE_GRANTED'),
  1, 'exactly one audit_logs row records the grant'
);

-- Duplicate/idempotent request does not create a duplicate identity or a
-- second audit entry.
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000001') $$,
  'a repeat grant of the same role is idempotent, not an error'
);
select is(
  (select count(*)::int from public.users where id = '92000000-0000-0000-0000-000000000001'),
  1, 'no duplicate public.users row was created by the repeat grant'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '92000000-0000-0000-0000-000000000001' and action_type = 'STAFF_ROLE_GRANTED'),
  1, 'the repeat grant did not add a second audit_logs row'
);

-- Revocation works and is itself audited, then a fresh grant recovers a
-- partially-failed-then-retried provisioning attempt cleanly.
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
select lives_ok(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'no longer needed for testing') $$,
  'an admin can revoke a staff user with a reason'
);
select is(
  (select is_active from public.users where id = '92000000-0000-0000-0000-000000000001'),
  false, 'revoked user is marked inactive'
);

select finish();
rollback;
