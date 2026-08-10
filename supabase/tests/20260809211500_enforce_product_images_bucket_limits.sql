-- Contract test for migration 20260809211500_enforce_product_images_bucket_limits.sql
begin;

select plan(1);

-- Point 27, Phase 12: product-images previously had no server-side size/MIME
-- enforcement at all (both null) — must now carry a real image-only allowlist
-- and size cap, matching supabase/seed.sql for local/preview parity.
do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'product-images'
      and file_size_limit = 10485760
      and allowed_mime_types @> array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
      and allowed_mime_types <@ array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
  ) then raise exception 'product-images bucket is missing its size/MIME enforcement'; end if;
end $$;

select ok(true, 'product-images bucket enforces a size cap and image-only MIME allowlist');
select * from finish();
rollback;
