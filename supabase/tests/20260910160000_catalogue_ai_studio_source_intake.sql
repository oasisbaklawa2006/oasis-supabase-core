-- Contract for 20260910160000_catalogue_ai_studio_source_intake.sql
-- Proves catalogue documents can be staged independently of public.products and
-- that the intake surface carries no automatic product-creation authority.

begin;
select plan(16);

select has_table('public', 'catalogue_source_batches', 'catalogue source batches table exists');
select has_table('public', 'catalogue_source_entries', 'catalogue source entries table exists');
select has_table('public', 'catalogue_source_audit_log', 'catalogue source audit table exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.catalogue_source_batches'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.catalogue_source_entries'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.catalogue_source_audit_log'::regclass),
  'all catalogue source intake tables have RLS enabled'
);

select ok(
  not has_table_privilege('anon', 'public.catalogue_source_batches', 'SELECT')
  and not has_table_privilege('anon', 'public.catalogue_source_batches', 'INSERT')
  and not has_table_privilege('anon', 'public.catalogue_source_entries', 'SELECT')
  and not has_table_privilege('anon', 'public.catalogue_source_entries', 'INSERT')
  and not has_table_privilege('anon', 'public.catalogue_source_audit_log', 'SELECT')
  and not has_table_privilege('anon', 'public.catalogue_source_audit_log', 'INSERT'),
  'anonymous callers have no catalogue source intake access'
);

select ok(
  not has_table_privilege('authenticated', 'public.catalogue_source_batches', 'DELETE')
  and not has_table_privilege('authenticated', 'public.catalogue_source_entries', 'DELETE')
  and not has_table_privilege('authenticated', 'public.catalogue_source_audit_log', 'DELETE'),
  'authenticated users cannot delete catalogue intake history'
);

select ok(
  has_table_privilege('authenticated', 'public.catalogue_source_batches', 'SELECT')
  and has_table_privilege('authenticated', 'public.catalogue_source_batches', 'INSERT')
  and has_table_privilege('authenticated', 'public.catalogue_source_batches', 'UPDATE')
  and has_table_privilege('authenticated', 'public.catalogue_source_entries', 'SELECT')
  and has_table_privilege('authenticated', 'public.catalogue_source_entries', 'INSERT')
  and has_table_privilege('authenticated', 'public.catalogue_source_entries', 'UPDATE')
  and has_table_privilege('authenticated', 'public.catalogue_source_audit_log', 'SELECT')
  and has_table_privilege('authenticated', 'public.catalogue_source_audit_log', 'INSERT'),
  'authenticated team workflow has only the intended table privileges'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.catalogue_source_entries'::regclass
      and conname = 'catalogue_source_entries_matched_product_id_fkey'
      and contype = 'f'
  ),
  'matched_product_id is an optional link to an existing product'
);

create temporary table _catalogue_source_products_before as
select count(*)::bigint as product_count from public.products;

insert into public.catalogue_source_batches (
  id,
  source_provider,
  source_document_id,
  source_document_name,
  source_revision,
  dedupe_key,
  source_metadata
) values (
  'ca710000-0000-4000-8000-000000000001',
  'test_catalogue',
  'source-doc-1',
  'Catalogue Source Contract Fixture',
  'v1',
  'test:catalogue-source-contract:v1',
  '{"fixture":true}'::jsonb
);

select throws_ok(
  $$
    insert into public.catalogue_source_batches (
      source_provider, source_document_id, source_document_name, source_revision, dedupe_key
    ) values (
      'test_catalogue', 'source-doc-1', 'Duplicate Fixture', 'v1', 'test:catalogue-source-contract:v1'
    )
  $$,
  '23505',
  null,
  'source batch dedupe key makes ingestion idempotent'
);

insert into public.catalogue_source_entries (
  id,
  batch_id,
  source_entry_key,
  source_page_number,
  source_title,
  raw_source_data,
  candidate_product_data
) values (
  'ca720000-0000-4000-8000-000000000001',
  'ca710000-0000-4000-8000-000000000001',
  'page-001:item-001',
  1,
  'Unapproved Catalogue Candidate',
  '{"title":"Unapproved Catalogue Candidate","source":"fixture"}'::jsonb,
  '{"catalogue_title":"Unapproved Catalogue Candidate"}'::jsonb
);

select is(
  (select count(*)::bigint from public.products),
  (select product_count from _catalogue_source_products_before),
  'staging an unmatched catalogue entry does not create a product'
);

select is(
  (select status from public.catalogue_source_entries where id = 'ca720000-0000-4000-8000-000000000001'),
  'STAGED',
  'new catalogue entry defaults to STAGED'
);

select ok(
  (select matched_product_id is null from public.catalogue_source_entries where id = 'ca720000-0000-4000-8000-000000000001'),
  'staged catalogue entry may remain unmatched to product master'
);

select throws_ok(
  $$
    insert into public.catalogue_source_entries (
      batch_id,
      source_entry_key,
      source_title,
      status,
      reviewed_at
    ) values (
      'ca710000-0000-4000-8000-000000000001',
      'invalid-approved-without-product',
      'Invalid Approval Fixture',
      'APPROVED_FOR_DRAFT',
      now()
    )
  $$,
  '23514',
  null,
  'an entry cannot be approved for an AI Studio product draft without matching an existing product'
);

insert into public.catalogue_source_audit_log (
  batch_id,
  entry_id,
  action,
  from_status,
  to_status,
  metadata
) values (
  'ca710000-0000-4000-8000-000000000001',
  'ca720000-0000-4000-8000-000000000001',
  'STAGE_SOURCE_ENTRY',
  null,
  'STAGED',
  '{"fixture":true}'::jsonb
);

select is(
  (select count(*)::bigint from public.catalogue_source_audit_log where entry_id = 'ca720000-0000-4000-8000-000000000001'),
  1::bigint,
  'catalogue source decisions can be retained in append-only audit history'
);

select is(
  (
    select count(*)::bigint
    from pg_trigger t
    where t.tgrelid = 'public.products'::regclass
      and not t.tgisinternal
      and t.tgname like '%catalogue_source%'
  ),
  0::bigint,
  'catalogue source intake installs no product mutation trigger'
);

select is(
  (
    select count(*)::bigint
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'catalogue_source%product%create%'
  ),
  0::bigint,
  'catalogue source intake exposes no product creation routine'
);

select * from finish();
rollback;
