-- Contract for 20260910160200_catalogue_ai_studio_source_attribution_trigger_fix.sql
-- Exact-head certification anchor after preview migration convergence.

begin;
select plan(4);

select has_function(
  'public',
  'catalogue_source_protect_attribution',
  array[]::text[],
  'shared catalogue attribution trigger function exists'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.catalogue_source_batches'::regclass
      and tgname = 'trg_catalogue_source_batches_attribution'
      and not tgisinternal
  ),
  'batch attribution trigger remains installed'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.catalogue_source_entries'::regclass
      and tgname = 'trg_catalogue_source_entries_attribution'
      and not tgisinternal
  ),
  'entry attribution trigger remains installed'
);

select ok(
  pg_get_functiondef('public.catalogue_source_protect_attribution()'::regprocedure)
    like '%IF TG_TABLE_NAME = ''catalogue_source_batches'' THEN%'
  and pg_get_functiondef('public.catalogue_source_protect_attribution()'::regprocedure)
    like '%ELSIF TG_TABLE_NAME = ''catalogue_source_entries'' THEN%',
  'shared trigger branches on table before dereferencing table-specific fields'
);

select * from finish();
rollback;
