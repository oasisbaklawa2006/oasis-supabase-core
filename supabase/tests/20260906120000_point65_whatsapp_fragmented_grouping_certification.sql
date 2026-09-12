-- POINT65 — fragmented WhatsApp message grouping canonical closure certification.
-- Synthetic fixtures only; no protected corpus; no migration; grouping lane only
-- (Point66 sender identity, Point67 draft extraction, Point68 review remain separate).
begin;
select plan(37);

-- ---------------------------------------------------------------------------
-- CENSUS: canonical grouping surfaces exist and are not client-mutable
-- ---------------------------------------------------------------------------
select has_function('public', 'stitch_whatsapp_messages_atomic', array['uuid', 'uuid[]', 'integer']);
select has_function('public', 'capture_whatsapp_commercial_fragment', array['uuid', 'uuid', 'text', 'uuid', 'integer', 'boolean', 'jsonb']);
select ok(
  exists(select 1 from pg_indexes where schemaname = 'public' and indexname = 'whatsapp_messages_provider_message_unique'),
  'CENSUS: provider_message_id idempotency index exists on whatsapp_messages'
);
select is_empty(
  $$select 1 from information_schema.role_routine_grants
    where routine_schema = 'public'
      and routine_name = 'stitch_whatsapp_messages_atomic'
      and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'CENSUS: stitch_whatsapp_messages_atomic is service-only'
);
select is_empty(
  $$select 1 from information_schema.role_routine_grants
    where routine_schema = 'public'
      and routine_name = 'capture_whatsapp_commercial_fragment'
      and grantee in ('PUBLIC', 'anon', 'authenticated')$$,
  'CENSUS: capture_whatsapp_commercial_fragment is service-only'
);

-- ---------------------------------------------------------------------------
-- Shared synthetic fixtures (86500000 namespace)
-- ---------------------------------------------------------------------------
insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('86500000-0000-0000-0000-000000000001', '919650000001', 'P65 Contact A'),
  ('86500000-0000-0000-0000-000000000002', '919650000002', 'P65 Contact B');

insert into public.whatsapp_messages (
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values
  ('86500000-0000-0000-0000-000000000011', '86500000-0000-0000-0000-000000000001', 'inbound', 'text', 'send pistachio', 'click2api', 'p65-stitch-a', 'received', '2026-09-06 10:00:00', '2026-09-06 10:00:00'),
  ('86500000-0000-0000-0000-000000000012', '86500000-0000-0000-0000-000000000001', 'inbound', 'text', '5 cartons', 'click2api', 'p65-stitch-b', 'received', '2026-09-06 10:00:05', '2026-09-06 10:00:05'),
  ('86500000-0000-0000-0000-000000000013', '86500000-0000-0000-0000-000000000001', 'inbound', 'image', '[image attachment]', 'click2api', 'p65-stitch-media', 'received', '2026-09-06 10:00:08', '2026-09-06 10:00:08'),
  ('86500000-0000-0000-0000-000000000014', '86500000-0000-0000-0000-000000000001', 'inbound', 'text', 'ok thanks', 'click2api', 'p65-stitch-nonorder', 'received', '2026-09-06 10:00:12', '2026-09-06 10:00:12'),
  ('86500000-0000-0000-0000-000000000015', '86500000-0000-0000-0000-000000000001', 'inbound', 'text', 'not 5, make it 6 cartons', 'click2api', 'p65-stitch-correct', 'received', '2026-09-06 10:00:15', '2026-09-06 10:00:15'),
  ('86500000-0000-0000-0000-000000000016', '86500000-0000-0000-0000-000000000001', 'inbound', 'text', 'later session order', 'click2api', 'p65-stitch-later', 'received', '2026-09-06 10:10:00', '2026-09-06 10:10:00'),
  ('86500000-0000-0000-0000-000000000017', '86500000-0000-0000-0000-000000000002', 'inbound', 'text', 'other customer order', 'click2api', 'p65-stitch-other', 'received', '2026-09-06 10:00:20', '2026-09-06 10:00:20');

insert into public.whatsapp_inbound_messages (
  id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
) values
  ('86500000-0000-0000-0000-000000000021', 'p65-wa4-first', '919650000001', 'send cashew', 'text', '2026-09-06 11:00:00+00', '{"kind":"fragment"}'),
  ('86500000-0000-0000-0000-000000000022', 'p65-wa4-later', '919650000001', '3 cartons', 'text', '2026-09-06 11:00:03+00', '{"kind":"later"}'),
  ('86500000-0000-0000-0000-000000000023', 'p65-wa4-correct', '919650000001', 'not 3, make it 4 cartons', 'text', '2026-09-06 11:00:05+00', '{"kind":"correction"}'),
  ('86500000-0000-0000-0000-000000000024', 'p65-wa4-nonorder', '919650000001', 'payment sent', 'text', '2026-09-06 11:00:04+00', '{"commercial_eligible":false}'),
  ('86500000-0000-0000-0000-000000000025', 'p65-wa4-second', '919650000001', 'send almond 2 cartons', 'text', '2026-09-06 11:00:07+00', '{}'),
  ('86500000-0000-0000-0000-000000000026', 'p65-wa4-other', '919650000002', 'join wrong packet', 'text', '2026-09-06 11:00:08+00', '{}');

-- ---------------------------------------------------------------------------
-- FLOW1: fragmented text + media references stitch deterministically (Core RPC)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000011'::uuid, '86500000-0000-0000-0000-000000000012'::uuid],
    300
  )$$,
  'FLOW1: fragmented text batch stitches atomically'
);
select is(
  (select count(distinct packet_id) from public.whatsapp_messages
    where id in ('86500000-0000-0000-0000-000000000011', '86500000-0000-0000-0000-000000000012')),
  1::bigint,
  'FLOW1: fragmented text shares exactly one stitch packet'
);
select is(
  (select array_agg(id order by packet_sequence)
   from public.whatsapp_messages
   where id in ('86500000-0000-0000-0000-000000000011', '86500000-0000-0000-0000-000000000012')),
  array['86500000-0000-0000-0000-000000000011'::uuid, '86500000-0000-0000-0000-000000000012'::uuid],
  'FLOW1: packet_sequence preserves chronology without inference'
);
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000013'::uuid],
    300
  )$$,
  'FLOW1: media reference fragment appends to open stitch packet'
);
select is(
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000013'),
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011'),
  'FLOW1: media fragment joins same stitch packet as prior text fragments'
);

-- ---------------------------------------------------------------------------
-- FLOW2: WA4 explicit conversation-key grouping (no time-proximity inference)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment('86500000-0000-0000-0000-000000000021', null, 'p65-wa4-first', null, 0, false, '{}')$$,
  'FLOW2: first WA4 fragment creates isolated packet'
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment('86500000-0000-0000-0000-000000000022', null, 'p65-wa4-first', null, 0, false, '{}')$$,
  'FLOW2: later fragment with explicit conversation key stitches'
);
select is(
  (select count(distinct packet_id) from public.whatsapp_commercial_evidence
    where provider_message_id in ('p65-wa4-first', 'p65-wa4-later')),
  1::bigint,
  'FLOW2: fragmented WA4 messages share exactly one commercial packet'
);
select is(
  (select array_agg(provider_message_id order by deterministic_sequence)
   from public.whatsapp_commercial_evidence
   where provider_message_id in ('p65-wa4-first', 'p65-wa4-later')),
  array['p65-wa4-first', 'p65-wa4-later']::text[],
  'FLOW2: WA4 deterministic_sequence preserves arrival lineage'
);

-- ---------------------------------------------------------------------------
-- FLOW3: correction / supersession linkage (both stitch and WA4 paths)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    '86500000-0000-0000-0000-000000000023', null, 'p65-wa4-later',
    '86500000-0000-0000-0000-000000000022', 0, false, '{"kind":"correction"}'
  )$$,
  'FLOW3: WA4 correction joins packet via reply source linkage'
);
select is(
  (select correction_of_source_message_id from public.whatsapp_commercial_evidence where provider_message_id = 'p65-wa4-correct'),
  '86500000-0000-0000-0000-000000000022'::uuid,
  'FLOW3: WA4 correction retains immutable prior source message id'
);
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000015'::uuid],
    300
  )$$,
  'FLOW3: stitch correction appends to same open packet'
);
select is(
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000015'),
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011'),
  'FLOW3: stitch correction does not split commercial instruction across packets'
);

-- ---------------------------------------------------------------------------
-- FLOW4: intervening non-order messages — stitch chronology vs WA4 isolation
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000014'::uuid],
    300
  )$$,
  'FLOW4: intervening non-order message stitches at contact+window layer'
);
select is(
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000014'),
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011'),
  'FLOW4: stitch layer preserves chronology including non-order fragments'
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment('86500000-0000-0000-0000-000000000024', null, null, null, 0, false, '{}')$$,
  'FLOW4: WA4 non-order without conversation key stays isolated'
);
select isnt(
  (select packet_id from public.whatsapp_commercial_evidence where provider_message_id = 'p65-wa4-nonorder'),
  (select packet_id from public.whatsapp_commercial_evidence where provider_message_id = 'p65-wa4-first'),
  'FLOW4: WA4 commercial grouping does not infer from intervening non-order'
);

-- ---------------------------------------------------------------------------
-- FLOW5: session / timeout boundary isolation
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000016'::uuid],
    300
  )$$,
  'FLOW5: message outside 300s window starts new stitch packet'
);
select isnt(
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000016'),
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011'),
  'FLOW5: session boundary isolates unrelated commercial instructions'
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment('86500000-0000-0000-0000-000000000025', null, null, null, 0, false, '{}')$$,
  'FLOW5: WA4 distinct intent without conversation key creates separate packet'
);
select is(
  (select count(distinct potential_order_id) from public.whatsapp_commercial_evidence
    where provider_message_id in ('p65-wa4-first', 'p65-wa4-second')),
  2::bigint,
  'FLOW5: WA4 same-sender distinct intents remain separate potential orders'
);

-- ---------------------------------------------------------------------------
-- FLOW6: duplicate replay and idempotency
-- ---------------------------------------------------------------------------
select throws_ok(
  $$insert into public.whatsapp_messages (
    contact_id, direction, message_type, content, provider, provider_message_id, status
  ) values (
    '86500000-0000-0000-0000-000000000001', 'inbound', 'text', 'duplicate', 'click2api', 'p65-stitch-a', 'received'
  )$$,
  '23505',
  null,
  'FLOW6: provider retry cannot create duplicate raw stitch row'
);
select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000011'::uuid, '86500000-0000-0000-0000-000000000012'::uuid],
    300
  )$$,
  'FLOW6: exact stitch replay is idempotent'
);
select is(
  (select fragment_count from public.whatsapp_message_packets
    where id = (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011')),
  5::integer,
  'FLOW6: stitch replay does not double-count fragments'
);
select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment('86500000-0000-0000-0000-000000000021', null, 'different', null, 9, true, '{"replay":true}')$$,
  'FLOW6: WA4 provider replay is idempotent despite changed payload'
);
select is(
  (select count(*) from public.whatsapp_commercial_evidence where provider_message_id = 'p65-wa4-first'),
  1::bigint,
  'FLOW6: WA4 replay creates no duplicate evidence'
);

-- ---------------------------------------------------------------------------
-- FLOW7: cross-sender / cross-conversation isolation
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000017'::uuid],
    300
  )$$,
  'WA_PACKET_MESSAGE_SCOPE_MISMATCH',
  'FLOW7: cross-contact stitch batch fails closed'
);
select is(
  (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000017'),
  null::uuid,
  'FLOW7: cross-contact failure leaves source message unstitched'
);
select throws_ok(
  format(
    $$select public.capture_whatsapp_commercial_fragment(
      '86500000-0000-0000-0000-000000000026', '%s', null, null, 0, false, '{}'
    )$$,
    (select packet_id from public.whatsapp_commercial_evidence where provider_message_id = 'p65-wa4-first')
  ),
  'WA4_PACKET_BOUNDARY_MISMATCH',
  'FLOW7: cross-customer WA4 explicit stitch fails closed'
);

-- ---------------------------------------------------------------------------
-- BOUNDARY: grouping lane does not infer SKU/quantity/customer identity
-- ---------------------------------------------------------------------------
select ok(
  (select order_id is null from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011'),
  'BOUNDARY: stitch grouping does not assign order_id'
);
select ok(
  position('pistachio' in (select stitched_content->>'text' from public.whatsapp_message_packets
    where id = (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011'))) > 0
  and position('sku' in lower((select stitched_content::text from public.whatsapp_message_packets
    where id = (select packet_id from public.whatsapp_messages where id = '86500000-0000-0000-0000-000000000011')))) = 0,
  'BOUNDARY: stitch content preserves raw text only without SKU inference'
);
select ok(
  (select original_body from public.whatsapp_commercial_evidence where provider_message_id = 'p65-wa4-first')
    = 'send cashew',
  'BOUNDARY: WA4 evidence preserves verbatim original_body without extraction'
);

select * from finish();
rollback;
