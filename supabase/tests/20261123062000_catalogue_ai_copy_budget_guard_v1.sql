-- Transactional pgTAP: no external calls or Production usage changes.
BEGIN;
SELECT plan(18);
SELECT has_table('public', 'catalogue_ai_copy_budget_policy_v1', 'budget policy exists');
SELECT has_table('public', 'catalogue_ai_copy_usage_v1', 'quota reservation ledger exists');
SELECT ok((SELECT NOT enabled FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton), 'disabled by default');
SELECT ok((SELECT approved_model='UNAPPROVED' FROM public.catalogue_ai_copy_budget_policy_v1 WHERE singleton), 'model unapproved by default');
SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class
 WHERE oid IN ('public.catalogue_ai_copy_budget_policy_v1'::regclass,
               'public.catalogue_ai_copy_usage_v1'::regclass)), 'RLS enabled');
SELECT ok(NOT has_table_privilege('authenticated','public.catalogue_ai_copy_usage_v1','SELECT') AND
 NOT has_table_privilege('authenticated','public.catalogue_ai_copy_usage_v1','INSERT') AND
 NOT has_table_privilege('authenticated','public.catalogue_ai_copy_budget_policy_v1','UPDATE'), 'authenticated cannot alter or inspect quota');
SELECT ok(NOT has_table_privilege('anon','public.catalogue_ai_copy_usage_v1','SELECT') AND
 NOT has_table_privilege('anon','public.catalogue_ai_copy_budget_policy_v1','SELECT'), 'anon cannot read budget internals');
SELECT ok(has_function_privilege('authenticated','public.reserve_catalogue_ai_copy_budget_v1(text,integer)','EXECUTE') AND
 NOT has_function_privilege('anon','public.reserve_catalogue_ai_copy_budget_v1(text,integer)','EXECUTE'), 'only authenticated can call budget reservation');
SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
 WHERE oid='public.reserve_catalogue_ai_copy_budget_v1(text,integer)'::regprocedure), 'definer with fixed search path');
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1400),false,'no JWT cannot reserve');
-- Synthetic fixture lives only within this test transaction.
SET LOCAL session_replication_role = replica;
INSERT INTO auth.users(id,email) VALUES
 ('94780000-0000-0000-0000-000000000001','qa-budget-owner@example.invalid'),
 ('94780000-0000-0000-0000-000000000002','qa-budget-viewer@example.invalid');
INSERT INTO public.users(id,email,role,is_active,invite_status) VALUES
 ('94780000-0000-0000-0000-000000000001','qa-budget-owner@example.invalid','SUPER_ADMIN',true,'active'),
 ('94780000-0000-0000-0000-000000000002','qa-budget-viewer@example.invalid','SUPER_ADMIN',true,'active');
INSERT INTO public.ai_studio_user_access(user_id,status,profile_keys,approved_by,approved_at,changed_by) VALUES
 ('94780000-0000-0000-0000-000000000001','active',ARRAY['owner'], '94780000-0000-0000-0000-000000000001', now(), '94780000-0000-0000-0000-000000000001'),
 ('94780000-0000-0000-0000-000000000002','active',ARRAY['viewer'], '94780000-0000-0000-0000-000000000002', now(), '94780000-0000-0000-0000-000000000002');
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','94780000-0000-0000-0000-000000000001',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1400),false, 'eligible owner denied while disabled');
RESET ROLE;
UPDATE public.catalogue_ai_copy_budget_policy_v1 SET enabled=true,approved_model='gpt-4.1-mini'
 WHERE singleton;
SET LOCAL ROLE authenticated;
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('wrong-model',1400),false, 'unapproved model denied');
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1399),false, 'unexpected requested token cap denied');
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1400),true, 'first owner reservation accepted');
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1400),true, 'second owner reservation accepted');
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1400),false, 'third owner reservation minute-limited');
SELECT set_config('request.jwt.claim.sub','94780000-0000-0000-0000-000000000002',true);
SELECT is(public.reserve_catalogue_ai_copy_budget_v1('gpt-4.1-mini',1400),false, 'viewer role denied');
RESET ROLE;
SELECT is((SELECT requests FROM public.catalogue_ai_copy_usage_v1
 WHERE bucket='global_day' AND actor_id='00000000-0000-0000-0000-000000000000'::uuid
 AND bucket_start=date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),2, 'global counter has two reservations');
SELECT is((SELECT reserved_output_tokens FROM public.catalogue_ai_copy_usage_v1
 WHERE bucket='global_day' AND actor_id='00000000-0000-0000-0000-000000000000'::uuid
 AND bucket_start=date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),2800::bigint, 'global token reservation is conservative');
SELECT * FROM finish();
ROLLBACK;
