-- Contract for 20260817120200_whatsapp_media_completion_append_only_fix.sql.
begin;
select plan(6);

insert into public.whatsapp_inbound_messages(
  id,provider_message_id,sender_phone,message_body,message_type,received_at,raw_payload
) values (
  '87120200-0000-0000-0000-000000000001',
  'wa-ai-success-image',
  '919333333333',
  '[image attachment]',
  'image',
  '2026-08-17 12:02:00+00',
  '{"media_id":"staging-test"}'::jsonb
);

select lives_ok(
  $$select public.capture_whatsapp_commercial_fragment(
    '87120200-0000-0000-0000-000000000001',
    null,
    null,
    null,
    1,
    true,
    '{"fail_open_media_review":true,"ingress_mode":"capture_only"}'::jsonb
  )$$,
  'capture-only media bootstrap remains durable and fail-open to human review'
);

select is(
  (select processing_state from public.whatsapp_commercial_evidence where provider_message_id='wa-ai-success-image'),
  'UNREADABLE',
  'immutable source evidence retains its original bootstrap processing marker'
);

select lives_ok(
  $$select public.complete_whatsapp_media_processing(
    'wa-ai-success-image',
    'SUCCEEDED',
    'packet-ai-success-1',
    '{"worker":"whatsapp-packet-ai-worker"}'::jsonb
  )$$,
  'successful AI media outcome appends without mutating source evidence'
);

select is(
  (select processing_state from public.whatsapp_commercial_evidence where provider_message_id='wa-ai-success-image'),
  'UNREADABLE',
  'successful processing never overwrites immutable commercial evidence'
);

select is(
  (select state from public.whatsapp_media_processing_events mpe
     join public.whatsapp_commercial_evidence e on e.id=mpe.evidence_id
    where e.provider_message_id='wa-ai-success-image'
    order by mpe.id desc limit 1),
  'SUCCEEDED',
  'successful media outcome is recorded in append-only processing history'
);

select is(
  (select p.state from public.whatsapp_potential_orders p
     join public.whatsapp_commercial_evidence e on e.potential_order_id=p.id
    where e.provider_message_id='wa-ai-success-image'),
  'UNASSIGNED',
  'only a proven successful fail-open bootstrap is recovered for human assignment'
);

select * from finish();
rollback;
