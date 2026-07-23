-- Contract for migration 20260723162100_trade_document_owner_upload_policy.sql
begin;

select plan(2);

select policies_are(
  'storage',
  'objects',
  array[
    'Authenticated upload own receipts',
    'Authenticated upload own trade documents',
    'Internal staff delete product media',
    'Internal staff insert product media',
    'Internal staff read whatsapp attachments',
    'Internal staff update product media',
    'Internal staff upload whatsapp attachments',
    'Owner or staff delete receipts',
    'Owner or staff read receipts'
  ],
  'storage.objects policies include the hardened Point 22 set'
);

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
