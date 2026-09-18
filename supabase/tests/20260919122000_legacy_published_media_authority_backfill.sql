-- Contract coverage for migration:
-- 20260919122000_legacy_published_media_authority_backfill.sql

begin;
select plan(14);

select has_function(
  'public',
  'reconcile_legacy_published_product_media_authority_v1',
  array[]::text[],
  'legacy published media reconciliation RPC exists'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.reconcile_legacy_published_product_media_authority_v1()',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.reconcile_legacy_published_product_media_authority_v1()',
    'EXECUTE'
  )
  and has_function_privilege(
    'service_role',
    'public.reconcile_legacy_published_product_media_authority_v1()',
    'EXECUTE'
  ),
  'reconciliation RPC is service-role only'
);

insert into public.products (
  id, name, product_name, category, sku, hsn_code,
  is_active, visible_in_catalog, hero_image_url, media_status
) values
(
  '19120000-0000-4000-8000-000000000001',
  'Media Backfill Visible',
  'Media Backfill Visible',
  'Test',
  'TEST-MEDIA-BACKFILL-001',
  '9999',
  true, true,
  'https://example.invalid/media/visible.jpg',
  'missing'
),
(
  '19120000-0000-4000-8000-000000000002',
  'Media Backfill Hidden',
  'Media Backfill Hidden',
  'Test',
  'TEST-MEDIA-BACKFILL-002',
  '9999',
  true, false,
  'https://example.invalid/media/hidden.jpg',
  'missing'
),
(
  '19120000-0000-4000-8000-000000000003',
  'Media Backfill No Hero',
  'Media Backfill No Hero',
  'Test',
  'TEST-MEDIA-BACKFILL-003',
  '9999',
  true, true,
  null,
  'missing'
),
(
  '19120000-0000-4000-8000-000000000004',
  'Media Backfill Existing Authority',
  'Media Backfill Existing Authority',
  'Test',
  'TEST-MEDIA-BACKFILL-004',
  '9999',
  true, true,
  'https://example.invalid/media/existing.jpg',
  'pending_approval'
),
(
  '19120000-0000-4000-8000-000000000005',
  'Media Backfill PDF Page',
  'Media Backfill PDF Page',
  'Test',
  'TEST-MEDIA-BACKFILL-005',
  '9999',
  true, true,
  'https://example.invalid/_pdf_pages/page-1.jpg',
  'missing'
),
(
  '19120000-0000-4000-8000-000000000006',
  'Media Backfill Inactive',
  'Media Backfill Inactive',
  'Test',
  'TEST-MEDIA-BACKFILL-006',
  '9999',
  false, true,
  'https://example.invalid/media/inactive.jpg',
  'missing'
),
(
  '19120000-0000-4000-8000-000000000007',
  'Media Backfill Similar Path',
  'Media Backfill Similar Path',
  'Test',
  'TEST-MEDIA-BACKFILL-007',
  '9999',
  true, true,
  'https://example.invalid/xpdf_pages/page-1.jpg',
  'missing'
);

insert into public.product_media (
  product_id, file_url, type, status, alt_text
) values (
  '19120000-0000-4000-8000-000000000004',
  'https://example.invalid/media/existing.jpg',
  'hero_image',
  'raw',
  'pre_existing_authority'
);

select lives_ok(
  $$select public.reconcile_legacy_published_product_media_authority_v1()$$,
  'reconciliation executes against fixture rows'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000001'
      and type='hero_image'
      and status='approved'
      and alt_text='legacy_published_catalogue_hero_backfill'
  ),
  1::bigint,
  'published visible legacy hero receives one governed approved media row'
);

select is(
  (
    select media_status
    from public.products
    where id='19120000-0000-4000-8000-000000000001'
  ),
  'approved'::text,
  'published visible product media_status is synchronized to approved'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'hidden product is never auto-approved'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000003'
  ),
  0::bigint,
  'product without hero URL is never auto-approved'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000004'
  ),
  1::bigint,
  'existing product_media authority is never duplicated or overridden'
);

select is(
  (
    select status
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000004'
  ),
  'raw'::text,
  'existing media authority status remains untouched'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000005'
  ),
  0::bigint,
  'PDF-page fallback is excluded from authority backfill'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000006'
  ),
  0::bigint,
  'inactive product is never auto-approved'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000007'
      and type='hero_image'
      and status='approved'
      and alt_text='legacy_published_catalogue_hero_backfill'
  ),
  1::bigint,
  'similar xpdf_pages path is not mistaken for the literal _pdf_pages fallback'
);



select lives_ok(
  $$select public.reconcile_legacy_published_product_media_authority_v1()$$,
  'reconciliation is safe to repeat'
);

select is(
  (
    select count(*)::bigint
    from public.product_media
    where product_id='19120000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'repeat reconciliation is idempotent'
);

select * from finish();
rollback;
