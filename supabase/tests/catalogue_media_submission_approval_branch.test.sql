begin;
-- Contract coverage for 20261010180000_catalogue_media_submission_approval_branch.sql:
-- the catalogue_media_submissions branch of approve_catalogue_draft_internal(), which
-- previously fell through unconditionally to approve_blocked_mapping_not_finalized
-- (Core #404). Covers create/update/delete_request mapping onto public.product_media
-- and every fail-closed path: unknown media type, missing product_id/file_url,
-- unresolved target row, product_id mismatch, non-reviewer caller, and re-approval
-- of an already-approved draft.
select plan(20);

SET LOCAL session_replication_role = replica;

insert into auth.users (id, email) values
  ('18000000-0000-0000-0000-000000000001', 'media-reviewer@test.invalid'),
  ('18000000-0000-0000-0000-000000000002', 'media-sales@test.invalid');

insert into public.users (id, role) values
  ('18000000-0000-0000-0000-000000000001', 'super_admin'),
  ('18000000-0000-0000-0000-000000000002', 'sales');

SET LOCAL session_replication_role = origin;

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('28000000-0000-0000-0000-000000000001', 'Pistachio Baklawa', 'sweets', 'MEDIA-PRODUCT-1', '1905', 'arabic_sweets'),
  ('28000000-0000-0000-0000-000000000002', 'Cashew Pyramid', 'sweets', 'MEDIA-PRODUCT-2', '1905', 'arabic_sweets');

-- ── create ──────────────────────────────────────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000001', 'catalogue_app', 'products', 'create',
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000001',
    'file_url', 'https://cdn.example.test/pistachio-hero.jpg',
    'type', 'hero_image',
    'angle', 'front',
    'alt_text', 'Pistachio baklawa tray, front view'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

set local request.jwt.claim.sub = '18000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000001') $$,
  'reviewer can approve a create media draft'
);

select is(
  (select status from public.catalogue_media_submissions where id = '38000000-0000-0000-0000-000000000001'),
  'approved', 'create draft status transitions to approved'
);

select is(
  (select count(*)::integer from public.product_media
     where product_id = '28000000-0000-0000-0000-000000000001'
       and file_url = 'https://cdn.example.test/pistachio-hero.jpg'
       and type = 'hero_image'
       and status = 'approved'),
  1, 'approved create draft is mapped onto product_media as approved'
);

select is(
  (select target_record_id from public.catalogue_media_submissions where id = '38000000-0000-0000-0000-000000000001'),
  (select id from public.product_media where product_id = '28000000-0000-0000-0000-000000000001'),
  'draft target_record_id is bound to the created product_media row'
);

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000001') $$,
  'Only pending_approval drafts can be approved%',
  'an already-approved draft cannot be approved again'
);

reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- ── update ──────────────────────────────────────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, target_record_id, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000002', 'catalogue_app', 'products', 'update',
  (select id from public.product_media where product_id = '28000000-0000-0000-0000-000000000001'),
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000001',
    'file_url', 'https://cdn.example.test/pistachio-hero-v2.jpg',
    'type', 'white_background',
    'angle', 'top',
    'alt_text', 'Pistachio baklawa, white background'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

set local request.jwt.claim.sub = '18000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000002') $$,
  'reviewer can approve an update media draft'
);

select is(
  (select type from public.product_media
     where product_id = '28000000-0000-0000-0000-000000000001'),
  'white_background', 'approved update draft overwrites type on the existing product_media row'
);

reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- ── delete_request ───────────────────────────────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, target_record_id, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000003', 'catalogue_app', 'products', 'delete_request',
  (select id from public.product_media where product_id = '28000000-0000-0000-0000-000000000001'),
  jsonb_build_object('product_id', '28000000-0000-0000-0000-000000000001'),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

set local request.jwt.claim.sub = '18000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000003') $$,
  'reviewer can approve a delete_request media draft'
);

select is(
  (select count(*)::integer from public.product_media
     where product_id = '28000000-0000-0000-0000-000000000001'),
  0, 'approved delete_request removes the product_media row'
);

reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- ── fail-closed: unknown media type ─────────────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000004', 'catalogue_app', 'products', 'create',
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000001',
    'file_url', 'https://cdn.example.test/unknown.jpg',
    'type', 'not_a_real_media_type'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

set local request.jwt.claim.sub = '18000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000004') $$,
  'Unsupported or missing media type%',
  'an unrecognized media type fails closed instead of being stored'
);

select is(
  (select count(*)::integer from public.product_media where file_url = 'https://cdn.example.test/unknown.jpg'),
  0, 'the rejected media type never reaches product_media'
);

-- ── fail-closed: missing product_id ─────────────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000005', 'catalogue_app', 'products', 'create',
  jsonb_build_object('file_url', 'https://cdn.example.test/no-product.jpg', 'type', 'raw_photo'),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000005') $$,
  'Media draft requires product_id%',
  'a media draft missing product_id fails closed'
);

-- ── fail-closed: missing file_url on create ─────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000006', 'catalogue_app', 'products', 'create',
  jsonb_build_object('product_id', '28000000-0000-0000-0000-000000000001', 'type', 'raw_photo'),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000006') $$,
  'Media create draft requires file_url%',
  'a create media draft missing file_url fails closed'
);

-- ── fail-closed: nonexistent product_id ─────────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000007', 'catalogue_app', 'products', 'create',
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000099',
    'file_url', 'https://cdn.example.test/orphan.jpg',
    'type', 'raw_photo'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000007') $$,
  'Media draft product_id does not reference an existing product%',
  'a media draft referencing a nonexistent product fails closed'
);

-- ── fail-closed: update/delete_request product_id mismatch ─────────────────
insert into public.product_media (id, product_id, file_url, type, status) values
  ('48000000-0000-0000-0000-000000000001', '28000000-0000-0000-0000-000000000002', 'https://cdn.example.test/cashew.jpg', 'raw_photo', 'approved');

insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, target_record_id, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000008', 'catalogue_app', 'products', 'update',
  '48000000-0000-0000-0000-000000000001',
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000001',
    'file_url', 'https://cdn.example.test/mismatched.jpg',
    'type', 'raw_photo'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000008') $$,
  'Media update payload product_id does not match target row%',
  'an update draft whose payload product_id does not match the target row fails closed'
);

select is(
  (select file_url from public.product_media where id = '48000000-0000-0000-0000-000000000001'),
  'https://cdn.example.test/cashew.jpg', 'the mismatched update never touches the unrelated product_media row'
);

-- ── fail-closed: unresolved target row on update ────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, target_record_id, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-000000000009', 'catalogue_app', 'products', 'update',
  '48000000-0000-0000-0000-000000000099',
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000001',
    'file_url', 'https://cdn.example.test/ghost.jpg',
    'type', 'raw_photo'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-000000000009') $$,
  'Media row not found for update%',
  'an update draft targeting a nonexistent product_media row fails closed'
);

reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- ── fail-closed: non-reviewer cannot approve ────────────────────────────────
insert into public.catalogue_media_submissions
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '38000000-0000-0000-0000-00000000000a', 'catalogue_app', 'products', 'create',
  jsonb_build_object(
    'product_id', '28000000-0000-0000-0000-000000000001',
    'file_url', 'https://cdn.example.test/non-reviewer.jpg',
    'type', 'raw_photo'
  ),
  'pending_approval', '18000000-0000-0000-0000-000000000002'
);

set local request.jwt.claim.sub = '18000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

select throws_like(
  $$ select public.approve_catalogue_draft_internal('catalogue_media_submissions', '38000000-0000-0000-0000-00000000000a') $$,
  'Catalogue reviewer permission required%',
  'a non-reviewer caller cannot approve a media draft'
);

reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select is(
  (select status from public.catalogue_media_submissions where id = '38000000-0000-0000-0000-00000000000a'),
  'pending_approval', 'a rejected-by-permission draft remains pending_approval, not silently approved'
);

-- ── bom/moq/pricing drafts remain intentionally unmapped ────────────────────
insert into public.catalogue_bom_drafts
  (id, source_app, target_table, operation, payload, status, submitted_by)
values (
  '58000000-0000-0000-0000-000000000001', 'catalogue_app', 'product_bom', 'create',
  jsonb_build_object('product_id', '28000000-0000-0000-0000-000000000001'),
  'pending_approval', '18000000-0000-0000-0000-000000000001'
);

set local request.jwt.claim.sub = '18000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select is(
  (select (public.approve_catalogue_draft_internal('catalogue_bom_drafts', '58000000-0000-0000-0000-000000000001') ->> 'ok')),
  'false', 'catalogue_bom_drafts remains an intentional approve_blocked_mapping_not_finalized fall-through'
);

reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select * from finish();
rollback;
