-- Contract coverage for migration: 20260917140000_whatsapp_packet_ai_direct_consumer_race_hardening.sql
-- Gate 6 keeps the legacy packet-scoped claim retired and consumes evidence
-- produced by scripts/test-whatsapp-packet-ai-claim-two-session-race.sh.
begin;
select plan(6);

insert into public.whatsapp_contacts(id, phone_number, customer_name) values
  ('86511000-0000-0000-0000-000000000001', '919651100001', 'Direct path retired contact');
insert into public.whatsapp_messages(
  id, contact_id, direction, message_type, content, provider, provider_message_id,
  status, message_timestamp, created_at
) values (
  '86511000-0000-0000-0000-000000000011', '86511000-0000-0000-0000-000000000001',
  'inbound', 'text', 'direct path retired', 'click2api', 'direct-retired-a', 'received',
  statement_timestamp(), statement_timestamp()
);

select lives_ok(
  $$select public.stitch_whatsapp_messages_atomic(
    '86511000-0000-0000-0000-000000000001',
    array['86511000-0000-0000-0000-000000000011'::uuid], 300)$$,
  'fixture packet exists for direct-path retirement check'
);

select is(
  (select public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
    (select packet_id from public.whatsapp_messages where id = '86511000-0000-0000-0000-000000000011'),
    120
  )),
  null::public.whatsapp_packet_ai_dispatch_jobs,
  'Gate 6 retires legacy direct packet-scoped dispatch claim'
);

select ok(
  to_regclass('public.wa_packet_ai_claim_race_evidence') is not null,
  'two-session canonical claim harness recorded evidence before pgTAP assertions'
);

select is(
  (
    select competitor_id
    from public.wa_packet_ai_claim_race_evidence
    where scenario='canonical_claim_skip_locked'
  ),
  null::uuid,
  'concurrent session B cannot claim the row while session A holds its lease transaction'
);

select is(
  (
    select winner_id
    from public.wa_packet_ai_claim_race_evidence
    where scenario='canonical_claim_skip_locked'
  ),
  '86511400-0000-0000-0000-000000000020'::uuid,
  'session A is the sole concurrent claimant'
);

select ok(
  (
    select final_state='LEASED'
      and attempt_count=1
      and lease_token_present
    from public.wa_packet_ai_claim_race_evidence
    where scenario='canonical_claim_skip_locked'
  ),
  'race evidence proves exactly one lease and one attempt'
);

select * from finish();
rollback;
