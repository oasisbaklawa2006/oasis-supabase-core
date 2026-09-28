begin;
-- Contract for migration 20260912010200_trace_reprint_execution_idempotency.sql.
-- Also certifies migration 20260912010300_trace_reprint_execution_unique_indexes.sql.
-- Also certifies migration 20260912010400_trace_reprint_execution_log_unique_index.sql.
select plan(14);

select has_function(
  'public', 'trace_record_reprint_command_v1',
  array['uuid','text','uuid','uuid','uuid','text','text','integer','text'],
  'atomic governed reprint command recorder exists'
);

select has_column('public', 'ols_print_jobs', 'reprint_request_id', 'print jobs carry structured reprint request identity');
select has_column('public', 'ols_print_logs', 'reprint_request_id', 'print logs carry structured reprint request identity');

select ok(
  exists (
    select 1 from pg_index i
    join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.ols_print_jobs'::regclass
      and c.relname = 'ols_print_jobs_reprint_request_uniq'
      and i.indisunique
  ),
  'print jobs enforce one durable row per reprint request'
);

select ok(
  exists (
    select 1 from pg_index i
    join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.ols_print_logs'::regclass
      and c.relname = 'ols_print_logs_reprint_request_uniq'
      and i.indisunique
  ),
  'print logs enforce one durable row per reprint request'
);

insert into public.users(id, role, is_sales_executive)
values ('d2920000-0000-0000-0000-000000000001', 'PACKING_SUPERVISOR', false)
on conflict (id) do nothing;

set local request.jwt.claim.sub = 'd2920000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

insert into public.ols_print_logs(ref_type, ref_id, printed_by, success, is_reprint, reprint_count, reason)
values (
  'carton',
  'd2920000-0000-0000-0000-00000000c001',
  'd2920000-0000-0000-0000-000000000001',
  true, false, 0, 'execution idempotency fixture'
);

insert into public.ols_reprint_requests(id, ref_type, ref_id, reason, status, requested_by)
values (
  'd2920000-0000-0000-0000-00000000a001',
  'carton',
  'd2920000-0000-0000-0000-00000000c001',
  'damaged label',
  'pending',
  'd2920000-0000-0000-0000-000000000001'
);

select is(
  (public.trace_allocate_reprint_count_v1(
    'carton',
    'd2920000-0000-0000-0000-00000000c001',
    'damaged label',
    'trace-reprint:d2920000-0000-0000-0000-00000000a001',
    null
  )->>'reprint_count')::int,
  1,
  'fixture receives first governed count'
);

select is(
  public.trace_record_reprint_command_v1(
    'd2920000-0000-0000-0000-00000000a001',
    'carton',
    'd2920000-0000-0000-0000-00000000c001',
    null,
    null,
    'TSPL',
    'SIZE 100 mm,50 mm\nTEXT 10,10,"0",0,1,1,"TEST"\nPRINT 1',
    1,
    'command_generated|request=d2920000-0000-0000-0000-00000000a001'
  )->>'idempotency_replayed',
  'false',
  'first command recording creates durable execution'
);

select is(
  public.trace_record_reprint_command_v1(
    'd2920000-0000-0000-0000-00000000a001',
    'carton',
    'd2920000-0000-0000-0000-00000000c001',
    null,
    null,
    'TSPL',
    'SIZE 100 mm,50 mm\nTEXT 10,10,"0",0,1,1,"TEST"\nPRINT 1',
    1,
    'command_generated|request=d2920000-0000-0000-0000-00000000a001'
  )->>'idempotency_replayed',
  'true',
  'repeat recording replays existing durable execution'
);

select is(
  (select count(*)::int from public.ols_print_jobs where reprint_request_id = 'd2920000-0000-0000-0000-00000000a001'),
  1,
  'replay creates no duplicate print job'
);

select is(
  (select count(*)::int from public.ols_print_logs where reprint_request_id = 'd2920000-0000-0000-0000-00000000a001'),
  1,
  'replay creates no duplicate print log'
);

select is(
  (select count(*)::int from public.ols_audit_logs where idempotency_key = 'trace-reprint-command:d2920000-0000-0000-0000-00000000a001'),
  1,
  'execution audit evidence is idempotent'
);

select throws_ok(
  $$select public.trace_record_reprint_command_v1(
    'd2920000-0000-0000-0000-00000000a001',
    'carton',
    'd2920000-0000-0000-0000-00000000c001',
    null,
    null,
    'TSPL',
    'DIFFERENT COMMAND',
    1,
    'command_generated|request=d2920000-0000-0000-0000-00000000a001'
  )$$,
  'IDEMPOTENCY_KEY_CONFLICT',
  'same request cannot be replayed with a different command payload'
);

select throws_ok(
  $$select public.trace_record_reprint_command_v1(
    'd2920000-0000-0000-0000-00000000afff',
    'carton',
    'd2920000-0000-0000-0000-00000000c001',
    null,
    null,
    'TSPL',
    'TEST',
    1,
    'missing allocation'
  )$$,
  'TRACE_REPRINT_ALLOCATION_REQUIRED',
  'execution cannot be persisted without a governed allocation'
);

select is(
  (select reprint_request_id::text from public.ols_print_logs where reprint_request_id = 'd2920000-0000-0000-0000-00000000a001'),
  'd2920000-0000-0000-0000-00000000a001',
  'structured request identity remains queryable independent of log history depth'
);

select * from finish();
rollback;
