-- Contract for migration 20260906130000_point17_org_hierarchy_integrity_hardening.sql
begin;

select plan(7);

select has_function(
  'public',
  'enforce_org_membership_branch_scope_company_match',
  array[]::text[],
  'enforce_org_membership_branch_scope_company_match trigger function exists'
);

select ok(
  exists(
    select 1
    from pg_trigger
    where tgrelid = 'public.org_membership_branch_scopes'::regclass
      and tgname = 'trg_org_membership_branch_scopes_company_match'
      and not tgisinternal
  ),
  'org_membership_branch_scopes company-match trigger is installed'
);

select ok(
  position('not owned by p_company_id' in lower(coalesce(obj_description(
    'public.has_app_permission(uuid,text,uuid,uuid)'::regprocedure::oid,
    'pg_proc'
  ), ''))) > 0,
  'has_app_permission comment documents branch-company fail-closed semantics'
);

insert into auth.users (id, email) values
  ('a1730000-0000-0000-0000-000000000001', 'point17-integrity@pgtap.invalid');

insert into public.roles (id, role_key, role_name, is_active) values
  ('a1730000-0000-0000-0000-000000000101', 'point17_integrity_manager', 'Point17 integrity manager', true)
on conflict (role_key) do update set is_active = true;

insert into public.role_permission_grants (role_key, permission_key, effect) values
  ('point17_integrity_manager', 'org.manage', 'allow')
on conflict (role_key, permission_key) do update set effect = excluded.effect;

set local session_replication_role = replica;

insert into public.org_companies (id, legal_name, status) values
  ('a1730000-0000-0000-0000-000000000011', 'Point17 Integrity Co A', 'active'),
  ('a1730000-0000-0000-0000-000000000012', 'Point17 Integrity Co B', 'active');

insert into public.org_branches (id, company_id, branch_code, name, status) values
  ('a1730000-0000-0000-0000-000000000021', 'a1730000-0000-0000-0000-000000000011', 'IA-HQ', 'Integrity A HQ', 'active'),
  ('a1730000-0000-0000-0000-000000000023', 'a1730000-0000-0000-0000-000000000012', 'IB-HQ', 'Integrity B HQ', 'active');

insert into public.org_memberships (id, company_id, user_id, status) values
  ('a1730000-0000-0000-0000-000000000041', 'a1730000-0000-0000-0000-000000000011', 'a1730000-0000-0000-0000-000000000001', 'active');

insert into public.org_membership_roles (membership_id, role_key) values
  ('a1730000-0000-0000-0000-000000000041', 'point17_integrity_manager');

set local session_replication_role = default;

set local request.jwt.claim.sub = 'a1730000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select ok(
  not public.has_app_permission(
    'a1730000-0000-0000-0000-000000000001',
    'org.manage',
    null,
    'a1730000-0000-0000-0000-000000000023'
  ),
  'has_app_permission rejects cross-company branch when p_company_id is null'
);

select ok(
  public.has_app_permission(
    'a1730000-0000-0000-0000-000000000001',
    'org.manage',
    null,
    'a1730000-0000-0000-0000-000000000021'
  ),
  'has_app_permission grants unscoped membership for same-company branch when p_company_id is null'
);

select ok(
  not public.has_app_permission(
    'a1730000-0000-0000-0000-000000000001',
    'org.manage',
    'a1730000-0000-0000-0000-000000000011',
    'a1730000-0000-0000-0000-000000000023'
  ),
  'has_app_permission rejects cross-company branch for unrestricted membership'
);

select throws_ok(
  $$insert into public.org_membership_branch_scopes (membership_id, branch_id)
    values (
      'a1730000-0000-0000-0000-000000000041',
      'a1730000-0000-0000-0000-000000000023'
    )$$,
  '23514',
  null,
  'org_membership_branch_scopes rejects cross-company branch pairing'
);

select * from finish();
rollback;
