-- Contract for migration 20261125010000_gifting_enquiries_release_prerequisite_verifier_v1.sql:
-- the preflight role can ask the narrow predicate, nobody else can, and no table access was granted.
begin;
select plan(11);

select has_function('public', 'gifting_enquiries_release_prerequisite_v1', array[]::text[], 'verifier exists');

select ok((select prosecdef from pg_proc where oid = 'public.gifting_enquiries_release_prerequisite_v1()'::regprocedure),
  'verifier is SECURITY DEFINER');

select ok((select 'search_path=""' = any(proconfig) from pg_proc where oid = 'public.gifting_enquiries_release_prerequisite_v1()'::regprocedure),
  'verifier pins an empty search_path');

select ok(has_function_privilege('oasis_drift_watch_ro', 'public.gifting_enquiries_release_prerequisite_v1()', 'execute'),
  'positive: oasis_drift_watch_ro can execute the verifier');

select ok(not has_function_privilege('anon', 'public.gifting_enquiries_release_prerequisite_v1()', 'execute')
  and not has_function_privilege('authenticated', 'public.gifting_enquiries_release_prerequisite_v1()', 'execute')
  and not has_function_privilege('service_role', 'public.gifting_enquiries_release_prerequisite_v1()', 'execute'),
  'negative: anon, authenticated and service_role cannot execute the verifier');

select ok(not exists (
  select 1 from pg_proc p
  where p.oid = 'public.gifting_enquiries_release_prerequisite_v1()'::regprocedure
    and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where a.privilege_type = 'EXECUTE' and a.grantee = 0)),
  'negative: PUBLIC has no EXECUTE on the verifier');

select ok(not has_table_privilege('oasis_drift_watch_ro', 'public.connect_profiles', 'select'),
  'negative: the preflight role still has no SELECT on connect_profiles');

select ok(not has_table_privilege('oasis_drift_watch_ro', 'public.connect_profiles', 'insert,update,delete'),
  'negative: the preflight role has no write privilege on connect_profiles');

-- Behavioural, as the preflight role: the verifier answers true, direct table access is still denied.
set local role oasis_drift_watch_ro;
select ok(public.gifting_enquiries_release_prerequisite_v1() is not null, 'positive: the preflight role gets a boolean answer');
select throws_ok($$select 1 from public.connect_profiles limit 1$$, '42501', null,
  'negative: direct connect_profiles read is still permission denied');
reset role;

-- Behavioural, as an API role: refused.
set local role authenticated;
select throws_ok($$select public.gifting_enquiries_release_prerequisite_v1()$$, '42501', null,
  'negative: authenticated is refused');
reset role;

select * from finish();
rollback;
