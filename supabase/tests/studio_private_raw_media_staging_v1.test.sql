begin;
-- Contract coverage for 20261107123000_studio_private_raw_media_staging_v1.sql
-- Core #484: private staging is a real separate Storage delivery boundary.
-- This suite inserts only synthetic metadata and rolls all changes back.
select plan(20);

select ok(
  exists(select 1 from storage.buckets where id = 'product-media-staging'),
  'P01 new raw-media bucket exists'
);
select is(
  (select public from storage.buckets where id = 'product-media-staging'),
  false,
  'P02 raw staging remains PRIVATE, not direct public URL delivery'
);
select is(
  (select file_size_limit::bigint from storage.buckets where id = 'product-media-staging'),
  52428800::bigint,
  'P03 media max size matches the verified 50 MiB server contract'
);
select is(
  (select cardinality(allowed_mime_types)::integer from storage.buckets where id = 'product-media-staging'),
  8,
  'P04 explicit MIME allowlist has exactly eight entries'
);
select is(
  (select classification from public.storage_bucket_contracts where bucket_id = 'product-media-staging'),
  'private_internal',
  'P05 bucket is registered as private internal product evidence'
);
select is(
  (select public_delivery from public.storage_bucket_contracts where bucket_id = 'product-media-staging'),
  false,
  'P06 governance register forbids public delivery'
);
select is(
  (select owning_application from public.storage_bucket_contracts where bucket_id = 'product-media-staging'),
  'AI Studio',
  'P07 bucket owner remains AI Studio'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and policyname='studio_staging_upload_staff_owned_v1'
    and cmd='INSERT' and roles = '{authenticated}'
    and with_check like '%has_catalogue_permission%'),
  'P08 upload requires authenticated Core media-submit authority'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and policyname='studio_staging_read_owner_or_reviewer_v1'
    and cmd='SELECT' and roles = '{authenticated}'
    and qual like '%owner_id%'),
  'P09 private read is owner/reviewer/Product Master governed'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and policyname='studio_staging_delete_reviewer_v1' and cmd='DELETE'
    and roles='{authenticated}' and qual like '%is_catalogue_reviewer%'),
  'P10 only designated reviewers/writers may delete staged media'
);
select ok(
  not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and cmd='UPDATE' and coalesce(qual,'') like '%product-media-staging%'),
  'P11 staged evidence has no UPDATE/upsert policy'
);
select ok(
  not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and roles @> ARRAY['anon']::name[]
    and (coalesce(qual,'') || coalesce(with_check,'')) like '%product-media-staging%'),
  'P12 no anon policy can read or write the private bucket'
);
select ok(
  (select relrowsecurity from pg_class where oid='storage.objects'::regclass),
  'P13 storage.objects RLS is enabled'
);

set local session_replication_role = replica;
insert into auth.users (id, email) values
 ('49000000-0000-0000-0000-000000000001','private-media-reviewer@example.invalid'),
 ('49000000-0000-0000-0000-000000000099','private-media-outsider@example.invalid');
insert into public.users (id, role, is_active) values
 ('49000000-0000-0000-0000-000000000001','super_admin',true);
insert into public.roles (id, role_key, role_name, is_active)
 values ('49000000-0000-0000-0000-00000000a001','super_admin','Super Admin',true)
 on conflict(role_key) do update set is_active=true;
insert into public.user_role_map(user_id,role_id)
 select '49000000-0000-0000-0000-000000000001'::uuid,r.id
 from public.roles r where r.role_key='super_admin'
 on conflict(user_id,role_id) do nothing;
set local session_replication_role = origin;

-- An object metadata fixture is NOT a published image and has no file bytes.
insert into storage.objects(id,bucket_id,name,owner_id)
values (
  '49000000-0000-0000-0000-000000000011',
  'product-media-staging',
  'products/test-sku/submissions/raw-one.jpg',
  '49000000-0000-0000-0000-000000000001'
);

set local role anon;
select is(
  (select count(*)::integer from storage.objects
   where id='49000000-0000-0000-0000-000000000011'),
  0,
  'P14 anon cannot list or retrieve private staging object metadata'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '49000000-0000-0000-0000-000000000099';
set local request.jwt.claim.role = 'authenticated';
select is(
  (select count(*)::integer from storage.objects
   where id='49000000-0000-0000-0000-000000000011'),
  0,
  'P15 an outsider authenticated session cannot view staged object'
);
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/outsider.jpg',
      '49000000-0000-0000-0000-000000000099')$$,
  '42501',null,
  'P16 nonstaff outsider cannot upload private staging object'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

set local role authenticated;
set local request.jwt.claim.sub = '49000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
select is(
  public.is_team_member('49000000-0000-0000-0000-000000000001'::uuid),
  true,
  'P17 seeded super_admin is a current internal team member'
);
select is(
  (select count(*)::integer from storage.objects
   where id='49000000-0000-0000-0000-000000000011'),
  1,
  'P18 a permitted reviewer can read staged evidence'
);
select lives_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/owner.jpg',
      '49000000-0000-0000-0000-000000000001')$$,
  'P19 authorised team member may upload their own immutable staging object'
);
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/spoof.jpg',
      '49000000-0000-0000-0000-000000000099')$$,
  '42501',null,
  'P20 an authorised reviewer cannot spoof another uploader owner_id'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select * from finish();
rollback;
