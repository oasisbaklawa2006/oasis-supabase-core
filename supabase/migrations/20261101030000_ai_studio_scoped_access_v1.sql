-- AI Studio #272: module-scoped identity administration on canonical Core users.
-- Proposal staged for protected review; NEVER change global is_admin() or Core
-- product/pricing/publication authority. No service-role keys in the browser.
--
-- Studio membership and role profiles are independent of global staff roles.
-- User approval and session activation remain governed by public.users/Auth.

CREATE TABLE public.ai_studio_role_templates (
  role_key text PRIMARY KEY,
  display_name text NOT NULL,
  permission_keys text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.ai_studio_user_access (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'pending_approval'
    CHECK (status IN ('pending_approval','active','suspended','revoked','rejected')),
  profile_keys text[] NOT NULL DEFAULT '{}',
  overrides jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(overrides)='object'),
  approved_by uuid REFERENCES public.users(id),
  approved_at timestamptz,
  changed_by uuid REFERENCES public.users(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0)
);
COMMENT ON TABLE public.ai_studio_user_access IS
  'Explicit AI Studio membership only. Pending/revoked/disabled Core identities have no effective rights.';

CREATE TABLE public.ai_studio_access_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id),
  actor_id uuid NOT NULL REFERENCES public.users(id),
  action text NOT NULL,
  before_value jsonb,
  after_value jsonb NOT NULL,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- Append-only audit: no authenticated user may update/delete this table.
ALTER TABLE public.ai_studio_role_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_studio_user_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_studio_access_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ai_studio_role_templates FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_studio_user_access FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_studio_access_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ai_studio_role_templates TO authenticated;
GRANT SELECT ON public.ai_studio_user_access TO authenticated;

INSERT INTO public.ai_studio_role_templates(role_key,display_name,permission_keys) VALUES
('owner','Owner / Super Admin',ARRAY[
  'ai_studio.products.read','ai_studio.products.create','ai_studio.products.update',
  'ai_studio.products.review','ai_studio.media.manage','ai_studio.catalogues.view',
  'ai_studio.catalogues.build','ai_studio.catalogues.review',
  'ai_studio.catalogues.distribute','ai_studio.pricing.propose',
  'ai_studio.pricing.select_approved','ai_studio.ai.use',
  'ai_studio.settings.manage','ai_studio.users.manage','ai_studio.audit.read']),
('studio_admin','AI Studio Manager',ARRAY[
  'ai_studio.products.read','ai_studio.products.create','ai_studio.products.update',
  'ai_studio.products.review','ai_studio.media.manage','ai_studio.catalogues.view',
  'ai_studio.catalogues.build','ai_studio.catalogues.review',
  'ai_studio.catalogues.distribute','ai_studio.pricing.propose',
  'ai_studio.pricing.select_approved','ai_studio.ai.use',
  'ai_studio.settings.manage','ai_studio.users.manage','ai_studio.audit.read']),
('product_editor','Product Creator / Editor',ARRAY[
  'ai_studio.products.read','ai_studio.products.create','ai_studio.products.update',
  'ai_studio.media.manage']),
('quality_controller','Product Quality Controller',ARRAY[
  'ai_studio.products.read','ai_studio.products.review','ai_studio.catalogues.view']),
('product_pricing_manager','Product & Pricing Manager',ARRAY[
  'ai_studio.products.read','ai_studio.pricing.propose']),
('channel_pricing_manager','Channel / Customer Pricing Manager',ARRAY[
  'ai_studio.products.read','ai_studio.pricing.select_approved']),
('catalogue_specialist','AI Catalogue Specialist',ARRAY[
  'ai_studio.products.read','ai_studio.catalogues.view',
  'ai_studio.catalogues.build','ai_studio.ai.use']),
('catalogue_distribution','Catalogue Distribution / Marketing',ARRAY[
  'ai_studio.catalogues.view','ai_studio.catalogues.distribute']),
('viewer','Product / Catalogue Viewer',ARRAY[
  'ai_studio.products.read','ai_studio.catalogues.view'])
ON CONFLICT (role_key) DO NOTHING;

-- This is a closed grantable permission namespace, not global role authority.
-- Reserved operations (hard delete, financial approval, protected sync) are
-- deliberately NOT in this catalog.
CREATE OR REPLACE FUNCTION public.ai_studio_permission_known_v1(p_key text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $fn$
  SELECT p_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.ai_studio_role_templates t
    WHERE p_key = ANY(t.permission_keys)
  )
$fn$;

-- Bootstrap only the TWO owner-approved accounts, by explicit email + active
-- canonical SUPER_ADMIN identity. Never auto-grant all uppercase ADMINs or
-- future holders of the SUPER_ADMIN role.
INSERT INTO public.ai_studio_user_access
  (user_id,status,profile_keys,approved_by,approved_at,changed_by)
SELECT u.id,'active',ARRAY['owner']::text[],u.id,now(),u.id
FROM public.users u
WHERE lower(u.email) IN ('admin@oasisbaklawa.com','purecocoa@live.in')
  AND u.role='SUPER_ADMIN' AND u.is_active IS TRUE
  AND u.invite_status IN ('active','accepted') AND u.deleted_at IS NULL
ON CONFLICT (user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.has_ai_studio_permission_v1(p_key text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.ai_studio_user_access a ON a.user_id=u.id
    WHERE u.id=auth.uid()
      AND u.is_active IS TRUE AND u.deleted_at IS NULL
      AND u.invite_status IN ('active','accepted')
      AND a.status='active'
      AND public.ai_studio_permission_known_v1(p_key)
      AND COALESCE(
        (a.overrides->>p_key)::boolean,
        EXISTS (
          SELECT 1 FROM public.ai_studio_role_templates t
          WHERE t.role_key=ANY(a.profile_keys)
            AND p_key=ANY(t.permission_keys)
        )
      )
  );
$fn$;

CREATE OR REPLACE FUNCTION public.can_manage_ai_studio_access_v1()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.has_ai_studio_permission_v1('ai_studio.users.manage');
$fn$;

CREATE POLICY "Studio users read own or authorized admins"
ON public.ai_studio_user_access FOR SELECT TO authenticated
USING (user_id=auth.uid() OR public.can_manage_ai_studio_access_v1());

CREATE POLICY "Studio roles visible to authenticated staff"
ON public.ai_studio_role_templates FOR SELECT TO authenticated
USING (true);

CREATE OR REPLACE FUNCTION public.list_ai_studio_access_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.can_manage_ai_studio_access_v1() THEN
    RAISE EXCEPTION 'Studio access administration is not authorized'
      USING ERRCODE='42501';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'user_id',u.id,'email',u.email,'display_name',coalesce(u.full_name,u.name),
    'core_active',coalesce(u.is_active,false),'invite_status',u.invite_status,
    'studio_status',coalesce(a.status,'not_assigned'),
    'profile_keys',coalesce(a.profile_keys,'{}'::text[]),
    'overrides',coalesce(a.overrides,'{}'::jsonb),
    'version',coalesce(a.version,0)
  ) ORDER BY lower(coalesce(u.email,''))), '[]'::jsonb)
  INTO v_result
  FROM public.users u
  LEFT JOIN public.ai_studio_user_access a ON a.user_id=u.id
  WHERE u.deleted_at IS NULL
    AND lower(btrim(u.role)) NOT IN ('pending','b2b_buyer','customer_user','buyer');
  RETURN v_result;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.set_ai_studio_access_v1(
  p_user_id uuid,
  p_status text,
  p_profiles text[],
  p_overrides jsonb,
  p_reason text,
  p_expected_version integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_actor uuid := auth.uid();
  v_target public.users%ROWTYPE;
  v_before public.ai_studio_user_access%ROWTYPE;
  v_profiles text[];
  v_overrides jsonb := coalesce(p_overrides,'{}'::jsonb);
  v_next public.ai_studio_user_access%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_ai_studio_access_v1()
     OR coalesce(auth.jwt()->>'aal','')<>'aal2' THEN
    RAISE EXCEPTION 'AI Studio administration requires authorized AAL2 session'
      USING ERRCODE='42501';
  END IF;
  IF p_user_id IS NULL OR p_user_id=v_actor THEN
    RAISE EXCEPTION 'Target is missing or self-permission change prohibited'
      USING ERRCODE='42501';
  END IF;
  IF p_status IS NULL OR p_status NOT IN (
    'pending_approval','active','suspended','revoked','rejected'
  ) THEN
    RAISE EXCEPTION 'Invalid Studio access status' USING ERRCODE='22023';
  END IF;
  IF char_length(btrim(coalesce(p_reason,''))) < 8
     OR char_length(p_reason) > 1000 THEN
    RAISE EXCEPTION 'A substantive audit reason is required' USING ERRCODE='22023';
  END IF;
  IF jsonb_typeof(v_overrides)<>'object' THEN
    RAISE EXCEPTION 'Permission overrides must be an object' USING ERRCODE='22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_each(v_overrides) e
    WHERE NOT public.ai_studio_permission_known_v1(e.key)
      OR jsonb_typeof(e.value)<>'boolean'
  ) THEN
    RAISE EXCEPTION 'Unknown or invalid per-user permission override'
      USING ERRCODE='22023';
  END IF;
  SELECT coalesce(array_agg(DISTINCT k),'{}'::text[]) INTO v_profiles
  FROM unnest(coalesce(p_profiles,'{}'::text[])) k;
  -- Owner grants cannot be delegated through routine administration.
  IF 'owner'=ANY(v_profiles) OR EXISTS(
    SELECT 1 FROM unnest(v_profiles) k
    WHERE NOT EXISTS(SELECT 1 FROM public.ai_studio_role_templates t
                     WHERE t.role_key=k)
  ) THEN
    RAISE EXCEPTION 'Unknown profile or protected Owner assignment'
      USING ERRCODE='42501';
  END IF;
  IF p_status='active' AND cardinality(v_profiles)=0 THEN
    RAISE EXCEPTION 'Active membership requires a role profile'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_target FROM public.users WHERE id=p_user_id FOR UPDATE;
  IF NOT FOUND OR v_target.deleted_at IS NOT NULL
     OR lower(btrim(v_target.role)) IN ('pending','b2b_buyer','customer_user','buyer') THEN
    RAISE EXCEPTION 'Target is not an eligible canonical staff identity'
      USING ERRCODE='42501';
  END IF;
  IF p_status='active' AND (v_target.is_active IS NOT TRUE
      OR v_target.invite_status NOT IN ('active','accepted')) THEN
    RAISE EXCEPTION 'Inactive or unapproved staff cannot be activated'
      USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_before FROM public.ai_studio_user_access
    WHERE user_id=p_user_id FOR UPDATE;
  IF FOUND AND 'owner'=ANY(v_before.profile_keys) THEN
    RAISE EXCEPTION 'Owner membership is protected from delegated changes'
      USING ERRCODE='42501';
  END IF;
  IF coalesce(v_before.version,0) <> coalesce(p_expected_version,0) THEN
    RAISE EXCEPTION 'Studio access version conflict; reload before editing'
      USING ERRCODE='40001';
  END IF;

  INSERT INTO public.ai_studio_user_access(
    user_id,status,profile_keys,overrides,approved_by,approved_at,changed_by,updated_at,version)
  VALUES (
    p_user_id,p_status,v_profiles,v_overrides,
    CASE WHEN p_status='active' THEN v_actor ELSE NULL END,
    CASE WHEN p_status='active' THEN now() ELSE NULL END,
    v_actor,now(),1)
  ON CONFLICT (user_id) DO UPDATE SET
    status=excluded.status,
    profile_keys=excluded.profile_keys,
    overrides=excluded.overrides,
    approved_by=CASE WHEN excluded.status='active' THEN v_actor ELSE public.ai_studio_user_access.approved_by END,
    approved_at=CASE WHEN excluded.status='active' THEN now() ELSE public.ai_studio_user_access.approved_at END,
    changed_by=v_actor,
    updated_at=now(),
    version=public.ai_studio_user_access.version+1
  RETURNING * INTO v_next;

  INSERT INTO public.ai_studio_access_audit
    (user_id,actor_id,action,before_value,after_value,reason)
  VALUES (
    p_user_id,v_actor,'STUDIO_ACCESS_SET',
    CASE WHEN v_before.user_id IS NULL THEN NULL ELSE
      jsonb_build_object('status',v_before.status,'profiles',v_before.profile_keys,
                         'overrides',v_before.overrides,'version',v_before.version) END,
    jsonb_build_object('status',v_next.status,'profiles',v_next.profile_keys,
                       'overrides',v_next.overrides,'version',v_next.version),
    btrim(p_reason)
  );
  RETURN jsonb_build_object(
    'user_id',v_next.user_id,'status',v_next.status,
    'profile_keys',v_next.profile_keys,'overrides',v_next.overrides,
    'version',v_next.version
  );
END;
$fn$;

-- Explicit least-privilege grants for browser RPC access.
REVOKE ALL ON FUNCTION public.ai_studio_permission_known_v1(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.has_ai_studio_permission_v1(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.can_manage_ai_studio_access_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_ai_studio_access_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.has_ai_studio_permission_v1(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_ai_studio_access_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_ai_studio_access_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_ai_studio_access_v1(uuid,text,text[],jsonb,text,integer)
  TO authenticated;
-- No public write privileges to any Studio IAM table and no change to
-- public.is_admin(), pricing, product RLS, publishing or other apps.
