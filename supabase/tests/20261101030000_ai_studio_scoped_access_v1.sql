-- Studio #272 — gated Core access contract (schema and least privilege).
-- Transactional test; detailed AAL2/role-transition UAT additionally required.
BEGIN;
SELECT plan(18);
SELECT has_table('public','ai_studio_role_templates','A01 role profiles exist');
SELECT has_table('public','ai_studio_user_access','A02 explicit membership exists');
SELECT has_table('public','ai_studio_access_audit','A03 append-only audit exists');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.ai_studio_role_templates'::regclass),'A04 role profiles RLS on');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.ai_studio_user_access'::regclass),'A05 memberships RLS on');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.ai_studio_access_audit'::regclass),'A06 audit RLS on');
SELECT has_function('public','has_ai_studio_permission_v1',ARRAY['text'],'A07 scoped permission resolver exists');
SELECT has_function('public','set_ai_studio_access_v1',ARRAY['uuid','text','text[]','jsonb','text','integer'],'A08 administered mutation exists');
SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""']
  FROM pg_proc WHERE oid='public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)'::regprocedure),
  'A09 privileged mutation uses fixed-path controlled authority');
SELECT ok(NOT has_function_privilege('anon',
  'public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)','EXECUTE'),
  'A10 anon cannot administer roles');
SELECT ok(NOT has_table_privilege('authenticated','public.ai_studio_user_access','UPDATE'),
  'A11 browser cannot update membership directly');
SELECT ok(NOT has_table_privilege('authenticated','public.ai_studio_access_audit','DELETE'),
  'A12 browser cannot erase audit');
SELECT is((SELECT count(*)::int FROM public.ai_studio_role_templates),
  9,'A13 nine controlled functional profiles exist');
SELECT ok(NOT EXISTS (
  SELECT 1 FROM public.ai_studio_user_access a
  JOIN public.users u ON u.id=a.user_id
  WHERE u.role='ADMIN' AND 'owner'=ANY(a.profile_keys)
),'A14 uppercase ADMIN has no owner bootstrap');
SELECT ok(position('aal2' IN pg_get_functiondef(
    'public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)'::regprocedure))>0,
  'A15 AAL2 requirement is coded into access changes');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.products'::regclass),
  'A16 product-master RLS remains enabled');
SELECT ok(position("'pending'" IN pg_get_functiondef(
  'public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)'::regprocedure))>0,
  'A17 pending canonical identity cannot be granted Studio membership');
SELECT ok(position('lower(btrim(v_target.role))' IN pg_get_functiondef(
  'public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)'::regprocedure))>0,
  'A18 staff eligibility excludes case-varied buyer identity roles');
SELECT * FROM finish();
ROLLBACK;
