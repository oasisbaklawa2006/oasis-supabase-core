begin;
-- Contract coverage for migration 20260912010000_trace_reprint_allocation_contract_repair.sql
-- Contract coverage for migration 20260912010100_trace_reprint_allocation_contract_repair.sql
select plan(2);

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
  '20260912010000 installs the single-use partial unique approval index'
);

select has_function(
  'public',
  'trace_allocate_reprint_count_v1',
  array['text','uuid','text','text','uuid'],
  '20260912010100 preserves the governed reprint allocation RPC signature'
);

select finish();
rollback;
