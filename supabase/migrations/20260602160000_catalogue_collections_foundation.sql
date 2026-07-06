-- AI Studio: catalogue collection builder + share links (additive only)

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

DROP POLICY IF EXISTS "Team read catalogue_collections" ON public.catalogue_collections;
CREATE POLICY "Team read catalogue_collections"
  ON public.catalogue_collections FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team write catalogue_collections" ON public.catalogue_collections;
CREATE POLICY "Team write catalogue_collections"
  ON public.catalogue_collections FOR ALL TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team read catalogue_collection_items" ON public.catalogue_collection_items;
CREATE POLICY "Team read catalogue_collection_items"
  ON public.catalogue_collection_items FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team write catalogue_collection_items" ON public.catalogue_collection_items;
CREATE POLICY "Team write catalogue_collection_items"
  ON public.catalogue_collection_items FOR ALL TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team read catalogue_share_links" ON public.catalogue_share_links;
CREATE POLICY "Team read catalogue_share_links"
  ON public.catalogue_share_links FOR SELECT TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team write catalogue_share_links" ON public.catalogue_share_links;
CREATE POLICY "Team write catalogue_share_links"
  ON public.catalogue_share_links FOR ALL TO authenticated
  USING (public.is_team_member(auth.uid()))
  WITH CHECK (public.is_team_member(auth.uid()));

COMMENT ON TABLE public.catalogue_collections IS
  'AI Studio catalogue publishing collections (builder foundation).';
