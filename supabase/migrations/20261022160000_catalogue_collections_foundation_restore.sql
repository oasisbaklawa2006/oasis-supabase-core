-- Restore AI Studio catalogue collection builder tables archived during the
-- 2026-07-27 production-baseline reconciliation (see
-- supabase/archived-migrations/pre-production-baseline-20260727/20260602160000_catalogue_collections_foundation.sql).
-- Additive only: no changes to product master authority or existing catalogue draft RPCs.

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

-- Publishing and share-link creation remain staff-only; published status requires catalogue reviewer.
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
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (
    public.is_team_member(auth.uid())
    AND (status <> 'published' OR public.is_catalogue_reviewer())
  );

DROP POLICY IF EXISTS catalogue_collections_staff_delete ON public.catalogue_collections;
CREATE POLICY catalogue_collections_staff_delete
  ON public.catalogue_collections FOR DELETE TO authenticated
  USING (public.is_team_member(auth.uid()));

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
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_collection_items_staff_update ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_staff_update
  ON public.catalogue_collection_items FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_collection_items_staff_delete ON public.catalogue_collection_items;
CREATE POLICY catalogue_collection_items_staff_delete
  ON public.catalogue_collection_items FOR DELETE TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_share_links_service_role ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_service_role
  ON public.catalogue_share_links FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS catalogue_share_links_staff_select ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_select
  ON public.catalogue_share_links FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_share_links_staff_insert ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_insert
  ON public.catalogue_share_links FOR INSERT TO authenticated
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_share_links_staff_update ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_update
  ON public.catalogue_share_links FOR UPDATE TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS catalogue_share_links_staff_delete ON public.catalogue_share_links;
CREATE POLICY catalogue_share_links_staff_delete
  ON public.catalogue_share_links FOR DELETE TO authenticated
  USING (public.is_team_member(auth.uid()));

COMMENT ON TABLE public.catalogue_collections IS
  'AI Studio catalogue publishing collections (builder foundation).';
COMMENT ON TABLE public.catalogue_collection_items IS
  'Curated product membership for catalogue_collections; product_id references public.products.';
COMMENT ON TABLE public.catalogue_share_links IS
  'Staff-governed share tokens for catalogue collections; no anon visibility.';
