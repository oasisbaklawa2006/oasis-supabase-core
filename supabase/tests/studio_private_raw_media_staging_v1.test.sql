begin;
-- Contract coverage for 20261107123000_studio_private_raw_media_staging_v1.sql
-- and follow-up 20261107124500_studio_private_media_permission_scope_v1.sql
-- Core #484: private staging is a real separate Storage delivery boundary.
-- This suite inserts only synthetic metadata and rolls all changes back.
select plan(33);

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
 ('49000000-0000-0000-0000-000000000002','private-media-contributor@example.invalid'),
 ('49000000-0000-0000-0000-000000000003','private-media-sales@example.invalid'),
 ('49000000-0000-0000-0000-000000000099','private-media-outsider@example.invalid');
insert into public.users (id, role, is_active) values
 ('49000000-0000-0000-0000-000000000001','super_admin',true),
 ('49000000-0000-0000-0000-000000000002','catalogue_contributor',true),
 ('49000000-0000-0000-0000-000000000003','sales',true);
insert into public.roles (id, role_key, role_name, is_active)
 values
 ('49000000-0000-0000-0000-00000000a001','super_admin','Super Admin',true),
 ('49000000-0000-0000-0000-00000000a002','catalogue_contributor','Catalogue Contributor',true),
 ('49000000-0000-0000-0000-00000000a003','sales','Sales',true)
 on conflict(role_key) do update set is_active=true;
insert into public.user_role_map(user_id,role_id)
 select fixture.user_id, r.id
 from (
   values
   ('49000000-0000-0000-0000-000000000001'::uuid,'super_admin'),
   ('49000000-0000-0000-0000-000000000002'::uuid,'catalogue_contributor'),
   ('49000000-0000-0000-0000-000000000003'::uuid,'sales')
 ) fixture(user_id,role_key)
 join public.roles r on r.role_key=fixture.role_key
 on conflict(user_id,role_id) do nothing;
-- Production grants catalogue.media.submit to catalogue_contributor; the
-- disposable Core replay seed is narrower, so add only the fixture's grant.
insert into public.permissions(permission_key,module_name,permission_name)
values ('catalogue.media.submit','catalogue','Submit catalogue media')
on conflict (permission_key) do nothing;
insert into public.role_permission_map(role_id,permission_id)
select r.id,p.id
from public.roles r
join public.permissions p on p.permission_key='catalogue.media.submit'
where r.role_key='catalogue_contributor'
on conflict do nothing;
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
-- A valid owner must also honor the exact immutable submission layout.
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/raw/not-reviewed.jpg',
      '49000000-0000-0000-0000-000000000001')$$,
  '42501',null,
  'P31 raw-folder bypass is denied; only submissions are accepted'
);
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/nested/unreviewed.jpg',
      '49000000-0000-0000-0000-000000000001')$$,
  '42501',null,
  'P32 nested folders cannot masquerade as canonical submissions'
);
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/unreviewed.jpg',
      '49000000-0000-0000-0000-000000000001')$$,
  '42501',null,
  'P33 incomplete submission path is denied'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- A catalogue_contributor is intentionally excluded by the legacy
-- is_team_member()/is_internal_staff() helpers. The scoped Core
-- catalogue.media.submit permission must authorize only their OWN raw files.
set local role authenticated;
set local request.jwt.claim.sub = '49000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
select is(
  public.is_team_member('49000000-0000-0000-0000-000000000002'::uuid),
  false,
  'P21 catalogue contributor is excluded by team-member legacy helper; scoped media-submit authorizes instead'
);
select is(
  public.has_catalogue_permission('catalogue.media.submit'),
  true,
  'P22 catalogue contributor has the explicit Core media-submit grant'
);
select lives_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/contributor.jpg',
      '49000000-0000-0000-0000-000000000002')$$,
  'P23 current contributor can upload their own private evidence'
);
select is(
  (select count(*)::integer from storage.objects
   where name='products/test-sku/submissions/contributor.jpg'
     and bucket_id='product-media-staging'),
  1,
  'P24 contributor can read their own private staged evidence'
);
select is(
  (select count(*)::integer from storage.objects
   where id='49000000-0000-0000-0000-000000000011'),
  0,
  'P25 contributor cannot read a different owner private asset'
);
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/contributor-spoof.jpg',
      '49000000-0000-0000-0000-000000000001')$$,
  '42501',null,
  'P26 contributor cannot upload as a different owner'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- Staff membership on its own is not media-submit authorization.
set local role authenticated;
set local request.jwt.claim.sub = '49000000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';
select is(
  public.is_team_member('49000000-0000-0000-0000-000000000003'::uuid),
  true,
  'P27 sales role has current team membership but no media author status'
);
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/sales.jpg',
      '49000000-0000-0000-0000-000000000003')$$,
  '42501',null,
  'P28 sales team role without catalogue.media.submit cannot upload raw photo'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- A soft-disabled or deleted contributor must not retain upload authority
-- merely because the role-permission mapping still exists.
update public.users set is_active=false
where id='49000000-0000-0000-0000-000000000002';
set local role authenticated;
set local request.jwt.claim.sub = '49000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/inactive.jpg',
      '49000000-0000-0000-0000-000000000002')$$,
  '42501',null,
  'P29 inactive contributor cannot upload despite cached media role mapping'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

update public.users set is_active=true, deleted_at=now()
where id='49000000-0000-0000-0000-000000000002';
set local role authenticated;
set local request.jwt.claim.sub = '49000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
select throws_ok(
  $$insert into storage.objects(bucket_id,name,owner_id)
    values('product-media-staging','products/test-sku/submissions/deleted.jpg',
      '49000000-0000-0000-0000-000000000002')$$,
  '42501',null,
  'P30 soft-deleted contributor cannot upload staged media'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select * from finish();
rollback;
