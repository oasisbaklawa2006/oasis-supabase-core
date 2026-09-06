-- Point 22 — canonical file/storage governance behavioral closure.
-- Schema authority: squashed baseline 20260723161256 + archived 20260723161959/62100.
-- Test-only: proves bucket contracts, visibility, MIME/size caps, policy absence,
-- tenant/role isolation, owner-folder writes, and staff-only internal buckets.
begin;

select plan(29);

select has_table(
  'public',
  'storage_bucket_contracts',
  'storage_bucket_contracts authority register exists'
);

select is(
  (
    select count(*)::integer
    from public.storage_bucket_contracts
    where bucket_id in (
      'product-images', 'product-media', 'receipts', 'trade-documents',
      'trade_documents', 'final-invoices', 'proforma-invoices', 'whatsapp_attachments'
    )
  ),
  8,
  'all eight governed storage buckets are registered in storage_bucket_contracts'
);

select ok(
  not exists (
    select 1
    from public.storage_bucket_contracts c
    left join storage.buckets b on b.id = c.bucket_id
    where b.id is null
  ),
  'every storage_bucket_contract row references a live storage.buckets row'
);

select is(
  (
    select count(*)::integer
    from public.storage_bucket_contracts
    where public_delivery
      and bucket_id in ('product-images', 'product-media')
  ),
  2,
  'only product media buckets are marked for intentional public delivery'
);

select is(
  (
    select count(*)::integer
    from storage.buckets b
    join public.storage_bucket_contracts c on c.bucket_id = b.id
    where c.public_delivery and not b.public
  ),
  0,
  'no public-delivery contract bucket remains private at the bucket layer'
);

select ok(
  exists (
    select 1 from storage.buckets
    where id = 'product-images'
      and file_size_limit = 10485760
      and allowed_mime_types @> array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
      and allowed_mime_types <@ array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']
  ),
  'product-images enforces image-only MIME allowlist and size cap'
);

select ok(
  exists (
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
  ),
  'product-media enforces governed MIME allowlist and size cap'
);

select ok(
  not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname in (
        'Allow Admin Uploads 16wiy3a_1',
        'Authenticated insert product media buckets',
        'public_read_receipts',
        'Authenticated users can upload trade documents',
        'Authenticated can read whatsapp attachments',
        'Authenticated can upload whatsapp attachments'
      )
  ),
  'unsafe legacy storage policies remain absent'
);

insert into public.users (id, role) values
  ('a0220000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('a0220000-0000-0000-0000-000000000002', 'B2B_BUYER'),
  ('a0220000-0000-0000-0000-000000000003', 'B2B_BUYER');

insert into storage.objects (bucket_id, name, owner) values
  ('receipts', 'a0220000-0000-0000-0000-000000000001/receipt-1/proof.pdf', 'a0220000-0000-0000-0000-000000000001'),
  ('receipts', 'a0220000-0000-0000-0000-000000000003/receipt-3/proof.pdf', 'a0220000-0000-0000-0000-000000000003'),
  ('trade-documents', 'a0220000-0000-0000-0000-000000000002/license/license.pdf', 'a0220000-0000-0000-0000-000000000002'),
  ('trade-documents', 'a0220000-0000-0000-0000-000000000003/license/license.pdf', 'a0220000-0000-0000-0000-000000000003'),
  ('whatsapp_attachments', 'threads/t1/m1/attach.pdf', 'a0220000-0000-0000-0000-000000000001'),
  ('product-images', 'products/p1/hero.jpg', 'a0220000-0000-0000-0000-000000000001'),
  ('final-invoices', 'company-1/inv-1/invoice.pdf', 'a0220000-0000-0000-0000-000000000001');

-- Staff can read storage bucket contracts; buyers cannot.
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a0220000-0000-0000-0000-000000000001';
set local role authenticated;

select is(
  (select count(*)::integer from public.storage_bucket_contracts),
  8,
  'internal staff can read the storage bucket contract register'
);

reset role;
set local request.jwt.claim.sub = 'a0220000-0000-0000-0000-000000000002';
set local role authenticated;

select is(
  (select count(*)::integer from public.storage_bucket_contracts),
  0,
  'non-staff authenticated callers cannot read storage bucket contracts'
);

-- Staff can write canonical product media.
reset role;
set local request.jwt.claim.sub = 'a0220000-0000-0000-0000-000000000001';
set local role authenticated;

select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('product-images', 'products/p2/hero.jpg', 'a0220000-0000-0000-0000-000000000001')$$,
  'internal staff can insert product media objects'
);

reset role;
set local request.jwt.claim.sub = 'a0220000-0000-0000-0000-000000000002';
set local role authenticated;

select throws_like(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('product-images', 'products/p3/hero.jpg', 'a0220000-0000-0000-0000-000000000002')$$,
  '%row-level security%',
  'non-staff authenticated callers cannot insert product media objects'
);

-- Receipt owner-folder isolation.
select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('receipts', 'a0220000-0000-0000-0000-000000000002/receipt-2/proof.pdf', 'a0220000-0000-0000-0000-000000000002')$$,
  'buyer can upload into their own receipts folder'
);

select throws_like(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('receipts', 'a0220000-0000-0000-0000-000000000003/receipt-x/proof.pdf', 'a0220000-0000-0000-0000-000000000002')$$,
  '%row-level security%',
  'buyer cannot upload into another user receipts folder'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'receipts'
      and name like 'a0220000-0000-0000-0000-000000000002/%'
  ),
  1,
  'buyer can read only their own receipt objects'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'receipts'
      and name like 'a0220000-0000-0000-0000-000000000003/%'
  ),
  0,
  'buyer cannot read another tenant receipt objects'
);

-- Trade-document owner-folder isolation.
select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('trade-documents', 'a0220000-0000-0000-0000-000000000002/tax/tax.pdf', 'a0220000-0000-0000-0000-000000000002')$$,
  'buyer can upload into their own trade-documents folder'
);

select throws_like(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('trade-documents', 'a0220000-0000-0000-0000-000000000003/tax/tax.pdf', 'a0220000-0000-0000-0000-000000000002')$$,
  '%row-level security%',
  'buyer cannot upload into another user trade-documents folder'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'trade-documents'
      and name like 'a0220000-0000-0000-0000-000000000002/%'
  ),
  2,
  'buyer can read only their own trade-document objects'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'trade-documents'
      and name like 'a0220000-0000-0000-0000-000000000003/%'
  ),
  0,
  'buyer cannot read another tenant trade-document objects'
);

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'whatsapp_attachments'),
  0,
  'buyer cannot read internal whatsapp attachment objects'
);

select throws_like(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('whatsapp_attachments', 'threads/t2/m2/attach.pdf', 'a0220000-0000-0000-0000-000000000002')$$,
  '%row-level security%',
  'buyer cannot upload whatsapp attachment objects'
);

-- Staff-only internal bucket access.
reset role;
set local request.jwt.claim.sub = 'a0220000-0000-0000-0000-000000000001';
set local role authenticated;

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'whatsapp_attachments'),
  1,
  'internal staff can read whatsapp attachment objects'
);

select lives_ok(
  $$insert into storage.objects (bucket_id, name, owner)
    values ('whatsapp_attachments', 'threads/t2/m2/attach.pdf', 'a0220000-0000-0000-0000-000000000001')$$,
  'internal staff can upload whatsapp attachment objects'
);

-- Private financial buckets have no authenticated read policy surface.
reset role;
set local request.jwt.claim.sub = 'a0220000-0000-0000-0000-000000000001';
set local role authenticated;

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'final-invoices'),
  0,
  'authenticated staff still cannot read service-role-only invoice objects through storage.objects RLS'
);

-- Intentional public product-media reads remain available without auth.
reset role;
set local request.jwt.claim.role = 'anon';
set local role anon;

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'product-images'),
  2,
  'anonymous callers can read public product-images objects'
);

select is(
  (select count(*)::integer from storage.objects where bucket_id = 'receipts'),
  0,
  'anonymous callers cannot read private receipt objects'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.storage_object_path_matches_buyer_owned_order(text)',
    'EXECUTE'
  ),
  'anon cannot execute privileged storage path matcher RPC'
);

select ok(
  pg_get_functiondef('public.customer_documents_v1()'::regprocedure) not like '%storage%',
  'buyer document contract does not leak storage paths or bucket references'
);

select * from finish();
rollback;
