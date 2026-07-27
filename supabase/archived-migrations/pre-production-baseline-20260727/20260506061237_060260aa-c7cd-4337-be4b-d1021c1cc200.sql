
-- Catalogue status workflow
ALTER TABLE public.catalogues
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'draft',
  ADD COLUMN IF NOT EXISTS published_at timestamptz,
  ADD COLUMN IF NOT EXISTS unpublished_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_previewed_at timestamptz;

-- Backfill: existing published catalogues become 'published'
UPDATE public.catalogues
  SET status = 'published',
      published_at = COALESCE(published_at, updated_at, created_at, now())
  WHERE is_published = true AND (status IS NULL OR status = 'draft');

-- Keep is_published in sync with status (back-compat)
CREATE OR REPLACE FUNCTION public.sync_catalogue_publish()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.is_published := (NEW.status = 'published');
  IF NEW.status = 'published' AND OLD.status IS DISTINCT FROM 'published' THEN
    NEW.published_at := COALESCE(NEW.published_at, now());
  END IF;
  IF NEW.status <> 'published' AND OLD.status = 'published' THEN
    NEW.unpublished_at := now();
  END IF;
  IF NEW.status = 'archived' AND OLD.status IS DISTINCT FROM 'archived' THEN
    NEW.archived_at := COALESCE(NEW.archived_at, now());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS catalogues_sync_publish ON public.catalogues;
CREATE TRIGGER catalogues_sync_publish
BEFORE INSERT OR UPDATE ON public.catalogues
FOR EACH ROW EXECUTE FUNCTION public.sync_catalogue_publish();

-- Tighten public read: only published or team
DROP POLICY IF EXISTS "Public read published catalogues" ON public.catalogues;
CREATE POLICY "Public read published catalogues"
ON public.catalogues
FOR SELECT
TO public
USING (status = 'published' OR is_team_member(auth.uid()));

-- Labels: lock metadata
ALTER TABLE public.labels
  ADD COLUMN IF NOT EXISTS locked_by uuid,
  ADD COLUMN IF NOT EXISTS locked_at timestamptz;
