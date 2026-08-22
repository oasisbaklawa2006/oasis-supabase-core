begin;
-- Behavioral and concurrency coverage for 20260822120000_whatsapp_packet_ai_hardening_closure.sql.

select plan(28);

select has_function(
  'public',
  'whatsapp_persist_packet_ai_interpretation_governed',
  array['uuid','text','text[]','jsonb','text','uuid','text','text','text','text','text','uuid','uuid','bigint'],
  'governed interpretation persistence RPC exists'
);
select has_function(
  'public',
  'whatsapp_require_packet_ai_dispatch_lease',
  array['uuid','uuid','bigint'],
  'dispatch lease requirement helper exists'
);
select has_column(
  'public',
  'whatsapp_packet_ai_interpretations',
  'knowledge_snapshot_content_checksum',
  'interpretations pin knowledge checksum provenance'
);
select isnt_empty(
  $$select 1 from pg_trigger
    where tgrelid = 'public.whatsapp_intelligence_knowledge_snapshots'::regclass
      and tgname = 'whatsapp_intelligence_snapshot_content_immutable'
      and (tgtype & 4) <> 0$$,
  'knowledge snapshot guard runs on INSERT and UPDATE'
);

insert into auth.users(id, email) values
  ('86300000-0000-0000-0000-000000000001', 'hardening-admin@example.test');

select throws_ok(
  $$insert into public.whatsapp_intelligence_knowledge_snapshots(
    schema_version, lifecycle, knowledge, content_checksum
  ) values (
    'wa-knowledge/v1', 'ACTIVE', '{"rules":[]}'::jsonb,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  )$$,
  '42501',
  'knowledge activation must use governed activation RPC',
  'direct ACTIVE insert is blocked'
);

select lives_ok(
  $$insert into public.whatsapp_intelligence_knowledge_snapshots(
    schema_version, lifecycle, knowledge, content_checksum, created_by
  ) values (
    'wa-knowledge/v1', 'DRAFT', '{"rules":["draft-only"]}'::jsonb,
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    '86300000-0000-0000-0000-000000000001'
  )$$,
  'DRAFT knowledge snapshot insert is permitted'
);

insert into public.whatsapp_intelligence_knowledge_snapshots(
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86300000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista":"Pista Bulbul"}}'::jsonb,
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  '86300000-0000-0000-0000-000000000001',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  '86300000-0000-0000-0000-000000000001', statement_timestamp()
);

insert into public.whatsapp_intelligence_knowledge_snapshots(
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86300000-0000-0000-0000-000000000011',
  'wa-knowledge/v2', 'APPROVED',
  '{"terminology":{"pista":"Pista Royale"}}'::jsonb,
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  '86300000-0000-0000-0000-000000000001',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  '86300000-0000-0000-0000-000000000001', statement_timestamp()
);

select lives_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot('86300000-0000-0000-0000-000000000010')$$,
  'first governed activation succeeds with no prior ACTIVE row'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id='86300000-0000-0000-0000-000000000010'),
  'ACTIVE',
  'first activation leaves exactly one ACTIVE snapshot'
);
select is(
  (select count(*)::integer from public.whatsapp_intelligence_knowledge_snapshots where lifecycle='ACTIVE'),
  1,
  'exactly one ACTIVE snapshot after first activation'
);

select lives_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot('86300000-0000-0000-0000-000000000011')$$,
  'second governed activation supersedes the previous ACTIVE snapshot'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id='86300000-0000-0000-0000-000000000010'),
  'SUPERSEDED',
  'prior ACTIVE snapshot is superseded'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id='86300000-0000-0000-0000-000000000011'),
  'ACTIVE',
  'newer approved snapshot becomes ACTIVE'
);
select is(
  (select count(*)::integer from public.whatsapp_intelligence_knowledge_snapshots where lifecycle='ACTIVE'),
  1,
  'exactly one ACTIVE snapshot remains after supersession'
);

insert into public.whatsapp_intelligence_knowledge_snapshots(
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  '86300000-0000-0000-0000-000000000012',
  'wa-knowledge/v3', 'APPROVED',
  '{"terminology":{"pista":"Pista Flag"}}'::jsonb,
  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  '86300000-0000-0000-0000-000000000001',
  '86300000-0000-0000-0000-000000000001', statement_timestamp(),
  '86300000-0000-0000-0000-000000000001', statement_timestamp()
);

select throws_ok(
$flag_reset$
do $inner$
begin
  perform public.whatsapp_activate_intelligence_knowledge_snapshot('86300000-0000-0000-0000-000000000012');
  update public.whatsapp_intelligence_knowledge_snapshots
  set lifecycle = 'ACTIVE'
  where id = '86300000-0000-0000-0000-000000000011';
end $inner$;
$flag_reset$,
  '42501',
  'knowledge activation must use governed activation RPC',
  'activation flag reset blocks direct ACTIVE mutation in same transaction'
);

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;

select throws_ok(
  $$update public.whatsapp_intelligence_knowledge_snapshots
    set lifecycle = 'ACTIVE'
    where id = '86300000-0000-0000-0000-000000000010'$$,
  '42501',
  'knowledge activation must use governed activation RPC',
  'direct ACTIVE update is blocked outside governed activation'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86300000-0000-0000-0000-000000000020', '919630000020', 'Hardening lease contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values
  ('86300000-0000-0000-0000-000000000021', '86300000-0000-0000-0000-000000000020',
   'inbound', 'text', '10 boxes', 'click2api', 'hardening-a', 'received',
   '2026-08-22 11:00:00', '2026-08-22 11:00:00'),
  ('86300000-0000-0000-0000-000000000022', '86300000-0000-0000-0000-000000000020',
   'inbound', 'text', '12 cartons', 'click2api', 'hardening-b', 'received',
   '2026-08-22 11:00:10', '2026-08-22 11:00:10');

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86300000-0000-0000-0000-000000000020',
    array['86300000-0000-0000-0000-000000000021'::uuid], 300)$$,
  'hardening packet A stitches atomically'
);
create temporary table hardening_claim as
  select * from public.claim_whatsapp_packet_ai_dispatch_job(120);
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86300000-0000-0000-0000-000000000020',
    array['86300000-0000-0000-0000-000000000022'::uuid], 300)$$,
  'hardening correction creates revision 2'
);

select throws_ok(
  $$select public.whatsapp_persist_packet_ai_interpretation_governed(
    (select packet_id from public.whatsapp_messages where id='86300000-0000-0000-0000-000000000021'),
    'fingerprint-stale',
    array['hardening-a'],
    '{"conclusion":{"summary":"x","recommended_action":"y"}}'::jsonb,
    'test-model',
    '86300000-0000-0000-0000-000000000011',
    'wa-knowledge/v2',
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
    'wa-packet-interpretation/v1',
    'wa-packet-policy/v1',
    'wa-resolver-policy/v1',
    (select id from hardening_claim),
    (select lease_token from hardening_claim),
  (select packet_revision from hardening_claim)
  )$$,
  '55000',
  null,
  'stale leased worker cannot persist interpretation after revision advance'
);

select throws_ok(
  $$select public.whatsapp_materialize_packet_ai_case(
    (select packet_id from public.whatsapp_messages where id='86300000-0000-0000-0000-000000000021'),
    '86300000-0000-0000-0000-000000000099',
    (select id from hardening_claim),
    (select lease_token from hardening_claim),
    (select packet_revision from hardening_claim)
  )$$,
  '55000',
  null,
  'stale leased worker cannot materialize case after revision advance'
);

select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.whatsapp_correlate_clarification_answer(uuid,text)'::regprocedure
      and pg_get_functiondef(oid) ~* '\mno compatible open clarification\M'$$,
  'zero compatible clarifications fail with explicit error text'
);
select isnt_empty(
  $$select 1 from pg_proc
    where oid = 'public.whatsapp_correlate_clarification_answer(uuid,text)'::regprocedure
      and pg_get_functiondef(oid) ~* '\mmultiple compatible clarifications\M'$$,
  'multiple compatible clarifications fail with explicit error text'
);

select * from finish();
rollback;
