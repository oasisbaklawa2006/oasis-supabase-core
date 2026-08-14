-- Forward-only production reconciliation; historical source timestamp remains immutable. 
-- Apply only after the ledger verifier classifies the original semantics as absent.
-- Point 27, Phase 12 (security spot-check continued): the product-images bucket
-- (used by a Central admin product-image upload flow) had no server-side size
-- cap or MIME allowlist at all (both null in seed.sql), and the client does no
-- validation of its own beyond a bypassable accept="image/*" hint on the file
-- input. Enforce a real image-only allowlist and a reasonable size cap
-- server-side. Safe to re-run (UPDATE only, no bucket creation/deletion, no
-- object data touched).

do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values (
    'product-images',
    'product-images',
    true,
    10485760,
    array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
  )
  on conflict (id) do nothing;

  update storage.buckets

  set
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
  where id = 'product-images';
  if not found then
    raise exception 'storage bucket "product-images" does not exist' using errcode='P0001';
  end if;
end $$;
