-- Contract coverage for migration 20260723161500_legacy_storage_bucket_baseline.sql
begin;

select plan(2);

select is(
  (
    select count(*)::integer
    from storage.buckets
    where id in (
      'product-images','product-media','receipts','trade-documents',
      'trade_documents','final-invoices','proforma-invoices','whatsapp_attachments'
    )
  ),
  8,
  'all governed legacy storage buckets exist'
);

select is(
  (
    select count(*)::integer
    from (
      values
        ('product-images', true),
        ('product-media', true),
        ('receipts', false),
        ('trade-documents', false),
        ('trade_documents', false),
        ('final-invoices', false),
        ('proforma-invoices', false),
        ('whatsapp_attachments', false)
    ) as expected(id, public)
    join storage.buckets actual using (id)
    where actual.public = expected.public
  ),
  8,
  'every governed bucket has the approved public visibility'
);

select * from finish();
rollback;
