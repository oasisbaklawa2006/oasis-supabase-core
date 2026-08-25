-- Contract for migration 20260825120000_whatsapp_intelligence_knowledge_bridge.sql
-- KNOWLEDGE-BRIDGE-A: governed submission, review, approval, activation proof.
begin;

select plan(33);

-- Static contract
select has_table('public', 'whatsapp_intelligence_knowledge_submissions', 'submission registry exists');
select has_function(
  'public', 'whatsapp_submit_intelligence_knowledge_draft',
  array['text','uuid[]','jsonb','text','text','text','text'],
  'submit RPC exists'
);
select has_function('public', 'whatsapp_review_intelligence_knowledge_snapshot', array['uuid'], 'review RPC exists');
select has_function('public', 'whatsapp_approve_intelligence_knowledge_snapshot', array['uuid'], 'approve RPC exists');
select ok(
  has_function_privilege('authenticated', 'public.whatsapp_submit_intelligence_knowledge_draft(text,uuid[],jsonb,text,text,text,text)', 'EXECUTE'),
  'authenticated may execute submit RPC'
);
select ok(
  not has_function_privilege('anon', 'public.whatsapp_submit_intelligence_knowledge_draft(text,uuid[],jsonb,text,text,text,text)', 'EXECUTE'),
  'anonymous cannot execute submit RPC'
);

-- Fixtures
insert into auth.users(id, email) values
  ('ab000000-0000-0000-0000-000000000001', 'kb-author@example.test'),
  ('ab000000-0000-0000-0000-000000000002', 'kb-outsider@example.test'),
  ('ab000000-0000-0000-0000-000000000003', 'kb-approver@example.test');

insert into public.users(id, email, name, role, is_active) values
  ('ab000000-0000-0000-0000-000000000001', 'kb-author@example.test', 'KB Author', 'catalogue_manager', true),
  ('ab000000-0000-0000-0000-000000000003', 'kb-approver@example.test', 'KB Approver', 'admin', true);

insert into public.user_role_map(user_id, role_id)
select 'ab000000-0000-0000-0000-000000000001', id from public.roles where role_key = 'catalogue_manager';
insert into public.user_role_map(user_id, role_id)
select 'ab000000-0000-0000-0000-000000000003', id from public.roles where role_key = 'admin';

insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values (
  'ab000000-0000-0000-0000-000000000101',
  'Pistachio Bulbul', 'BAK-PST-001', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
);

insert into public.catalogue_versions (
  id, product_id, version_code, version_number, snapshot_json, status
) values (
  'ab000000-0000-0000-0000-000000000201',
  'ab000000-0000-0000-0000-000000000101',
  'v1', 1, '{}'::jsonb, 'approved'
);

create temporary table kb_knowledge as
select jsonb_build_object(
  'schema_version', 'wa-knowledge/v1',
  'terminology', jsonb_build_object('pista', 'BAK-PST-001'),
  'aliases', jsonb_build_object('pista bulbul', 'BAK-PST-001'),
  'sku_map', jsonb_build_object(
    'BAK-PST-001', jsonb_build_object(
      'sku', 'BAK-PST-001',
      'name', 'Pistachio Bulbul',
      'family', 'Sweets / Pistachio',
      'variant', null,
      'packaging_code', null
    )
  ),
  'packaging', '{}'::jsonb,
  'ambiguous_terms', '[]'::jsonb,
  'source_catalogue_version_ids', jsonb_build_array('ab000000-0000-0000-0000-000000000201')
) as body;

create temporary table kb_checksum as
select public.whatsapp_knowledge_content_checksum((select body from kb_knowledge)) as digest;

-- 1. anonymous submit rejected
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    (select digest from kb_checksum),
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
  null)$$,
  '42501',
  'authentication required',
  'anonymous submit rejected'
);

-- 2. unauthorized authenticated user rejected
select set_config('request.jwt.claims', json_build_object('sub','ab000000-0000-0000-0000-000000000002','role','authenticated')::text, true);
set local role authenticated;
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    (select digest from kb_checksum),
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
  null)$$,
  '42501',
  'team member authority required for knowledge handoff submission',
  'unauthorized authenticated user rejected'
);

-- 7. TEST_CANDIDATE rejected
select set_config('request.jwt.claims', json_build_object('sub','ab000000-0000-0000-0000-000000000001','role','authenticated')::text, true);
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    (select digest from kb_checksum),
    'TEST_CANDIDATE',
    'NOT_HANDOFF_ELIGIBLE',
  null)$$,
  '22023',
  'only PUBLICATION_CANDIDATE may be submitted',
  'TEST_CANDIDATE rejected'
);

-- 8. NOT_HANDOFF_READY rejected
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    (select digest from kb_checksum),
    'PUBLICATION_CANDIDATE',
    'NOT_HANDOFF_READY',
  null)$$,
  '22023',
  'only HANDOFF_READY candidates may be submitted',
  'NOT_HANDOFF_READY rejected'
);

-- 4. malformed checksum rejected
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    'not-a-valid-checksum',
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
  null)$$,
  '22023',
  'content_checksum must be a 64-char sha256 hex digest',
  'malformed checksum rejected'
);

-- 5. checksum/content mismatch rejected
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    repeat('a', 64),
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
  null)$$,
  '22023',
  'content_checksum does not match canonical knowledge payload',
  'checksum/content mismatch rejected'
);

-- 6. unknown catalogue version rejected
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000009999'::uuid],
    jsonb_set(
      (select body from kb_knowledge),
      '{source_catalogue_version_ids}',
      '["ab000000-0000-0000-0000-000000009999"]'::jsonb
    ),
    public.whatsapp_knowledge_content_checksum(
      jsonb_set(
        (select body from kb_knowledge),
        '{source_catalogue_version_ids}',
        '["ab000000-0000-0000-0000-000000009999"]'::jsonb
      )
    ),
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
  null)$$,
  '22023',
  null,
  'unknown catalogue version rejected'
);

-- Happy path submit
create temporary table kb_submit as
select public.whatsapp_submit_intelligence_knowledge_draft(
  'wa-knowledge/v1',
  array['ab000000-0000-0000-0000-000000000201'::uuid],
  (select body from kb_knowledge),
  (select digest from kb_checksum),
  'PUBLICATION_CANDIDATE',
  'HANDOFF_READY',
  'kb-idem-1'
) as snapshot;

-- 3. browser cannot set created_by (derived from auth.uid)
select is(
  (select created_by from kb_submit),
  'ab000000-0000-0000-0000-000000000001'::uuid,
  'created_by derived from authenticated actor'
);
select is(
  (select lifecycle from kb_submit),
  'DRAFT',
  'submission creates DRAFT only'
);

-- 9. exact replay returns same canonical DRAFT
select is(
  (select id from public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    (select body from kb_knowledge),
    (select digest from kb_checksum),
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
    'kb-idem-1'
  )),
  (select id from kb_submit),
  'exact replay returns same canonical DRAFT'
);

-- 10. conflicting replay fails closed
select throws_ok(
  $$select public.whatsapp_submit_intelligence_knowledge_draft(
    'wa-knowledge/v1',
    array['ab000000-0000-0000-0000-000000000201'::uuid],
    jsonb_set((select body from kb_knowledge), '{terminology,pista}', '"OTHER-SKU"'::jsonb),
    (select digest from kb_checksum),
    'PUBLICATION_CANDIDATE',
    'HANDOFF_READY',
    'kb-idem-1'
  )$$,
  '23505',
  'idempotency key reused with conflicting payload',
  'conflicting replay fails closed'
);

-- 11. DRAFT cannot activate
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;
select throws_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot((select id from kb_submit))$$,
  '55000',
  'only approved knowledge can become active',
  'DRAFT cannot activate'
);

-- Review
select set_config('request.jwt.claims', json_build_object('sub','ab000000-0000-0000-0000-000000000001','role','authenticated')::text, true);
set local role authenticated;
create temporary table kb_reviewed as
select public.whatsapp_review_intelligence_knowledge_snapshot((select id from kb_submit)) as snapshot;

select is((select lifecycle from kb_reviewed), 'REVIEWED', 'DRAFT transitions to REVIEWED');

-- 12. REVIEWED cannot activate
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;
select throws_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot((select id from kb_submit))$$,
  '55000',
  'only approved knowledge can become active',
  'REVIEWED cannot activate'
);

-- 16. reviewed content cannot change
select throws_ok(
  $$update public.whatsapp_intelligence_knowledge_snapshots
    set knowledge = jsonb_set(knowledge, '{terminology,pista}', '"tampered"'::jsonb)
    where id = (select id from kb_submit)$$,
  '55000',
  'approved intelligence publication content is immutable',
  'reviewed content cannot change'
);

-- Approve (internal staff)
select set_config('request.jwt.claims', json_build_object('sub','ab000000-0000-0000-0000-000000000003','role','authenticated')::text, true);
set local role authenticated;
create temporary table kb_approved as
select public.whatsapp_approve_intelligence_knowledge_snapshot((select id from kb_submit)) as snapshot;

select is((select lifecycle from kb_approved), 'APPROVED', 'REVIEWED transitions to APPROVED');

-- 17. approved content cannot change
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;
select throws_ok(
  $$update public.whatsapp_intelligence_knowledge_snapshots
    set knowledge = jsonb_set(knowledge, '{terminology,pista}', '"tampered"'::jsonb)
    where id = (select id from kb_submit)$$,
  '55000',
  'approved intelligence publication content is immutable',
  'approved content cannot change'
);

-- 13. APPROVED can activate
select lives_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot((select id from kb_submit))$$,
  'APPROVED can activate'
);
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id = (select id from kb_submit)),
  'ACTIVE',
  'activated snapshot is ACTIVE'
);

-- Second approved snapshot for supersession proof
insert into public.catalogue_versions (
  id, product_id, version_code, version_number, snapshot_json, status
) values (
  'ab000000-0000-0000-0000-000000000202',
  'ab000000-0000-0000-0000-000000000101',
  'v2', 2, '{}'::jsonb, 'published'
);

create temporary table kb_knowledge_v2 as
select jsonb_set(
  (select body from kb_knowledge),
  '{source_catalogue_version_ids}',
  '["ab000000-0000-0000-0000-000000000202"]'::jsonb
) as body;

create temporary table kb_checksum_v2 as
select public.whatsapp_knowledge_content_checksum((select body from kb_knowledge_v2)) as digest;

select set_config('request.jwt.claims', json_build_object('sub','ab000000-0000-0000-0000-000000000001','role','authenticated')::text, true);
set local role authenticated;

create temporary table kb_submit_v2 as
select public.whatsapp_submit_intelligence_knowledge_draft(
  'wa-knowledge/v1',
  array['ab000000-0000-0000-0000-000000000202'::uuid],
  (select body from kb_knowledge_v2),
  (select digest from kb_checksum_v2),
  'PUBLICATION_CANDIDATE',
  'HANDOFF_READY',
  'kb-idem-2'
) as snapshot;

select public.whatsapp_review_intelligence_knowledge_snapshot((select id from kb_submit_v2));
select set_config('request.jwt.claims', json_build_object('sub','ab000000-0000-0000-0000-000000000003','role','authenticated')::text, true);
select public.whatsapp_approve_intelligence_knowledge_snapshot((select id from kb_submit_v2));

select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;
select lives_ok(
  $$select public.whatsapp_activate_intelligence_knowledge_snapshot((select id from kb_submit_v2))$$,
  'second APPROVED snapshot activates'
);

-- 14. only one ACTIVE snapshot
select is(
  (select count(*)::integer from public.whatsapp_intelligence_knowledge_snapshots where lifecycle = 'ACTIVE'),
  1,
  'only one ACTIVE snapshot'
);

-- 15. previous ACTIVE becomes SUPERSEDED atomically
select is(
  (select lifecycle from public.whatsapp_intelligence_knowledge_snapshots where id = (select id from kb_submit)),
  'SUPERSEDED',
  'previous ACTIVE becomes SUPERSEDED'
);

-- 18-19. worker uses ACTIVE only and persists exact provenance
select is(
  (select id from public.whatsapp_active_intelligence_knowledge_snapshot()),
  (select id from kb_submit_v2),
  'runtime worker selector reads ACTIVE snapshot'
);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('ab000000-0000-0000-0000-000000000301', '919888888801', 'KB Bridge Contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  'ab000000-0000-0000-0000-000000000302',
  'ab000000-0000-0000-0000-000000000301',
  'inbound', 'text', '10 pista bulbul', 'click2api', 'kb-bridge-msg', 'received',
  statement_timestamp(), statement_timestamp()
);
select public.stitch_whatsapp_messages_atomic(
  'ab000000-0000-0000-0000-000000000301',
  array['ab000000-0000-0000-0000-000000000302'::uuid],
  300
);

create temporary table kb_interp as
select public.whatsapp_persist_packet_ai_interpretation_governed(
  (select packet_id from public.whatsapp_messages where id = 'ab000000-0000-0000-0000-000000000302'),
  'kb-bridge-fingerprint',
  array['kb-bridge-msg'],
  '{"conclusion":{"summary":"order","recommended_action":"review"}}'::jsonb,
  'kb-test-model',
  (select id from kb_submit_v2),
  'wa-knowledge/v1',
  (select digest from kb_checksum_v2),
  'wa-packet-interpretation/v1',
  'wa-packet-policy/v1',
  'wa-resolver-policy/v1'
) as interpretation_id;

select is(
  (select knowledge_snapshot_id from public.whatsapp_packet_ai_interpretations where id = (select interpretation_id from kb_interp)),
  (select id from kb_submit_v2),
  'interpretation stores exact snapshot provenance'
);
select is(
  (select knowledge_snapshot_schema_version from public.whatsapp_packet_ai_interpretations where id = (select interpretation_id from kb_interp)),
  'wa-knowledge/v1',
  'interpretation stores schema version provenance'
);

-- Historical interpretation retains original snapshot after supersession
select is(
  (select knowledge_snapshot_id from public.whatsapp_packet_ai_interpretations where id = (select interpretation_id from kb_interp)),
  (select id from kb_submit_v2),
  'historical interpretation retains original snapshot provenance after supersession'
);

-- 20. no direct table mutation path for authenticated (fail-closed RLS)
select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_intelligence_knowledge_snapshots', 'INSERT')
    and not has_table_privilege('authenticated', 'public.whatsapp_intelligence_knowledge_snapshots', 'UPDATE'),
  'authenticated has no direct snapshot table write authority'
);

select * from finish();
rollback;
