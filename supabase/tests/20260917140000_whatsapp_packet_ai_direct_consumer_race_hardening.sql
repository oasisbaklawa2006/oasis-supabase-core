begin;
select plan(14);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86600000-0000-0000-0000-000000000001', '919660000001', 'Race hardening contact');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86600000-0000-0000-0000-000000000011', '86600000-0000-0000-0000-000000000001',
  'inbound', 'text', 'race packet one', 'click2api', 'race-hardening-a',
  'received', '2026-09-17 11:00:00', '2026-09-17 11:00:00'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86600000-0000-0000-0000-000000000001',
    array['86600000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'race fixture stitches packet'
);

create temporary table race_packet as
  select packet_id::uuid as packet_id
  from public.whatsapp_messages
  where id = '86600000-0000-0000-0000-000000000011';

select has_function(
  'public',
  'claim_whatsapp_packet_ai_dispatch_job_for_packet',
  array['uuid', 'integer'],
  'packet-scoped claim RPC exists'
);

create temporary table race_claim_a as
  select * from public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
    (select packet_id from race_packet), 120
  );

select isnt(
  (select id from race_claim_a),
  null::uuid,
  'worker A claims packet-scoped dispatch job'
);
select is(
  (select state from race_claim_a),
  'LEASED',
  'worker A holds active lease'
);

select is(
  (select id from public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
    (select packet_id from race_packet), 120
  )),
  null::uuid,
  'worker B cannot claim while worker A lease is active'
);

select ok(
  not public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from race_packet)
  ),
  'reconcile cannot complete an actively leased job without interpretation'
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version
) values (
  '86600000-0000-0000-0000-000000000099',
  (select packet_id from race_packet),
  'race-fingerprint',
  array['race-hardening-a'],
  jsonb_build_object('intent', 'ENQUIRY', 'summary', 'race packet one'),
  'gemini-test'
);

select ok(
  not public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from race_packet)
  ),
  'reconcile still blocked while lease is active even if interpretation exists'
);

update public.whatsapp_packet_ai_dispatch_jobs
set
  state = 'QUEUED',
  claimed_at = null,
  lease_expires_at = null,
  lease_token = null
where packet_id = (select packet_id from race_packet);

select ok(
  public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from race_packet)
  ),
  'reconcile completes queued job once interpretation exists and lease is clear'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs
   where packet_id = (select packet_id from race_packet)),
  'COMPLETED',
  'reconciled job reaches completed terminal state'
);

-- Superseded revision must not reconcile against current packet authority.
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at, packet_id, packet_sequence
) values (
  '86600000-0000-0000-0000-000000000012', '86600000-0000-0000-0000-000000000001',
  'inbound', 'text', 'race correction', 'click2api', 'race-hardening-b',
  'received', '2026-09-17 11:01:00', '2026-09-17 11:01:00',
  (select packet_id from race_packet), 2
);

update public.whatsapp_packet_ai_dispatch_jobs
set state = 'QUEUED', packet_revision = 1, completed_at = null
where packet_id = (select packet_id from race_packet);

select ok(
  not public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from race_packet)
  ),
  'reconcile fails closed when job revision is superseded by packet restitch'
);

-- Window 1: interpretation stored, dispatch still queued, safe recovery without duplicate AI row.
insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86600000-0000-0000-0000-000000000002', '919660000002', 'Crash window contact');

insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86600000-0000-0000-0000-000000000021', '86600000-0000-0000-0000-000000000002',
  'inbound', 'text', 'crash window', 'click2api', 'race-hardening-crash',
  'received', '2026-09-17 11:05:00', '2026-09-17 11:05:00'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86600000-0000-0000-0000-000000000002',
    array['86600000-0000-0000-0000-000000000021'::uuid], 300)$$,
  'crash window fixture stitches packet'
);

insert into public.whatsapp_packet_ai_interpretations(
  id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version
) values (
  '86600000-0000-0000-0000-000000000199',
  (select packet_id from public.whatsapp_messages where id = '86600000-0000-0000-0000-000000000021'),
  'crash-fingerprint',
  array['race-hardening-crash'],
  jsonb_build_object('intent', 'OTHER', 'summary', 'crash window'),
  'gemini-test'
);

select is(
  (select count(*) from public.whatsapp_packet_ai_interpretations
   where packet_id = (
     select packet_id from public.whatsapp_messages
     where id = '86600000-0000-0000-0000-000000000021'
   )),
  1::bigint,
  'window 1 keeps a single interpretation row before reconcile'
);

select ok(
  public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
    (select packet_id from public.whatsapp_messages where id = '86600000-0000-0000-0000-000000000021')
  ),
  'window 1 recovery completes dispatch without requiring another interpretation insert'
);

select is(
  (select count(*) from public.whatsapp_packet_ai_interpretations
   where packet_id = (
     select packet_id from public.whatsapp_messages
     where id = '86600000-0000-0000-0000-000000000021'
   )),
  1::bigint,
  'window 1 recovery does not duplicate interpretation authority'
);

select * from finish();
rollback;
