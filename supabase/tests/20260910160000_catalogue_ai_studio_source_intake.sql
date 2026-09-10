-- Contract for 20260910160000_catalogue_ai_studio_source_intake.sql
-- Proves catalogue documents can be staged independently of public.products and
-- that the intake surface carries no automatic product-creation authority.

begin;
select plan(26);

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

-- Product-master lifecycle is independent of source staging. A referenced product
-- may be deleted; the FK's SET NULL action must demote match-dependent source state
-- before CHECK constraints are evaluated.
insert into public.products (
  id, name, category, sku, hsn_code, price_per_kg, base_price, price_b2b, primary_pack_weight_kg
) values (
  'ca740000-0000-4000-8000-000000000001',
  'Catalogue Dereference Fixture',
  'Baklawa',
  'CAT-SOURCE-DEREF-001',
  '1905',
  100,
  100,
  100,
  1
);

insert into public.catalogue_source_entries (
  id,
  batch_id,
  source_entry_key,
  source_title,
  matched_product_id,
  status,
  reviewed_by,
  reviewed_at
) values (
  'ca720000-0000-4000-8000-000000000002',
  'ca710000-0000-4000-8000-000000000001',
  'page-001:item-dereference',
  'Dereference Fixture',
  'ca740000-0000-4000-8000-000000000001',
  'APPROVED_FOR_DRAFT',
  'ca730000-0000-4000-8000-000000000001',
  now()
);

delete from public.products where id = 'ca740000-0000-4000-8000-000000000001';

select ok(
  (select matched_product_id is null from public.catalogue_source_entries where id = 'ca720000-0000-4000-8000-000000000002'),
  'deleting a referenced product clears only the staging match link'
);

select is(
  (select status from public.catalogue_source_entries where id = 'ca720000-0000-4000-8000-000000000002'),
  'STAGED',
  'deleting a referenced product demotes match-dependent source state to STAGED'
);

select ok(
  (select reviewed_by is null from public.catalogue_source_entries where id = 'ca720000-0000-4000-8000-000000000002'),
  'dereference clears stale reviewer attribution from the demoted source entry'
);

select ok(
  (select reviewed_at is null from public.catalogue_source_entries where id = 'ca720000-0000-4000-8000-000000000002'),
  'dereference clears stale review timestamp from the demoted source entry'
);

-- Authenticated attribution integrity: use the same canonical user_role_map authority
-- that public.is_team_member(auth.uid()) reads in production. Team members may
-- attribute only to themselves; provenance cannot be forged as another UUID.
set local session_replication_role = replica;
insert into auth.users (id, email) values
  ('ca730000-0000-4000-8000-000000000001', 'catalogue-source-staff@example.invalid'),
  ('ca730000-0000-4000-8000-000000000002', 'catalogue-source-other@example.invalid');
insert into public.users (id, email, role, is_active) values
  ('ca730000-0000-4000-8000-000000000001', 'catalogue-source-staff@example.invalid', 'admin', true),
  ('ca730000-0000-4000-8000-000000000002', 'catalogue-source-other@example.invalid', 'admin', true);
insert into public.user_role_map (id, user_id, role_id)
select gen_random_uuid(), fixture.user_id, r.id
from (
  values
    ('ca730000-0000-4000-8000-000000000001'::uuid),
    ('ca730000-0000-4000-8000-000000000002'::uuid)
) as fixture(user_id)
cross join lateral (
  select id from public.roles where role_key = 'admin' and coalesce(is_active, true) limit 1
) r;
set local session_replication_role = default;

set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'ca730000-0000-4000-8000-000000000001';
set local role authenticated;

select throws_ok(
  $$
    insert into public.catalogue_source_batches (
      source_provider, source_document_name, dedupe_key, imported_by
    ) values (
      'test_catalogue', 'Forged Import Attribution', 'test:catalogue-source-forged-import:v1',
      'ca730000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  null,
  'authenticated importer cannot forge imported_by as another user'
);

insert into public.catalogue_source_batches (
  id, source_provider, source_document_name, dedupe_key, imported_by
) values (
  'ca710000-0000-4000-8000-000000000002',
  'test_catalogue',
  'Self Attribution Fixture',
  'test:catalogue-source-self-import:v1',
  'ca730000-0000-4000-8000-000000000001'
);

select is(
  (select imported_by from public.catalogue_source_batches where id = 'ca710000-0000-4000-8000-000000000002'),
  'ca730000-0000-4000-8000-000000000001'::uuid,
  'authenticated importer may bind imported_by to self'
);

select throws_ok(
  $$
    update public.catalogue_source_entries
    set reviewed_by = 'ca730000-0000-4000-8000-000000000002'
    where id = 'ca720000-0000-4000-8000-000000000001'
  $$,
  '42501',
  null,
  'authenticated reviewer cannot forge reviewed_by as another user'
);

update public.catalogue_source_entries
set status = 'IGNORED',
    reviewed_by = 'ca730000-0000-4000-8000-000000000001',
    reviewed_at = now()
where id = 'ca720000-0000-4000-8000-000000000001';

select ok(
  (select status = 'IGNORED'
          and reviewed_by = 'ca730000-0000-4000-8000-000000000001'::uuid
          and reviewed_at is not null
   from public.catalogue_source_entries
   where id = 'ca720000-0000-4000-8000-000000000001'),
  'authenticated reviewer may bind review attribution to self'
);

select throws_ok(
  $$
    insert into public.catalogue_source_audit_log (
      batch_id, entry_id, action, actor_id
    ) values (
      'ca710000-0000-4000-8000-000000000001',
      'ca720000-0000-4000-8000-000000000001',
      'FORGED_AUDIT_ACTOR',
      'ca730000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  null,
  'authenticated staff cannot forge immutable audit actor attribution'
);

insert into public.catalogue_source_audit_log (
  batch_id, entry_id, action, actor_id
) values (
  'ca710000-0000-4000-8000-000000000001',
  'ca720000-0000-4000-8000-000000000001',
  'SELF_AUDIT_ACTOR',
  'ca730000-0000-4000-8000-000000000001'
);

select is(
  (select actor_id from public.catalogue_source_audit_log where action = 'SELF_AUDIT_ACTOR'),
  'ca730000-0000-4000-8000-000000000001'::uuid,
  'authenticated staff may bind immutable audit actor attribution to self'
);

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select * from finish();
rollback;
