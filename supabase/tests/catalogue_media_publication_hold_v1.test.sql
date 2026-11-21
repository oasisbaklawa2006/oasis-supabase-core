BEGIN;
-- Contracts: 20261120180000_catalogue_media_reference_validation_v1
-- and 20261121000000_catalogue_media_private_transform_hold_v1 (forward correction).\n-- 20261121132000_catalogue_media_browser_numeric_host_hold_v1 blocks browser numeric authorities.
SELECT plan(60);
SET LOCAL session_replication_role = replica;
INSERT INTO auth.users (id, email) VALUES
 ('19000000-0000-0000-0000-000000000001', 'publication-reviewer@test.invalid'),
 ('19000000-0000-0000-0000-000000000002', 'publication-denied@test.invalid');
INSERT INTO public.users (id, role) VALUES
 ('19000000-0000-0000-0000-000000000001', 'super_admin'),
 ('19000000-0000-0000-0000-000000000002', 'sales');
SET LOCAL session_replication_role = origin;
INSERT INTO public.products (id, name, category, sku, hsn_code, production_department)
 VALUES ('29000000-0000-0000-0000-000000000001', 'Synthetic media fixture', 'sweets', 'MEDIA-HOLD-TEST', '1905', 'arabic_sweets');
INSERT INTO public.catalogue_media_submissions
 (id, source_app, target_table, operation, payload, status, submitted_by)
 SELECT id, 'catalogue_app', 'products', 'create', payload, 'pending_approval',
 '19000000-0000-0000-0000-000000000001'::uuid FROM (VALUES
('39000000-0000-0000-0000-000000000001'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://cdn.example.test/published.jpg", "storage_path": "products/fixture/source.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000002'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://cdn.example.test/published.jpg", "storagePath": "products/fixture/source.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000003'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://cdn.example.test/published.jpg", "bucket_id": "product-media-staging"}'::jsonb),
('39000000-0000-0000-0000-000000000004'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://cdn.example.test/published.jpg", "storage_bucket": "product-media-staging"}'::jsonb),
('39000000-0000-0000-0000-000000000005'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "private://fixture/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000006'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test/storage/v1/object/sign/product-media/photo.jpg?token=fixture"}'::jsonb),
('39000000-0000-0000-0000-000000000007'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test/storage/v1/object/authenticated/product-media/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000008'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test/storage/v1/object/%73ign/product-media/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000009'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "not-a-url"}'::jsonb),
('39000000-0000-0000-0000-00000000000a'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test/storage/v1/object/public/product-media-staging/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-00000000000b'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test/storage/v1/object/public/../sign/product-media/photo.jpg?token=fixture"}'::jsonb),
('39000000-0000-0000-0000-00000000000c'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test/storage/v1/object/public/./sign/product-media/photo.jpg?token=fixture"}'::jsonb),
('39000000-0000-0000-0000-00000000000d'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test\\storage\\v1\\object\\sign\\product-media\\photo.jpg?token=fixture"}'::jsonb),
('39000000-0000-0000-0000-00000000000e'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://#"}'::jsonb),
('39000000-0000-0000-0000-00000000000f'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test:invalid/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000010'::uuid, '{"product_id": "29000000-0000-0000-0000-000000000001", "type": "hero_image", "file_url": "https://example.test:65536/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000011'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://example.test/storage/v1/render/image/sign/product-media/photo.jpg?token=fixture"}'::jsonb),
('39000000-0000-0000-0000-000000000012'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://example.test/storage/v1/render/image/authenticated/product-media/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000013'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://999.999.999.999/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000014'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://256.1.1.1/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000015'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://0x100000000/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000016'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://0x7f000001/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000017'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://0177.0.0.1/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000018'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://127.1/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-000000000019'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://000.000.000.001/photo.jpg"}'::jsonb),
('39000000-0000-0000-0000-00000000001a'::uuid, '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://cdn.0x7f000001/photo.jpg"}'::jsonb)
) fixtures(id, payload);
SET LOCAL request.jwt.claim.sub = '19000000-0000-0000-0000-000000000001';
SET LOCAL request.jwt.claim.role = 'authenticated';

-- Exercise the public wrapper, not only a pure predicate. Each failure must undo
-- the master insertion that precedes the draft status update in the dispatcher.
SELECT throws_like(
 format('SELECT public.approve_catalogue_media_submission(%L::uuid)', id),
 'Media requires governed publication before approval',
 'private, malformed or path-normalized reference cannot be approved: ' || id::text
) FROM public.catalogue_media_submissions
 WHERE submitted_by = '19000000-0000-0000-0000-000000000001' ORDER BY id;
SELECT is((SELECT count(*)::int FROM public.catalogue_media_submissions
WHERE submitted_by = '19000000-0000-0000-0000-000000000001' AND status = 'pending_approval'),
 20, 'wrapper failures retain all drafts for retry or rejection');
SELECT is((SELECT count(*)::int FROM public.product_media
WHERE product_id = '29000000-0000-0000-0000-000000000001'),
 0, 'wrapper failures leave no master rows');
SELECT throws_like(
format('SELECT public.approve_catalogue_draft_internal(%L, %L::uuid)', 'catalogue_media_submissions', id),
'Media requires governed publication before approval',
'direct dispatcher holds private, malformed or path-normalized reference: ' || id::text
) FROM public.catalogue_media_submissions
WHERE submitted_by = '19000000-0000-0000-0000-000000000001' ORDER BY id;
SELECT is((SELECT count(*)::int FROM public.catalogue_media_submissions
WHERE submitted_by = '19000000-0000-0000-0000-000000000001' AND status = 'pending_approval'),
 20, 'dispatcher failures retain all drafts for retry or rejection');
SELECT is((SELECT count(*)::int FROM public.product_media
WHERE product_id = '29000000-0000-0000-0000-000000000001'),
 0, 'dispatcher failures leave no master rows');

INSERT INTO public.catalogue_media_submissions
 (id, source_app, target_table, operation, payload, status, submitted_by)
 VALUES ('39000000-0000-0000-0000-000000000020', 'catalogue_app', 'products', 'create',
 '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://cdn.example.test:8443/published.jpg"}',
 'pending_approval', '19000000-0000-0000-0000-000000000001');
SELECT lives_ok($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000020')$$,
 'durable URL-only approval still uses canonical mapping');
SELECT is((SELECT count(*)::int FROM public.product_media
 WHERE product_id = '29000000-0000-0000-0000-000000000001' AND status = 'approved'),
 1, 'durable approval maps exactly one approved master row');
SET LOCAL request.jwt.claim.sub = '19000000-0000-0000-0000-000000000002';
SELECT throws_like($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000001')$$,
 'Catalogue reviewer permission required', 'non-reviewer remains denied by canonical authority');
SET LOCAL request.jwt.claim.sub = '19000000-0000-0000-0000-000000000001';

INSERT INTO public.product_media (id, product_id, type, status, file_url)
 VALUES ('49000000-0000-0000-0000-000000000001', '29000000-0000-0000-0000-000000000001',
 'hero_image', 'raw', 'private://fixture/existing.jpg');
INSERT INTO public.catalogue_media_submissions
 (id, source_app, target_table, target_record_id, operation, payload, status, submitted_by)
 VALUES ('39000000-0000-0000-0000-000000000021', 'catalogue_app', 'products',
 '49000000-0000-0000-0000-000000000001', 'update',
 '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","alt_text":"Metadata only"}',
 'pending_approval', '19000000-0000-0000-0000-000000000001');
SELECT throws_like($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000021')$$,
 'Media requires governed publication before approval', 'metadata-only update cannot approve an existing private URL');
SELECT is((SELECT status FROM public.product_media WHERE id = '49000000-0000-0000-0000-000000000001'),
 'raw', 'failed update retains prior master status');
SELECT is((SELECT status FROM public.catalogue_media_submissions WHERE id = '39000000-0000-0000-0000-000000000021'),
 'pending_approval', 'failed update retains pending draft');
UPDATE public.catalogue_media_submissions SET operation = 'delete_request'
 WHERE id = '39000000-0000-0000-0000-000000000021';
SELECT lives_ok($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000021')$$,
 'governed deletion of an existing private reference remains available');
SELECT ok(NOT has_function_privilege('anon', 'public.catalogue_media_reference_requires_publication_v1(jsonb)', 'EXECUTE'),
 'anonymous caller gains no helper execution');
SELECT ok(NOT has_function_privilege('authenticated', 'public.enforce_catalogue_media_publication_hold_v1()', 'EXECUTE'),
 'authenticated caller gains no direct trigger execution');
SELECT lives_ok($$SELECT public.reject_catalogue_media_submission('39000000-0000-0000-0000-000000000001', 'Synthetic rejection')$$,
 'private draft remains rejectable through canonical reviewer path');
-- Exercise the actual application DB role, not only JWT claims as postgres.
INSERT INTO public.catalogue_media_submissions
 (id, source_app, target_table, operation, payload, status, submitted_by)
 VALUES
 ('39000000-0000-0000-0000-000000000022', 'catalogue_app', 'products', 'create',
  '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://203.0.113.10:8443/published.jpg"}',
  'pending_approval', '19000000-0000-0000-0000-000000000001'),
 ('39000000-0000-0000-0000-000000000023', 'catalogue_app', 'products', 'create',
  '{"product_id":"29000000-0000-0000-0000-000000000001","type":"hero_image","file_url":"https://example.test/storage/v1/render/image/public/product-media/photo.jpg?width=640"}',
  'pending_approval', '19000000-0000-0000-0000-000000000001');
SET LOCAL ROLE authenticated;
SELECT throws_like($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000011')$$,
 'Media requires governed publication before approval', 'authenticated reviewer wrapper holds signed image transformation');
SELECT throws_like($$SELECT public.approve_catalogue_draft_internal('catalogue_media_submissions', '39000000-0000-0000-0000-000000000012')$$,
 'Media requires governed publication before approval', 'authenticated reviewer dispatcher holds private image transformation');
SELECT lives_ok($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000022')$$,
 'authenticated reviewer wrapper accepts a valid IPv4 durable URL');
SELECT lives_ok($$SELECT public.approve_catalogue_draft_internal('catalogue_media_submissions', '39000000-0000-0000-0000-000000000023')$$,
 'authenticated reviewer dispatcher accepts public image transformation');
SET LOCAL request.jwt.claim.sub = '19000000-0000-0000-0000-000000000002';
SELECT throws_like($$SELECT public.approve_catalogue_media_submission('39000000-0000-0000-0000-000000000013')$$,
 'Catalogue reviewer permission required', 'authenticated non-reviewer wrapper remains denied');
SELECT throws_like($$SELECT public.approve_catalogue_draft_internal('catalogue_media_submissions', '39000000-0000-0000-0000-000000000014')$$,
 'Catalogue reviewer permission required', 'authenticated non-reviewer dispatcher remains denied');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
