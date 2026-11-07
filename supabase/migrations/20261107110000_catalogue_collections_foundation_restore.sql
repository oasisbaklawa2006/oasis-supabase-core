-- AI Studio G3: canonical forward-only catalogue collections restoration.
-- Core source provenance: closed/unmerged PR #417 and audited G3 staging branch.
-- The historical 20261029020000 file was NEVER applied to production and
-- cannot be replayed on the 20261101030000 canonical Core main ceiling.
-- This *new* version is additive on protected Core main; no production writes,
-- product master/pricing changes, external share-token resolver or public access.
-- Reviewers own publication and share-token lifecycle; draft edits are staff-only.
-- Related: Core #485, Studio #240; private media gate Core #484 remains separate.

CREATE TABLE IF NOT EXISTS public.catalogue_collections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  slug text NOT NULL,
  catalogue_type text NOT NULL DEFAULT 'b2b_catalogue'
    CHECK (catalogue_type IN (
      'b2b_catalogue', 'retail_catalogue', 'export_catalogue', 'franchise_catalogue',
      'wedding_catalogue', 'corporate_catalogue', 'whatsapp_mini_catalogue',
      'qr_exhibition_catalogue', 'seasonal_catalogue'
    )),
  channel text NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'internal_review', 'published', 'archived')),
  description text NULL,
  theme text NULL,
  created_by uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (slug)
);

CREATE TABLE IF NOT EXISTS public.catalogue_collection_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES public.catalogue_collections(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  catalogue_version_id uuid NULL,
  sort_order integer NOT NULL DEFAULT 0,
  display_name_override text NULL,
  description_override text NULL,
  price_visibility text NOT NULL DEFAULT 'visible'
    CHECK (price_visibility IN ('visible', 'hidden', 'inquiry')),
  is_featured boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (collection_id, product_id)
);

CREATE TABLE IF NOT EXISTS public.catalogue_share_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES public.catalogue_collections(id) ON DELETE CASCADE,
  share_token text NOT NULL UNIQUE,
  share_type text NOT NULL DEFAULT 'view'
    CHECK (share_type IN ('view', 'whatsapp', 'qr', 'pdf')),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'revoked', 'expired')),
  expires_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalogue_collections_status
  ON public.catalogue_collections (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_catalogue_collection_items_collection
  ON public.catalogue_collection_items (collection_id, sort_order);

CREATE INDEX IF NOT EXISTS idx_catalogue_share_links_token
  ON public.catalogue_share_links (share_token) WHERE status = 'active';

ALTER TABLE public.catalogue_collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_collection_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalogue_share_links ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.catalogue_collections FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.catalogue_collection_items FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.catalogue_share_links FROM PUBLIC, anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.catalogue_collections TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.catalogue_collection_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.catalogue_share_links TO authenticated;

GRANT ALL ON TABLE public.catalogue_collections TO service_role;
GRANT ALL ON TABLE public.catalogue_collection_items TO service_role;
GRANT ALL ON TABLE public.catalogue_share_links TO service_role;

-- Published collections, their membership, and share tokens are reviewer-governed.
-- Staff may edit drafts only. Public share tokens may be issued for published collections only.
DROP POLICY IF EXISTS catalogue_collections_service_role ON public.catalogue_collections;
CREATE POLICY catalogue_collections_service_role
  ON public.catalogue_collections FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_collections_staff_select ON public.catalogue_collections;
CREATE POLICY catalogue_collections_staff_select
  ON public.catalogue_collections FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_collections_staff_insert ON public.catalogue_collections;
CREATE POLICY catalogue_collections_staff_insert
  ON public.catalogue_collections FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (status <> 'published' OR public.is_catalogue_reviewer())
  );

DROP POLICY IF EXISTS catalogue_collections_staff_update ON public.catalogue_collections;
CREATE POLICY catalogue_collections_staff_update
  ON public.catalogue_collections FOR UPDATE TO authenticated
  USING (
    public.is_team_member(auth.uid())
    AND (status <> 'published' OR public.is_catalogue_reviewer())
  )
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (status <> 'published' OR public.is_catalogue_reviewer())
  );

DROP POLICY IF EXISTS catalogue_collections_staff_delete ON public.catalogue_collections;
CREATE POLICY catalogue_collections_staff_delete
  ON public.catalogue_collections FOR DELETE TO authenticated
  USING (
    public.is_team_member(auth.uid())
    AND (status <> 'published' OR public.is_catalogue_reviewer())
  );

DROP POLICY IF EXISTS catalogue_collection_items_service_role ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_service_role
  ON public.catalogue_collection_items FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_collection_items_staff_select ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_staff_select
  ON public.catalogue_collection_items FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_collection_items_staff_insert ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_staff_insert
  ON public.catalogue_collection_items FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.catalogue_collections c
      WHERE c.id = collection_id
        AND (c.status <> 'published' OR public.is_catalogue_reviewer())
    )
  );

DROP POLICY IF EXISTS catalogue_collection_items_staff_update ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_staff_update
  ON public.catalogue_collection_items FOR UPDATE TO authenticated
  USING (
    public.is_team_member(auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.catalogue_collections c
      WHERE c.id = collection_id
        AND (c.status <> 'published' OR public.is_catalogue_reviewer())
    )
  )
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.catalogue_collections c
      WHERE c.id = collection_id
        AND (c.status <> 'published' OR public.is_catalogue_reviewer())
    )
  );

DROP POLICY IF EXISTS catalogue_collection_items_staff_delete ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_staff_delete
  ON public.catalogue_collection_items FOR DELETE TO authenticated
  USING (
    public.is_team_member(auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.catalogue_collections c
      WHERE c.id = collection_id
        AND (c.status <> 'published' OR public.is_catalogue_reviewer())
    )
  );

DROP POLICY IF EXISTS catalogue_share_links_service_role ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_service_role
  ON public.catalogue_share_links FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_share_links_staff_select ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_select
  ON public.catalogue_share_links FOR SELECT TO authenticated
  -- Bearer share tokens must not be readable by every team member.
  USING (public.is_team_member(auth.uid()) AND public.is_catalogue_reviewer());

DROP POLICY IF EXISTS catalogue_share_links_staff_insert ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_insert
  ON public.catalogue_share_links FOR INSERT TO authenticated
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND public.is_catalogue_reviewer()
    AND EXISTS (
      SELECT 1 FROM public.catalogue_collections c
      WHERE c.id = collection_id AND c.status = 'published'
    )
  );

DROP POLICY IF EXISTS catalogue_share_links_staff_update ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_update
  ON public.catalogue_share_links FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()) AND public.is_catalogue_reviewer())
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND public.is_catalogue_reviewer()
    AND (
      status <> 'active'
      OR EXISTS (
        SELECT 1 FROM public.catalogue_collections c
        WHERE c.id = collection_id AND c.status = 'published'
      )
    )
  );

DROP POLICY IF EXISTS catalogue_share_links_staff_delete ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_delete
  ON public.catalogue_share_links FOR DELETE TO authenticated
  USING (public.is_team_member(auth.uid()) AND public.is_catalogue_reviewer());

-- A published collection must not retain live bearer links once a reviewer
-- withdraws publication. Enforce this on the collection status transition,
-- not only when a share-link row is subsequently inserted or updated.
-- The invoker must already be authorized by the Core collection and
-- share-link RLS policies; do not introduce a bypassing SECURITY DEFINER.
CREATE OR REPLACE FUNCTION public.catalogue_collections_revoke_active_links()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $revoke$
BEGIN
  IF OLD.status = 'published' AND NEW.status <> 'published' THEN
    UPDATE public.catalogue_share_links
       SET status = 'revoked'
     WHERE collection_id = NEW.id
       AND status = 'active';
  END IF;
  RETURN NEW;
END;
$revoke$;

DROP TRIGGER IF EXISTS trg_catalogue_collections_revoke_active_links
  ON public.catalogue_collections;
CREATE TRIGGER trg_catalogue_collections_revoke_active_links
  AFTER UPDATE OF status ON public.catalogue_collections
  FOR EACH ROW
  EXECUTE FUNCTION public.catalogue_collections_revoke_active_links();

COMMENT ON TABLE public.catalogue_collections IS
  'AI Studio catalogue publishing collections (builder foundation).';
COMMENT ON TABLE public.catalogue_collection_items IS
  'Curated product membership for catalogue_collections; product_id references public.products.';
COMMENT ON TABLE public.catalogue_share_links IS
  'Staff-governed share tokens for catalogue collections; no anon visibility.';
