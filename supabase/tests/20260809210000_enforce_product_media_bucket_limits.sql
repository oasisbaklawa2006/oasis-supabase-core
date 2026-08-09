-- Contract test for migration 20260809210000_enforce_product_media_bucket_limits.sql
begin;

select plan(1);

-- Point 27, Phase 12: product-media must carry a real size cap and MIME
-- allowlist so unrestricted uploads aren't accepted server-side, whether the
-- bucket predates this migration (production) or is freshly seeded
-- (local/preview, via supabase/seed.sql which sets the same values).
do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'product-media'
      and file_size_limit = 52428800
      and allowed_mime_types @> array[
        'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif',
        'video/mp4', 'video/webm', 'application/pdf'
      ]
      and allowed_mime_types <@ array[
        'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif',
        'video/mp4', 'video/webm', 'application/pdf'
      ]
  ) then raise exception 'product-media bucket is missing its size/MIME enforcement'; end if;
end $$;

select ok(true, 'product-media bucket enforces a size cap and MIME allowlist');
select * from finish();
rollback;
