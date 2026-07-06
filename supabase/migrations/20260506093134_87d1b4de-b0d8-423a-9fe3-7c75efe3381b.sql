-- Create three public-read media buckets (idempotent)
INSERT INTO storage.buckets (id, name, public)
VALUES
  ('product-media', 'product-media', true),
  ('generated-media', 'generated-media', true),
  ('label-assets', 'label-assets', true)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

-- Public read for all three buckets
CREATE POLICY "Public read product-media"
ON storage.objects FOR SELECT
USING (bucket_id = 'product-media');

CREATE POLICY "Public read generated-media"
ON storage.objects FOR SELECT
USING (bucket_id = 'generated-media');

CREATE POLICY "Public read label-assets"
ON storage.objects FOR SELECT
USING (bucket_id = 'label-assets');

-- Team write (insert/update/delete) for all three buckets
CREATE POLICY "Team insert product-media"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'product-media' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team update product-media"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'product-media' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team delete product-media"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'product-media' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team insert generated-media"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'generated-media' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team update generated-media"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'generated-media' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team delete generated-media"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'generated-media' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team insert label-assets"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'label-assets' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team update label-assets"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'label-assets' AND public.is_team_member(auth.uid()));

CREATE POLICY "Team delete label-assets"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'label-assets' AND public.is_team_member(auth.uid()));