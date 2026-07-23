begin;

select plan(1);

do $$
begin
  if not exists (
    select 1 from public.storage_bucket_contracts
    where bucket_id='product-images' and classification='public_product_media' and public_delivery
  ) then raise exception 'product-images contract missing'; end if;

  if exists (
    select 1 from storage.buckets
    where id in ('receipts','trade-documents','trade_documents','final-invoices','proforma-invoices') and public
  ) then raise exception 'private bucket remains public'; end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname='Internal staff insert product media'
      and roles='{authenticated}'
  ) then raise exception 'staff-only product media insert policy missing'; end if;

  if exists (
    select 1 from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname in ('Allow Admin Uploads 16wiy3a_1','Authenticated insert product media buckets','public_read_receipts','Authenticated users can upload trade documents')
  ) then raise exception 'unsafe legacy storage policy remains'; end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname='Authenticated upload own trade documents'
      and with_check ilike '%foldername%auth.uid%'
  ) then raise exception 'owner-folder trade upload policy missing'; end if;
end $$;

select ok(true, 'Point 22 storage architecture contract holds');
select * from finish();
rollback;
