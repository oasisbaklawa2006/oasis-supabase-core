-- Point 27, Phase 12 (security spot-check): the product-media storage bucket's
-- size cap and MIME allowlist were only declared in supabase/seed.sql, which
-- Supabase applies for local/preview environments, not for the already-live
-- production bucket. Client uploaders (AI Studio's ProductMediaUploader,
-- Central's admin upload flow) do no size/type validation of their own and
-- rely entirely on this server-side enforcement, so codify it in a migration
-- that reaches every environment, including production, and is safe to
-- re-run (UPDATE only, no bucket creation/deletion, no data touched).

update storage.buckets
set
  file_size_limit = 52428800,
  allowed_mime_types = array[
    'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif',
    'video/mp4', 'video/webm', 'application/pdf'
  ]
where id = 'product-media';
