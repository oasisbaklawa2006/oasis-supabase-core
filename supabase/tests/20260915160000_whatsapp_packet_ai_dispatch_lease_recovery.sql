begin;
-- Lease expiry reclaim and stale-token protection for packet AI dispatch outbox.
select plan(9);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86400000-0000-0000-0000-000000000001', '919640000001', 'Lease recovery contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86400000-0000-0000-0000-000000000011', '86400000-0000-0000-0000-000000000001',
  'inbound', 'text', '10 boxes', 'click2api', 'lease-recovery-a', 'received',
  '2026-09-15 10:00:00', '2026-09-15 10:00:00'
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86400000-0000-0000-0000-000000000001',
    array['86400000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'lease recovery fixture stitches one inbound packet'
);

create temporary table lease_claim_a as
  select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select isnt(
  (select id from lease_claim_a),
  null::uuid,
  'worker A claims the dispatch job'
);
select is(
  (select state from lease_claim_a),
  'LEASED',
  'worker A holds an active lease'
);

update public.whatsapp_packet_ai_dispatch_jobs
set lease_expires_at = statement_timestamp() - interval '1 second'
where id = (select id from lease_claim_a);

create temporary table lease_claim_b as
  select * from public.claim_whatsapp_packet_ai_dispatch_job(120);

select is(
  (select id from lease_claim_b),
  (select id from lease_claim_a),
  'worker B reclaims the same job after lease expiry'
);
select isnt(
  (select lease_token from lease_claim_b),
  (select lease_token from lease_claim_a),
  'worker B receives a new lease token'
);
select ok(
  not public.complete_whatsapp_packet_ai_dispatch_job(
    (select id from lease_claim_a),
    (select lease_token from lease_claim_a),
    (select packet_revision from lease_claim_a)
  ),
  'stale worker A token cannot complete the reclaimed job'
);
select ok(
  not public.retry_whatsapp_packet_ai_dispatch_job(
    (select id from lease_claim_a),
    (select lease_token from lease_claim_a),
    (select packet_revision from lease_claim_a),
    'stale_worker',
    'stale lease after expiry reclaim'
  ),
  'stale worker A token cannot retry/update the reclaimed job'
);

select is(
  (select state from public.whatsapp_packet_ai_dispatch_jobs where id = (select id from lease_claim_b)),
  'LEASED',
  'reclaimed job remains exclusively leased by worker B'
);
select is(
  (select id from public.claim_whatsapp_packet_ai_dispatch_job(120)),
  null::uuid,
  'concurrent claim cannot own the same job while an active lease exists'
);

select * from finish();
rollback;
