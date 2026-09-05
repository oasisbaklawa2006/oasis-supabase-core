-- Contract and behavioral coverage for Point 20 shared operational event ledger.
-- Schema authority: squashed baseline 20260723161256 + archived 20260723154000.
begin;

select plan(26);

select has_function(
  'public',
  'append_operational_event_v1',
  array[
    'text','text','uuid','text','text','text','jsonb','uuid','uuid','uuid','uuid',
    'text','text','text','text','text','text','text','text','integer','text','text','text','timestamptz'
  ],
  'append_operational_event_v1 canonical writer exists'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz)',
    'EXECUTE'
  ),
  'anon cannot execute append_operational_event_v1'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.append_operational_event_v1(text,text,uuid,text,text,text,jsonb,uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,integer,text,text,text,timestamptz)',
    'EXECUTE'
  ),
  'authenticated can execute append_operational_event_v1 through governed RPC'
);

select ok(
  exists(
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'operational_events'
      and indexname = 'operational_events_source_idempotency_uidx'
      and indexdef ilike '%unique%'
      and indexdef ilike '%source_application%'
      and indexdef ilike '%idempotency_key%'
  ),
  'source-scoped idempotency index is unique on source_application and idempotency_key'
);

select ok(
  exists(
    select 1
    from pg_trigger
    where tgrelid = 'public.operational_events'::regclass
      and tgname = 'trg_operational_events_no_update'
      and tgenabled <> 'D'
  )
  and exists(
    select 1
    from pg_trigger
    where tgrelid = 'public.operational_events'::regclass
      and tgname = 'trg_operational_events_no_delete'
      and tgenabled <> 'D'
  ),
  'append-only update/delete guard triggers are enabled'
);

insert into public.users (id, role) values
  ('a0200000-0000-0000-0000-000000000001', 'HOD_ARABIC'),
  ('a0200000-0000-0000-0000-000000000002', 'B2B_BUYER');

set local request.jwt.claim.role = 'authenticated';

-- Unauthenticated append is rejected.
reset request.jwt.claim.sub;
select throws_ok(
  $$select public.append_operational_event_v1(
    'point20_contract_probe', 'order', 'a0200000-0000-0000-0000-000000000099'::uuid,
    'Unauthenticated probe', 'point20-pgtap', 'point20-unauth-corr', '{}'::jsonb
  )$$,
  'authentication required',
  'unauthenticated callers cannot append operational events'
);

-- Non-staff authenticated caller is rejected.
set local request.jwt.claim.sub = 'a0200000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.append_operational_event_v1(
    'point20_contract_probe', 'order', 'a0200000-0000-0000-0000-000000000099'::uuid,
    'Non-staff probe', 'point20-pgtap', 'point20-nonstaff-corr', '{}'::jsonb
  )$$,
  'internal staff authority required',
  'non-staff authenticated callers cannot append operational events'
);

set local request.jwt.claim.sub = 'a0200000-0000-0000-0000-000000000001';

-- Actor spoofing is rejected.
select throws_ok(
  $$select public.append_operational_event_v1(
    'point20_contract_probe', 'order', 'a0200000-0000-0000-0000-000000000099'::uuid,
    'Actor mismatch probe', 'point20-pgtap', 'point20-actor-corr', '{}'::jsonb,
    null, null, null, 'a0200000-0000-0000-0000-000000000002'::uuid
  )$$,
  'actor identity mismatch',
  'append binds actor_id to the authenticated caller'
);

-- Positive append succeeds and persists canonical envelope metadata.
select lives_ok(
  $$select public.append_operational_event_v1(
    'point20_contract_probe', 'order', 'a0200000-0000-0000-0000-000000000099'::uuid,
    'Canonical append probe', 'point20-pgtap', 'point20-append-corr',
    jsonb_build_object('probe', true),
    null, null, null, null, 'HOD_ARABIC', 'ARABIC_SWEETS',
    'internal', 'info', 'Point20 pgTAP append probe', null, null,
    'point20-idem-1', 1, 'point20.command.append', 'cmd-point20-1', 'cause-point20-1',
    timestamptz '2026-07-23 12:00:00+00'
  )$$,
  'internal staff can append a canonical operational event'
);

select is(
  (select source_application from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  'point20-pgtap',
  'appended event records source_application'
);

select is(
  (select actor_id from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  'a0200000-0000-0000-0000-000000000001'::uuid,
  'appended event binds actor_id to the authenticated caller when omitted'
);

select is(
  (select event_version from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  1,
  'appended event records event_version'
);

select is(
  (select command_name from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  'point20.command.append',
  'appended event records command_name audit metadata'
);

select is(
  (select occurred_at from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  timestamptz '2026-07-23 12:00:00+00',
  'appended event records occurred_at separately from created_at'
);

select ok(
  coalesce(
    (select btrim(payload_fingerprint) <> '' from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
    false
  ),
  'appended event records a non-empty payload_fingerprint'
);

-- Appended row is persisted for downstream staff read surfaces.
select is(
  (select count(*)::bigint from public.operational_events where correlation_id = 'point20-append-corr'),
  1::bigint,
  'appended operational event row is persisted'
);

-- Same idempotency key and same payload replays the original event id.
select is(
  public.append_operational_event_v1(
    'point20_contract_probe', 'order', 'a0200000-0000-0000-0000-000000000099'::uuid,
    'Canonical append probe', 'point20-pgtap', 'point20-append-corr',
    jsonb_build_object('probe', true),
    null, null, null, null, 'HOD_ARABIC', 'ARABIC_SWEETS',
    'internal', 'info', 'Point20 pgTAP append probe', null, null,
    'point20-idem-1', 1, 'point20.command.append', 'cmd-point20-1', 'cause-point20-1',
    timestamptz '2026-07-23 12:00:00+00'
  ),
  (select id from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  'same idempotency key and payload replays the original event id'
);

select is(
  (select count(*)::bigint from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'),
  1::bigint,
  'idempotent replay does not insert a duplicate row'
);

-- Same idempotency key with a changed payload is rejected.
select throws_ok(
  $$select public.append_operational_event_v1(
    'point20_contract_probe', 'order', 'a0200000-0000-0000-0000-000000000099'::uuid,
    'Canonical append probe', 'point20-pgtap', 'point20-append-corr',
    jsonb_build_object('probe', false),
    null, null, null, null, 'HOD_ARABIC', 'ARABIC_SWEETS',
    'internal', 'info', 'Point20 pgTAP append probe', null, null,
    'point20-idem-1', 1, 'point20.command.append', 'cmd-point20-1', 'cause-point20-1',
    timestamptz '2026-07-23 12:00:00+00'
  )$$,
  'idempotency key conflict',
  'same idempotency key with a different payload is rejected'
);

-- Direct mutation attempts fail closed even for staff.
select throws_like(
  $$update public.operational_events set title = 'mutated' where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'$$,
  '%append-only%',
  'direct UPDATE on operational_events is blocked'
);

select throws_like(
  $$delete from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'$$,
  '%append-only%',
  'direct DELETE on operational_events is blocked'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.operational_events'::regclass),
  'operational_events row level security is enabled'
);

reset role;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a0200000-0000-0000-0000-000000000001';
set local role authenticated;

select isnt_empty(
  $$select 1 from public.operational_events where idempotency_key = 'point20-idem-1' and source_application = 'point20-pgtap'$$,
  'staff authenticated role can read operational events under RLS'
);

set local request.jwt.claim.sub = 'a0200000-0000-0000-0000-000000000002';

select is_empty(
  $$select 1 from public.operational_events where idempotency_key = 'point20-idem-1'$$,
  'non-staff authenticated role cannot read operational events under RLS'
);

select throws_like(
  $$insert into public.operational_events (
    event_type, entity_type, entity_id, title, correlation_id,
    source_application, payload_fingerprint
  ) values (
    'point20_rls_probe', 'order', 'a0200000-0000-0000-0000-000000000097'::uuid,
    'RLS probe', 'point20-rls-nonstaff', 'point20-pgtap', 'rls-nonstaff-fingerprint'
  )$$,
  '%row-level security%',
  'non-staff direct INSERT is blocked by operational_events RLS'
);

set local request.jwt.claim.sub = 'a0200000-0000-0000-0000-000000000001';

select lives_ok(
  $$insert into public.operational_events (
    event_type, entity_type, entity_id, title, correlation_id,
    source_application, payload_fingerprint, idempotency_key
  ) values (
    'point20_rls_probe', 'order', 'a0200000-0000-0000-0000-000000000098'::uuid,
    'RLS staff insert probe', 'point20-rls-staff', 'point20-pgtap', 'rls-staff-fingerprint', 'point20-rls-staff-idem'
  )$$,
  'staff direct INSERT is permitted by operational_events RLS'
);

select * from finish();
rollback;
