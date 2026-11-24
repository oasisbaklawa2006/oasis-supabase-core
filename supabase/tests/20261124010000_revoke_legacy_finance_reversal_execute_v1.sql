-- Contract for migration 20261124010000_revoke_legacy_finance_reversal_execute_v1.sql:
-- the immediate single-actor reversal is no longer callable by any API role, while the two-step flow stays callable.
begin;
select plan(8);

select has_function('public', 'reverse_finance_control_v1', array['uuid','text','text','text','text','uuid'],
  'legacy reversal function still exists (history-preserving; only EXECUTE is revoked)');

select ok(
  not has_function_privilege('authenticated', 'public.reverse_finance_control_v1(uuid,text,text,text,text,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.reverse_finance_control_v1(uuid,text,text,text,text,uuid)', 'execute')
  and not has_function_privilege('service_role', 'public.reverse_finance_control_v1(uuid,text,text,text,text,uuid)', 'execute'),
  'no API role can execute the single-actor reversal');

select ok(
  has_function_privilege('authenticated', 'public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.complete_finance_reversal_v1(uuid,text,text,text,text,uuid)', 'execute'),
  'the two-step maker-checker reversal functions remain executable by authenticated');

select ok(
  not has_function_privilege('anon', 'public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)', 'execute')
  and not has_function_privilege('service_role', 'public.request_finance_reversal_v1(uuid,text,text,text,text,uuid)', 'execute'),
  'the two-step functions keep their narrow grants (no anon, no service_role)');

select ok(pg_get_functiondef('public.decide_finance_reversal_v1(uuid,boolean,text,text,text,text,uuid)'::regprocedure)
  like '%FINANCE_REVERSAL_MAKER_CHECKER%', 'two-step approval still enforces maker-checker');

-- Behavioural: an authenticated session is refused with insufficient_privilege (42501), not a Finance-actor error.
set local role authenticated;
select throws_ok(
  $$select * from public.reverse_finance_control_v1('00000000-0000-4000-8000-000000000001'::uuid, 'reason text', 'evidence', 'corr', 'key-1')$$,
  '42501', 'permission denied for function reverse_finance_control_v1', 'authenticated cannot call the single-actor reversal');
reset role;

select ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'reverse_finance_control_v1'
    and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where a.privilege_type = 'EXECUTE' and a.grantee = 0)),
  'PUBLIC has no EXECUTE on the legacy reversal');

select ok(exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'finance_control_events'),
  'the append-only finance_control_events history is untouched');

select * from finish();
rollback;
