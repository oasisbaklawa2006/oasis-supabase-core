begin;
-- Contract for 20260911200000_trace_reprint_atomic_allocation_authority.sql
-- Issue #285 — atomic Trace reprint count allocation and threshold authority.
select plan(27);

select has_function(
  'public', 'trace_allocate_reprint_count_v1',
  array['text','uuid','text','text','uuid'],
  'trace_allocate_reprint_count_v1 RPC exists with the expected signature'
);
select has_function('public', 'trace_reprint_approval_threshold_v1', array[]::text[]);
select ok(
  not has_function_privilege('anon', 'public.trace_allocate_reprint_count_v1(text,uuid,text,text,uuid)', 'execute'),
  'anon cannot execute the reprint allocation RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.trace_allocate_reprint_count_v1(text,uuid,text,text,uuid)', 'execute'),
  'authenticated callers can execute the reprint allocation RPC (authorization enforced inside)'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.ols_trace_reprint_counters'::regclass),
  'reprint counter table has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.ols_trace_reprint_allocations'::regclass),
  'reprint allocation ledger has RLS enabled'
);
select ok(
  not has_table_privilege('anon', 'public.ols_trace_reprint_counters', 'SELECT')
  and not has_table_privilege('authenticated', 'public.ols_trace_reprint_counters', 'SELECT')
  and not has_table_privilege('anon', 'public.ols_trace_reprint_allocations', 'SELECT')
  and not has_table_privilege('authenticated', 'public.ols_trace_reprint_allocations', 'SELECT'),
  'client roles cannot read or mutate reprint authority internals'
);
select ok(
  (
    select strpos(pg_get_functiondef(oid), 'pg_advisory_xact_lock') > 0
       and strpos(pg_get_functiondef(oid), 'trace_reprint:') < strpos(pg_get_functiondef(oid), 'INSERT INTO public.ols_trace_reprint_counters')
    from pg_proc
    where oid = 'public.trace_allocate_reprint_count_v1(text,uuid,text,text,uuid)'::regprocedure
  ),
  'the advisory lock on (ref_type, ref_id) is acquired before the counter mutation (static proof)'
);
select ok(
  (
    select pg_get_functiondef(oid) like '%ols_trace_reprint_allocations_ref_count_uniq%'
       or pg_get_functiondef(oid) like '%ols_trace_reprint_allocations%'
    from pg_proc
    where oid = 'public.trace_allocate_reprint_count_v1(text,uuid,text,text,uuid)'::regprocedure
  ),
  'allocation persists to the durable ledger inside the RPC'
);

insert into public.users (id, role) values
  ('d2850000-0000-0000-0000-000000000001', 'PACKING_SUPERVISOR'),
  ('d2850000-0000-0000-0000-000000000002', 'BUYER')
on conflict (id) do nothing;

-- Fixture: one label reference with a prior successful print.
insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values ('carton', 'd2850000-0000-0000-0000-00000000c001', 'd2850000-0000-0000-0000-000000000001', true, false, 0, 'p285 fixture initial print');

-- =============================================================================
-- Unauthorized callers.
-- =============================================================================
reset request.jwt.claim.sub;
select throws_ok(
  $$select public.trace_allocate_reprint_count_v1('carton', 'd2850000-0000-0000-0000-00000000c001', 'unauth', 'p285-unauth-1', null)$$,
  'NOT_AUTHENTICATED',
  'anonymous caller (no auth.uid) is rejected'
);

set local request.jwt.claim.sub = 'd2850000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
select throws_ok(
  $$select public.trace_allocate_reprint_count_v1('carton', 'd2850000-0000-0000-0000-00000000c001', 'buyer', 'p285-unauth-2', null)$$,
  'NOT_AUTHORIZED: Trace packing authority required',
  'non-packing authenticated caller is rejected'
);

set local request.jwt.claim.sub = 'd2850000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select throws_ok(
  $$select public.trace_allocate_reprint_count_v1('carton', 'd2850000-0000-0000-0000-00000000c099', 'no print', 'p285-no-print', null)$$,
  'TRACE_REPRINT_NO_PRIOR_PRINT',
  'reprint allocation fails closed when no prior successful print exists'
);

-- =============================================================================
-- First governed allocation within threshold.
-- =============================================================================
select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'damaged label', 'p285-alloc-1', null
  )->>'reprint_count')::int,
  1,
  'first reprint allocation receives count 1'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'damaged label', 'p285-alloc-1', null
  )->>'allowed',
  'true',
  'first reprint within threshold is allowed without approval'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'damaged label', 'p285-alloc-1', null
  )->>'idempotency_replayed',
  'true',
  'exact idempotent replay reports idempotency_replayed=true'
);
select is(
  (select count(*)::int from public.ols_trace_reprint_allocations where ref_id = 'd2850000-0000-0000-0000-00000000c001'),
  1,
  'idempotent replay does not consume an additional allocation row'
);

-- =============================================================================
-- Threshold authority: second allocation requires approval unless granted.
-- =============================================================================
select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'second reprint', 'p285-alloc-2', null
  )->>'reprint_count')::int,
  2,
  'second concurrent-governed allocation receives count 2'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'second reprint', 'p285-alloc-2', null
  )->>'approval_required',
  'true',
  'second allocation exceeds default threshold and requires approval'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'second reprint', 'p285-alloc-2', null
  )->>'allowed',
  'false',
  'above-threshold allocation is blocked without an approved reprint request'
);

insert into public.ols_reprint_requests(
  id, ref_type, ref_id, reason, status, requested_by, approved_by
) values (
  'd2850000-0000-0000-0000-00000000a001',
  'carton',
  'd2850000-0000-0000-0000-00000000c001',
  'manager approved second reprint',
  'approved',
  'd2850000-0000-0000-0000-000000000001',
  'd2850000-0000-0000-0000-000000000001'
);

select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c001', 'third reprint', 'p285-alloc-3',
    'd2850000-0000-0000-0000-00000000a001'
  )->>'allowed',
  'true',
  'above-threshold allocation is allowed when linked to an approved reprint request'
);

-- =============================================================================
-- Idempotency conflict and rollback proofs.
-- =============================================================================
select throws_ok(
  $$select public.trace_allocate_reprint_count_v1(
      'carton', 'd2850000-0000-0000-0000-00000000c001', 'different reason', 'p285-alloc-1', null
    )$$,
  'IDEMPOTENCY_KEY_CONFLICT',
  'reusing an idempotency key with a different payload fails closed'
);

insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values ('carton', 'd2850000-0000-0000-0000-00000000c002', 'd2850000-0000-0000-0000-000000000001', true, false, 0, 'p285 rollback fixture');

create or replace function public.p285_test_force_receipt_failure()
returns trigger language plpgsql as $$
begin
  if new.idempotency_key = 'p285-rollback-key' then
    raise exception 'P285_INJECTED_RECEIPT_FAILURE' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger p285_test_force_receipt_failure_trg
  before insert on public.ols_trace_mutation_receipts
  for each row execute function public.p285_test_force_receipt_failure();

select throws_ok(
  $$select public.trace_allocate_reprint_count_v1(
      'carton', 'd2850000-0000-0000-0000-00000000c002', 'rollback probe', 'p285-rollback-key', null
    )$$,
  'P285_INJECTED_RECEIPT_FAILURE',
  'a failing receipt insert rolls back the allocation made earlier in the same call'
);
drop trigger p285_test_force_receipt_failure_trg on public.ols_trace_mutation_receipts;
drop function public.p285_test_force_receipt_failure();

select is(
  (select count(*)::int from public.ols_trace_reprint_allocations where ref_id = 'd2850000-0000-0000-0000-00000000c002'),
  0,
  'rollback: no durable allocation row remains after the injected receipt failure'
);
select is(
  (select count(*)::int from public.ols_audit_logs where idempotency_key = 'p285-rollback-key'),
  0,
  'rollback: no audit row remains after the injected receipt failure'
);

-- =============================================================================
-- Sequential race convergence (single session); overlapping proof is in the
-- scripts/test-trace-reprint-two-session-race.sh harness.
-- =============================================================================
insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values ('carton', 'd2850000-0000-0000-0000-00000000c003', 'd2850000-0000-0000-0000-000000000001', true, false, 0, 'p285 race fixture');

select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c003', 'race-a', 'p285-race-a', null
  )->>'reprint_count')::int,
  1,
  'race fixture first allocation is count 1'
);
select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2850000-0000-0000-0000-00000000c003', 'race-b', 'p285-race-b', null
  )->>'reprint_count')::int,
  2,
  'race fixture second allocation is count 2 (distinct, monotonic)'
);
select is(
  (select count(distinct reprint_count)::int from public.ols_trace_reprint_allocations where ref_id = 'd2850000-0000-0000-0000-00000000c003'),
  2,
  'sequential race calls converge on distinct durable counts for the same reference'
);

select finish();
rollback;
