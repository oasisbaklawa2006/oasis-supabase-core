-- Contract coverage for 20260829070000_wa_noncommercial_media_completion.sql.
begin;
select plan(9);

select has_function(
  'public',
  'complete_whatsapp_media_processing',
  array['text','text','text','jsonb'],
  'media completion RPC exists'
);

-- Explicitly noncommercial media is processed by the packet AI worker but
-- intentionally has no whatsapp_commercial_evidence row. This must not turn a
-- complaint/payment image into a worker failure.
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
) values (
  'e2900000-0000-0000-0000-000000000001',
  'wa-s1b-noncommercial-media',
  '919955550001',
  '[unreadable image attachment]',
  'image',
  statement_timestamp(),
  '{"studio_fanout":true,"commercial_eligible":false,"commercial_risk_reason":null}'::jsonb
);

select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1b-noncommercial-media',
    'SUCCEEDED',
    'packet-ai:noncommercial',
    '{"worker":"whatsapp-packet-ai-worker"}'::jsonb
  )$$,
  'explicit noncommercial media without commercial evidence does not fail worker completion'
);

select is(
  (select count(*) from public.whatsapp_commercial_evidence where provider_message_id='wa-s1b-noncommercial-media'),
  0::bigint,
  'noncommercial media completion does not invent commercial evidence'
);

select is(
  (select count(*) from public.whatsapp_media_processing_events mpe
    join public.whatsapp_commercial_evidence e on e.id=mpe.evidence_id
   where e.provider_message_id='wa-s1b-noncommercial-media'),
  0::bigint,
  'noncommercial media completion creates no commercial media event'
);

-- Commercial provenance with missing evidence remains fail-closed. This is
-- essential: a broken commercial fan-out must never be silently treated as a
-- harmless non-order message.
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
) values (
  'e2900000-0000-0000-0000-000000000002',
  'wa-s1b-commercial-missing-evidence',
  '919955550002',
  '[unreadable image attachment]',
  'image',
  statement_timestamp(),
  '{"studio_fanout":true,"commercial_eligible":true,"commercial_risk_reason":"ORDER_KEYWORD"}'::jsonb
);

select throws_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1b-commercial-missing-evidence','SUCCEEDED','packet-ai:commercial-missing','{}'::jsonb
  )$$,
  'WA4_EVIDENCE_NOT_FOUND',
  'commercial media missing its evidence row remains fail-closed'
);

-- Missing/ambiguous provenance also remains fail-closed.
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
) values (
  'e2900000-0000-0000-0000-000000000003',
  'wa-s1b-unknown-missing-evidence',
  '919955550003',
  '[unreadable image attachment]',
  'image',
  statement_timestamp(),
  '{}'::jsonb
);

select throws_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1b-unknown-missing-evidence','SUCCEEDED','packet-ai:unknown-missing','{}'::jsonb
  )$$,
  'WA4_EVIDENCE_NOT_FOUND',
  'missing commercial provenance cannot bypass evidence requirements'
);

-- Existing commercial media behavior must remain unchanged.
insert into public.whatsapp_inbound_messages(
  id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
) values (
  'e2900000-0000-0000-0000-000000000004',
  'wa-s1b-commercial-valid',
  '919955550004',
  '[unreadable image attachment]',
  'image',
  statement_timestamp(),
  '{"studio_fanout":true,"commercial_eligible":true,"commercial_risk_reason":"ORDER_KEYWORD"}'::jsonb
);

select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    'e2900000-0000-0000-0000-000000000004',
    null,
    'wa-s1b-commercial-valid',
    null,
    1,
    false,
    '{"fail_open_media_review":true}'::jsonb
  )$$,
  'commercial media evidence still captures normally'
);

select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-s1b-commercial-valid',
    'SUCCEEDED',
    'packet-ai:commercial-valid',
    '{"worker":"whatsapp-packet-ai-worker"}'::jsonb
  )$$,
  'commercial media completion still persists normally'
);

select is(
  (select count(*) from public.whatsapp_media_processing_events mpe
    join public.whatsapp_commercial_evidence e on e.id=mpe.evidence_id
   where e.provider_message_id='wa-s1b-commercial-valid'
     and mpe.state='SUCCEEDED'),
  1::bigint,
  'commercial media retains its governed SUCCEEDED event'
);

select * from finish(); -- skipcq (pgTAP finish returns setof text)
rollback;
