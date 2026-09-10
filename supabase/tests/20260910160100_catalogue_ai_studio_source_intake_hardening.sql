-- Contract for 20260910160100_catalogue_ai_studio_source_intake_hardening.sql
-- Ensures review hardening remains present even when a Supabase Preview branch had
-- already recorded the original 20260910160000 migration filename.

begin;
select plan(8);

select has_function(
  'public',
  'catalogue_source_demote_dereferenced_entry',
  array[]::text[],
  'product dereference demotion trigger function exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.catalogue_source_entries'::regclass
      and tgname = 'trg_catalogue_source_entries_dereference'
      and not tgisinternal
  ),
  'source entries have product dereference demotion trigger'
);

select has_function(
  'public',
  'catalogue_source_protect_attribution',
  array[]::text[],
  'source attribution protection trigger function exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.catalogue_source_batches'::regclass
      and tgname = 'trg_catalogue_source_batches_attribution'
      and not tgisinternal
  ),
  'source batches protect imported_by attribution on update'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.catalogue_source_entries'::regclass
      and tgname = 'trg_catalogue_source_entries_attribution'
      and not tgisinternal
  ),
  'source entries protect reviewed_by attribution on update'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'catalogue_source_batches'
      and policyname = 'catalogue_source_batches_staff_insert'
      and coalesce(with_check, '') like '%imported_by%'
      and coalesce(with_check, '') like '%auth.uid()%'
  ),
  'batch insert policy binds imported_by to the authenticated caller'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'catalogue_source_entries'
      and policyname = 'catalogue_source_entries_staff_update'
      and coalesce(with_check, '') like '%reviewed_by%'
      and coalesce(with_check, '') like '%auth.uid()%'
  ),
  'entry update policy binds reviewed_by to the authenticated caller'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'catalogue_source_audit_log'
      and policyname = 'catalogue_source_audit_staff_insert'
      and coalesce(with_check, '') like '%actor_id%'
      and coalesce(with_check, '') like '%auth.uid()%'
  ),
  'audit insert policy binds actor_id to the authenticated caller'
);

select * from finish();
rollback;
