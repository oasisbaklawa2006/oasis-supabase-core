-- Contract test for migration 20260913010000_trace_reprint_approval_authority.sql
begin;
select plan(13);

select has_function(
  'public', 'trace_reprint_approver_allowed_v1', array[]::text[],
  'reprint approver role helper exists'
);
select has_function(
  'public', 'trace_approve_reprint_request_v1', array['uuid','text'],
  'reprint approval authority RPC exists'
);
select ok(
  not has_function_privilege('anon', 'public.trace_approve_reprint_request_v1(uuid,text)', 'EXECUTE'),
  'anon cannot invoke reprint approval authority'
);
select ok(
  has_function_privilege('authenticated', 'public.trace_approve_reprint_request_v1(uuid,text)', 'EXECUTE'),
  'authenticated callers reach the role-gated reprint approval authority'
);

insert into public.users (id, role, is_sales_executive) values
  ('d3140000-0000-0000-0000-000000000001', 'PACKING', false),
  ('d3140000-0000-0000-0000-000000000002', 'PACKING_SUPERVISOR', false)
on conflict (id) do update set role = excluded.role;

insert into public.ols_reprint_requests(id, ref_type, ref_id, reason, status, requested_by)
values (
  'd3140000-0000-0000-0000-00000000a001',
  'carton',
  'd3140000-0000-0000-0000-00000000b001',
  'manager-gated reprint approval fixture',
  'pending',
  'd3140000-0000-0000-0000-000000000001'
);

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'd3140000-0000-0000-0000-000000000001';

select is(
  public.trace_reprint_approver_allowed_v1(), false,
  'ordinary packing operator is not a reprint approver'
);
select throws_ok(
  $$select public.trace_approve_reprint_request_v1(
      'd3140000-0000-0000-0000-00000000a001', 'p314-approval-unauthorized'
    )$$,
  'NOT_AUTHORIZED: Trace reprint approval authority required',
  'ordinary packing operator cannot approve a reprint request'
);
select is(
  (select status from public.ols_reprint_requests where id = 'd3140000-0000-0000-0000-00000000a001'),
  'pending',
  'failed approval leaves request pending'
);

set local request.jwt.claim.sub = 'd3140000-0000-0000-0000-000000000002';

select is(
  public.trace_reprint_approver_allowed_v1(), true,
  'packing supervisor has reprint approval authority'
);
select is(
  public.trace_approve_reprint_request_v1(
    'd3140000-0000-0000-0000-00000000a001', 'p314-approval-authorized'
  )->>'status',
  'approved',
  'authorized supervisor can approve the pending request'
);
select is(
  (select approved_by::text from public.ols_reprint_requests where id = 'd3140000-0000-0000-0000-00000000a001'),
  'd3140000-0000-0000-0000-000000000002',
  'approval records the authenticated supervisor as approved_by'
);
select is(
  public.trace_approve_reprint_request_v1(
    'd3140000-0000-0000-0000-00000000a001', 'p314-approval-authorized'
  )->>'status',
  'approved',
  'exact idempotent replay returns the approved result'
);
select is(
  (select count(*)::int from public.ols_audit_logs where idempotency_key = 'p314-approval-authorized'),
  1,
  'approval writes one immutable audit record'
);
select is(
  (select count(*)::int from public.ols_trace_mutation_receipts where idempotency_key = 'p314-approval-authorized'),
  1,
  'approval writes one idempotency receipt'
);

select * from finish();
rollback;
