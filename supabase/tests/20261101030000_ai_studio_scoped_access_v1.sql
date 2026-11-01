-- Contract and behaviour test for migration 20261101030000_ai_studio_scoped_access_v1.sql
-- (Studio #272): membership resolver, AAL2-gated administration, audit, least privilege.
-- Transactional; synthetic identities only. Triggers/FKs on seeded rows are bypassed via
-- session_replication_role = replica (RLS and function logic are NOT bypassed).
BEGIN;
SELECT plan(119);

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
SELECT ok(NOT has_function_privilege('authenticated', 'public.ai_studio_permission_known_v1(text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.ai_studio_human_staff_role_v1(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.ai_studio_human_staff_role_v1(text)', 'EXECUTE'),
  'S11 internal catalog and eligibility helpers are not browser-callable');
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

SELECT ok(NOT has_table_privilege('service_role','public.ai_studio_access_audit','TRUNCATE')
  AND NOT has_table_privilege('service_role','public.ai_studio_access_audit','DELETE')
  AND NOT has_table_privilege('service_role','public.ai_studio_access_audit','UPDATE'),
  'S15 service_role cannot truncate, delete or update the audit table');
SELECT ok(EXISTS (
  SELECT 1 FROM pg_trigger WHERE tgrelid='public.ai_studio_access_audit'::regclass
    AND tgname='ai_studio_access_audit_no_truncate' AND NOT tgisinternal
  ), 'S16 statement-level audit TRUNCATE trigger is installed');

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
 ('deleted_member',  '94727200-0000-0000-0000-000000000012', 'sales_executive', TRUE,  'active', 'product_editor', 'active'),
 ('manager2', '94727200-0000-0000-0000-000000000013', 'operations_manager', TRUE, 'active', 'studio_admin',   'active'),
 ('denied_mgr','94727200-0000-0000-0000-000000000014', 'operations_manager', TRUE, 'active', 'studio_admin',   'active'),
 ('machine_member','94727200-0000-0000-0000-000000000015', 'tv_display',     TRUE, 'active', 'studio_admin',   'active'),
 ('tv',       '94727200-0000-0000-0000-000000000016', 'tv_display',         TRUE,  'active',   NULL, NULL),
 ('gate',     '94727200-0000-0000-0000-000000000017', 'GATE_SECURITY',      TRUE,  'active',   NULL, NULL),
 ('secctl',   '94727200-0000-0000-0000-000000000018', 'security_control',   TRUE,  'active',   NULL, NULL),
 ('svc',      '94727200-0000-0000-0000-000000000019', 'system_service',     TRUE,  'active',   NULL, NULL),
 ('store',    '94727200-0000-0000-0000-000000000020', 'store_incharge',     TRUE,  'active',   NULL, NULL),
 ('cand2',    '94727200-0000-0000-0000-000000000021', 'support_executive',  TRUE,  'active',   NULL, NULL),
 ('denied_editor','94727200-0000-0000-0000-000000000022', 'sales_executive', TRUE, 'active', 'product_editor', 'active');
GRANT ALL ON c272_ids TO PUBLIC;
INSERT INTO auth.users (id, email) SELECT sub, 'qa-c272-' || label || '@example.invalid' FROM c272_ids;
INSERT INTO public.users (id, role, email, is_active, invite_status)
SELECT sub, role_value, 'qa-c272-' || label || '@example.invalid', active, invite FROM c272_ids;
UPDATE public.users SET deleted_at = now() WHERE id = '94727200-0000-0000-0000-000000000012';
INSERT INTO public.ai_studio_user_access (user_id, status, profile_keys, approved_by, approved_at, changed_by)
SELECT sub, studio_status, ARRAY[profile], sub, now(), sub FROM c272_ids WHERE profile IS NOT NULL;

-- explicit denial of application access while other grants remain
UPDATE public.ai_studio_user_access SET overrides = '{"ai_studio.app.access": false}'::jsonb
 WHERE user_id IN ('94727200-0000-0000-0000-000000000014', '94727200-0000-0000-0000-000000000022');

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

-- ---------------------------------------------------------------- finding 1: AAL1 direct table read
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user('manager', 'aal1');
SELECT is((SELECT count(*)::int FROM public.ai_studio_user_access), 1,
  'F1a AAL1 manager sees only the own membership row on direct SELECT');
SELECT is((SELECT count(*)::int FROM public.ai_studio_user_access WHERE user_id <> '94727200-0000-0000-0000-000000000002'), 0,
  'F1b AAL1 manager cannot read other members, overrides or approver ids');
SELECT pg_temp.as_user('manager', 'aal2');
SELECT cmp_ok((SELECT count(*)::int FROM public.ai_studio_user_access), '>', 5, 'F1c AAL2 manager can read the directory table');
SELECT pg_temp.as_user('editor', 'aal2');
SELECT is((SELECT count(*)::int FROM public.ai_studio_user_access), 1, 'F1d ordinary member still reads only the own row');

-- ---------------------------------------------------------------- finding 2: app.access denial blocks everything
SELECT pg_temp.as_user('denied_mgr', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE, 'F2a explicit app.access denial removes app access');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.users.manage'), FALSE, 'F2b app.access denial blocks a granted users.manage');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.audit.read'), FALSE, 'F2c app.access denial blocks a granted audit.read');
SELECT is(public.can_manage_ai_studio_access_v1(), FALSE, 'F2d denied identity cannot manage access');
SELECT throws_ok($$SELECT public.list_ai_studio_access_v1()$$, '42501', NULL, 'F2e denied identity cannot list the directory');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F2f denied identity cannot administer');
SELECT throws_ok($$SELECT public.read_ai_studio_access_audit_v1()$$, '42501', NULL, 'F2g denied identity cannot read audit history');
SELECT is((SELECT count(*)::int FROM public.ai_studio_user_access), 1, 'F2h denied identity gets no directory through the table either');
SELECT pg_temp.as_user('denied_editor', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.products.update'), FALSE, 'F2i app.access denial blocks product permissions of the profile');

-- ---------------------------------------------------------------- finding 3: positive human-staff eligibility
SELECT pg_temp.as_user('manager', 'aal2');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000016','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F3a tv_display device account cannot receive Studio membership');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000017','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F3b GATE_SECURITY cannot receive Studio membership');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000018','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F3c security_control cannot receive Studio membership');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000019','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F3d system_service cannot receive Studio membership');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000020','active',ARRAY['viewer'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F3e store_incharge (not an allow-listed role) cannot receive Studio membership');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000016','pending_approval',ARRAY[]::text[],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F3f ineligible identities cannot even be pre-registered');
SELECT ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_ai_studio_access_v1()) e
  WHERE e->>'email' ~ 'qa-c272-(tv|gate|secctl|svc|store|buyer)@'), 'F3g directory lists only eligible human staff');
SELECT ok(EXISTS (SELECT 1 FROM jsonb_array_elements(public.list_ai_studio_access_v1()) e
  WHERE e->>'email' = 'qa-c272-cand@example.invalid'), 'F3h eligible staff remain listed');
SELECT pg_temp.as_user('machine_member', 'aal2');
SELECT is(public.has_ai_studio_permission_v1('ai_studio.app.access'), FALSE,
  'F3i an existing membership on a non-human identity gives no effective rights');
SELECT is(public.can_manage_ai_studio_access_v1(), FALSE, 'F3j non-human identity cannot manage even with studio_admin');

-- ---------------------------------------------------------------- finding 4: manager creation is Owner-only
SELECT pg_temp.as_user('manager', 'aal2');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['studio_admin'],'{}','valid audit reason',0)$$,
  '42501', NULL, 'F4a delegated manager cannot assign studio_admin');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{"ai_studio.users.manage":true}','valid audit reason',0)$$,
  '42501', NULL, 'F4b delegated manager cannot grant users.manage by override to a viewer');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000013','suspended',ARRAY['studio_admin'],'{}','valid audit reason',1)$$,
  '42501', NULL, 'F4c delegated manager cannot suspend or revoke another manager');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000013','active',ARRAY['viewer'],'{}','valid audit reason',1)$$,
  '42501', NULL, 'F4d delegated manager cannot demote another manager');
SELECT lives_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['viewer'],'{"ai_studio.users.manage":false}','routine nonprivileged access',4)$$,
  'F4e delegated manager keeps routine non-privileged assignment (deny override on users.manage is allowed)');
SELECT lives_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000021','active',ARRAY['product_editor'],'{}','routine editor onboarding',0)$$,
  'F4f delegated manager can still onboard an editor');
SELECT pg_temp.as_user('owner', 'aal2');
SELECT lives_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000021','active',ARRAY['studio_admin'],'{}','owner appoints a Studio manager',1)$$,
  'F4g Owner can appoint a manager');
SELECT pg_temp.as_user('cand2', 'aal2');
SELECT is(public.can_manage_ai_studio_access_v1(), TRUE, 'F4h the Owner-appointed manager can manage');
SELECT pg_temp.as_user('manager', 'aal2');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000021','revoked',ARRAY['studio_admin'],'{}','valid audit reason',2)$$,
  '42501', NULL, 'F4i a non-owner manager cannot revoke the Owner-appointed manager');
SELECT pg_temp.as_user('owner', 'aal2');
SELECT is((public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000021','revoked',ARRAY['studio_admin'],'{}','owner revokes the manager',2))->>'status',
  'revoked', 'F4j Owner can revoke a manager');
SELECT throws_ok($$SELECT public.set_ai_studio_access_v1('94727200-0000-0000-0000-000000000007','active',ARRAY['owner'],'{}','valid audit reason',4)$$,
  '42501', NULL, 'F4k even an Owner cannot delegate the Owner profile through the RPC');

-- ---------------------------------------------------------------- finding 5: governed audit-history reader
SELECT pg_temp.as_user('manager', 'aal2');
SELECT ok(jsonb_array_length(public.read_ai_studio_access_audit_v1()) >= 4, 'F5a authorized AAL2 reader gets audit history');
SELECT ok((SELECT bool_and(e ? 'actor_email' AND e ? 'reason' AND e ? 'before' AND e ? 'after' AND e ? 'created_at')
  FROM jsonb_array_elements(public.read_ai_studio_access_audit_v1()) e), 'F5b entries carry actor, reason, before and after');
SELECT is((SELECT count(DISTINCT e->>'user_id')::int FROM jsonb_array_elements(
  public.read_ai_studio_access_audit_v1('94727200-0000-0000-0000-000000000007')) e), 1, 'F5c per-user filter works');
SELECT is(jsonb_array_length(public.read_ai_studio_access_audit_v1(NULL, 1)), 1, 'F5d limit is honoured');
SELECT is(jsonb_array_length(public.read_ai_studio_access_audit_v1(NULL, 0)), 1, 'F5e a zero limit is clamped to one row');
SELECT cmp_ok(jsonb_array_length(public.read_ai_studio_access_audit_v1(NULL, 100000)), '<=', 200, 'F5f an oversized limit is clamped');
SELECT ok((public.read_ai_studio_access_audit_v1(NULL, 2)->0->>'created_at')::timestamptz >=
  (public.read_ai_studio_access_audit_v1(NULL, 2)->1->>'created_at')::timestamptz, 'F5g newest entries come first');
SELECT is(jsonb_array_length(public.read_ai_studio_access_audit_v1(NULL, 50, '1970-01-01'::timestamptz)), 0,
  'F5h keyset pagination (before cursor) is applied');
-- Explicit keyset cursor (timestamp + id) must not skip same-timestamp audit rows.
SELECT is(jsonb_array_length(public.read_ai_studio_access_audit_v1(
    NULL, 50,
    (public.read_ai_studio_access_audit_v1(NULL,1)->0->>'created_at')::timestamptz,
    (public.read_ai_studio_access_audit_v1(NULL,1)->0->>'id')::uuid)),
  jsonb_array_length(public.read_ai_studio_access_audit_v1(NULL,50)) - 1,
  'F5n composite audit cursor preserves every entry in a shared transaction timestamp');
SELECT isnt(
  public.read_ai_studio_access_audit_v1(NULL,1)->0->>'id',
  public.read_ai_studio_access_audit_v1(
    NULL,1,
    (public.read_ai_studio_access_audit_v1(NULL,1)->0->>'created_at')::timestamptz,
    (public.read_ai_studio_access_audit_v1(NULL,1)->0->>'id')::uuid)->0->>'id',
  'F5o next page does not repeat previous audit row');
SELECT pg_temp.as_user('manager', 'aal1');
SELECT throws_ok($$SELECT public.read_ai_studio_access_audit_v1()$$, '42501', NULL, 'F5i audit history requires AAL2');
SELECT pg_temp.as_user('editor', 'aal2');
SELECT throws_ok($$SELECT public.read_ai_studio_access_audit_v1()$$, '42501', NULL, 'F5j a member without audit.read cannot read audit history');
SELECT throws_ok($$SELECT * FROM public.ai_studio_access_audit$$, '42501', NULL, 'F5k audit table stays unreadable directly');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.read_ai_studio_access_audit_v1()$$, '42501', NULL, 'F5l anon cannot call the audit reader');
RESET ROLE;
SELECT ok(NOT has_function_privilege('anon', 'public.read_ai_studio_access_audit_v1(uuid,integer,timestamptz,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.read_ai_studio_access_audit_v1(uuid,integer,timestamptz,uuid)', 'EXECUTE'),
  'F5m audit reader grants are authenticated-only');

-- ---------------------------------------------------------------- audit trail
SELECT is((SELECT count(*)::int FROM public.ai_studio_access_audit WHERE user_id = '94727200-0000-0000-0000-000000000007'),
  5, 'U01 every accepted change wrote one audit row (refusals wrote none)');
SELECT is((SELECT count(*)::int FROM public.ai_studio_access_audit
  WHERE user_id = '94727200-0000-0000-0000-000000000007' AND before_value IS NULL), 1,
  'U02 only the first change has no before-image');
SELECT is((SELECT bool_and(actor_id IS NOT NULL AND char_length(reason) >= 8) FROM public.ai_studio_access_audit),
  TRUE, 'U03 audit rows carry an actor and a reason');
SET LOCAL session_replication_role = origin;  -- triggers must be live for the immutability proof
SELECT throws_ok($$UPDATE public.ai_studio_access_audit SET reason = 'tampered'$$, '42501', NULL,
  'U04 audit rows cannot be updated even by the table owner');
SELECT throws_ok($$DELETE FROM public.ai_studio_access_audit$$, '42501', NULL,
  'U05 audit rows cannot be deleted even by the table owner');
SELECT throws_ok($$TRUNCATE public.ai_studio_access_audit$$, '42501', NULL,
  'U07 audit log rejects TRUNCATE even from its table owner');
SELECT is((SELECT approved_by FROM public.ai_studio_user_access WHERE user_id = '94727200-0000-0000-0000-000000000007'),
  '94727200-0000-0000-0000-000000000002'::uuid, 'U06 approver is recorded on activation');

SELECT * FROM finish();
ROLLBACK;
