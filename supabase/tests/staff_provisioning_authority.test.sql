begin;
-- Contract coverage for 20260819110000_staff_provisioning_authority.sql.
select plan(28);

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

-- Fixtures: one active admin actor, one ordinary staff actor, and one
-- revoked/inactive admin actor. audit_logs.actor_id has a foreign key to
-- auth.users(id), so all actors need auth.users rows as well.
insert into auth.users (id, email) values
  ('91000000-0000-0000-0000-000000000001', 'qa-admin-actor@example.invalid'),
  ('91000000-0000-0000-0000-000000000002', 'qa-ordinary-actor@example.invalid'),
  ('91000000-0000-0000-0000-000000000003', 'qa-inactive-admin@example.invalid');
insert into public.users (id, role, email, is_active) values
  ('91000000-0000-0000-0000-000000000001', 'admin', 'qa-admin-actor@example.invalid', true),
  ('91000000-0000-0000-0000-000000000002', 'support_executive', 'qa-ordinary-actor@example.invalid', true),
  ('91000000-0000-0000-0000-000000000003', 'admin', 'qa-inactive-admin@example.invalid', false);

-- Pre-flight authority must fail closed for invalid/inactive actors and
-- non-allowlisted roles before any future Auth Admin API call occurs.
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000001', 'rgs_admin'),
  true, 'an active admin may pre-flight an allowlisted role'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000002', 'rgs_admin'),
  false, 'ordinary staff fails the grant pre-flight'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000001', 'totally_made_up_role'),
  false, 'non-allowlisted role fails the grant pre-flight'
);
select is(
  public.can_grant_staff_role('91000000-0000-0000-0000-000000000003', 'rgs_admin'),
  false, 'an inactive admin fails the grant pre-flight'
);

-- Ordinary authenticated staff cannot provision (not admin/super_admin).
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000002') $$,
  '%Not authorised%',
  'a non-admin actor cannot grant a staff role'
);

-- Revoked/inactive admins cannot continue granting roles with a still-live
-- session or through a service-role caller that presents their actor id.
select throws_like(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS', 'rgs_admin', '91000000-0000-0000-0000-000000000003') $$,
  '%Not authorised%',
  'an inactive admin actor cannot grant a staff role'
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

-- A same-role request with changed metadata is not incorrectly swallowed by
-- the idempotency shortcut; the effective metadata update must be applied.
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS Updated', 'rgs_admin', '91000000-0000-0000-0000-000000000001', 'RGS', 'QA Device') $$,
  'same-role replay with changed metadata updates the existing staff row'
);
select is(
  (select full_name || '|' || department || '|' || designation from public.users where id = '92000000-0000-0000-0000-000000000001'),
  'QA RGS Updated|RGS|QA Device',
  'same-role metadata changes are persisted'
);

-- Direct revoke authorization is independently fail-closed for both an
-- ordinary user and a revoked/inactive admin, even if their JWT session has
-- not yet expired.
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
select throws_like(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'unauthorised attempt') $$,
  '%Not authorised%',
  'a non-admin authenticated actor cannot revoke staff users'
);

set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000003';
select throws_like(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'inactive admin attempt') $$,
  '%Not authorised%',
  'an inactive admin cannot revoke staff users'
);

-- Revocation works for an active admin and is itself audited.
set local request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.revoke_staff_user('92000000-0000-0000-0000-000000000001', 'no longer needed for testing') $$,
  'an active admin can revoke a staff user with a reason'
);
select is(
  (select is_active from public.users where id = '92000000-0000-0000-0000-000000000001'),
  false, 'revoked user is marked inactive'
);

-- A fresh/retried grant must recover a previously-created but inactive user
-- instead of being swallowed by idempotency.
select lives_ok(
  $$ select public.grant_staff_role('92000000-0000-0000-0000-000000000001', 'qa-rgs@example.invalid', 'QA RGS Updated', 'rgs_admin', '91000000-0000-0000-0000-000000000001', 'RGS', 'QA Device') $$,
  'a fresh grant recovers an inactive partially-provisioned identity'
);
select is(
  (select is_active from public.users where id = '92000000-0000-0000-0000-000000000001'),
  true, 'fresh grant restores the staff row to active'
);

select finish();
rollback;
