begin;
-- Contract coverage for 20260819110000_staff_provisioning_authority.sql.
select plan(41);

select has_function('public', 'can_grant_staff_role', 'can_grant_staff_role exists');
select has_function('public', 'grant_staff_role', 'grant_staff_role exists');
select has_function('public', 'revoke_staff_user', 'revoke_staff_user exists');

select is(
  (select has_function_privilege('anon', 'public.grant_staff_role(uuid,text,text,text,uuid,text,text)', 'execute')),
  false, 'anonymous cannot grant staff roles'
);
select is(
  (select has_function_privilege('authenticated', 'public.grant_staff_role(uuid,text,text,text,uuid,text,text)', 'execute')),
  false, 'authenticated cannot grant staff roles directly'
);
select is(
  (select has_function_privilege('service_role', 'public.grant_staff_role(uuid,text,text,text,uuid,text,text)', 'execute')),
  true, 'service_role can grant staff roles'
);
select is(
  (select has_function_privilege('authenticated', 'public.revoke_staff_user(uuid,text)', 'execute')),
  true, 'authenticated can invoke revoke RPC subject to runtime admin checks'
);

insert into auth.users (id, email) values
  ('91000000-0000-0000-0000-000000000001', 'qa-admin-actor@example.invalid'),
  ('91000000-0000-0000-0000-000000000002', 'qa-ordinary-actor@example.invalid'),
  ('91000000-0000-0000-0000-000000000003', 'qa-inactive-admin@example.invalid'),
  ('91000000-0000-0000-0000-000000000004', 'qa-super-admin@example.invalid');
insert into public.users (id, role, email, is_active) values
  ('91000000-0000-0000-0000-000000000001', 'admin', 'qa-admin-actor@example.invalid', true),
  ('91000000-0000-0000-0000-000000000002', 'support_executive', 'qa-ordinary-actor@example.invalid', true),
  ('91000000-0000-0000-0000-000000000003', 'admin', 'qa-inactive-admin@example.invalid', false),
  ('91000000-0000-0000-0000-000000000004', 'super_admin', 'qa-super-admin@example.invalid', true);

-- Pre-flight authority and explicit grant matrix.
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000001', 'rgs_admin'),
  true, 'active admin may pre-flight an ordinary allowlisted role'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000002', 'rgs_admin'),
  false, 'ordinary staff fails grant pre-flight'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000001', 'totally_made_up_role'),
  false, 'non-allowlisted role fails grant pre-flight'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000003', 'rgs_admin'),
  false, 'inactive admin fails grant pre-flight'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000001', 'super_admin'),
  false, 'admin cannot pre-flight super_admin grant'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000004', 'super_admin'),
  true, 'super_admin retains authority to pre-flight super_admin grant'
);

-- is_admin must fail closed immediately for inactive/revoked admins.
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
select is(public.is_admin(), true, 'active admin satisfies public.is_admin');
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000003';
select is(public.is_admin(), false, 'inactive admin does not satisfy public.is_admin');

-- Direct privilege-bearing browser paths are removed. users UPDATE remains
-- available for the existing self-service profile contract, but its privilege
-- fields are trigger-protected below.
select is(
  (select has_table_privilege('authenticated', 'public.users', 'INSERT')),
  false, 'authenticated cannot directly insert public.users'
);
select is(
  (select has_table_privilege('authenticated', 'public.users', 'DELETE')),
  false, 'authenticated cannot directly delete public.users'
);
select is(
  (select has_table_privilege('authenticated', 'public.user_role_map', 'INSERT')),
  false, 'authenticated cannot directly insert user_role_map'
);
select is(
  (select has_table_privilege('authenticated', 'public.user_role_map', 'UPDATE')),
  false, 'authenticated cannot directly update user_role_map'
);
select is(
  (select has_table_privilege('authenticated', 'public.user_role_map', 'DELETE')),
  false, 'authenticated cannot directly delete user_role_map'
);

-- grant_staff_role is a service-role RPC. Set the request role accordingly so
-- existing privilege-field triggers exercise the same governed runtime path.
set local request.jwt.claim.role = 'service_role';

select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000002') $$,
  '%Not authorised%',
  'non-admin actor cannot grant a staff role'
);
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000003') $$,
  '%Not authorised%',
  'inactive admin actor cannot grant a staff role'
);
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000003', 'qa-escalation@example.invalid', 'QA Escalation', 'super_admin', '91000000-0000-0000-0000-000000000001') $$,
  '%Admin cannot grant privileged role%',
  'admin cannot elevate a user to super_admin'
);
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'totally_made_up_role', '91000000-0000-0000-0000-000000000001') $$,
  '%not on the provisionable allowlist%',
  'granting a role outside the allowlist is refused'
);
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000002', 'qa-super@example.invalid', 'QA Super', 'super_admin', '91000000-0000-0000-0000-000000000004') $$,
  'super_admin retains authority to grant super_admin'
);

-- Ordinary allowlisted grant and idempotency.
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000001') $$,
  'admin can grant an ordinary allowlisted role'
);
select is(
  (select role from public.users where id = '92000000-0000-0000-0000-000000000001'),
  'rgs_admin', 'granted role is recorded on public.users'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '92000000-0000-0000-0000-000000000001' and action_type = 'STAFF_ROLE_GRANTED'),
  1, 'exactly one audit row records the initial grant'
);
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000001') $$,
  'identical repeat grant is idempotent'
);
select is(
  (select count(*)::int from public.users where id = '92000000-0000-0000-0000-000000000001'),
  1, 'repeat grant creates no duplicate user row'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '92000000-0000-0000-0000-000000000001' and action_type = 'STAFF_ROLE_GRANTED'),
  1, 'identical repeat grant creates no duplicate audit row'
);

-- Same role with changed metadata must update instead of being swallowed by
-- the idempotency shortcut.
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS Updated', 'rgs_admin', '91000000-0000-0000-0000-000000000001', 'RGS', 'QA Device') $$,
  'same-role request with changed metadata updates the user'
);
select is(
  (select full_name || '|' || department || '|' || designation from public.users where id = '92000000-0000-0000-0000-000000000001'),
  'QA RGS Updated|RGS|QA Device', 'same-role metadata changes are persisted'
);

-- Active admin browser cannot directly mutate its own privileged role field.
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
select throws_like(
  $$ update public.users set role = 'super_admin' where id = '91000000-0000-0000-0000-000000000001' $$,
  '%privileged user fields require governed server authority%',
  'admin cannot directly promote itself through public.users update'
);

-- Direct revoke authority fails closed for ordinary and inactive admins.
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000002';
select throws_like(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'unauthorised attempt') $$,
  '%Not authorised%',
  'non-admin authenticated actor cannot revoke staff users'
);
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000003';
select throws_like(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'inactive admin attempt') $$,
  '%Not authorised%',
  'inactive admin cannot revoke staff users'
);

-- Active-admin revoke uses the governed RPC marker and is audited.
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'no longer needed for testing') $$,
  'active admin can revoke a staff user with a reason'
);
select is(
  (select is_active from public.users where id = '92000000-0000-0000-0000-000000000001'),
  false, 'revoked user is marked inactive'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '92000000-0000-0000-0000-000000000001' and action_type = 'STAFF_USER_REVOKED'),
  1, 'exactly one audit row records the revoke'
);

-- Fresh/retried server-side grant recovers an inactive partially-provisioned
-- identity instead of being swallowed by idempotency.
set local request.jwt.claim.role = 'service_role';
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS Updated', 'rgs_admin', '91000000-0000-0000-0000-000000000001', 'RGS', 'QA Device') $$,
  'fresh grant recovers an inactive partially-provisioned identity'
);
select is(
  (select is_active from public.users where id = '92000000-0000-0000-0000-000000000001'),
  true, 'fresh grant restores the user to active'
);

select finish();
rollback;
