-- Contract for migration 20260723162100_trade_document_owner_upload_policy.sql
begin;

select plan(1);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Authenticated upload own trade documents'
      and roles = '{authenticated}'
      and with_check ilike '%bucket_id = ''trade-documents''%'
      and with_check ilike '%foldername%auth.uid%'
  ),
  'trade-document uploads are restricted to the authenticated user folder'
);

select * from finish();
rollback;
