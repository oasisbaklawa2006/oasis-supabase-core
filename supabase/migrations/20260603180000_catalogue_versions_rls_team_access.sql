-- Central Sync: catalogue_versions + catalogue_sync_events RLS for authenticated studio users.
-- Safe to re-run. Fixes "Permission/RLS blocked" when policies were never applied after table create.

-- ---------------------------------------------------------------------------
-- 1) Ensure helper functions are callable from RLS policies
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.is_team_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_team_member(uuid) TO anon;

CREATE OR REPLACE FUNCTION public.is_catalogue_studio_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL AND (
    public.is_team_member(auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid())
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_catalogue_studio_user() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Ensure known admin has team role (idempotent)
-- ---------------------------------------------------------------------------
INSERT INTO public.user_roles (user_id, role)
SELECT p.id, 'owner'::public.app_role
FROM public.profiles p
WHERE lower(trim(coalesce(p.email, ''))) = 'admin@oasisbaklawa.com'
  AND NOT EXISTS (
    SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p.id
  );

-- ---------------------------------------------------------------------------
-- 3) catalogue_versions policies
-- ---------------------------------------------------------------------------
ALTER TABLE public.catalogue_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read catalogue_versions" ON public.catalogue_versions;
DROP POLICY IF EXISTS "Team insert catalogue_versions" ON public.catalogue_versions;
DROP POLICY IF EXISTS "Team update catalogue_versions" ON public.catalogue_versions;
DROP POLICY IF EXISTS "Studio read catalogue_versions" ON public.catalogue_versions;
DROP POLICY IF EXISTS "Studio insert catalogue_versions" ON public.catalogue_versions;
DROP POLICY IF EXISTS "Studio update catalogue_versions" ON public.catalogue_versions;

CREATE POLICY "Studio read catalogue_versions"
  ON public.catalogue_versions
  FOR SELECT
  TO authenticated
  USING (public.is_catalogue_studio_user());

CREATE POLICY "Studio insert catalogue_versions"
  ON public.catalogue_versions
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_catalogue_studio_user());

CREATE POLICY "Studio update catalogue_versions"
  ON public.catalogue_versions
  FOR UPDATE
  TO authenticated
  USING (public.is_catalogue_studio_user())
  WITH CHECK (public.is_catalogue_studio_user());

-- ---------------------------------------------------------------------------
-- 4) catalogue_sync_events policies
-- ---------------------------------------------------------------------------
ALTER TABLE public.catalogue_sync_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read catalogue_sync_events" ON public.catalogue_sync_events;
DROP POLICY IF EXISTS "Team insert catalogue_sync_events" ON public.catalogue_sync_events;
DROP POLICY IF EXISTS "Studio read catalogue_sync_events" ON public.catalogue_sync_events;
DROP POLICY IF EXISTS "Studio insert catalogue_sync_events" ON public.catalogue_sync_events;

CREATE POLICY "Studio read catalogue_sync_events"
  ON public.catalogue_sync_events
  FOR SELECT
  TO authenticated
  USING (public.is_catalogue_studio_user());

CREATE POLICY "Studio insert catalogue_sync_events"
  ON public.catalogue_sync_events
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_catalogue_studio_user());

-- ---------------------------------------------------------------------------
-- 5) sku_code_rules — ensure public read (SkuBuilder dropdowns)
-- ---------------------------------------------------------------------------
ALTER TABLE public.sku_code_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read sku rules" ON public.sku_code_rules;
CREATE POLICY "Public read sku rules"
  ON public.sku_code_rules
  FOR SELECT
  USING (true);
