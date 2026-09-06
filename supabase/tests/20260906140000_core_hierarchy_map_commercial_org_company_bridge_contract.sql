-- CORE-HIERARCHY-MAP-01 behavioral contract for commercial ↔ org hierarchy bridge.
-- Schema authority: 20260906130000_core_hierarchy_map_commercial_org_company_bridge.sql
begin;

select plan(18);

-- ---------------------------------------------------------------------------
-- A. Structural census
-- ---------------------------------------------------------------------------
select has_table(
  'public',
  'commercial_org_company_links',
  'commercial_org_company_links bridge table exists'
);

select has_function(
  'public',
  'staff_company_hierarchy_v1',
  array['uuid'],
  'staff_company_hierarchy_v1 exists'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.commercial_org_company_links'::regclass),
  'commercial_org_company_links has RLS enabled'
);

select ok(
  exists(
    select 1
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum = any(c.conkey)
    where c.conrelid = 'public.commercial_org_company_links'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.companies'::regclass
      and a.attname = 'commercial_company_id'
  ),
  'commercial_org_company_links.commercial_company_id references companies'
);

select ok(
  exists(
    select 1
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum = any(c.conkey)
    where c.conrelid = 'public.commercial_org_company_links'::regclass
      and c.contype = 'f'
      and c.confrelid = 'public.org_companies'::regclass
      and a.attname = 'org_company_id'
  ),
  'commercial_org_company_links.org_company_id references org_companies'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'commercial_org_company_links_org_company_id_uidx'
  ),
  'org_company_id uniqueness enforced for 1:1 bridge'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.staff_company_hierarchy_v1(uuid)'::regprocedure),
  'staff_company_hierarchy_v1 is SECURITY DEFINER'
);

select ok(
  not has_function_privilege('anon', 'public.staff_company_hierarchy_v1(uuid)', 'EXECUTE'),
  'anon cannot execute staff_company_hierarchy_v1'
);

select ok(
  has_function_privilege('authenticated', 'public.staff_company_hierarchy_v1(uuid)', 'EXECUTE'),
  'authenticated can execute staff_company_hierarchy_v1'
);

-- ---------------------------------------------------------------------------
-- B. Fixture: commercial + org hierarchy + staff actors
-- ---------------------------------------------------------------------------
set local session_replication_role = replica;

insert into auth.users (id, email)
values
  ('b1600000-0000-0000-0000-000000000001', 'hmap-super@point60.invalid'),
  ('b1600000-0000-0000-0000-000000000002', 'hmap-scoped@point60.invalid'),
  ('b1600000-0000-0000-0000-000000000003', 'hmap-stranger@point60.invalid');

insert into public.companies (id, business_name, status, wallet_balance, credit_limit, is_frozen)
values
  ('b1600000-0000-0000-0000-000000000101', 'Commercial Linked Co', 'active', 99999, 50000, false),
  ('b1600000-0000-0000-0000-000000000102', 'Commercial Unlinked Co', 'active', 88888, 40000, false),
  ('b1600000-0000-0000-0000-000000000103', 'Commercial Inactive Link Co', 'active', 77777, 30000, false),
  ('b1600000-0000-0000-0000-000000000104', 'Commercial Frozen Co', 'active', 66666, 20000, true);

insert into public.org_companies (id, legal_name, display_name, status)
values
  ('b1600000-0000-0000-0000-000000000201', 'Org Linked Legal', 'Org Linked Display', 'active'),
  ('b1600000-0000-0000-0000-000000000202', 'Org Suspended Legal', 'Org Suspended Display', 'suspended'),
  ('b1600000-0000-0000-0000-000000000203', 'Org Other Legal', 'Org Other Display', 'active'),
  ('b1600000-0000-0000-0000-000000000204', 'Org Suspended Probe Legal', 'Org Suspended Probe Display', 'suspended');

insert into public.org_branches (id, company_id, branch_code, name, branch_type, status)
values
  ('b1600000-0000-0000-0000-000000000301', 'b1600000-0000-0000-0000-000000000201', 'HQ', 'Head Office', 'operating', 'active'),
  ('b1600000-0000-0000-0000-000000000302', 'b1600000-0000-0000-0000-000000000201', 'WH', 'Warehouse', 'warehouse', 'active'),
  ('b1600000-0000-0000-0000-000000000303', 'b1600000-0000-0000-0000-000000000203', 'OTH', 'Other Branch', 'operating', 'active');

insert into public.org_contacts (id, full_name, email, phone, status)
values
  ('b1600000-0000-0000-0000-000000000401', 'Linked Contact', 'linked@point60.invalid', '+911111111111', 'active'),
  ('b1600000-0000-0000-0000-000000000402', 'Other Contact', 'other@point60.invalid', '+912222222222', 'active');

insert into public.org_memberships (id, company_id, contact_id, user_id, status)
values
  ('b1600000-0000-0000-0000-000000000501', 'b1600000-0000-0000-0000-000000000201', 'b1600000-0000-0000-0000-000000000401', 'b1600000-0000-0000-0000-000000000001', 'active'),
  ('b1600000-0000-0000-0000-000000000502', 'b1600000-0000-0000-0000-000000000201', null, 'b1600000-0000-0000-0000-000000000002', 'active'),
  ('b1600000-0000-0000-0000-000000000503', 'b1600000-0000-0000-0000-000000000203', 'b1600000-0000-0000-0000-000000000402', 'b1600000-0000-0000-0000-000000000003', 'active');

insert into public.org_membership_roles (membership_id, role_key)
values
  ('b1600000-0000-0000-0000-000000000501', 'owner'),
  ('b1600000-0000-0000-0000-000000000502', 'operations');

insert into public.org_membership_branch_scopes (membership_id, branch_id)
values
  ('b1600000-0000-0000-0000-000000000502', 'b1600000-0000-0000-0000-000000000301');

insert into public.commercial_org_company_links (commercial_company_id, org_company_id, link_status)
values
  ('b1600000-0000-0000-0000-000000000101', 'b1600000-0000-0000-0000-000000000201', 'active'),
  ('b1600000-0000-0000-0000-000000000104', 'b1600000-0000-0000-0000-000000000203', 'active');

insert into public.commercial_org_company_links (commercial_company_id, org_company_id, link_status)
values
  ('b1600000-0000-0000-0000-000000000103', 'b1600000-0000-0000-0000-000000000202', 'inactive');

insert into public.user_role_map (user_id, role_id)
select 'b1600000-0000-0000-0000-000000000001', id
from public.roles
where role_key = 'super_admin';

set local session_replication_role = default;

-- ---------------------------------------------------------------------------
-- C. Resolution semantics
-- ---------------------------------------------------------------------------
do $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', 'b1600000-0000-0000-0000-000000000001',
    'role', 'authenticated'
  )::text, true);
  set local role authenticated;

  v_result := public.staff_company_hierarchy_v1(null);
  if v_result->>'resolution_status' <> 'INVALID' then
    raise exception 'expected INVALID for null commercial company id';
  end if;

  v_result := public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000199');
  if v_result->>'resolution_status' <> 'INVALID' then
    raise exception 'expected INVALID for missing commercial company';
  end if;

  v_result := public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000102');
  if v_result->>'resolution_status' <> 'UNLINKED' then
    raise exception 'expected UNLINKED for commercial company without bridge row';
  end if;

  v_result := public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000103');
  if v_result->>'resolution_status' <> 'INACTIVE' then
    raise exception 'expected INACTIVE for inactive bridge link';
  end if;

  v_result := public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000101');
  if v_result->>'resolution_status' <> 'RESOLVED' then
    raise exception 'expected RESOLVED for active linked commercial company, got %', v_result;
  end if;

  if jsonb_array_length(v_result->'branches') <> 2 then
    raise exception 'super_admin RESOLVED hierarchy must include both branches';
  end if;

  if jsonb_array_length(v_result->'contacts') <> 1 then
    raise exception 'RESOLVED hierarchy must include linked org contacts only';
  end if;

  if v_result ? 'wallet_balance' or v_result ? 'credit_limit' then
    raise exception 'SECURITY REGRESSION: commercial wallet/credit leaked in hierarchy payload';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('resolution semantics: INVALID, UNLINKED, INACTIVE, RESOLVED without commercial leakage');

-- Frozen commercial company resolves INACTIVE even with active link
do $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', 'b1600000-0000-0000-0000-000000000001',
    'role', 'authenticated'
  )::text, true);
  set local role authenticated;

  v_result := public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000104');
  if v_result->>'resolution_status' <> 'INACTIVE'
     or v_result->>'reason' <> 'COMMERCIAL_COMPANY_INACTIVE' then
    raise exception 'expected INACTIVE for frozen commercial company, got %', v_result;
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('frozen commercial company fails closed as INACTIVE');

-- Suspended org company resolves INACTIVE
do $$
declare
  v_commercial uuid := 'b1600000-0000-0000-0000-000000000102';
  v_result jsonb;
begin
  set local session_replication_role = replica;
  insert into public.commercial_org_company_links (commercial_company_id, org_company_id, link_status)
  values (v_commercial, 'b1600000-0000-0000-0000-000000000204', 'active');
  set local session_replication_role = default;

  perform set_config('request.jwt.claims', json_build_object(
    'sub', 'b1600000-0000-0000-0000-000000000001',
    'role', 'authenticated'
  )::text, true);
  set local role authenticated;

  v_result := public.staff_company_hierarchy_v1(v_commercial);
  if v_result->>'resolution_status' <> 'INACTIVE'
     or v_result->>'reason' <> 'ORG_COMPANY_INACTIVE' then
    raise exception 'expected INACTIVE for suspended org company';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('suspended org company fails closed as INACTIVE');

-- ---------------------------------------------------------------------------
-- D. Branch scope + cross-company authorization
-- ---------------------------------------------------------------------------
do $$
declare
  v_result jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', 'b1600000-0000-0000-0000-000000000002',
    'role', 'authenticated'
  )::text, true);
  set local role authenticated;

  v_result := public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000101');
  if v_result->>'resolution_status' <> 'RESOLVED' then
    raise exception 'branch-scoped member should resolve linked commercial company';
  end if;

  if jsonb_array_length(v_result->'branches') <> 1 then
    raise exception 'branch-scoped member must see only scoped branch, saw %', v_result->'branches';
  end if;

  if (v_result->'branches'->0->>'branch_code') <> 'HQ' then
    raise exception 'branch-scoped member should only receive HQ branch';
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end $$;

select pass('branch-scoped org.read limits returned branches');

do $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', 'b1600000-0000-0000-0000-000000000003',
    'role', 'authenticated'
  )::text, true);
  set local role authenticated;

  perform public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000101');

  raise exception 'SECURITY REGRESSION: stranger with org membership in another company could read linked hierarchy';
exception
  when others then
    if sqlstate <> '42501' then
      raise;
    end if;
end $$;

select pass('cross-company caller without org.read on resolved org company fails closed');

do $$
begin
  set local role authenticated;
  perform public.staff_company_hierarchy_v1('b1600000-0000-0000-0000-000000000101');
  raise exception 'SECURITY REGRESSION: unauthenticated caller could invoke staff_company_hierarchy_v1';
exception
  when others then
    if sqlstate <> '42501' then
      raise;
    end if;
end $$;

select pass('unauthenticated caller fails closed');

-- ---------------------------------------------------------------------------
-- E. Bridge integrity constraints
-- ---------------------------------------------------------------------------
set local session_replication_role = replica;

insert into public.companies (id, business_name, status)
values ('b1600000-0000-0000-0000-000000000105', 'Integrity Probe Co', 'active');

select throws_ok(
  $$insert into public.commercial_org_company_links (commercial_company_id, org_company_id)
    values (
      'b1600000-0000-0000-0000-000000000101',
      'b1600000-0000-0000-0000-000000000203'
    )$$,
  '23505',
  null,
  'duplicate commercial_company_id link is rejected'
);

select throws_ok(
  $$insert into public.commercial_org_company_links (commercial_company_id, org_company_id)
    values (
      'b1600000-0000-0000-0000-000000000105',
      'b1600000-0000-0000-0000-000000000201'
    )$$,
  '23505',
  null,
  'duplicate org_company_id link is rejected (1:1 org side)'
);

set local session_replication_role = default;

select pass('bridge table enforces deterministic 1:1 uniqueness');

select * from finish();
rollback;
