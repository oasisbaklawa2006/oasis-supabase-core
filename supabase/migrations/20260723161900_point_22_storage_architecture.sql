-- Point 22: shared storage architecture and policy hardening

create table if not exists public.storage_bucket_contracts (
  bucket_id text primary key references storage.buckets(id) on update cascade on delete restrict,
  classification text not null check (classification in ('public_product_media','private_financial','private_customer_document','private_internal','legacy_review')),
  owning_application text not null,
  public_delivery boolean not null default false,
  write_authority text not null,
  path_convention text not null,
  retention_notes text,
  migration_status text not null default 'active' check (migration_status in ('active','legacy','retire_pending')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.storage_bucket_contracts enable row level security;

drop policy if exists "Staff read storage bucket contracts" on public.storage_bucket_contracts;
create policy "Staff read storage bucket contracts"
on public.storage_bucket_contracts for select
to authenticated
using (public.is_internal_staff(auth.uid()));

drop policy if exists "Super admins manage storage bucket contracts" on public.storage_bucket_contracts;
create policy "Super admins manage storage bucket contracts"
on public.storage_bucket_contracts for all
to authenticated
using (public.get_user_role(auth.uid()) = 'super_admin')
with check (public.get_user_role(auth.uid()) = 'super_admin');

insert into public.storage_bucket_contracts (
  bucket_id, classification, owning_application, public_delivery,
  write_authority, path_convention, retention_notes, migration_status
) values
  ('product-images','public_product_media','Central',true,'internal_staff','products/{product_id}/{filename}','Legacy Central hero/product images','active'),
  ('product-media','public_product_media','AI Studio',true,'internal_staff','products/{product_id}/{media_role}/{filename}','Canonical rich product media','active'),
  ('receipts','private_financial','Central',false,'authenticated_owner_or_internal_staff','{user_id}/{receipt_id}/{filename}','Financial evidence; signed access only','active'),
  ('trade-documents','private_customer_document','Customer App/Central',false,'authenticated_owner_folder','{user_id}/{document_type}/{filename}','Customer trade documents; owner and staff access','active'),
  ('trade_documents','legacy_review','Legacy',false,'service_role_only','legacy/{filename}','Duplicate underscore bucket; migrate two objects after caller review','legacy'),
  ('final-invoices','private_financial','Central',false,'service_role_only','{company_id}/{invoice_id}/{filename}','Generated final invoices','active'),
  ('proforma-invoices','private_financial','Central',false,'service_role_only','{company_id}/{invoice_id}/{filename}','Generated proforma invoices','active'),
  ('whatsapp_attachments','private_internal','Central',false,'authenticated_internal_staff','threads/{thread_id}/{message_id}/{filename}','WhatsApp evidence and attachments','active')
on conflict (bucket_id) do update set
  classification=excluded.classification,
  owning_application=excluded.owning_application,
  public_delivery=excluded.public_delivery,
  write_authority=excluded.write_authority,
  path_convention=excluded.path_convention,
  retention_notes=excluded.retention_notes,
  migration_status=excluded.migration_status,
  updated_at=now();

-- Empty invoice buckets and legacy trade bucket must not expose direct public URLs.
update storage.buckets
set public = false,
    updated_at = now()
where id in ('final-invoices','proforma-invoices','trade_documents');

-- Keep only intentional public-read delivery for product media.
drop policy if exists "Allow Admin Uploads 16wiy3a_0" on storage.objects;
drop policy if exists "Allow Admin Uploads 16wiy3a_1" on storage.objects;
drop policy if exists "Allow Admin Uploads 16wiy3a_2" on storage.objects;
drop policy if exists "Allow Admin Uploads 16wiy3a_3" on storage.objects;
drop policy if exists "Authenticated insert product media buckets" on storage.objects;
drop policy if exists "Authenticated update product media buckets" on storage.objects;
drop policy if exists "Authenticated delete product media buckets" on storage.objects;
drop policy if exists "Team insert product-images" on storage.objects;
drop policy if exists "Team update product-images" on storage.objects;
drop policy if exists "Team delete product-images" on storage.objects;
drop policy if exists "Team insert product-media" on storage.objects;
drop policy if exists "Team update product-media" on storage.objects;
drop policy if exists "Team delete product-media" on storage.objects;

create policy "Internal staff insert product media"
on storage.objects for insert
to authenticated
with check (
  bucket_id in ('product-images','product-media')
  and public.is_internal_staff(auth.uid())
);

create policy "Internal staff update product media"
on storage.objects for update
to authenticated
using (
  bucket_id in ('product-images','product-media')
  and public.is_internal_staff(auth.uid())
)
with check (
  bucket_id in ('product-images','product-media')
  and public.is_internal_staff(auth.uid())
);

create policy "Internal staff delete product media"
on storage.objects for delete
to authenticated
using (
  bucket_id in ('product-images','product-media')
  and public.is_internal_staff(auth.uid())
);

-- Receipts are private: owner and internal staff only.
drop policy if exists "public_read_receipts" on storage.objects;
drop policy if exists "authenticated_upload_receipts" on storage.objects;
drop policy if exists "authenticated_delete_receipts" on storage.objects;

create policy "Authenticated upload own receipts"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy "Owner or staff read receipts"
on storage.objects for select
to authenticated
using (
  bucket_id = 'receipts'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_internal_staff(auth.uid())
  )
);

create policy "Owner or staff delete receipts"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'receipts'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_internal_staff(auth.uid())
  )
);

-- Customer trade-document writes must remain in the caller's own folder.
drop policy if exists "Authenticated users can upload trade documents" on storage.objects;

-- WhatsApp attachments are internal operational evidence.
drop policy if exists "Authenticated can read whatsapp attachments" on storage.objects;
drop policy if exists "Authenticated can upload whatsapp attachments" on storage.objects;

create policy "Internal staff read whatsapp attachments"
on storage.objects for select
to authenticated
using (bucket_id='whatsapp_attachments' and public.is_internal_staff(auth.uid()));

create policy "Internal staff upload whatsapp attachments"
on storage.objects for insert
to authenticated
with check (bucket_id='whatsapp_attachments' and public.is_internal_staff(auth.uid()));

comment on table public.storage_bucket_contracts is
'Point 22 authority register for bucket classification, ownership, public-delivery intent, write authority and path conventions.';