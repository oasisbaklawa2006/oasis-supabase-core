-- Point 25 contract repair: restore the intended owner-folder upload boundary
-- for the canonical private trade-documents bucket.

drop policy if exists "Authenticated upload own trade documents" on storage.objects;

create policy "Authenticated upload own trade documents"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'trade-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
);
