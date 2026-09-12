begin;
-- Contract for the Trace reprint approval contract repair migrations.
select plan(26);

select has_function(
  'public', 'trace_allocate_reprint_count_v1',
  array['text','uuid','text','text','uuid'],
  'reprint allocation RPC retains the production v1 signature'
);

select ok(
  exists (
    select 1
      from pg_index i
      join pg_class idx on idx.oid = i.indexrelid
     where i.indrelid = 'public.ols_trace_reprint_allocations'::regclass
       and idx.relname = 'ols_trace_reprint_allocations_approval_request_uniq'
       and i.indisunique
       and pg_get_expr(i.indpred, i.indrelid) is not null
  ),
  'approval_request_id has a partial unique index for one-time binding'
);

insert into public.users (id, role, is_sales_executive) values
  ('d2910000-0000-0000-0000-000000000001', 'PACKING_SUPERVISOR', false),
  ('d2910000-0000-0000-0000-000000000002', 'PACKING_SUPERVISOR', false)
on conflict (id) do nothing;

set local request.jwt.claim.sub = 'd2910000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- Historical Trace shipping logs use `shipping`; Core canonicalizes the new
-- authority to `shipping_label` without rejecting the prior-print evidence.
insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values (
  'shipping',
  'd2910000-0000-0000-0000-00000000b001',
  'd2910000-0000-0000-0000-000000000001',
  true, false, 0, 'contract repair shipping fixture'
);

select is(
  public.trace_allocate_reprint_count_v1(
    'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping label damaged', 'p291-shipping-1', null
  )->>'ref_type',
  'shipping_label',
  'shipping alias is accepted and canonicalized to shipping_label'
);
select is(
  (public.trace_allocate_reprint_count_v1(
    'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping label damaged', 'p291-shipping-1', null
  )->>'reprint_count')::int,
  1,
  'shipping alias idempotent replay retains count 1'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping label damaged', 'p291-shipping-1', null
  )->>'allowed',
  'true',
  'shipping alias first reprint remains allowed within threshold'
);

-- Approval IDs are nonsensical below the threshold and must be rejected rather
-- than silently discarded from durable allocation/audit state.
insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values (
  'carton',
  'd2910000-0000-0000-0000-00000000c002',
  'd2910000-0000-0000-0000-000000000001',
  true, false, 0, 'below-threshold approval fixture'
);

select throws_ok(
  $$select public.trace_allocate_reprint_count_v1(
      'carton', 'd2910000-0000-0000-0000-00000000c002', 'first governed reprint', 'p291-carton-low-1',
      'd2910000-0000-0000-0000-00000000afff'
    )$$,
  'TRACE_REPRINT_APPROVAL_NOT_REQUIRED',
  'approval_request_id is rejected when approval is not required'
);
select is(
  (select count(*)::int from public.ols_trace_reprint_counters where ref_type = 'carton' and ref_id = 'd2910000-0000-0000-0000-00000000c002'),
  0,
  'below-threshold approval rejection rolls back counter allocation'
);

-- Approval transition fixture. Count 1 is allowed, count 2 is reserved and
-- blocked, then the SAME count 2 allocation is attached to an approval request
-- and later unlocked after approval without consuming count 3.
insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values (
  'carton',
  'd2910000-0000-0000-0000-00000000c001',
  'd2910000-0000-0000-0000-000000000001',
  true, false, 0, 'contract repair carton fixture'
);

select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'first governed reprint', 'p291-carton-1', null
  )->>'reprint_count')::int,
  1,
  'first carton reprint receives count 1'
);
select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2', null
  )->>'reprint_count')::int,
  2,
  'second carton reprint reserves count 2'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2', null
  )->>'approval_required',
  'true',
  'reserved count 2 requires approval'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2', null
  )->>'allowed',
  'false',
  'reserved count 2 is blocked before approval'
);

insert into public.ols_reprint_requests(id, ref_type, ref_id, reason, status, requested_by)
values (
  'd2910000-0000-0000-0000-00000000a001',
  'carton',
  'd2910000-0000-0000-0000-00000000c001',
  'second governed reprint',
  'pending',
  'd2910000-0000-0000-0000-000000000001'
);

select is(
  (public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2',
    'd2910000-0000-0000-0000-00000000a001'
  )->>'reprint_count')::int,
  2,
  'attaching a pending approval reuses reserved count 2'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2',
    'd2910000-0000-0000-0000-00000000a001'
  )->>'allowed',
  'false',
  'pending approval remains blocked'
);
select is(
  (select approval_request_id::text from public.ols_trace_reprint_allocations where idempotency_key = 'p291-carton-2'),
  'd2910000-0000-0000-0000-00000000a001',
  'pending approval is durably bound to the existing allocation'
);
select is(
  (select count(*)::int from public.ols_trace_reprint_allocations where ref_id = 'd2910000-0000-0000-0000-00000000c001'),
  2,
  'attaching approval creates no additional allocation row'
);

update public.ols_reprint_requests
   set status = 'approved', approved_by = 'd2910000-0000-0000-0000-000000000002'
 where id = 'd2910000-0000-0000-0000-00000000a001';

select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2',
    'd2910000-0000-0000-0000-00000000a001'
  )->>'allowed',
  'true',
  'approved request unlocks the same reserved allocation'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2',
    'd2910000-0000-0000-0000-00000000a001'
  )->>'approval_granted',
  'true',
  'approved replay reports approval_granted=true'
);
select is(
  (select count(*)::int from public.ols_trace_reprint_allocations where ref_id = 'd2910000-0000-0000-0000-00000000c001'),
  2,
  'approved replay still creates no additional allocation row'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'carton', 'd2910000-0000-0000-0000-00000000c001', 'second governed reprint', 'p291-carton-2', null
  )->>'allowed',
  'true',
  'original null-approval replay returns fresh allowed state after attachment and approval'
);

select throws_ok(
  $$select public.trace_allocate_reprint_count_v1(
      'carton', 'd2910000-0000-0000-0000-00000000c001', 'third logical action', 'p291-carton-3',
      'd2910000-0000-0000-0000-00000000a001'
    )$$,
  'TRACE_REPRINT_APPROVAL_ALREADY_BOUND',
  'one approved request cannot authorize a second logical allocation'
);
select is(
  (select next_reprint_count from public.ols_trace_reprint_counters where ref_type = 'carton' and ref_id = 'd2910000-0000-0000-0000-00000000c001'),
  2,
  'rejected approval reuse rolls back the attempted counter increment'
);

-- Exercise the historical shipping approval-match branch and mismatch rejection.
select is(
  (public.trace_allocate_reprint_count_v1(
    'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping second reprint', 'p291-shipping-2', null
  )->>'reprint_count')::int,
  2,
  'second historical shipping reprint reserves count 2'
);

insert into public.ols_reprint_requests(id, ref_type, ref_id, reason, status, requested_by) values
  (
    'd2910000-0000-0000-0000-00000000a002', 'shipping',
    'd2910000-0000-0000-0000-00000000b001', 'shipping second reprint', 'pending',
    'd2910000-0000-0000-0000-000000000001'
  ),
  (
    'd2910000-0000-0000-0000-00000000a003', 'shipping',
    'd2910000-0000-0000-0000-00000000b999', 'wrong reference', 'pending',
    'd2910000-0000-0000-0000-000000000001'
  );

select throws_ok(
  $$select public.trace_allocate_reprint_count_v1(
      'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping second reprint', 'p291-shipping-2',
      'd2910000-0000-0000-0000-00000000a003'
    )$$,
  'TRACE_REPRINT_APPROVAL_REQUEST_INVALID',
  'mismatched approval reference is rejected'
);
select is(
  (public.trace_allocate_reprint_count_v1(
    'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping second reprint', 'p291-shipping-2',
    'd2910000-0000-0000-0000-00000000a002'
  )->>'reprint_count')::int,
  2,
  'historical shipping approval attaches to the same reserved count'
);
select is(
  (select approval_request_id::text from public.ols_trace_reprint_allocations where idempotency_key = 'p291-shipping-2'),
  'd2910000-0000-0000-0000-00000000a002',
  'historical shipping approval row is durably bound'
);
select is(
  public.trace_allocate_reprint_count_v1(
    'shipping', 'd2910000-0000-0000-0000-00000000b001', 'shipping second reprint', 'p291-shipping-2',
    'd2910000-0000-0000-0000-00000000a002'
  )->>'allowed',
  'false',
  'pending historical shipping approval remains blocked'
);

select finish();
rollback;
