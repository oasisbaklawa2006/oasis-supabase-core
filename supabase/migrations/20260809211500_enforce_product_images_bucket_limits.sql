-- Point 27, Phase 12 (security spot-check continued): the product-images bucket
-- (used by Oasis-Baklawa-Central's AdminProducts.tsx handleImageUpload) had no
-- server-side size cap or MIME allowlist at all (both null in seed.sql), and the
-- client does no validation of its own beyond a bypassable accept="image/*" hint
-- on the file input. Enforce a real image-only allowlist and a reasonable size
-- cap server-side. Safe to re-run (UPDATE only, no bucket creation/deletion, no
-- object data touched).

update storage.buckets
set
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
where id = 'product-images';
