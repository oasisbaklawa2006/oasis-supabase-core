-- Contract and behavioral coverage for Point 17 canonical company/branch/contact hierarchy.
-- Schema authority: squashed baseline 20260723161256 + archived 20260723143000.
-- Evidence-only closure: no migration scope; proves linkage, integrity, isolation, and branch semantics.
begin;

select plan(40);

-- ---------------------------------------------------------------------------
-- A. Canonical authority census (structural)
-- ---------------------------------------------------------------------------
select has_function(
  'public',
  'has_active_company_membership',
  array['uuid', 'uuid'],
  'has_active_company_membership helper exists'
);

select has_function(
  'public',
  'has_app_permission',
  array['uuid', 'text', 'uuid', 'uuid'],
  'has_app_permission helper exists'
);

select has_table('public', 'org_companies', 'org_companies is canonical company authority');
select has_table('public', 'org_branches', 'org_branches is canonical branch/location authority');
select has_table('public', 'org_contacts', 'org_contacts is canonical contact authority');
select has_table('public', 'org_memberships', 'org_memberships links contacts/users to companies');
select has_table('public', 'org_membership_branch_scopes', 'org_membership_branch_scopes scopes membership to branches');
select has_table('public', 'org_membership_roles', 'org_membership_roles carries company-scoped roles');

select ok(
  exists(
    select 1
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum = any(c.conkey)
    where c.conrelid = 'public.org_branches'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.org_companies'::regclass
      and a.attname = 'company_id'
  ),
  'org_branches.company_id references org_companies'
);

select ok(
  exists(
    select 1
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum = any(c.conkey)
    where c.conrelid = 'public.org_memberships'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.org_companies'::regclass
      and a.attname = 'company_id'
  ),
  'org_memberships.company_id references org_companies'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'org_memberships_company_user_uidx'
  ),
  'active company+user membership uniqueness index exists'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'org_branches_company_code_uidx'
  ),
  'company-scoped branch_code uniqueness index exists'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'org_contacts_email_uidx'
  ),
  'case-insensitive contact email uniqueness index exists'
);

select ok(
  (
    select count(*) = 6
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = any(array[
        'org_companies', 'org_branches', 'org_contacts',
        'org_memberships', 'org_membership_branch_scopes', 'org_membership_roles'
      ])
      and c.relrowsecurity
  ),
  'RLS is enabled on all six hierarchy junction tables'
);

select ok(
  exists(
    select 1 from public.access_permissions
    where permission_key = 'org.read' and is_active
  )
  and exists(
    select 1 from public.access_permissions
    where permission_key = 'org.manage' and is_active
  ),
  'org.read and org.manage capability seeds are active'
);

select ok(
  (
    select column_default
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'org_branches'
      and column_name = 'branch_type'
  ) like '%operating%',
  'org_branches.branch_type defaults to operating (canonical branch type)'
);

-- ---------------------------------------------------------------------------
-- B. Fixture: two isolated companies with branches, contacts, memberships
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1700000-0000-0000-0000-000000000001', 'point17-member-a@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000002', 'point17-member-b@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000003', 'point17-stranger@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000004', 'point17-branch-scope@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000005', 'point17-ended-only@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000006', 'point17-company-manager@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000007', 'point17-suspended-only@pgtap.invalid'),
  ('a1700000-0000-0000-0000-000000000008', 'point17-expired-only@pgtap.invalid');

insert into public.roles (id, role_key, role_name, is_active) values
  ('a1700000-0000-0000-0000-000000000101', 'point17_branch_manager', 'Point17 branch manager', true)
on conflict (role_key) do update set is_active = true;

insert into public.role_permission_grants (role_key, permission_key, effect) values
  ('point17_branch_manager', 'org.manage', 'allow')
on conflict (role_key, permission_key) do update set effect = excluded.effect;

set local session_replication_role = replica;

insert into public.org_companies (id, legal_name, display_name, status) values
  ('a1700000-0000-0000-0000-000000000011', 'Point17 Company A Ltd', 'Company A', 'active'),
  ('a1700000-0000-0000-0000-000000000012', 'Point17 Company B Ltd', 'Company B', 'active');

insert into public.org_branches (id, company_id, branch_code, name, branch_type, status) values
  ('a1700000-0000-0000-0000-000000000021', 'a1700000-0000-0000-0000-000000000011', 'A-HQ', 'Company A HQ', 'operating', 'active'),
  ('a1700000-0000-0000-0000-000000000022', 'a1700000-0000-0000-0000-000000000011', 'A-WH', 'Company A Warehouse', 'warehouse', 'active'),
  ('a1700000-0000-0000-0000-000000000023', 'a1700000-0000-0000-0000-000000000012', 'B-HQ', 'Company B HQ', 'operating', 'active');

insert into public.org_contacts (id, auth_user_id, full_name, email, status) values
  ('a1700000-0000-0000-0000-000000000031', 'a1700000-0000-0000-0000-000000000001', 'Member A Contact', 'member-a@point17.invalid', 'active'),
  ('a1700000-0000-0000-0000-000000000032', 'a1700000-0000-0000-0000-000000000002', 'Member B Contact', 'member-b@point17.invalid', 'active');

insert into public.org_memberships (id, company_id, contact_id, user_id, status, valid_from, valid_until) values
  ('a1700000-0000-0000-0000-000000000041', 'a1700000-0000-0000-0000-000000000011', 'a1700000-0000-0000-0000-000000000031', 'a1700000-0000-0000-0000-000000000001', 'active', now(), null),
  ('a1700000-0000-0000-0000-000000000042', 'a1700000-0000-0000-0000-000000000012', 'a1700000-0000-0000-0000-000000000032', 'a1700000-0000-0000-0000-000000000002', 'active', now(), null),
  ('a1700000-0000-0000-0000-000000000043', 'a1700000-0000-0000-0000-000000000011', null, 'a1700000-0000-0000-0000-000000000004', 'active', now(), null),
  ('a1700000-0000-0000-0000-000000000044', 'a1700000-0000-0000-0000-000000000011', null, 'a1700000-0000-0000-0000-000000000005', 'ended', now(), null),
  ('a1700000-0000-0000-0000-000000000045', 'a1700000-0000-0000-0000-000000000011', null, 'a1700000-0000-0000-0000-000000000006', 'active', now(), null),
  ('a1700000-0000-0000-0000-000000000048', 'a1700000-0000-0000-0000-000000000011', null, 'a1700000-0000-0000-0000-000000000007', 'suspended', now(), null),
  ('a1700000-0000-0000-0000-000000000049', 'a1700000-0000-0000-0000-000000000011', null, 'a1700000-0000-0000-0000-000000000008', 'active', timestamptz '2019-01-01 00:00:00+00', timestamptz '2020-01-01 00:00:00+00');

insert into public.org_membership_roles (membership_id, role_key) values
  ('a1700000-0000-0000-0000-000000000043', 'point17_branch_manager'),
  ('a1700000-0000-0000-0000-000000000045', 'point17_branch_manager');

insert into public.org_membership_branch_scopes (membership_id, branch_id) values
  ('a1700000-0000-0000-0000-000000000043', 'a1700000-0000-0000-0000-000000000021');

set local session_replication_role = default;

-- ---------------------------------------------------------------------------
-- C. Membership lifecycle and duplicate prevention
-- ---------------------------------------------------------------------------
set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select ok(
  public.has_active_company_membership(
    'a1700000-0000-0000-0000-000000000001',
    'a1700000-0000-0000-0000-000000000011'
  ),
  'active membership is recognised by has_active_company_membership'
);

select ok(
  not public.has_active_company_membership(
    'a1700000-0000-0000-0000-000000000001',
    'a1700000-0000-0000-0000-000000000012'
  ),
  'membership does not leak across companies'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000005';

select ok(
  not public.has_active_company_membership(
    'a1700000-0000-0000-0000-000000000005',
    'a1700000-0000-0000-0000-000000000011'
  ),
  'ended-only membership is not treated as active'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000007';

select ok(
  not public.has_active_company_membership(
    'a1700000-0000-0000-0000-000000000007',
    'a1700000-0000-0000-0000-000000000011'
  ),
  'suspended membership is not treated as active'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000008';

select ok(
  not public.has_active_company_membership(
    'a1700000-0000-0000-0000-000000000008',
    'a1700000-0000-0000-0000-000000000011'
  ),
  'expired valid_until membership is not treated as active'
);

set local session_replication_role = replica;
select throws_ok(
  $$insert into public.org_memberships (company_id, user_id, status)
    values (
      'a1700000-0000-0000-0000-000000000011',
      'a1700000-0000-0000-0000-000000000001',
      'active'
    )$$,
  '23505',
  null,
  'duplicate active company+user membership is rejected'
);

select throws_ok(
  $$insert into public.org_branches (company_id, branch_code, name, status)
    values (
      'a1700000-0000-0000-0000-000000000011',
      'A-HQ',
      'Duplicate code probe',
      'active'
    )$$,
  '23505',
  null,
  'duplicate company branch_code is rejected'
);

select throws_ok(
  $$insert into public.org_contacts (full_name, email, status)
    values ('Duplicate Email Probe', 'MEMBER-A@point17.invalid', 'active')$$,
  '23505',
  null,
  'duplicate contact email is rejected case-insensitively'
);
set local session_replication_role = default;

-- ---------------------------------------------------------------------------
-- D. Default branch semantics: empty scopes grant all branches; explicit scopes restrict
-- ---------------------------------------------------------------------------
set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000006';

select ok(
  public.has_app_permission(
    'a1700000-0000-0000-0000-000000000006',
    'org.manage',
    'a1700000-0000-0000-0000-000000000011',
    'a1700000-0000-0000-0000-000000000021'
  ),
  'membership role without branch scopes grants org.manage for any branch in the company (default-all-branches semantics)'
);

select ok(
  public.has_app_permission(
    'a1700000-0000-0000-0000-000000000006',
    'org.manage',
    'a1700000-0000-0000-0000-000000000011',
    'a1700000-0000-0000-0000-000000000022'
  ),
  'membership role without branch scopes grants org.manage for a second branch in the same company'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000004';

select ok(
  public.has_app_permission(
    'a1700000-0000-0000-0000-000000000004',
    'org.manage',
    'a1700000-0000-0000-0000-000000000011',
    'a1700000-0000-0000-0000-000000000021'
  ),
  'branch-scoped membership role grants org.manage for the scoped branch'
);

select ok(
  not public.has_app_permission(
    'a1700000-0000-0000-0000-000000000004',
    'org.manage',
    'a1700000-0000-0000-0000-000000000011',
    'a1700000-0000-0000-0000-000000000022'
  ),
  'branch-scoped membership role denies org.manage for a non-scoped branch'
);

-- ---------------------------------------------------------------------------
-- E. Tenant isolation under RLS (cross-company denial)
-- ---------------------------------------------------------------------------
set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select isnt_empty(
  $$select 1 from public.org_companies where id = 'a1700000-0000-0000-0000-000000000011'$$,
  'company A member can read own company under RLS'
);

select is_empty(
  $$select 1 from public.org_companies where id = 'a1700000-0000-0000-0000-000000000012'$$,
  'company A member cannot read company B under RLS'
);

select isnt_empty(
  $$select 1 from public.org_branches where company_id = 'a1700000-0000-0000-0000-000000000011'$$,
  'company A member can read own branches under RLS'
);

select is_empty(
  $$select 1 from public.org_branches where company_id = 'a1700000-0000-0000-0000-000000000012'$$,
  'company A member cannot read company B branches under RLS'
);

select isnt_empty(
  $$select 1 from public.org_contacts where id = 'a1700000-0000-0000-0000-000000000031'$$,
  'company A member can read co-member contact under RLS'
);

select is_empty(
  $$select 1 from public.org_contacts where id = 'a1700000-0000-0000-0000-000000000032'$$,
  'company A member cannot read company B contact under RLS'
);

set local request.jwt.claim.sub = 'a1700000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';

select is_empty(
  $$select 1 from public.org_companies$$,
  'authenticated stranger without membership cannot read any company under RLS'
);

select is_empty(
  $$select 1 from public.org_memberships where company_id = 'a1700000-0000-0000-0000-000000000011'$$,
  'authenticated stranger cannot read memberships for company A under RLS'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;
set local role anon;

select is_empty(
  $$select 1 from public.org_companies$$,
  'unauthenticated caller cannot read org_companies under RLS'
);

select is_empty(
  $$select 1 from public.org_memberships where company_id = 'a1700000-0000-0000-0000-000000000011'$$,
  'unauthenticated caller cannot read org_memberships under RLS'
);

-- ---------------------------------------------------------------------------
-- F. Canonical hierarchy linkage integrity in fixture
-- ---------------------------------------------------------------------------
reset role;

select ok(
  exists (
    select 1
    from public.org_memberships m
    join public.org_branches b on b.company_id = m.company_id
    join public.org_contacts c on c.id = m.contact_id
    where m.id = 'a1700000-0000-0000-0000-000000000041'
      and b.id = 'a1700000-0000-0000-0000-000000000021'
      and c.id = 'a1700000-0000-0000-0000-000000000031'
  ),
  'company -> branch -> contact -> membership chain is referentially consistent'
);

select ok(
  exists (
    select 1
    from public.org_membership_branch_scopes s
    join public.org_memberships m on m.id = s.membership_id
    join public.org_branches b on b.id = s.branch_id and b.company_id = m.company_id
    where s.membership_id = 'a1700000-0000-0000-0000-000000000043'
  ),
  'membership branch scopes reference a branch within the same company'
);

select * from finish();
rollback;
