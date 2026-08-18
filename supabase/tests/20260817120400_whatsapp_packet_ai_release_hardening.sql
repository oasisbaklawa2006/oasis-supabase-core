-- Contract for 20260817120400_whatsapp_packet_ai_release_hardening.sql.
begin;
select plan(12);

select ok(
  has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','SELECT'),
  'authenticated retains read-only access to governed packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','INSERT'),
  'authenticated cannot insert packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','UPDATE'),
  'authenticated cannot update packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','DELETE'),
  'authenticated cannot delete packet AI interpretations'
);
select ok(
  not has_table_privilege('authenticated','public.whatsapp_packet_ai_interpretations','TRUNCATE'),
  'authenticated cannot bypass RLS and append-only triggers with truncate'
);
select is(
  (select column_default
     from information_schema.columns
    where table_schema='public'
      and table_name='whatsapp_packet_ai_interpretations'
      and column_name='provider_message_ids'),
  null::text,
  'provider_message_ids has no unreachable empty-array default'
);

insert into public.whatsapp_inbound_messages(
  id,provider_message_id,sender_phone,message_body,message_type,received_at,raw_payload
) values (
  '87120400-0000-0000-0000-000000000001',
  'wa-ai-replay-image',
  '919444444444',
  '[image attachment]',
  'image',
  '2026-08-17 12:04:00+00',
  '{"media_id":"release-hardening-test"}'::jsonb
);

select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    '87120400-0000-0000-0000-000000000001',
    null,
    null,
    null,
    1,
    true,
    '{"fail_open_media_review":true,"ingress_mode":"capture_only"}'::jsonb
  )$$,
  'capture-only bootstrap fixture is durable'
);

create temp table wa_release_hardening_before on commit drop as
select p.id as packet_id, p.version
  from public.whatsapp_commercial_packets p
  join public.whatsapp_commercial_evidence e on e.packet_id=p.id
 where e.provider_message_id='wa-ai-replay-image';

select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-ai-replay-image',
    'SUCCEEDED',
    'packet-ai-release-replay',
    '{"worker":"whatsapp-packet-ai-worker"}'::jsonb
  )$$,
  'first media completion attempt succeeds'
);

select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-ai-replay-image',
    'SUCCEEDED',
    'packet-ai-release-replay',
    '{"worker":"whatsapp-packet-ai-worker"}'::jsonb
  )$$,
  'exact media completion replay is accepted idempotently'
);

select is(
  (select count(*)
     from public.whatsapp_media_processing_events mpe
     join public.whatsapp_commercial_evidence e on e.id=mpe.evidence_id
    where e.provider_message_id='wa-ai-replay-image'
      and mpe.attempt_key='packet-ai-release-replay'),
  1::bigint,
  'exact replay creates only one immutable processing event'
);

select is(
  (select count(*)
     from public.whatsapp_packet_audit_log a
     join public.whatsapp_commercial_evidence e on e.packet_id=a.packet_id
    where e.provider_message_id='wa-ai-replay-image'
      and a.action='MEDIA_PROCESSING_SUCCEEDED'
      and a.evidence->>'attempt_key'='packet-ai-release-replay'),
  1::bigint,
  'exact replay appends only one media-processing audit event'
);

select is(
  (select p.version
     from public.whatsapp_commercial_packets p
     join public.whatsapp_commercial_evidence e on e.packet_id=p.id
    where e.provider_message_id='wa-ai-replay-image'),
  (select version + 1 from wa_release_hardening_before),
  'exact replay increments packet version only once'
);

select * from finish();
rollback;