-- Contract and behaviour test for migration 20261101030000_ai_studio_scoped_access_v1.sql
-- (Studio #272): membership resolver, AAL2-gated administration, audit, least privilege.
-- Transactional; synthetic identities only. Triggers/FKs on seeded rows are bypassed via
-- session_replication_role = replica (RLS and function logic are NOT bypassed).
BEGIN;
SELECT plan(70);

-- ---------------------------------------------------------------- structure
SELECT has_table('public', 'ai_studio_role_templates', 'S01 role profiles exist');
SELECT has_table('public', 'ai_studio_user_access', 'S02 explicit membership exists');
SELECT has_table('public', 'ai_studio_access_audit', 'S03 audit exists');
SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN (
  'public.ai_studio_role_templates'::regclass, 'public.ai_studio_user_access'::regclass,
  'public.ai_studio_access_audit'::regclass)), 'S04 RLS enabled on all three tables');
SELECT is((SELECT count(*)::int FROM public.ai_studio_role_templates), 9, 'S05 nine controlled profiles');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.ai_studio_role_templates
  WHERE EXISTS (SELECT 1 FROM unnest(permission_keys) k
    WHERE k ~* '(delete|financ|sync|price_approve|publish)')),
  'S06 catalog contains no hard-delete, finance, sync or publication permission');
SELECT ok(NOT has_table_privilege('authenticated', 'public.ai_studio_user_access', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.ai_studio_user_access', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.ai_studio_user_access', 'DELETE'),
  'S07 browser cannot write membership directly');
SELECT ok(NOT has_table_privilege('authenticated', 'public.ai_studio_access_audit', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.ai_studio_access_audit', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.ai_studio_access_audit', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.ai_studio_access_audit', 'DELETE'),
  'S08 browser has no access to audit');
SELECT ok(NOT has_table_privilege('anon', 'public.ai_studio_user_access', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.ai_studio_role_templates', 'SELECT'),
  'S09 anon cannot read Studio IAM tables');
SELECT ok(NOT has_function_privilege('anon', 'public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.has_ai_studio_permission_v1(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.list_ai_studio_access_v1()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.can_manage_ai_studio_access_v1()', 'EXECUTE'),
  'S10 anon cannot execute any Studio access RPC');
SELECT ok(NOT has_function_privilege('authenticated', 'public.ai_studio_permission_known_v1(text)', 'EXECUTE'),
  'S11 internal catalog helper is not browser-callable');
SELECT ok((SELECT bool_and(prosecdef AND proconfig @> ARRAY['search_path=""']) FROM pg_proc WHERE oid IN (
  'public.has_ai_studio_permission_v1(text)'::regprocedure,
  'public.can_manage_ai_studio_access_v1()'::regprocedure,
  'public.list_ai_studio_access_v1()'::regprocedure,
  'public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)'::regprocedure)),
  'S12 privileged functions are SECURITY DEFINER with an empty search_path');
SELECT is((SELECT count(*)::int FROM pg_policies WHERE schemaname = 'public'
  AND tablename IN ('products', 'product_media', 'product_variants')
  AND (COALESCE(qual, '') || COALESCE(with_check, '')) LIKE '%ai_studio%'),
  0, 'S13 no product/media/variant policy depends on Studio IAM (no authority change)');
SELECT ok((SELECT prosrc FROM pg_proc WHERE oid = 'public.is_admin()'::regprocedure) NOT LIKE '%ai_studio%',
  'S14 global is_admin() is not touched');

-- ---------------------------------------------------------------- identities
SET LOCAL session_replication_role = replica;
CREATE TEMP TABLE c272_ids (label text PRIMARY KEY, sub uuid, role_value text, active boolean, invite text, profile text, studio_status text);
INSERT INTO c272_ids VALUES
 ('owner',     '94727200-0000-0000-0000-000000000001', 'SUPER_ADMIN',        TRUE,  'active',   'owner',          'active'),
 ('manager',   '94727200-0000-0000-0000-000000000002', 'operations_manager', TRUE,  'active',   'studio_admin',   'active'),
 ('editor',    '94727200-0000-0000-0000-000000000003', 'sales_executive',    TRUE,  'active',   'product_editor', 'active'),
 ('suspended', '94727200-0000-0000-0000-000000000004', 'sales_executive',    TRUE,  'active',   'product_editor', 'suspended'),
 ('revoked',   '94727200-0000-0000-0000-000000000005', 'sales_executive',    TRUE,  'active',   'studio_admin',   'revoked'),
 ('nomember',  '94727200-0000-0000-0000-000000000006', 'ADMIN',              TRUE,  'active',   NULL,             NULL),
 ('cand',      '94727200-0000-0000-0000-000000000007', 'sales_executive',    TRUE,  'active',   NULL,             NULL),
 ('inactive',  '94727200-0000-0000-0000-000000000008', 'sales_executive',    FALSE, 'active',   NULL,             NULL),
 ('uninvited', '94727200-0000-0000-0000-000000000009', 'sales_executive',    TRUE,  'pending',  NULL,             NULL),
 ('buyer',     '94727200-0000-0000-0000-000000000010', 'BUYER',              TRUE,  'active',   NULL,             NULL),
 ('inactive_member', '94727200-0000-0000-0000-000000000011', 'sales_executive', FALSE, 'active', 'product_editor', 'active'),
 ('deleted_member',  '94727200-0000-0000-0000-000000000012', 'sales_executive', TRUE,  'active', 'product_editor', 'active');
GRANT ALL ON c272_ids TO PUBLIC;
INSERT INTO auth.users (id, email) SELECT sub, 'qa-c272-' || label || '@example.invalid' FROM c272_ids;
INSERT INTO public.users (id, role, email, is_active, invite_status)
SELECT sub, role_value, 'qa-c272-' || label || '@example.invalid', active, invite FROM c272_ids;
UPDATE public.users SET deleted_at = now() WHERE id = '94727200-0000-0000-0000-000000000012';
INSERT INTO public.ai_studio_user_access (user_id, status, profile_keys, approved_by, approved_at, changed_by)
SELECT sub, studio_status, ARRAY[profile], sub, now(), sub FROM c272_ids WHERE profile IS NOT NULL;

CREATE FUNCTION pg_temp.as_user(p_label text, p_aal text DEFAULT 'aal2') RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claim.role', 'authenticated', true),
         set_config('request.jwt.claim.sub', (SELECT sub::text FROM c272_ids WHERE label = p_label), true),
         set_config('request.jwt.claims', json_build_object('sub', (SELECT sub FROM c272_ids WHERE label = p_label),
           'role', 'authenticated', 'aal', p_aal)::text, true);
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text, text) TO PUBLIC;

-- ---------------------------------------------------------------- resolver (S15-S32)
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('owner');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), TRUE, 'R01 owner has app access');
SELECT is(public.can_manage_ai_studio_access_v1(), TRUE, 'R02 owner can manage access');
SELECT pg_temp.as_user('manager');
SELECT is(public.can_manage_ai_studio_access_v1(), TRUE, 'R03 studio_admin can manage access');
SELECT pg_temp.as_user('editor');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.update'), TRUE, 'R04 product_editor can update products');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.users.manage'), FALSE, 'R05 product_editor cannot manage users');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.review'), FALSE, 'R06 product_editor cannot review');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.no_such_permission'), FALSE, 'R07 unknown permission key is false');
SELECT is(public.has_ai_studio_permission_v1(NULL), FALSE, 'R08 null permission key is false');
SELECT is(public.can_manage_ai_studio_access_v1(), FALSE, 'R09 product_editor cannot manage access');
SELECT pg_temp.as_user('suspended');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'R10 suspended member has no access');
SELECT pg_temp.as_user('revoked');
SELECT is(public.can_manage_ai_studio_access_v1(), FALSE, 'R11 revoked studio_admin cannot manage');
SELECT pg_temp.as_user('nomember');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'R12 uppercase ADMIN without membership has no access');
SELECT pg_temp.as_user('inactive_member');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'R13 inactive Core identity loses access despite membership');
SELECT pg_temp.as_user('deleted_member');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'R14 soft-deleted Core identity loses access');
SELECT set_config('request.jwt.claim.sub', '94727200-0000-0000-0000-000000000099', true);
SELECT set_config('request.jwt.claims', '{"sub":"94727200-0000-0000-0000-000000000099","aal":"aal2"}', true);
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'R15 unknown identity has no access');
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claims', '', true);
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'R16 missing identity fails closed');
SELECT is(public.can_manage_ai_studio_access_v1(), FALSE, 'R17 missing identity cannot manage');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.has_ai_studio_permission_v1('ai_studio.app.access')$$, '42501', NULL, 'R18 anon cannot call the resolver');
RESET ROLE;

-- ---------------------------------------------------------------- RLS reads
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('editor');
SELECT is((SELECT count(*)::int FROM public.ai_studio_user_access), 1, 'L01 ordinary member sees only own membership row');
SELECT pg_temp.as_user('manager');
SELECT cmp_ok((SELECT count(*)::int FROM public.ai_studio_user_access), '>', 1, 'L02 manager sees the membership directory');
SELECT throws_ok($$UPDATE public.ai_studio_user_access SET status = 'active'$$, '42501', NULL, 'L03 direct membership UPDATE is refused');
SELECT throws_ok($$SELECT * FROM public.ai_studio_access_audit$$, '42501', NULL, 'L04 audit is unreadable from the browser');

-- ---------------------------------------------------------------- directory listing
SELECT pg_temp.as_user('manager', 'aal2');
SELECT ok((SELECT jsonb_array_length(public.list_ai_studio_access_v1())) >= 8, 'D01 manager (AAL2) can list staff directory');
SELECT ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_ai_studio_access_v1()) e
  WHERE e->>'email' = 'qa-c272-buyer@example.invalid'), 'D02 buyer identities are excluded from the directory');
SELECT pg_temp.as_user('manager', 'aal1');
SELECT throws_ok($$SELECT public.list_ai_studio_access_v1()$$, '42501', NULL, 'D03 directory requires AAL2');
SELECT pg_temp.as_user('editor', 'aal2');
SELECT throws_ok($$SELECT public.list_ai_studio_access_v1()$$, '42501', NULL, 'D04 non-manager cannot list directory');

-- ---------------------------------------------------------------- administration
SELECT pg_temp.as_user('editor', 'aal2');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A01 non-manager cannot administer');
SELECT pg_temp.as_user('manager', 'aal1');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A02 manager without AAL2 cannot administer');
SELECT pg_temp.as_user('manager', 'aal2');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000002','active',ARRAY['viewer'],'{}','valid audit reason',1)$$,
  '42501', NULL, 'A03 self-permission change is prohibited');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['owner'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A04 Owner profile cannot be delegated');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000001','suspended',ARRAY['viewer'],'{}','valid audit reason',1)$$,
  '42501', NULL, 'A05 Owner membership is protected from delegated change');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000010','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A06 buyer identity cannot receive Studio membership');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000008','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A07 inactive Core identity cannot be activated');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000009','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A08 unaccepted invitation cannot be activated');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{}','short',0)$$,
  '22023', NULL, 'A09 audit reason is mandatory and substantive');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['nonexistent'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'A10 unknown profile is refused');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{"ai_studio.products.delete":true}','valid audit reason',0)$$,
  '22023', NULL, 'A11 override outside the closed catalog (hard delete) is refused');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{"ai_studio.media.manage":"yes"}','valid audit reason',0)$$,
  '22023', NULL, 'A12 non-boolean override is refused');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY[]::text[],'{}','valid audit reason',0)$$,
  '22023', NULL, 'A13 active membership requires a profile');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{}','valid audit reason',5)$$,
  '40001', NULL, 'A14 stale version is refused');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','bogus',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '22023', NULL, 'A15 invalid status is refused');

-- successful grant, then update, then revoke
SELECT is((public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{}','onboard catalogue viewer',0))->>'version',
  '1', 'G01 first grant creates version 1');
SELECT pg_temp.as_user('cand', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.read'), TRUE, 'G02 granted member now has read access');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.update'), FALSE, 'G03 viewer profile does not include update');
SELECT pg_temp.as_user('manager', 'aal2');
SELECT is((public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{"ai_studio.products.update":true}','grant individual update right',1))->>'version',
  '2', 'G04 second change increments version');
SELECT pg_temp.as_user('cand', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.update'), TRUE, 'G05 individual allow override applies');
SELECT pg_temp.as_user('manager', 'aal2');
SELECT is((public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{"ai_studio.products.read":false}','deny read as individual override',2))->>'version',
  '3', 'G06 third change increments version');
SELECT pg_temp.as_user('cand', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.read'), FALSE, 'G07 individual deny override beats the role profile');
SELECT pg_temp.as_user('manager', 'aal2');
SELECT is((public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','suspended',ARRAY['viewer'],'{}','suspend pending review',3))->>'status',
  'suspended', 'G08 suspension is recorded');
SELECT pg_temp.as_user('cand', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'G09 suspended member loses access immediately');
RESET ROLE;

-- ---------------------------------------------------------------- audit trail
SELECT is((SELECT count(*)::int FROM public.ai_studio_access_audit WHERE user_id = '94727200-0000-0000-0000-000000000007'),
  4, 'U01 every accepted change wrote one audit row (refusals wrote none)');
SELECT is((SELECT count(*)::int FROM public.ai_studio_access_audit
  WHERE user_id = '94727200-0000-0000-0000-000000000007' AND before_value IS NULL), 1,
  'U02 only the first change has no before-image');
SELECT is((SELECT bool_and(actor_id = '94727200-0000-0000-0000-000000000002' AND char_length(reason) >= 8)
  FROM public.ai_studio_access_audit), TRUE, 'U03 audit rows carry the actor and a reason');
SET LOCAL session_replication_role = origin;  -- triggers must be live for the immutability proof
SELECT throws_ok($$UPDATE public.ai_studio_access_audit SET reason = 'tampered'$$, '42501', NULL,
  'U04 audit rows cannot be updated even by the table owner');
SELECT throws_ok($$DELETE FROM public.ai_studio_access_audit$$, '42501', NULL,
  'U05 audit rows cannot be deleted even by the table owner');
SELECT is((SELECT approved_by FROM public.ai_studio_user_access WHERE user_id = '94727200-0000-0000-0000-000000000007'),
  '94727200-0000-0000-0000-000000000002'::uuid, 'U06 approver is recorded on activation');

SELECT * FROM finish();
ROLLBACK;
