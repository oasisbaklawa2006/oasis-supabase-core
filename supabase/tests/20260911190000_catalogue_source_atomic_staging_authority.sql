begin;
-- Contract for 20260911190000_catalogue_source_atomic_staging_authority.sql
-- Issue #282 — CATALOGUE SOURCE atomic batch+entries+status+audit staging RPC.
-- Proves public.stage_catalogue_source_entry() performs batch create/replay
-- resolution, entry persistence, permitted batch status transition and the
-- mandatory audit event as ONE transaction: any genuine failure at any
-- substep rolls back every write already made by that same call.
--
-- Schema note: catalogue_source_batches/entries/audit_log carry no
-- company/tenant column -- this is a single shared internal staging surface
-- gated only by team-member authority (public.is_team_member), not a
-- per-company boundary. The "cross-company/tenant isolation" requirement is
-- therefore proven here as cross-BATCH isolation: independent batches never
-- cross-contaminate each other's entries or audit history.
select plan(37);

select has_function(
  'public', 'stage_catalogue_source_entry',
  array['text','text','text','text','text','text','text','jsonb','integer','text','text','text','jsonb','jsonb','text'],
  'stage_catalogue_source_entry RPC exists with the expected signature'
);
select ok(
  not has_function_privilege('anon', 'public.stage_catalogue_source_entry(text,text,text,text,text,text,text,jsonb,integer,text,text,text,jsonb,jsonb,text)', 'execute'),
  'anon cannot execute the staging RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.stage_catalogue_source_entry(text,text,text,text,text,text,text,jsonb,integer,text,text,text,jsonb,jsonb,text)', 'execute'),
  'authenticated callers can execute the staging RPC (authorization enforced inside)'
);
select ok(
  (
    select pg_get_functiondef(oid) not ilike '%insert into public.products%'
       and pg_get_functiondef(oid) not ilike '%update public.products%'
       and pg_get_functiondef(oid) not ilike '%publish%'
       and pg_get_functiondef(oid) not ilike '%activat%'
    from pg_proc
    where oid = 'public.stage_catalogue_source_entry(text,text,text,text,text,text,text,jsonb,integer,text,text,text,jsonb,jsonb,text)'::regprocedure
  ),
  'staging RPC body contains no products/publication/activation authority (static proof)'
);

-- =============================================================================
-- Fixtures: one team-member actor, one non-team-member actor.
-- =============================================================================
insert into public.roles (id, role_key, role_name, is_active) values
  ('d2820000-0000-0000-0000-00000000a001', 'catalogue_manager', 'Catalogue manager', true)
on conflict (role_key) do update set is_active = true;

insert into public.users (id, role) values
  ('d2820000-0000-0000-0000-000000000001', 'CATALOGUE_MANAGER'),
  ('d2820000-0000-0000-0000-000000000002', 'BUYER')
on conflict (id) do nothing;

insert into public.user_role_map (user_id, role_id)
select 'd2820000-0000-0000-0000-000000000001', id from public.roles where role_key = 'catalogue_manager'
on conflict (user_id, role_id) do nothing;

select is(public.is_team_member('d2820000-0000-0000-0000-000000000001'::uuid), true, 'fixture team-member actor is recognised as team member');
select is(public.is_team_member('d2820000-0000-0000-0000-000000000002'::uuid), false, 'fixture non-team-member actor is not a team member');

select set_config('p282.products_before', (select count(*)::text from public.products), true);

-- =============================================================================
-- Unauthorized callers.
-- =============================================================================
reset request.jwt.claim.sub;
select throws_ok(
  $$select * from public.stage_catalogue_source_entry('p282-unauth','P282Provider','P282 Doc','entry-1')$$,
  'CATALOGUE_SOURCE_STAGING_UNAUTHORIZED',
  'anonymous caller (no auth.uid) is rejected'
);

set local request.jwt.claim.sub = 'd2820000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
select throws_ok(
  $$select * from public.stage_catalogue_source_entry('p282-unauth','P282Provider','P282 Doc','entry-1')$$,
  'CATALOGUE_SOURCE_STAGING_UNAUTHORIZED',
  'authenticated non-team-member caller is rejected'
);
select is((select count(*)::int from public.catalogue_source_batches where dedupe_key = 'p282-unauth'), 0, 'no batch was created by the rejected unauthorized calls');

-- =============================================================================
-- 1. Successful atomic staging (new batch, new entry, mandatory audit row).
-- =============================================================================
set local request.jwt.claim.sub = 'd2820000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select results_eq(
  $$select batch_status, entry_status, entry_was_replayed, (audit_id is not null)
    from public.stage_catalogue_source_entry(
      'p282-batch-A','P282Provider','P282 Document A','entry-1',
      'doc-A','rev-1',null,'{"note":"p282"}'::jsonb,
      1,'Title A','SKU-A','slug-a','{"raw":1}'::jsonb,'{"candidate":1}'::jsonb,null
    )$$,
  $$values ('PARSING','STAGED',false,true)$$,
  'first staging call creates batch (auto RECEIVED->PARSING), STAGED entry, and an audit row'
);
select is((select count(*)::int from public.catalogue_source_batches where dedupe_key = 'p282-batch-A'), 1, 'exactly one batch row exists for the new dedupe_key');
select is((select count(*)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'exactly one entry row exists for the new entry key');
select is((select count(*)::int from public.catalogue_source_audit_log al join public.catalogue_source_batches b on b.id = al.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'exactly one audit row was appended for the first staging call');
select is((select matched_product_id from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-A'), null, 'staged entry carries no product match (no promotion/activation side effect)');

-- =============================================================================
-- 2. Exact idempotent replay: identical call returns existing durable state,
--    does not duplicate the batch/entry, and (no-op transition) skips a
--    redundant audit row.
-- =============================================================================
select results_eq(
  $$select entry_was_replayed, batch_status
    from public.stage_catalogue_source_entry(
      'p282-batch-A','P282Provider','P282 Document A','entry-1',
      'doc-A','rev-1',null,'{"note":"p282"}'::jsonb,
      1,'Title A','SKU-A','slug-a','{"raw":1}'::jsonb,'{"candidate":1}'::jsonb,null
    )$$,
  $$values (true,'PARSING')$$,
  'exact replay reports entry_was_replayed=true and returns existing batch status'
);
select is((select count(*)::int from public.catalogue_source_batches where dedupe_key = 'p282-batch-A'), 1, 'exact replay does not duplicate the batch row');
select is((select count(*)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'exact replay does not duplicate the entry row');
select is((select count(*)::int from public.catalogue_source_audit_log al join public.catalogue_source_batches b on b.id = al.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'exact no-op replay does not append a redundant audit row');

-- =============================================================================
-- 3. Mismatched batch replay is rejected (fail closed); rollback proof: the
--    attempted call adds no new entry/audit row anywhere.
-- =============================================================================
select throws_ok(
  $$select * from public.stage_catalogue_source_entry(
      'p282-batch-A','DifferentProvider','P282 Document A','entry-2',
      'doc-A','rev-1',null,'{}'::jsonb, null,null,null,null,'{}'::jsonb,'{}'::jsonb,null
    )$$,
  'CATALOGUE_SOURCE_STAGING_BATCH_REPLAY_MISMATCH',
  'mismatched batch replay (same dedupe_key, different provider) fails closed'
);
select is((select count(*)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'rollback: mismatched batch replay adds no new entry');
select is((select count(*)::int from public.catalogue_source_audit_log al join public.catalogue_source_batches b on b.id = al.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'rollback: mismatched batch replay adds no new audit row');

-- =============================================================================
-- 4. Duplicate-entry protection: same entry key, different content is
--    rejected; rollback proof that the original entry content is untouched.
-- =============================================================================
select throws_ok(
  $$select * from public.stage_catalogue_source_entry(
      'p282-batch-A','P282Provider','P282 Document A','entry-1',
      'doc-A','rev-1',null,'{"note":"p282"}'::jsonb,
      1,'Title A','SKU-A','slug-a','{"raw":"DIFFERENT"}'::jsonb,'{"candidate":1}'::jsonb,null
    )$$,
  'CATALOGUE_SOURCE_STAGING_ENTRY_REPLAY_MISMATCH',
  'duplicate source_entry_key with different content fails closed (no silent overwrite)'
);
select results_eq(
  $$select raw_source_data from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-A' and e.source_entry_key = 'entry-1'$$,
  $$values ('{"raw":1}'::jsonb)$$,
  'rollback: original entry content is unchanged after the rejected mismatched replay'
);
select is((select count(*)::int from public.catalogue_source_audit_log al join public.catalogue_source_batches b on b.id = al.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'rollback: rejected entry mismatch adds no new audit row');

-- =============================================================================
-- 5. Rollback when status transition fails: the entry INSERT that happens
--    earlier in the SAME call must be undone when the later transition check
--    raises. Uses a second, independent batch/dedupe_key.
-- =============================================================================
select * from public.stage_catalogue_source_entry(
  'p282-batch-B','P282Provider','P282 Document B','entry-1',
  null,null,null,'{}'::jsonb, null,null,null,null,'{}'::jsonb,'{}'::jsonb,'READY_FOR_REVIEW'
);
select is((select status from public.catalogue_source_batches where dedupe_key = 'p282-batch-B'), 'READY_FOR_REVIEW', 'batch B advanced directly to READY_FOR_REVIEW via explicit target status');

select throws_ok(
  $$select * from public.stage_catalogue_source_entry(
      'p282-batch-B','P282Provider','P282 Document B','entry-2',
      null,null,null,'{}'::jsonb, null,null,null,null,'{}'::jsonb,'{}'::jsonb,'RECEIVED'
    )$$,
  'CATALOGUE_SOURCE_STAGING_BATCH_TRANSITION_DENIED',
  'backward batch transition (READY_FOR_REVIEW -> RECEIVED) is denied'
);
select is((select count(*)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-B'), 1, 'rollback: entry-2 insert made before the transition check is undone by the later exception');
select is((select status from public.catalogue_source_batches where dedupe_key = 'p282-batch-B'), 'READY_FOR_REVIEW', 'rollback: batch B status is unchanged after the denied transition');
select is((select count(*)::int from public.catalogue_source_audit_log al join public.catalogue_source_batches b on b.id = al.batch_id where b.dedupe_key = 'p282-batch-B'), 1, 'rollback: denied transition adds no new audit row');

-- =============================================================================
-- 6. Terminal-batch mutation rejection: REVIEWED/ARCHIVED/FAILED batches
--    cannot acquire new staged entries.
-- =============================================================================
update public.catalogue_source_batches set status = 'REVIEWED', completed_at = now() where dedupe_key = 'p282-batch-B';
select throws_ok(
  $$select * from public.stage_catalogue_source_entry(
      'p282-batch-B','P282Provider','P282 Document B','entry-3',
      null,null,null,'{}'::jsonb, null,null,null,null,'{}'::jsonb,'{}'::jsonb,null
    )$$,
  'CATALOGUE_SOURCE_STAGING_BATCH_TERMINAL',
  'a REVIEWED batch rejects a new staged entry'
);
select is((select count(*)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-B'), 1, 'rollback: terminal-batch rejection adds no new entry');

-- =============================================================================
-- 7. Concurrent execution safety (sequential-race proof, same convention as
--    the Point83 reservation audit): two calls racing the SAME dedupe_key
--    for a brand-new batch converge on exactly one batch row via the
--    advisory lock + dedupe_key UNIQUE constraint.
-- =============================================================================
select * from public.stage_catalogue_source_entry(
  'p282-batch-C','P282Provider','P282 Document C','race-1',
  null,null,null,'{}'::jsonb, null,null,null,null,'{}'::jsonb,'{}'::jsonb,null
);
select * from public.stage_catalogue_source_entry(
  'p282-batch-C','P282Provider','P282 Document C','race-2',
  null,null,null,'{}'::jsonb, null,null,null,null,'{}'::jsonb,'{}'::jsonb,null
);
select is((select count(*)::int from public.catalogue_source_batches where dedupe_key = 'p282-batch-C'), 1, 'racing calls on the same dedupe_key converge on exactly one batch row');
select is((select count(distinct e.id)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-C'), 2, 'both distinct entries in the race were staged onto the single batch');

-- =============================================================================
-- 8. Cross-batch isolation (schema has no company/tenant column; batches are
--    the isolation boundary here -- see file header note).
-- =============================================================================
select is((select count(*)::int from public.catalogue_source_entries e join public.catalogue_source_batches b on b.id = e.batch_id where b.dedupe_key = 'p282-batch-A'), 1, 'batch A entry count is unaffected by all work performed on batches B and C');
select is((select status from public.catalogue_source_batches where dedupe_key = 'p282-batch-A'), 'PARSING', 'batch A status is unaffected by batch B''s terminal transition or batch C''s race');

-- =============================================================================
-- 9. Non-negotiables: no product row was ever created, and every entry this
--    RPC ever staged in this test remains STAGED (never auto-promoted).
-- =============================================================================
select is((select count(*)::text from public.products), current_setting('p282.products_before'), 'public.products row count is unchanged by any staging call in this test');
select is((select count(*)::int from public.catalogue_source_entries where status <> 'STAGED' and batch_id in (select id from public.catalogue_source_batches where dedupe_key in ('p282-batch-A','p282-batch-B','p282-batch-C'))), 0, 'every entry staged by this RPC remains STAGED (no publication/activation/matching side effect)');

select finish();
rollback;
