-- Contract coverage for migration 20260723161500_legacy_storage_bucket_baseline.sql
begin;

select plan(2);

select is(
  (select count(*)::integer from storage.buckets where id in (
    'product-images','product-media','receipts','trade-documents',
    'trade_documents','final-invoices','proforma-invoices','whatsapp_attachments'
  )),
  8,
  'all governed legacy storage buckets exist'
);

select ok(
  not exists (
    select 1 from storage.buckets
    where id in ('receipts','trade-documents','trade_documents','final-invoices','proforma-invoices','whatsapp_attachments')
      and public
  ),
  'private governed buckets are not public'
);

select * from finish();
rollback;
