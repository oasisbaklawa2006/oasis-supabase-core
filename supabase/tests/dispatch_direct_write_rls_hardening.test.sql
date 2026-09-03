begin;

-- Contract coverage for 20260903193000_dispatch_direct_write_rls_hardening.sql
-- and 20260904030000_dispatch_direct_write_table_privilege_closure.sql.
select plan(21);

select ok(
  has_table_privilege('authenticated', 'public.finance_review_evidence', 'SELECT'),
  'authenticated retains SELECT privilege on finance_review_evidence; RLS decides row visibility'
);
select ok(
  has_table_privilege('authenticated', 'public.finance_review_evidence', 'INSERT'),
  'authenticated retains INSERT privilege on finance_review_evidence; finance-only RLS decides append authority'
);
select ok(
  not has_table_privilege('authenticated', 'public.finance_review_evidence', 'UPDATE'),
  'authenticated cannot directly UPDATE append-only finance evidence'
);
select ok(
  not has_table_privilege('authenticated', 'public.finance_review_evidence', 'DELETE'),
  'authenticated cannot directly DELETE append-only finance evidence'
);
select ok(
  not has_table_privilege('authenticated', 'public.finance_review_evidence', 'TRUNCATE'),
  'authenticated cannot TRUNCATE finance evidence'
);
select ok(
  not has_table_privilege('authenticated', 'public.finance_review_evidence', 'REFERENCES'),
  'authenticated has no REFERENCES privilege on finance evidence'
);
select ok(
  not has_table_privilege('authenticated', 'public.finance_review_evidence', 'TRIGGER'),
  'authenticated has no TRIGGER privilege on finance evidence'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'finance_review_evidence'
      and cmd = 'INSERT'
  ),
  1,
  'finance_review_evidence has exactly one direct INSERT policy'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'finance_review_evidence'
      and cmd in ('ALL', 'UPDATE', 'DELETE')
  ),
  0,
  'finance_review_evidence exposes no ALL/UPDATE/DELETE RLS policy'
);

select ok(
  has_table_privilege('authenticated', 'public.inventory_reservations', 'SELECT'),
  'authenticated retains staff-readable SELECT privilege on inventory_reservations'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'INSERT'),
  'authenticated cannot directly INSERT inventory_reservations'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'UPDATE'),
  'authenticated cannot directly UPDATE inventory_reservations'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'DELETE'),
  'authenticated cannot directly DELETE inventory_reservations'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'TRUNCATE'),
  'authenticated cannot TRUNCATE inventory reservations'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'REFERENCES'),
  'authenticated has no REFERENCES privilege on inventory reservations'
);
select ok(
  not has_table_privilege('authenticated', 'public.inventory_reservations', 'TRIGGER'),
  'authenticated has no TRIGGER privilege on inventory reservations'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'inventory_reservations'
      and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
  ),
  0,
  'inventory_reservations exposes no direct-write RLS policy'
);

insert into public.users (id, role) values
  ('18200000-0000-0000-0000-000000000001', 'DISPATCH_MANAGER'),
  ('18200000-0000-0000-0000-000000000002', 'FINANCE_EXEC');

insert into public.orders (id, order_number, tracking_token, order_origin)
values (
  '18210000-0000-0000-0000-000000000001',
  'P0-RLS-182-ORDER-1',
  'p0-rls-182-token-1',
  'MANUAL'
);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '18200000-0000-0000-0000-000000000001';
set local role authenticated;

select throws_like(
  $$
    insert into public.finance_review_evidence (
      order_id, review_type, review_status, evidence_type,
      actor_id, actor_role, correlation_id, metadata
    ) values (
      '18210000-0000-0000-0000-000000000001'::uuid,
      'finance_hold', 'blocked', 'pgtap',
      '18200000-0000-0000-0000-000000000001'::uuid,
      'DISPATCH_MANAGER', 'p0-rls-182-dispatch-finance', '{}'::jsonb
    )
  $$,
  '%row-level security%',
  'DISPATCH_MANAGER direct PostgREST-equivalent finance evidence INSERT fails closed'
);

select throws_ok(
  $$insert into public.inventory_reservations default values$$,
  'permission denied for table inventory_reservations',
  'DISPATCH_MANAGER direct PostgREST-equivalent reservation INSERT is blocked at table privilege boundary'
);

reset role;
set local request.jwt.claim.sub = '18200000-0000-0000-0000-000000000002';
set local role authenticated;

select lives_ok(
  $$
    insert into public.finance_review_evidence (
      order_id, review_type, review_status, evidence_type,
      actor_id, actor_role, correlation_id, metadata
    ) values (
      '18210000-0000-0000-0000-000000000001'::uuid,
      'advance_verification', 'verified', 'pgtap',
      '18200000-0000-0000-0000-000000000002'::uuid,
      'FINANCE_EXEC', 'p0-rls-182-finance-positive', '{}'::jsonb
    )
  $$,
  'FINANCE_EXEC retains canonical direct append authority for finance evidence'
);

reset role;

select is(
  (
    select count(*)::integer
    from public.finance_review_evidence
    where correlation_id = 'p0-rls-182-finance-positive'
  ),
  1,
  'authorized finance append persists exactly one evidence row'
);

select * from finish();
rollback;
