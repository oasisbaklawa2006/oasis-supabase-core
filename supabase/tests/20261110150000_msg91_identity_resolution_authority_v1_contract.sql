begin;

-- Contract for 20261110150000_msg91_identity_resolution_authority_v1.sql
select plan(15);

select has_function('public', 'msg91_canonical_indian_phone_v1', array['text'], 'canonical phone function installed');
select has_function('public', 'msg91_canonical_phones_v1', array['text[]'], 'canonical phone array function installed');
select has_function('public', 'resolve_msg91_identity_v1', array['text'], 'identity resolver installed');
select has_function('public', 'bind_msg91_pending_profile_v1', array['text','uuid'], 'profile binder installed');

select is(public.msg91_canonical_indian_phone_v1('+91 98765 43210'), '919876543210', 'formatted E.164 canonicalises');
select is(public.msg91_canonical_indian_phone_v1('9919876543210'), null, 'embedded-suffix number is not canonicalised');
select is(public.msg91_canonical_indian_phone_v1('+1 9876543210'), null, 'non-Indian number is rejected');
select is(public.resolve_msg91_identity_v1('12345') ->> 'status', 'phone_invalid', 'invalid phone fails closed');

select ok(not has_function_privilege('anon', 'public.resolve_msg91_identity_v1(text)', 'execute'), 'anon cannot resolve');
select ok(not has_function_privilege('authenticated', 'public.resolve_msg91_identity_v1(text)', 'execute'), 'authenticated cannot resolve');
select ok(has_function_privilege('service_role', 'public.resolve_msg91_identity_v1(text)', 'execute'), 'service_role can resolve');
select ok(not has_function_privilege('anon', 'public.bind_msg91_pending_profile_v1(text,uuid)', 'execute'), 'anon cannot bind');
select ok(not has_function_privilege('authenticated', 'public.bind_msg91_pending_profile_v1(text,uuid)', 'execute'), 'authenticated cannot bind');
select ok((select prosecdef from pg_proc where oid = 'public.bind_msg91_pending_profile_v1(text,uuid)'::regprocedure), 'binder is SECURITY DEFINER');
select ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'users_msg91_canonical_secondary_idx'), 'secondary phone GIN index installed');

select * from finish();
rollback;
