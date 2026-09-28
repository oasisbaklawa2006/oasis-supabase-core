begin;
-- Contract coverage for migration
-- 20260921110000_trace_remaining_runtime_authority.sql.

select plan(18);

select has_function('public', 'trace_add_carton_content_v1', array['uuid','uuid','text'], 'carton-content RPC exists');
select has_function('public', 'trace_allocate_carton_index_v1', array['text'], 'carton-index RPC exists');
select has_function('public', 'trace_reconcile_external_refs_v1', array[]::text[], 'external-ref RPC exists');
select has_function('public', 'trace_record_gate_scan_v1', array['text','uuid','text','text','text'], 'gate scan RPC exists');
select has_function('public', 'trace_legacy_gate_clear_v1', array['text','uuid','uuid','text'], 'legacy gate clear RPC exists');

select has_table('public', 'ols_trace_carton_index_sequences', 'carton index sequence table exists');
select ok(
  (select relrowsecurity from pg_class where oid='public.ols_trace_carton_index_sequences'::regclass),
  'carton index sequence table has RLS'
);

select is(has_function_privilege('anon','public.trace_add_carton_content_v1(uuid,uuid,text)','EXECUTE'), false, 'anon cannot add carton content');
select is(has_function_privilege('anon','public.trace_allocate_carton_index_v1(text)','EXECUTE'), false, 'anon cannot allocate carton index');
select is(has_function_privilege('anon','public.trace_reconcile_external_refs_v1()','EXECUTE'), false, 'anon cannot reconcile refs');
select is(has_function_privilege('anon','public.trace_record_gate_scan_v1(text,uuid,text,text,text)','EXECUTE'), false, 'anon cannot record gate scan');
select is(has_function_privilege('anon','public.trace_legacy_gate_clear_v1(text,uuid,uuid,text)','EXECUTE'), false, 'anon cannot clear gate');

select is(has_function_privilege('authenticated','public.trace_add_carton_content_v1(uuid,uuid,text)','EXECUTE'), true, 'authenticated RPC grant present');
select is(has_function_privilege('authenticated','public.trace_allocate_carton_index_v1(text)','EXECUTE'), true, 'authenticated carton-index grant present');
select is(has_function_privilege('authenticated','public.trace_record_gate_scan_v1(text,uuid,text,text,text)','EXECUTE'), true, 'authenticated gate-scan grant present');

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = '';

select throws_like(
  $$select public.trace_reconcile_external_refs_v1()$$,
  '%TRACE_EXTERNAL_REF_AUTHORITY_REQUIRED%',
  'external ref reconciliation fails closed without actor'
);

select throws_like(
  $$select public.trace_allocate_carton_index_v1('SO-CONTRACT')$$,
  '%NOT_AUTHENTICATED%',
  'carton index allocation fails closed without actor'
);

select throws_like(
  $$select public.trace_record_gate_scan_v1('QR-CONTRACT', null, 'green', null, 'gate-contract-1')$$,
  '%NOT_AUTHENTICATED%',
  'gate scan fails closed without dispatch authority'
);

select * from finish();
rollback;
