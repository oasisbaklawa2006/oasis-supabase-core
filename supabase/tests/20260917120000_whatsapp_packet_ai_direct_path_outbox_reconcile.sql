begin;
select plan(6);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86500000-0000-0000-0000-000000000001', '919650000001', 'Direct path reconcile contact');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86500000-0000-0000-0000-000000000011', '86500000-0000-0000-0000-000000000001',
  'inbound', 'text', '25 boxes pistachio', 'click2api', 'direct-path-reconcile-a',
  'received', '2026-09-17 10:00:00', '2026-09-17 10:00:00'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86500000-0000-0000-0000-000000000001',
    array['86500000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'fixture stitches one inbound packet'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id = (
     select packet_id from public.whatsapp_messages
     where id = '86500000-0000-0000-0000-000000000011'
   )),
  'QUEUED',
  'dispatch job starts queued before direct worker reconciliation'
);

select ok(
  not public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from public.whatsapp_messages
     where id = '86500000-0000-0000-0000-000000000011')
  ),
  'reconcile fails closed without interpretation evidence'
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version
) values (
  '86500000-0000-0000-0000-000000000099',
  (select packet_id from public.whatsapp_messages
   where id = '86500000-0000-0000-0000-000000000011'),
  'direct-path-fingerprint',
  array['direct-path-reconcile-a'],
  jsonb_build_object('intent', 'NEW_ORDER', 'summary', '25 boxes pistachio'),
  'gemini-test'
);

select ok(
  public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from public.whatsapp_messages
     where id = '86500000-0000-0000-0000-000000000011')
  ),
  'reconcile completes queued job once interpretation exists'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id = (
     select packet_id from public.whatsapp_messages
     where id = '86500000-0000-0000-0000-000000000011'
   )),
  'COMPLETED',
  'dispatch job reaches completed terminal state'
);

select ok(
  public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from public.whatsapp_messages
     where id = '86500000-0000-0000-0000-000000000011')
  ),
  'reconcile is idempotent for already completed jobs'
);

select * from finish();
rollback;
