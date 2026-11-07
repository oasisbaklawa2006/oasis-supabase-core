begin;
-- Contract tests for 20261107114000_product_media_unapproved_metadata_guard.sql
-- Roll back every fixture; NEVER exercise this on production.
select plan(24);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.product_media'::regclass),
  'product_media RLS remains enabled'
);
select ok(has_table_privilege('anon', 'public.product_media', 'SELECT'),
  'anonymous consumer keeps approved-media SELECT');
select ok(not has_table_privilege('anon', 'public.product_media', 'INSERT'),
  'anonymous cannot insert media metadata');
select ok(not has_table_privilege('anon', 'public.product_media', 'UPDATE'),
  'anonymous cannot update media metadata');
select ok(not has_table_privilege('anon', 'public.product_media', 'DELETE'),
  'anonymous cannot delete media metadata');
select ok(not has_table_privilege('anon', 'public.product_media', 'TRUNCATE'),
  'anonymous cannot bypass RLS using TRUNCATE');
select ok(not has_table_privilege('anon', 'public.product_media', 'TRIGGER'),
  'anonymous cannot install triggers');
select ok(not has_table_privilege('anon', 'public.product_media', 'REFERENCES'),
  'anonymous cannot create foreign-key references');

select ok(has_table_privilege('authenticated', 'public.product_media', 'SELECT'),
  'authenticated read remains available through role RLS');
select ok(has_table_privilege('authenticated', 'public.product_media', 'INSERT'),
  'authenticated product author insert grant preserved');
select ok(has_table_privilege('authenticated', 'public.product_media', 'UPDATE'),
  'authenticated product author update grant preserved');
select ok(has_table_privilege('authenticated', 'public.product_media', 'DELETE'),
  'authenticated product author delete grant preserved');
select ok(not has_table_privilege('authenticated', 'public.product_media', 'TRUNCATE'),
  'authenticated clients cannot bypass RLS with TRUNCATE');
select ok(not has_table_privilege('authenticated', 'public.product_media', 'TRIGGER'),
  'authenticated clients cannot install triggers');

-- Synthetic, null-product fixtures only; any accidental static URL in this
-- suite points to a reserved invalid domain, not production Storage content.
insert into public.product_media (id, product_id, file_url, type, status) values
  ('44000000-0000-0000-0000-000000000001', null, 'https://example.invalid/studio-approved', 'image', 'approved'),
  ('44000000-0000-0000-0000-000000000002', null, 'https://example.invalid/studio-raw', 'image', 'raw');

set local role anon;
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000001'),
  1, 'anonymous can still read an approved-media row'
);
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000002'),
  0, 'anonymous cannot read raw media metadata/URL'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '44000000-0000-0000-0000-000000000099';
set local request.jwt.claim.role = 'authenticated';
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000001'),
  1, 'unprivileged authenticated user can read approved-media metadata'
);
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000002'),
  0, 'unprivileged authenticated user cannot read raw media metadata'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- Reviewer and Product Master author are different Core privileges.
-- Fixtures exist only inside this transaction and are removed by ROLLBACK.
set local session_replication_role = replica;
insert into auth.users (id, email) values
  ('44000000-0000-0000-0000-000000000011', 'studio-media-author@test.invalid'),
  ('44000000-0000-0000-0000-000000000012', 'studio-media-reviewer@test.invalid');
insert into public.users (id, role, is_active) values
  ('44000000-0000-0000-0000-000000000011', 'admin', true),
  ('44000000-0000-0000-0000-000000000012', 'studio_media_reviewer_fixture', true);
insert into public.roles (id, role_key, role_name, is_active) values
  ('44000000-0000-0000-0000-000000000013',
   'studio_media_reviewer_fixture', 'Media Reviewer Fixture', true);
insert into public.role_permission_map (role_id, permission_id)
select '44000000-0000-0000-0000-000000000013'::uuid, p.id
  from public.permissions p
 where p.permission_key = 'catalogue.approvals.review';
set local session_replication_role = origin;

set local role authenticated;
set local request.jwt.claim.sub = '44000000-0000-0000-0000-000000000011';
set local request.jwt.claim.role = 'authenticated';
select is(
  public.can_write_product_master(),
  true,
  'active admin fixture is a Core Product Master writer'
);
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000002'),
  1,
  'authorized Product Master writer can review raw media metadata'
);

set local request.jwt.claim.sub = '44000000-0000-0000-0000-000000000012';
select is(
  public.can_write_product_master(),
  false,
  'catalogue reviewer fixture is not automatically a Product Master writer'
);
select is(
  public.is_catalogue_reviewer(),
  true,
  'independently permissioned catalogue reviewer fixture is recognized'
);
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000002'),
  1,
  'catalogue reviewer can review raw media metadata without write authority'
);
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

set local role service_role;
select is(
  (select count(*)::integer from public.product_media
   where id = '44000000-0000-0000-0000-000000000002'),
  1, 'service-role governance can still review raw metadata'
);
reset role;

select * from finish();
rollback;
